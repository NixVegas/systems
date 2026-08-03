#!/usr/bin/env python3
"""Live-caption client for Tenstorrent Whisper.

Captures audio from an input device (the AV mixer feed), transcribes rolling
windows against a tt-media-server OpenAI /v1/audio/transcriptions endpoint,
stitches the overlapping window transcripts into one growing transcript, and
serves an SSE stream + the OBS overlay page.

Point an OBS Browser Source at http://localhost:<port>/overlay.

This is a v1: fixed sliding window + difflib overlap-merge. It is deliberately
backend-agnostic (any OpenAI-compatible STT works). The natural upgrade is the
whisper_streaming LocalAgreement policy with verbose_json word timestamps.
"""
import argparse
import asyncio
import difflib
import io
import json
import os
import re
import threading
import time
import wave
from math import gcd

import numpy as np
import sounddevice as sd
from scipy.signal import resample_poly
import aiohttp
from aiohttp import web

SAMPLE_RATE = 16000  # Whisper wants 16 kHz mono.


class AudioRing:
    """Thread-safe ring of the most recent `seconds` of mono float32 audio."""

    def __init__(self, seconds: float, rate: int = SAMPLE_RATE):
        self._rate = rate
        self._buf = np.zeros(int(seconds * rate), dtype=np.float32)
        self._lock = threading.Lock()

    def push(self, frames: np.ndarray):
        n = len(frames)
        with self._lock:
            if n >= len(self._buf):
                self._buf[:] = frames[-len(self._buf):]
            else:
                self._buf[:-n] = self._buf[n:]
                self._buf[-n:] = frames

    def tail(self, seconds: float) -> np.ndarray:
        n = int(seconds * self._rate)
        with self._lock:
            return self._buf[-n:].copy()


def wav_bytes(audio: np.ndarray) -> bytes:
    pcm = np.clip(audio * 32767.0, -32768, 32767).astype("<i2")
    b = io.BytesIO()
    with wave.open(b, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm.tobytes())
    return b.getvalue()


def rms(audio: np.ndarray) -> float:
    return float(np.sqrt(np.mean(np.square(audio)) + 1e-12))


def stitch(committed: list[str], hyp: list[str]) -> tuple[list[str], list[str]]:
    """Merge a new window transcript into the running transcript.

    Finds where the new hypothesis overlaps the tail of what we already have and
    appends only the continuation. Returns (new_committed, tentative_words).
    """
    if not hyp:
        return committed, []
    if not committed:
        # First window: commit its stable prefix, keep the tail tentative.
        cont = hyp
    else:
        tail = committed[-24:]
        sm = difflib.SequenceMatcher(None, tail, hyp, autojunk=False)
        m = sm.find_longest_match(0, len(tail), 0, len(hyp))
        if m.size >= 2:
            cont = hyp[m.b + m.size:]
        else:
            # No confident overlap. Assume the whole window is fresh speech but
            # keep the tail tentative so a duplicate does not get locked in.
            cont = hyp
    if not cont:
        return committed, []
    # Lock all but the trailing few words (those still lack right-context and
    # may be revised by the next window).
    keep_tentative = min(4, len(cont))
    newly_committed = cont[:-keep_tentative] if keep_tentative else cont
    tentative = cont[-keep_tentative:] if keep_tentative else []
    return committed + newly_committed, tentative


class Trigger:
    """One hotword -> one webhook. Matched on the raw window text (fast path,
    ~one window of latency) with a per-trigger cooldown so the same spoken word,
    which shows up in several overlapping windows, fires only once."""

    def __init__(self, keyword, webhook, cooldown, payload=None):
        self.keyword = keyword
        self.rx = re.compile(rf"\b{re.escape(keyword)}\b", re.IGNORECASE)
        self.webhook = webhook
        self.cooldown = float(cooldown)
        self.payload = payload  # optional dict; default is {keyword,text,ts}
        self.last = 0.0


def build_triggers(args) -> list[Trigger]:
    """Collect triggers from --triggers-file (JSON), repeatable --trigger
    kw=url, and the single --keyword/--webhook-url shorthand."""
    out: list[Trigger] = []
    if args.triggers_file:
        with open(args.triggers_file) as f:
            for t in json.load(f):
                out.append(Trigger(
                    t["keyword"], t["webhook"],
                    t.get("cooldown", args.keyword_cooldown), t.get("payload"),
                ))
    for spec in (args.trigger or []):
        kw, sep, url = spec.partition("=")
        if kw and sep and url:
            out.append(Trigger(kw, url, args.keyword_cooldown))
    if args.keyword and args.webhook_url:
        out.append(Trigger(args.keyword, args.webhook_url, args.keyword_cooldown))
    return out


