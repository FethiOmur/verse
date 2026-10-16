"""Two-track synthetic dialogues for the replay harness: a remote track and a "me" track (Alex), plus a speaker-bleed
simulation (the remote track leaking into the microphone).

Audio is only ever created in a temp directory the caller deletes (same rule as audio.py). Stdlib only.

    fixture = load("t01")
    r = render(fixture, workdir, lead_in=25.0)          # r.remote_path, r.me_path, r.timeline
    me = bleed_wav(r.remote_path, ..., into=r.me_path)  # the microphone with the speakers on

Fixture format (eval/twotrack/<id>.json): utterances in order; `offset_s` is where the speech starts relative to the
true acoustic end of the previous utterance (negative: it starts before the previous one ended, i.e. they overlap).
`speaker == owner` goes on the me track, everyone else on the remote track. `expect`:
  answer     a remote turn that is a question for the owner and must get exactly one answer
  no_answer  a remote statement or fragment: no answer (a short acknowledgement is allowed)
  either     ambiguous by design (an interrupted question, a backchannel): reported, never counted as wrong
  me_turn    the owner's speech: must land as me turn(s), and never be answered
Follow my answer (optional, owner utterances only): `follow` = "none" (he stays on the card: no follow card may come) or
"diverge" (he leaves it: a follow card must come), `off_from_word` = index of the first word that is off the card.
"""

from __future__ import annotations

import array
import json
import math
import random
import wave
from dataclasses import dataclass
from pathlib import Path

import audio

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "twotrack"
RATE = audio.RATE
EXPECTS = {"answer", "no_answer", "either", "me_turn"}


def load(fid: str, directory: Path = FIXTURES) -> dict:
    d = json.loads((directory / f"{fid}.json").read_text(encoding="utf-8"))
    errs = validate(d)
    if errs:
        raise ValueError(f"{fid}: " + "; ".join(errs))
    return d


def validate(d: dict) -> list[str]:
    errs = []
    for k in ("id", "owner", "participants", "voices", "utterances"):
        if k not in d:
            errs.append(f"missing {k!r}")
    if errs:
        return errs
    for i, u in enumerate(d["utterances"]):
        if u.get("follow") not in (None, "none", "diverge"):
            errs.append(f"utterance {i}: bad follow {u.get('follow')!r}")
        if u.get("follow") and u.get("speaker") != d.get("owner"):
            errs.append(f"utterance {i}: only the owner's utterances carry a follow label")
        if u.get("follow") == "diverge" and not isinstance(u.get("off_from_word"), int):
            errs.append(f"utterance {i}: a diverge label needs off_from_word")
        for k in ("speaker", "text", "offset_s", "expect"):
            if k not in u:
                errs.append(f"utterance {i}: missing {k!r}")
        if u.get("expect") not in EXPECTS:
            errs.append(f"utterance {i}: bad expect {u.get('expect')!r}")
        if u.get("speaker") not in d["voices"]:
            errs.append(f"utterance {i}: no voice for {u.get('speaker')!r}")
        owner_expect = u.get("expect") in ("me_turn", "either") if u.get("speaker") == d["owner"] else u.get("expect") in ("answer", "no_answer", "either")
        if not owner_expect:
            errs.append(f"utterance {i}: the owner's utterances expect me_turn or either; everyone else's answer, no_answer or either")
    return errs


@dataclass
class Rendered:
    remote_path: Path
    me_path: Path
    duration: float
    timeline: list[dict]    # index, speaker, channel, t_start, t_end (true acoustic bounds on the file clock)


def _mix(buf: array.array, seg: array.array, pos: int) -> None:
    if pos < 0:
        seg = seg[-pos:]
        pos = 0
    if len(buf) < pos + len(seg):
        buf.extend(array.array("h", [0]) * (pos + len(seg) - len(buf)))
    for k, v in enumerate(seg):
        x = buf[pos + k] + v
        buf[pos + k] = 32767 if x > 32767 else -32768 if x < -32768 else x


def write_wav(path: Path, samples: array.array) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(samples.tobytes())


def read_wav(path: Path) -> array.array:
    with wave.open(str(path), "rb") as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2
        a = array.array("h")
        a.frombytes(w.readframes(w.getnframes()))
        return a


