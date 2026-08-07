#!/usr/bin/env python3
"""Live-caption client for Tenstorrent Whisper.

Captures audio from an input device (the AV mixer feed), transcribes rolling
windows against a tt-media-server OpenAI /v1/audio/transcriptions endpoint,
stitches the overlapping window transcripts into one growing transcript, and
serves an SSE stream + the OBS overlay page.

Point an OBS Browser Source at http://localhost:<port>/overlay.

This is a v1: fixed sliding window + difflib overlap-merge. It is deliberately
backend-agnostic (any OpenAI-compatible STT works).

Subtitle timing note (SubtitleWriter): tt-whisper does NOT return word/segment
timestamps -- probing `response_format=verbose_json` +
`timestamp_granularities[]=word` yields only `{text, duration}`. So subtitle
event times are commit-based (~1-2s coarse), not per-word. Accurate timing would
need either a backend that emits word timestamps or post-hoc forced alignment
against the recording's own audio (whisperx / whisper.cpp token timestamps).
"""
import argparse
import asyncio
import contextlib
import datetime
import difflib
import io
import json
import os
import re
import signal
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

    def __init__(self, keyword, webhook, cooldown, payload=None, caption_file=None):
        self.keyword = keyword
        # re.escape leaves ASCII spaces intact, so multi-word phrases like
        # "escape your fate" match as a literal phrase (single-spaced, as Whisper
        # emits). \b guards word boundaries at each end.
        self.rx = re.compile(rf"\b{re.escape(keyword)}\b", re.IGNORECASE)
        self.webhook = webhook  # optional HA webhook to POST
        self.cooldown = float(cooldown)
        self.payload = payload  # optional dict; default is {keyword,text,ts}
        # optional file whose contents are flashed onto the overlay as a flag
        # banner when this keyword fires (read live, so it's editable on the fly).
        self.caption_file = caption_file
        self.last = 0.0


def build_triggers(args) -> list[Trigger]:
    """Collect triggers from --triggers-file (JSON), repeatable --trigger
    kw=url, and the single --keyword/--webhook-url shorthand."""
    out: list[Trigger] = []
    if args.triggers_file:
        with open(args.triggers_file) as f:
            for t in json.load(f):
                out.append(Trigger(
                    t["keyword"], t.get("webhook"),
                    t.get("cooldown", args.keyword_cooldown), t.get("payload"),
                    t.get("caption_file"),
                ))
    for spec in (args.trigger or []):
        kw, sep, url = spec.partition("=")
        if kw and sep and url:
            out.append(Trigger(kw, url, args.keyword_cooldown))
    if args.keyword and args.webhook_url:
        out.append(Trigger(args.keyword, args.webhook_url, args.keyword_cooldown))
    return out


def _ass_ts(t: float) -> str:
    """Seconds -> ASS timestamp H:MM:SS.cc (centiseconds)."""
    cs = int(round(max(0.0, t) * 100))
    h, cs = divmod(cs, 360000)
    m, cs = divmod(cs, 6000)
    s, cs = divmod(cs, 100)
    return f"{h:d}:{m:02d}:{s:02d}.{cs:02d}"