class Captioner:
    def __init__(self, args):
        self.args = args
        # Capture at a rate the device actually supports (many only offer their
        # native 44.1/48 kHz -- opening a raw 16 kHz InputStream fails with
        # PaErrorCode -9997). Keep the ring at that rate and resample each window
        # to 16 kHz for Whisper. Resampling the contiguous window once (not each
        # callback block) avoids per-block filter discontinuities.
        self.capture_rate = self._pick_capture_rate()
        if self.capture_rate != SAMPLE_RATE:
            g = gcd(SAMPLE_RATE, self.capture_rate)
            self._resamp = (SAMPLE_RATE // g, self.capture_rate // g)
            print(f"[audio] device native {self.capture_rate} Hz -> resample to {SAMPLE_RATE} Hz")
        else:
            self._resamp = None
        self.ring = AudioRing(seconds=max(args.window * 2, 12), rate=self.capture_rate)
        self.committed: list[str] = []
        self.subscribers: set[asyncio.Queue] = set()
        self.loop: asyncio.AbstractEventLoop | None = None
        self.triggers = build_triggers(args)

    # --- audio ---
    def _pick_capture_rate(self) -> int:
        """Prefer 16 kHz (no resample); fall back to the device's native rate if
        it won't open a 16 kHz stream."""
        try:
            sd.check_input_settings(
                device=self.args.device, channels=1, dtype="float32",
                samplerate=SAMPLE_RATE,
            )
            return SAMPLE_RATE
        except Exception:
            info = sd.query_devices(self.args.device, "input")
            return int(round(info["default_samplerate"]))

    def _to_16k(self, audio: np.ndarray) -> np.ndarray:
        if self._resamp is None:
            return audio
        up, down = self._resamp
        return resample_poly(audio, up, down).astype(np.float32)

    def _audio_cb(self, indata, frames, time_info, status):
        mono = indata[:, 0] if indata.ndim > 1 else indata
        self.ring.push(np.asarray(mono, dtype=np.float32))

    def start_audio(self):
        self.stream = sd.InputStream(
            samplerate=self.capture_rate, channels=1, dtype="float32",
            device=self.args.device, blocksize=int(0.1 * self.capture_rate),
            callback=self._audio_cb,
        )
        self.stream.start()

    # --- transcription loop ---
    async def transcribe_loop(self):
        url = self.args.whisper_url
        headers = {"Authorization": f"Bearer {self.args.api_key}"}
        async with aiohttp.ClientSession() as sess:
            # Let the ring fill before the first window.
            await asyncio.sleep(self.args.window)
            while True:
                t0 = time.monotonic()
                audio = self._to_16k(self.ring.tail(self.args.window))
                if rms(audio) < self.args.silence_rms:
                    await self._broadcast_tentative([])  # keep last state
                else:
                    text = await self._transcribe(sess, url, headers, audio)
                    if text is not None:
                        await self._check_triggers(sess, text)
                        words = text.split()
                        self.committed, tentative = stitch(self.committed, words)
                        await self._broadcast(tentative)
                dt = time.monotonic() - t0
                await asyncio.sleep(max(0.0, self.args.hop - dt))

    async def _check_triggers(self, sess, text: str):
        now = time.monotonic()
        for tg in self.triggers:
            if now - tg.last < tg.cooldown or not tg.rx.search(text):
                continue
            tg.last = now
            payload = tg.payload or {"keyword": tg.keyword, "text": text, "ts": time.time()}
            try:
                async with sess.post(tg.webhook, json=payload,
                                     timeout=aiohttp.ClientTimeout(total=3)) as r:
                    await r.read()
                    print(f"[trigger] heard '{tg.keyword}' -> {tg.webhook} ({r.status})")
            except Exception as e:
                print(f"[trigger] '{tg.keyword}' webhook failed: {e}")

    async def _transcribe(self, sess, url, headers, audio) -> str | None:
        form = aiohttp.FormData()
        form.add_field("file", wav_bytes(audio), filename="window.wav",
                       content_type="audio/wav")
        form.add_field("model", self.args.model)
        form.add_field("response_format", "json")
        try:
            async with sess.post(url, data=form, headers=headers,
                                 timeout=aiohttp.ClientTimeout(total=self.args.hop * 4)) as r:
                if r.status != 200:
                    return None
                data = await r.json()
                return (data.get("text") or "").strip()
        except Exception:
            return None

    # --- SSE fan-out ---
    def _payload(self, tentative: list[str]) -> str:
        # Show a bounded tail of committed words so the box does not grow forever.
        tail = " ".join(self.committed[-60:])
        return json.dumps({"committed": tail, "tentative": " ".join(tentative)})

    async def _broadcast(self, tentative: list[str]):
        msg = self._payload(tentative)
        for q in list(self.subscribers):
            q.put_nowait(msg)

    async def _broadcast_tentative(self, tentative):
        await self._broadcast(tentative)

    # --- HTTP ---
    async def handle_overlay(self, request):
        here = os.path.dirname(os.path.abspath(__file__))
        return web.FileResponse(os.path.join(here, "overlay.html"))

    async def handle_events(self, request):
        resp = web.StreamResponse(headers={
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "Access-Control-Allow-Origin": "*",
        })
        await resp.prepare(request)
        q: asyncio.Queue = asyncio.Queue()
        self.subscribers.add(q)
        # Send current state immediately.
        q.put_nowait(self._payload([]))
        try:
            while True:
                msg = await q.get()
                await resp.write(f"data: {msg}\n\n".encode())
        except (asyncio.CancelledError, ConnectionResetError):
            pass
        finally:
            self.subscribers.discard(q)
        return resp

    async def run(self):
        self.loop = asyncio.get_running_loop()
        self.start_audio()
        app = web.Application()
        app.router.add_get("/", lambda r: web.HTTPFound("/overlay"))
        app.router.add_get("/overlay", self.handle_overlay)
        app.router.add_get("/events", self.handle_events)
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, "0.0.0.0", self.args.port)
        await site.start()
        print(f"[captions] overlay: http://localhost:{self.args.port}/overlay")
        print(f"[captions] whisper: {self.args.whisper_url} (model={self.args.model})")
        await self.transcribe_loop()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--whisper-url", default=os.environ.get(
        "WHISPER_URL", "http://10.4.1.2:8031/v1/audio/transcriptions"))
    p.add_argument("--api-key", default=os.environ.get("WHISPER_API_KEY", "sk-whisper"))
    p.add_argument("--api-key-file", default=os.environ.get("WHISPER_API_KEY_FILE"),
                   help="read the whisper Bearer key from this file (keeps it out of argv/store)")
    p.add_argument("--model", default=os.environ.get("WHISPER_MODEL", "whisper-large-v3"))
    p.add_argument("--device", default=os.environ.get("AUDIO_DEVICE"),
                   help="input device index or name substring (see --list-devices)")
    p.add_argument("--window", type=float, default=6.0, help="window length seconds")
    p.add_argument("--hop", type=float, default=3.0, help="seconds between windows")
    p.add_argument("--silence-rms", type=float, default=0.004,
                   help="skip transcribing windows quieter than this RMS")
    p.add_argument("--port", type=int, default=8090)
    # Hotword -> webhook triggers. Each hotword fires its own webhook (a distinct
    # Home Assistant automation), so different words do different things. Provide
    # them three ways (all combine): a JSON file, repeatable --trigger kw=url, or
    # the single --keyword/--webhook-url shorthand. No webhook set = caption only.
    p.add_argument("--triggers-file", default=os.environ.get("TRIGGERS_FILE"),
                   help='JSON: [{"keyword":"agency","webhook":"http://...",'
                        '"cooldown":6.0,"payload":{...}}, ...]')
    p.add_argument("--trigger", action="append", metavar="KEYWORD=URL",
                   help="hotword -> webhook (repeatable), e.g. --trigger agency=http://...")
    p.add_argument("--keyword", default=os.environ.get("TRIGGER_KEYWORD", "agency"),
                   help="single-trigger shorthand: word that fires --webhook-url")
    p.add_argument("--webhook-url", default=os.environ.get("HA_WEBHOOK_URL"),
                   help="single-trigger shorthand: webhook for --keyword")
    p.add_argument("--keyword-cooldown", type=float, default=6.0,
                   help="default min seconds between fires per hotword (dedupes windows)")
    p.add_argument("--list-devices", action="store_true")
    args = p.parse_args()

    if args.list_devices:
        print(sd.query_devices())
        return
    if args.api_key_file:
        with open(args.api_key_file) as f:
            args.api_key = f.read().strip()
    if args.device is not None and args.device.isdigit():
        args.device = int(args.device)

    try:
        asyncio.run(Captioner(args).run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
