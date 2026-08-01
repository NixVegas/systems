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

import numpy as np
import sounddevice as sd
import aiohttp
from aiohttp import web

SAMPLE_RATE = 16000  # Whisper wants 16 kHz mono.


class AudioRing:
    """Thread-safe ring of the most recent `seconds` of mono float32 audio."""

    def __init__(self, seconds: float):
        self._buf = np.zeros(int(seconds * SAMPLE_RATE), dtype=np.float32)
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
        n = int(seconds * SAMPLE_RATE)
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


class Captioner:
    def __init__(self, args):
        self.args = args
        self.ring = AudioRing(seconds=max(args.window * 2, 12))
        self.committed: list[str] = []
        self.subscribers: set[asyncio.Queue] = set()
        self.loop: asyncio.AbstractEventLoop | None = None
        # Keyword trigger (e.g. "agency" -> Home Assistant flashes the lights).
        # Match on the raw window text (fast path, ~one window of latency) with a
        # cooldown so the same spoken word, which shows up in several overlapping
        # windows, fires the webhook only once.
        self._kw_re = (
            re.compile(rf"\b{re.escape(args.keyword)}\b", re.IGNORECASE)
            if args.keyword and args.webhook_url else None
        )
        self._last_fire = 0.0

    # --- audio ---
    def _audio_cb(self, indata, frames, time_info, status):
        mono = indata[:, 0] if indata.ndim > 1 else indata
        self.ring.push(np.asarray(mono, dtype=np.float32))

    def start_audio(self):
        self.stream = sd.InputStream(
            samplerate=SAMPLE_RATE, channels=1, dtype="float32",
            device=self.args.device, blocksize=int(0.1 * SAMPLE_RATE),
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
                audio = self.ring.tail(self.args.window)
                if rms(audio) < self.args.silence_rms:
                    await self._broadcast_tentative([])  # keep last state
                else:
                    text = await self._transcribe(sess, url, headers, audio)
                    if text is not None:
                        await self._maybe_fire(sess, text)
                        words = text.split()
                        self.committed, tentative = stitch(self.committed, words)
                        await self._broadcast(tentative)
                dt = time.monotonic() - t0
                await asyncio.sleep(max(0.0, self.args.hop - dt))

    async def _maybe_fire(self, sess, text: str):
        if self._kw_re is None or not self._kw_re.search(text):
            return
        now = time.monotonic()
        if now - self._last_fire < self.args.keyword_cooldown:
            return
        self._last_fire = now
        payload = {"keyword": self.args.keyword, "text": text, "ts": time.time()}
        try:
            async with sess.post(self.args.webhook_url, json=payload,
                                 timeout=aiohttp.ClientTimeout(total=3)) as r:
                await r.read()
                print(f"[trigger] heard '{self.args.keyword}' -> HA webhook ({r.status})")
        except Exception as e:
            print(f"[trigger] webhook failed: {e}")

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
    p.add_argument("--model", default=os.environ.get("WHISPER_MODEL", "whisper-large-v3"))
    p.add_argument("--device", default=os.environ.get("AUDIO_DEVICE"),
                   help="input device index or name substring (see --list-devices)")
    p.add_argument("--window", type=float, default=6.0, help="window length seconds")
    p.add_argument("--hop", type=float, default=3.0, help="seconds between windows")
    p.add_argument("--silence-rms", type=float, default=0.004,
                   help="skip transcribing windows quieter than this RMS")
    p.add_argument("--port", type=int, default=8090)
    # Keyword -> Home Assistant trigger. When the keyword is heard, POST the
    # webhook (HA automation flashes the Govee lights). Leave --webhook-url unset
    # to just caption with no trigger.
    p.add_argument("--keyword", default=os.environ.get("TRIGGER_KEYWORD", "agency"),
                   help="word that fires the webhook (case-insensitive, whole word)")
    p.add_argument("--webhook-url", default=os.environ.get("HA_WEBHOOK_URL"),
                   help="Home Assistant webhook URL to POST when the keyword is heard")
    p.add_argument("--keyword-cooldown", type=float, default=6.0,
                   help="min seconds between webhook fires (dedupes overlapping windows)")
    p.add_argument("--list-devices", action="store_true")
    args = p.parse_args()

    if args.list_devices:
        print(sd.query_devices())
        return
    if args.device is not None and args.device.isdigit():
        args.device = int(args.device)

    try:
        asyncio.run(Captioner(args).run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