def render(fixture: dict, workdir: Path, lead_in: float = 25.0, tail: float = 1.0) -> Rendered:
    """Speaks every utterance with `say`, places it by its offset and mixes the owner onto the me track and everyone else
    onto the remote track. Both files have the same length and the same start, so they play side by side."""
    remote = array.array("h")
    me = array.array("h")
    timeline = []
    end_prev = lead_in
    for i, u in enumerate(fixture["utterances"]):
        clip = audio.say_clip(fixture["voices"][u["speaker"]], u["text"], workdir, u.get("rate_wpm"))
        a = max(0, int((clip.speech_start - audio.PAD_S) * RATE))
        b = min(len(clip.samples), int((clip.speech_end + audio.PAD_S) * RATE))
        seg = clip.samples[a:b]
        t_start = max(0.0, end_prev + float(u["offset_s"]))
        t_end = t_start + (clip.speech_end - clip.speech_start)
        pos = int(round((t_start - (clip.speech_start - a / RATE)) * RATE))
        owner = u["speaker"] == fixture["owner"]
        _mix(me if owner else remote, seg, pos)
        timeline.append({"index": i, "speaker": u["speaker"], "channel": "me" if owner else "remote",
                         "t_start": round(t_start, 3), "t_end": round(t_end, 3)})
        end_prev = t_end
    total = int((max(t["t_end"] for t in timeline) + tail) * RATE)
    for buf in (remote, me):
        if len(buf) < total:
            buf.extend(array.array("h", [0]) * (total - len(buf)))
    rp, mp = workdir / "remote.wav", workdir / "me.wav"
    write_wav(rp, remote)
    write_wav(mp, me)
    return Rendered(rp, mp, total / RATE, timeline)


# ---------------------------------------------------------------- speaker bleed

def db_to_gain(db: float) -> float:
    return 10 ** (db / 20)


def rms_dbfs(samples: array.array) -> float | None:
    if not samples:
        return None
    ms = sum(s * s for s in samples) / len(samples)
    return None if ms <= 0 else 20 * math.log10(math.sqrt(ms) / 32768)


def room_noise(n: int, dbfs: float, seed: int, pole: float = 0.9) -> array.array:
    """Gaussian noise through a one-pole low-pass (room and fan noise sit low), scaled to `dbfs` RMS."""
    rng = random.Random(seed)
    raw, y = [], 0.0
    for _ in range(n):
        y = pole * y + (1 - pole) * rng.gauss(0, 1)
        raw.append(y)
    rms = math.sqrt(sum(v * v for v in raw) / max(n, 1)) or 1.0
    k = db_to_gain(dbfs) * 32768 / rms
    return array.array("h", [max(-32768, min(32767, int(round(v * k)))) for v in raw])


def bleed(remote: array.array, own: array.array | None, attenuation_db: float, delay_ms: float, noise_dbfs: float | None,
          seed: int = 7) -> array.array:
    """The microphone with the speakers on: the remote track attenuated by `attenuation_db` (positive = quieter) and delayed
    by `delay_ms`, plus the owner's own speech (full level) if given, plus room noise."""
    n = len(remote)
    g = db_to_gain(-attenuation_db)
    d = int(round(delay_ms / 1000 * RATE))
    out = array.array("h", [0]) * n
    for i in range(d, n):
        out[i] = int(round(remote[i - d] * g))
    if own is not None:
        _mix(out, own[:n], 0)
    if noise_dbfs is not None:
        _mix(out, room_noise(n, noise_dbfs, seed), 0)
    return out


def bleed_wav(remote_path: Path, own_path: Path | None, out_path: Path, attenuation_db: float, delay_ms: float,
              noise_dbfs: float | None, seed: int = 7) -> dict:
    remote = read_wav(remote_path)
    own = read_wav(own_path) if own_path else None
    out = bleed(remote, own, attenuation_db, delay_ms, noise_dbfs, seed)
    write_wav(out_path, out)
    speech = array.array("h", [s for s in out if abs(s) > 0])
    return {"attenuation_db": attenuation_db, "delay_ms": delay_ms, "noise_dbfs": noise_dbfs, "with_own_speech": own is not None,
            "remote_rms_dbfs": _r(rms_dbfs(array.array("h", [s for s in remote if s]))),
            "mic_rms_dbfs": _r(rms_dbfs(speech))}


def _r(x: float | None) -> float | None:
    return None if x is None else round(x, 1)
