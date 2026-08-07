#!/usr/bin/env python3
"""Align a live-captions .ass onto an OBS recording.

`live-captions` writes each session's subtitles with times relative to the
session start, and stamps that start as `SessionEpoch` in the .ass header. To
drop those subtitles onto a specific OBS recording, every event must shift by
(session_start - recording_start). This reads the session start from the .ass,
works out the recording start (from --record-start, the recording filename's
trailing `YYYY-MM-DD HH-MM-SS`, or the file's mtime as a fallback), and writes a
new .ass whose t=0 lines up with the recording start.

  caption-align captions-20260804-050000.ass '2026-08-04 05-06-20.mkv'
  caption-align captions-20260804-050000.ass --record-start 1754308800 -o out.ass
  caption-align captions-20260804-050000.ass --offset -372.5   # explicit shift
"""
import argparse
import os
import re
import sys
import time


def _parse_ts(s: str) -> float:
    h, m, rest = s.split(":")
    return int(h) * 3600 + int(m) * 60 + float(rest)


def _fmt_ts(t: float) -> str:
    cs = int(round(max(0.0, t) * 100))
    h, cs = divmod(cs, 360000)
    m, cs = divmod(cs, 6000)
    sec, cs = divmod(cs, 100)
    return f"{h:d}:{m:02d}:{sec:02d}.{cs:02d}"


def _session_epoch(lines) -> float:
    for ln in lines:
        m = re.match(r"\s*;\s*SessionEpoch:\s*([0-9.]+)", ln)
        if m:
            return float(m.group(1))
    raise SystemExit("no SessionEpoch header -- is this a live-captions .ass?")


# OBS's default filename (`%CCYY-%MM-%DD %hh-%mm-%ss`) and close variants.
_FNAME_RE = re.compile(r"(\d{4})-(\d{2})-(\d{2})[ _T](\d{2})[-:](\d{2})[-:](\d{2})")


def _record_start(rec, explicit) -> float:
    if explicit is not None:
        try:
            return float(explicit)
        except ValueError:
            return time.mktime(time.strptime(explicit, "%Y-%m-%d %H:%M:%S"))
    if rec:
        m = _FNAME_RE.search(os.path.basename(rec))
        if m:
            y, mo, d, hh, mm, ss = map(int, m.groups())
            return time.mktime((y, mo, d, hh, mm, ss, 0, 0, -1))
        if os.path.exists(rec):
            sys.stderr.write(
                f"[caption-align] no timestamp in name; using mtime of {rec}\n")
            return os.path.getmtime(rec)
    raise SystemExit(
        "give a RECORDING with a dated name, or --record-start / --offset")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("captions", help="the live-captions .ass to align")
    ap.add_argument("recording", nargs="?",
                    help="the OBS recording, for its start time")
    ap.add_argument("--record-start",
                    help="recording start: epoch seconds or 'YYYY-MM-DD HH:MM:SS'")
    ap.add_argument("--offset", type=float,
                    help="explicit shift in seconds (overrides record-start)")
    ap.add_argument("-o", "--out",
                    help="output .ass (default: <recording>.ass, else <captions>.aligned.ass)")
    a = ap.parse_args()

    with open(a.captions, encoding="utf-8") as f:
        lines = f.readlines()

    if a.offset is not None:
        shift = a.offset
    else:
        shift = _session_epoch(lines) - _record_start(a.recording, a.record_start)

    out = a.out or (
        os.path.splitext(a.recording)[0] + ".ass" if a.recording
        else os.path.splitext(a.captions)[0] + ".aligned.ass")

    kept = dropped = 0
    with open(out, "w", encoding="utf-8") as w:
        for ln in lines:
            if ln.startswith("Dialogue:"):
                _, _, rest = ln.partition(":")
                fields = rest.split(",", 9)  # keep commas in the text field
                start = _parse_ts(fields[1].strip()) + shift
                end = _parse_ts(fields[2].strip()) + shift
                if end <= 0:  # ended before the recording began
                    dropped += 1
                    continue
                fields[1] = _fmt_ts(start)
                fields[2] = _fmt_ts(end)
                w.write("Dialogue:" + ",".join(fields))
                if not ln.endswith("\n"):
                    w.write("\n")
                kept += 1
            else:
                w.write(ln)

    sys.stderr.write(
        f"[caption-align] shift {shift:+.2f}s -> {out} "
        f"({kept} events, {dropped} before t=0 dropped)\n")


if __name__ == "__main__":
    main()
