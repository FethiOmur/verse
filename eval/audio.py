"""Synthetic dialogue audio for the replay harness: `say` per utterance -> one mono 16 kHz WAV on a temp timeline.

Audio is only ever created in a temp directory the caller deletes. Nothing here writes into the repo, the session
folder or the brain folder. Stdlib only (no numpy).
"""

from __future__ import annotations

import array
import math
import shutil
import subprocess
import tempfile
import wave
from dataclasses import dataclass
from pathlib import Path

RATE = 16000
LEAD_IN_S = 1.0       # silence before the first utterance
PAD_S = 0.05          # kept around the detected speech of each clip


@dataclass
class Clip:
    samples: array.array  # int16
    speech_start: float   # seconds from the start of `samples`
    speech_end: float


def speech_bounds(samples: array.array, rate: int = RATE) -> tuple[float, float]:
    """Energy-based speech bounds (10 ms frames, threshold 4 % of the loudest frame): the P0-B / MemorySource rule."""
    hop = rate // 100
    rms: list[float] = []
    for i in range(0, len(samples) - hop + 1, hop):
        seg = samples[i:i + hop]
        rms.append(math.sqrt(sum(s * s for s in seg) / hop))
    if not rms:
        return (0.0, 0.0)
    peak = max(rms)
    thr = max(peak * 0.04, 3.0)
    idx = [k for k, v in enumerate(rms) if v > thr]
    if not idx:
        return (0.0, 0.0)
    return (idx[0] * 0.01, (idx[-1] + 1) * 0.01)


def say_clip(voice: str, text: str, workdir: Path, rate_wpm: int | None = None) -> Clip:
    out = workdir / "u.wav"
    cmd = ["/usr/bin/say", "-v", voice, "-o", str(out), "--file-format=WAVE", f"--data-format=LEI16@{RATE}"]
    if rate_wpm:
        cmd += ["-r", str(rate_wpm)]
    cmd.append(text)
    r = subprocess.run(cmd, capture_output=True, timeout=120)
    if r.returncode != 0 or not out.exists():
        raise RuntimeError(f"say -v {voice!r} failed (exit {r.returncode})")
    with wave.open(str(out), "rb") as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2, "unexpected say format"
        samples = array.array("h")
        samples.frombytes(w.readframes(w.getnframes()))
    out.unlink()
    s, e = speech_bounds(samples)
    return Clip(samples, s, e)


def silence(seconds: float) -> array.array:
    return array.array("h", [0]) * int(round(seconds * RATE))


@dataclass
class Rendered:
    path: Path | None
    duration: float
    timeline: list[dict]  # one per utterance: index, speaker, t_start, t_end (speech bounds on the file's clock)


def render(utterances: list[dict], voices: dict[str, str], workdir: Path, write_wav: bool = True,
           lead_in: float = LEAD_IN_S) -> Rendered:
    """Builds the timeline. utterances: dicts with speaker, text, gap_before (s), and either `silent_s` (a silent
    stretch, e.g. Alex answering) or text to speak. Returns where each utterance's speech starts and ends."""
    buf = array.array("h")
    buf.extend(silence(lead_in))
    timeline = []
    for i, u in enumerate(utterances):
        buf.extend(silence(u.get("gap_before", 0.0)))
        if u.get("silent_s"):
            t0 = len(buf) / RATE
            buf.extend(silence(u["silent_s"]))
            timeline.append({"index": i, "speaker": u["speaker"], "t_start": round(t0, 3), "t_end": round(len(buf) / RATE, 3), "silent": True})
            continue
        clip = say_clip(voices[u["speaker"]], u["text"], workdir, u.get("rate_wpm"))
        a = max(0, int((clip.speech_start - PAD_S) * RATE))
        b = min(len(clip.samples), int((clip.speech_end + PAD_S) * RATE))
        t0 = len(buf) / RATE + (clip.speech_start - a / RATE)
        buf.extend(clip.samples[a:b])
        t1 = t0 + (clip.speech_end - clip.speech_start)
        timeline.append({"index": i, "speaker": u["speaker"], "t_start": round(t0, 3), "t_end": round(t1, 3), "silent": False})
    path = None
    if write_wav:
        path = workdir / "dialogue.wav"
        with wave.open(str(path), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(buf.tobytes())
    return Rendered(path, len(buf) / RATE, timeline)


def make_workdir() -> Path:
    return Path(tempfile.mkdtemp(prefix="verse-eval-audio-"))


def remove_workdir(p: Path) -> bool:
    shutil.rmtree(p, ignore_errors=True)
    return not p.exists()
