#!/usr/bin/env python3
"""OpenAI chat-completions proxy that hides model reasoning and redacts flags.

Sits between a client (the tt-studio console) and a vLLM OpenAI server. For a
POST to a /chat/completions path it forwards to the upstream, then on the way
back:

  - strips `reasoning_content` from every response (streaming and not), so a
    reasoning model's chain-of-thought never reaches the client, and
  - redacts anything shaped like a flag (default `Nix{...}`) from the answer,
    correctly even when a flag is split across streaming chunks.

The proxy never reads the flag itself; it hides the whole pattern. Every other
path and method passes straight through.
"""
import argparse
import json
import os
import re

import aiohttp
from aiohttp import web

REDACTED = "[REDACTED]"
# vLLM has used both names for a reasoning model's chain-of-thought, depending on
# version and parser. Strip every one so no build leaks the trace.
REASONING_FIELDS = ("reasoning_content", "reasoning", "reasoning_tokens")


class Redactor:
    """Streaming-safe pattern redactor. Feed content fragments; complete matches
    of OPENER..CLOSER are replaced, and any fragment that could still grow into a
    match (an unclosed opener, or a trailing prefix of the opener) is held back
    until the next fragment or the final flush."""

    def __init__(self, opener="Nix{", closer="}"):
        self.opener = opener
        self.closer = closer
        self.rx = re.compile(re.escape(opener) + "[^" + re.escape(closer) + "]*" + re.escape(closer))
        self.hold = ""

    def _hold_from(self, buf):
        idx = buf.rfind(self.opener)
        if idx != -1 and self.closer not in buf[idx + len(self.opener):]:
            return idx  # unclosed opener: everything from here may still complete
        for k in range(min(len(self.opener) - 1, len(buf)), 0, -1):
            if buf.endswith(self.opener[:k]):
                return len(buf) - k  # trailing prefix of the opener
        return len(buf)

    def feed(self, fragment):
        if not fragment:
            return ""
        self.hold += fragment
        i = self._hold_from(self.hold)
        safe, self.hold = self.hold[:i], self.hold[i:]
        return self.rx.sub(REDACTED, safe)

    def flush(self):
        out = self.rx.sub(REDACTED, self.hold)
        di = out.rfind(self.opener)
        if di != -1 and self.closer not in out[di + len(self.opener):]:
            out = out[:di] + REDACTED  # dangling opener at end of stream
        self.hold = ""
        return out


def transform_chunk(payload, strip_reasoning, red):
    """Transform one SSE data payload (text after 'data: '). Returns the new
    payload string, or None to drop it."""
    if payload.strip() == "[DONE]":
        return None
    try:
        obj = json.loads(payload)
    except Exception:
        return payload
    for ch in obj.get("choices", []):
        d = ch.get("delta")
        if not isinstance(d, dict):
            continue
        for rf in REASONING_FIELDS:
            if strip_reasoning:
                d.pop(rf, None)
            elif isinstance(d.get(rf), str):
                d[rf] = red.rx.sub(REDACTED, d[rf])
        c = d.get("content")
        if isinstance(c, str) and c:
            d["content"] = red.feed(c)
        if ch.get("finish_reason") is not None:
            tail = red.flush()
            if tail:
                d["content"] = (d.get("content") or "") + tail
    return json.dumps(obj, ensure_ascii=False)


class Proxy:
    def __init__(self, args):
        self.args = args

    def _redactor(self):
        return Redactor(self.args.redact_open, self.args.redact_close)

    async def handle(self, request):
        path = request.rel_url.raw_path_qs
        body = await request.read()
        is_chat = request.method == "POST" and "/chat/completions" in request.path
        stream = False
        if is_chat:
            try:
                stream = bool(json.loads(body).get("stream"))
            except Exception:
                stream = False
        headers = {
            k: v
            for k, v in request.headers.items()
            if k.lower() not in ("host", "content-length", "accept-encoding")
        }
        timeout = aiohttp.ClientTimeout(total=self.args.timeout)
        session = aiohttp.ClientSession(timeout=timeout, auto_decompress=True)
        up = await session.request(request.method, self.args.upstream + path, data=body, headers=headers)
        if not is_chat:
            data = await up.read()
            await session.close()
            # Set Content-Type via headers, not the content_type kwarg: the
            # upstream value often carries a charset, which the kwarg rejects.
            return web.Response(
                body=data, status=up.status,
                headers={"Content-Type": up.headers.get("Content-Type", "application/octet-stream")},
            )
        if stream:
            return await self._stream(request, session, up)
        data = await up.read()
        await session.close()
        try:
            red = self._redactor()
            obj = json.loads(data)
            for ch in obj.get("choices", []):
                msg = ch.get("message") or {}
                for rf in REASONING_FIELDS:
                    if self.args.strip_reasoning:
                        msg.pop(rf, None)
                    elif isinstance(msg.get(rf), str):
                        msg[rf] = red.rx.sub(REDACTED, msg[rf])
                if isinstance(msg.get("content"), str):
                    msg["content"] = red.rx.sub(REDACTED, msg["content"])
            data = json.dumps(obj, ensure_ascii=False).encode()
        except Exception:
            pass
        return web.Response(body=data, status=up.status, content_type="application/json")

    async def _stream(self, request, session, up):
        resp = web.StreamResponse(status=up.status,
                                  headers={"Content-Type": "text/event-stream", "Cache-Control": "no-cache"})
        await resp.prepare(request)
        red = self._redactor()
        buf = b""
        try:
            async for raw in up.content.iter_any():
                buf += raw
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    text = line.decode("utf-8", "replace")
                    if not text.startswith("data:"):
                        await resp.write(line + b"\n")
                        continue
                    payload = text[len("data:"):].strip()
                    if payload == "[DONE]":
                        await resp.write(b"data: [DONE]\n")
                        continue
                    new = transform_chunk(payload, self.args.strip_reasoning, red)
                    if new is not None:
                        await resp.write(("data: " + new + "\n").encode("utf-8"))
        finally:
            await session.close()
        await resp.write_eof()
        return resp


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--listen-host", default=os.environ.get("PROXY_HOST", "127.0.0.1"))
    p.add_argument("--listen-port", type=int, default=int(os.environ.get("PROXY_PORT", "8009")))
    p.add_argument("--upstream", default=os.environ.get("PROXY_UPSTREAM", "http://127.0.0.1:8000"))
    p.add_argument("--redact-open", default=os.environ.get("PROXY_REDACT_OPEN", "Nix{"))
    p.add_argument("--redact-close", default=os.environ.get("PROXY_REDACT_CLOSE", "}"))
    p.add_argument("--timeout", type=float, default=float(os.environ.get("PROXY_TIMEOUT", "1800")))
    strip = os.environ.get("PROXY_STRIP_REASONING", "true").lower() != "false"
    p.add_argument("--strip-reasoning", dest="strip_reasoning", action="store_true", default=strip)
    p.add_argument("--no-strip-reasoning", dest="strip_reasoning", action="store_false")
    args = p.parse_args()

    proxy = Proxy(args)
    print(f"[proxy] {args.listen_host}:{args.listen_port} -> {args.upstream} "
          f"strip_reasoning={args.strip_reasoning} redact={args.redact_open}...{args.redact_close}")
    app = web.Application(client_max_size=1024 * 1024 * 64)
    app.router.add_route("*", "/{tail:.*}", proxy.handle)
    web.run_app(app, host=args.listen_host, port=args.listen_port, print=None)


if __name__ == "__main__":
    main()