_ASS_HEADER = """\
[Script Info]
; Live captions. Event times are relative to this session's start; to drop them
; onto an OBS recording, shift every time by (SessionEpoch - record_start_epoch)
; -- the `caption-align` CLI does exactly that from these two headers.
; SessionStart: {iso}
; SessionEpoch: {epoch:.3f}
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080
WrapStyle: 2
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,3,0,2,60,60,60,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""


class SubtitleWriter:
    """Append committed caption text to a per-session .ass as Dialogue events,
    timed relative to session start so `caption-align` can shift it onto an OBS
    recording.

    There are no per-word timestamps (the STT returns plain text), so a line's
    START is when its words *commit* out of the LocalAgreement stitch, minus a
    fixed `latency` to approximate when they were spoken. Lines are kept short --
    up to `max_words`, or a sentence -- and each finished line is held back one
    step so its END can be set to the *next* line's start: continuous speech then
    has no gaps, and a line lingers into a pause only up to `max_secs`. (Timing is
    commit-based, so ~1-2s coarse; use `caption-align` for the constant offset.)"""

    def __init__(self, directory, latency=1.5, max_words=8, max_secs=6.0):
        self.latency = float(latency)
        self.max_words = max_words
        self.max_secs = max_secs
        self.t0 = time.time()
        self.mono0 = time.monotonic()
        os.makedirs(directory, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(self.t0))
        self.path = os.path.join(directory, f"captions-{stamp}.ass")
        # Line-buffered: each event hits disk as soon as it's sealed.
        self.f = open(self.path, "w", encoding="utf-8", buffering=1)
        iso = datetime.datetime.fromtimestamp(self.t0).astimezone().isoformat(timespec="seconds")
        self.f.write(_ASS_HEADER.format(iso=iso, epoch=self.t0))
        self._words: list[str] = []       # the line currently being assembled
        self._start: float | None = None  # monotonic start of that line
        self._pending: tuple[float, str] | None = None  # finished line awaiting its END

    def _rel(self, mono: float) -> float:
        return max(0.0, (mono - self.mono0) - self.latency)

    def _emit(self, start: float, end: float, text: str):
        if end <= start:
            end = start + 0.4  # keep events strictly positive-length
        self.f.write(f"Dialogue: 0,{_ass_ts(start)},{_ass_ts(end)},Default,,0,0,0,,{text}\n")

    def _seal(self, upto: float):
        """Write the held-back line, ending it where the next line starts (or a
        pause), but never lingering more than `max_secs`."""
        if self._pending is None:
            return
        start, text = self._pending
        self._emit(start, min(upto, start + self.max_secs), text)
        self._pending = None

    def _line(self, mono: float):
        """Finish the current buffer into a line: seal the previous one up to this
        line's start, then hold this one back as pending."""
        if not self._words:
            return
        start = self._rel(self._start if self._start is not None else mono)
        # '{'/'}' open ASS override blocks; neutralize so caption text can't
        # inject styling or corrupt the event.
        text = " ".join(self._words).replace("{", "(").replace("}", ")").strip()
        self._seal(start)
        self._pending = (start, text)
        self._words = []
        self._start = None

    def add(self, words, mono: float):
        if not words:
            return
        if self._start is None:
            self._start = mono
        self._words.extend(words)
        if len(self._words) >= self.max_words or self._words[-1][-1:] in ".?!":
            self._line(mono)

    def flush(self, mono: float):
        """Called at a speech pause: finish any half-line and let the last line
        end at the pause instead of hanging until the next utterance."""
        pause = self._rel(mono)
        self._line(mono)
        self._seal(pause)

    def close(self):
        try:
            self.flush(time.monotonic())
            self.f.close()
        except Exception:
            pass


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
        # Optional .ass subtitle log (for aligning onto OBS recordings).
        self.subtitle = (
            SubtitleWriter(args.subtitle_dir, latency=args.subtitle_latency)
            if getattr(args, "subtitle_dir", None)
            else None
        )

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
                    if self.subtitle:
                        self.subtitle.flush(time.monotonic())  # close the line at a pause
                    await self._broadcast_tentative([])  # keep last state
                else:
                    text = await self._transcribe(sess, url, headers, audio)
                    if text is not None:
                        await self._check_triggers(sess, text)
                        words = text.split()
                        before = len(self.committed)
                        self.committed, tentative = stitch(self.committed, words)
                        if self.subtitle:
                            self.subtitle.add(self.committed[before:], time.monotonic())
                        await self._broadcast(tentative)
                dt = time.monotonic() - t0
                await asyncio.sleep(max(0.0, self.args.hop - dt))

    async def _check_triggers(self, sess, text: str):
        now = time.monotonic()
        for tg in self.triggers:
            if now - tg.last < tg.cooldown or not tg.rx.search(text):
                continue
            tg.last = now
            # A trigger can flash a flag banner, POST a webhook, or both.
            if tg.caption_file:
                await self._show_flag(tg)
            if tg.webhook:
                payload = tg.payload or {"keyword": tg.keyword, "text": text, "ts": time.time()}
                try:
                    async with sess.post(tg.webhook, json=payload,
                                         timeout=aiohttp.ClientTimeout(total=3)) as r:
                        await r.read()
                        print(f"[trigger] heard '{tg.keyword}' -> {tg.webhook} ({r.status})")
                except Exception as e:
                    print(f"[trigger] '{tg.keyword}' webhook failed: {e}")

    async def _show_flag(self, tg):
        """Read the trigger's caption file (each time, so it's editable live) and
        push it to the overlay as a flag banner for flag_seconds."""
        try:
            text = open(tg.caption_file, encoding="utf-8").read().strip()
        except Exception as e:
            print(f"[flag] '{tg.keyword}': cannot read {tg.caption_file}: {e}")
            return
        if not text:
            return
        msg = json.dumps({"flag": text, "flag_seconds": self.args.flag_seconds})
        for q in list(self.subscribers):
            q.put_nowait(msg)
        print(f"[flag] heard '{tg.keyword}' -> banner ({len(text)} chars, {self.args.flag_seconds}s)")

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
        if self.subtitle:
            print(f"[captions] subtitles: {self.subtitle.path}")
        # Stop cleanly on SIGTERM (how systemd stops the service) as well as
        # SIGINT, so the subtitle writer flushes its last line on stop instead of
        # losing it to an abrupt kill.
        stop = asyncio.Event()
        for sig in (signal.SIGTERM, signal.SIGINT):
            with contextlib.suppress(NotImplementedError):
                self.loop.add_signal_handler(sig, stop.set)
        worker = asyncio.create_task(self.transcribe_loop())
        try:
            await asyncio.wait(
                {worker, asyncio.create_task(stop.wait())},
                return_when=asyncio.FIRST_COMPLETED,
            )
        finally:
            worker.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await worker
            if self.subtitle:
                self.subtitle.close()


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
    p.add_argument("--flag-seconds", type=float, default=10.0,
                   help="how long a flag banner (a trigger's caption_file) stays on the overlay")
    p.add_argument("--subtitle-dir", default=os.environ.get("SUBTITLE_DIR"),
                   help="write a per-session .ass subtitle file into this dir (to "
                        "align onto OBS recordings via caption-align); unset = off")
    p.add_argument("--subtitle-latency", type=float, default=1.5,
                   help="seconds subtracted from each line's commit time to "
                        "approximate when it was spoken (a constant alignment nudge)")
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
