#!/usr/bin/env python3
"""Install gate for live nudges (docs/specs/2026-11-27-live-nudges-plan.md): replay a recorded call straight into the Python brain.

    cd brain
    .venv/bin/python ../eval/run_nudges.py --write-demo /scratch/demo                     # a small synthetic session
    .venv/bin/python ../eval/run_nudges.py --arm A --session /scratch/demo                 # fake transport, free
    .venv/bin/python ../eval/run_nudges.py --arm B --session DIR --speed 4 --runs 3 [--trace F] # real judge for tier K (paid)

The session folder needs `pack.md` (+ `bank.jsonl`, `meta.json` as usual), `transcript.jsonl` (one finalized turn per line:
`{turn_id, speaker me|remote|room, text, t_audio_end, ...}`, as the app writes it) and `nudges.jsonl` (prep/nudges.py). Both arms
work on a temporary copy; the given folder is only read.

Arm A (fake transport only): the transcript is fed twice through one Brain each, nudges on and nudges off (VERSE_NUDGES=0), one
turn at a time with every call settled in between, then `control stop`. Every event that is not a nudge event (`nudge`,
`nudge_clear`, tier-K metrics, `nudge_*` metric stages) must be identical; timestamps, durations, the temp path and the
process-wide call ids are normalised first. The K answers come from `runtime.nudges.fake_judge_line`, the answer tiers from
`runtime.fake.bank_responder`. Exit 0 means zero differences.

Arm B (the real API for the nudge checks only, judge `--judge sonnet|haiku`, default sonnet; every other tier stays on the fake
transport, so nothing but the nudge checks is paid; each run also prints the parsed picks the code rejected, with the reason): the
turns are sent at their `t_audio_end` pace divided by `--speed`, without waiting for calls. It prints one line per fired nudge
(id, 0-based row in transcript.jsonl, the speaker of the quoted turn, the quote, seconds from the turn's delivery to the `nudge`
event), then the totals (K calls, audio minutes) and one JSON line with the same data. `--trace FILE` also writes one JSON line
per decision (see `Tracer`); the default output is unchanged by it. The K prefix is not pre-warmed by F calls
here (they are fake), so the first K call of a run writes the cache and latency is slightly pessimistic.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import shutil
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
BRAIN = HERE.parent / "brain"
if str(BRAIN) not in sys.path:
    sys.path.insert(0, str(BRAIN))

from verse_brain.runtime.engine import Brain  # noqa: E402
from verse_brain.runtime.fake import FakeTransport, bank_responder, lines_script  # noqa: E402
from verse_brain.runtime.nudges import fake_judge_line  # noqa: E402
from verse_brain.runtime.protocol import ADDRESSEES, LANGS, TURN_KINDS, ListEmitter  # noqa: E402
from verse_brain.runtime.settings import Config  # noqa: E402

_CALL_ID = re.compile(r"^[a-z]\d{4}$")


# --------------------------------------------------------------------------------------------- input
NEW_RUN_DROP_S = 30.0   # without `run_start`, a clock that goes back by more than this starts a new run (persona/rows.py rule)


def _num(v: object) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def read_transcript(folder: Path) -> list[dict]:
    """The finalized turns of transcript.jsonl as `turn` messages, in file order; `row` is the 0-based line index among the
    lines that hold a turn (the index the label files use). `t_audio_end` is the run clock: rows of the two channels arrive a
    little out of order (a second or two back is normal), so only a new `run_start`, or without one a drop of more than
    NEW_RUN_DROP_S, starts a new run, which is then placed after the previous one."""
    out: list[dict] = []
    offset = last = 0.0
    run = None
    row = -1
    for ln in (folder / "transcript.jsonl").read_text(encoding="utf-8").splitlines():
        if not ln.strip():
            continue
        try:
            o = json.loads(ln)
        except json.JSONDecodeError:
            continue
        row += 1
        tid, text, sp = o.get("turn_id"), o.get("text"), o.get("speaker", "remote")
        if not isinstance(tid, str) or not isinstance(text, str) or not text.strip() or sp not in ("me", "remote", "room"):
            continue
        t = _num(o.get("t_audio_end"))
        t = (last - offset) if t is None else t
        rs = _num(o.get("run_start"))
        if (rs is not None and run is not None and rs != run) or (rs is None and t + offset < last - NEW_RUN_DROP_S):
            offset = last
        run = rs if rs is not None else run
        t_abs = t + offset
        last = max(last, t_abs)
        msg = {"type": "turn", "turn_id": tid, "speaker": sp, "text": text, "t_audio_end": round(t_abs, 3), "_row": row,
               "addressee": o.get("addressee") if o.get("addressee") in ADDRESSEES else ("unknown" if sp == "me" else "me")}
        if o.get("kind") in TURN_KINDS:
            msg["kind"] = o["kind"]
        if o.get("lang") in LANGS:
            msg["lang"] = o["lang"]
        out.append(msg)
    return out


def _copy(session: Path, tmp: Path, name: str) -> Path:
    dst = tmp / name
    shutil.copytree(session, dst)
    return dst


def check_session(session: Path) -> None:
    for f in ("pack.md", "transcript.jsonl"):
        if not (session / f).is_file():
            raise SystemExit(f"{session}: no {f}")
    if not (session / "nudges.jsonl").is_file():
        print(f"warning: {session} has no nudges.jsonl; nothing can fire", file=sys.stderr)


async def settle(b: Brain, timeout: float = 30.0) -> None:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if not [c for c in b.calls if not c.done.is_set()] and not [t for t in b.tasks if not t.done()]:
            return
        await asyncio.sleep(0.01)
    raise RuntimeError("brain did not settle")


def _judge_env(judge: str):
    class _Ctx:
        def __enter__(self):
            self.old = os.environ.get("VERSE_NUDGE_MODEL")
            os.environ["VERSE_NUDGE_MODEL"] = judge

        def __exit__(self, *exc):
            if self.old is None:
                os.environ.pop("VERSE_NUDGE_MODEL", None)
            else:
                os.environ["VERSE_NUDGE_MODEL"] = self.old
    return _Ctx()


def _env(on: bool):
    class _Ctx:
        def __enter__(self):
            self.old = os.environ.get("VERSE_NUDGES")
            os.environ["VERSE_NUDGES"] = "1" if on else "0"

        def __exit__(self, *exc):
            if self.old is None:
                os.environ.pop("VERSE_NUDGES", None)
            else:
                os.environ["VERSE_NUDGES"] = self.old
    return _Ctx()


# --------------------------------------------------------------------------------------------- arm A
def is_k(info) -> bool:
    """A nudge check, whichever judge sends it (the Sonnet judge travels on route label "D", the Haiku judge on "K")."""
    return "NUDGE CHECK." in (info.tail if hasattr(info, "tail") else _tail_of(info))


def _tail_of(request: dict) -> str:
    try:
        return request["messages"][-1]["content"][-1]["text"]
    except (KeyError, IndexError, TypeError):
        return ""


def fake_responder(info):
    if is_k(info):
        return lines_script(fake_judge_line(info.tail))
    return bank_responder(info)


def is_nudge_event(e: dict) -> bool:
    if e.get("type") in ("nudge", "nudge_clear"):
        return True
    return e.get("type") == "metric" and (e.get("tier") == "K" or str(e.get("stage", "")).startswith("nudge"))


def normalise(events: list[dict], folder: Path) -> list[dict]:
    names: dict[str, str] = {}
    root = str(folder)
    out = []
    for e in events:
        if is_nudge_event(e):
            continue
        n = {}
        for k, v in e.items():
            if k == "t" or k == "ms" or k.endswith("_ms"):
                continue
            if k in ("id", "card_id", "call") and isinstance(v, str) and _CALL_ID.match(v):
                v = names.setdefault(v, f"{v[0]}#{len(names)}")
            if isinstance(v, str) and root in v:
                v = v.replace(root, "<session>")
            n[k] = v
        out.append(n)
    return out


async def _arm_a_once(folder: Path, turns: list[dict], on: bool) -> tuple[list[dict], FakeTransport, Brain]:
    with _env(on):
        t = FakeTransport(fake_responder)
        em = ListEmitter()
        b = Brain(t, em, Config())
        b.start_background = False
        await b.handle({"type": "start", "session_dir": str(folder), "lang": "en"})
        await b.warmed()
        for m in turns:
            await b.handle(_send(m))
            await settle(b)
        await b.stop()
    return em.events, t, b


def arm_a(session: Path) -> int:
    turns = read_transcript(session)
    with tempfile.TemporaryDirectory(prefix="verse-nudges-a-") as tmp:
        on_dir = _copy(session, Path(tmp), "on")
        off_dir = _copy(session, Path(tmp), "off")
        ev_on, t_on, _ = asyncio.run(_arm_a_once(on_dir, turns, True))
        ev_off, t_off, _ = asyncio.run(_arm_a_once(off_dir, turns, False))
        a, b = normalise(ev_on, on_dir), normalise(ev_off, off_dir)
    diffs = []
    for i in range(max(len(a), len(b))):
        x = a[i] if i < len(a) else None
        y = b[i] if i < len(b) else None
        if x != y:
            diffs.append({"index": i, "on": x, "off": y})
    fired = [e for e in ev_on if e.get("type") == "nudge"]
    cleared = [e for e in ev_on if e.get("type") == "nudge_clear"]
    k_calls = sum(1 for c in t_on.calls if is_k(c))
    k_off = sum(1 for c in t_off.calls if is_k(c))
    print(f"arm A: {len(turns)} turns, {len(a)} non-nudge events compared, {len(diffs)} differences")
    print(f"nudges on: {k_calls} K calls, {len(fired)} nudge(s) fired ({', '.join(e['id'] + '@' + e['turn_id'] for e in fired) or '-'}), "
          f"{len(cleared)} cleared; nudges off: {k_off} K calls")
    for d in diffs[:5]:
        print(f"  diff at {d['index']}: on={json.dumps(d['on'])[:200]} off={json.dumps(d['off'])[:200]}")
    if not fired:
        print("warning: no nudge fired in the on run; the comparison does not exercise a fire", file=sys.stderr)
    print(json.dumps({"arm": "A", "turns": len(turns), "events": len(a), "differences": len(diffs), "k_calls": k_calls,
                      "fired": [{"id": e["id"], "turn_id": e["turn_id"]} for e in fired], "cleared": len(cleared),
                      "k_calls_off": k_off}))
    return 0 if not diffs and not k_off else 1


# --------------------------------------------------------------------------------------------- arm B
class SplitTransport:
    """The nudge checks go to the real API; everything else (pre-warm, pings, S/F/D/R/A/V/C) to the fake transport."""

    def __init__(self, real, fake: FakeTransport) -> None:
        self.real, self.fake = real, fake
        self.k_calls = 0

    async def open_stream(self, route, request, lane):
        if "NUDGE CHECK." in _tail_of(request):
            self.k_calls += 1
            return await self.real.open_stream(route, request, lane)
        return await self.fake.open_stream(route, request, lane)

    async def create(self, route, request, lane):
        return await self.fake.create(route, request, lane)

    async def ping(self, model, lane):
        return await self.fake.ping(model, lane)

    async def aclose(self) -> None:
        await self.fake.aclose()


class Tracer:
    """`--trace FILE`: one JSON line per decision. `turn`: every turn sent (row, speaker, text clipped to 160 chars, the
    candidates and the skip reason when no K call went out: no_candidates, repeat (the row added no new words), cooling,
    in_flight (deferred to a catch-up), bucket_low, offline, not_started, nudges_off). `catch_up`: a deferred evaluation run
    after a K call returned. `judge`: every K result (the tail's candidate ids, the raw judge line, the verdict: fired, none,
    garbage, or the reason a pick was rejected: not_candidate, quote_not_in_window, who, cooldown, stale, retired, gates,
    quote_too_long; error/discarded for a failed call; plus the window the judge saw). `retire`: the money rule."""

    def __init__(self, fh, run_no: int, rows: dict[str, int]) -> None:
        self.fh, self.run, self.rows = fh, run_no, rows
        self.gate: dict | None = None

    def write(self, rec: dict) -> None:
        if self.fh is not None:
            self.fh.write(json.dumps({"run": self.run, **rec}, ensure_ascii=False) + "\n")
            self.fh.flush()

    def on_ev(self, ev: str, fields: dict) -> None:
        turn = fields.get("turn")
        if ev == "nudge_gate":
            if fields.get("reason") == "catch_up":
                self.write({"kind": "catch_up", "row": self.rows.get(turn), "turn_id": turn,
                            "candidates": fields.get("candidates"), "skip": fields.get("skipped")})
            else:
                self.gate = fields
        elif ev == "nudge_judge":
            self.write({"kind": "judge", "row": self.rows.get(turn), "turn_id": turn, "call": fields.get("call"),
                        "tail_ids": fields.get("candidates"), "raw": fields.get("raw"), "verdict": fields.get("result"),
                        "pick": fields.get("pick"), "quote": fields.get("quote"), "who": fields.get("who"),
                        "age_s": fields.get("age_s"),
                        "window": fields.get("window")})
        elif ev == "nudge_retire":
            self.write({"kind": "retire", "row": self.rows.get(turn), "turn_id": turn, "id": fields.get("id"),
                        "cleared": fields.get("cleared")})

    def turn(self, b: Brain, m: dict, words_before: int) -> None:
        g, self.gate = self.gate, None
        tr = b.nudges
        if g is not None:
            skip, cands, keys, reason = g.get("skipped"), g.get("candidates"), g.get("keys"), g.get("reason")
        else:
            cands, keys, reason = [], [], None
            if tr is None:
                skip = "nudges_off"
            elif m["speaker"] not in ("me", "remote"):
                skip = "speaker"
            elif _utt_words(tr) == words_before:
                skip = "repeat"
            elif tr.cooling():
                skip = "cooling"
            else:
                skip = "no_candidates"
        self.write({"kind": "turn", "row": m.get("_row"), "turn_id": m["turn_id"], "speaker": m["speaker"],
                    "t": m["t_audio_end"], "text": m["text"][:160], "candidates": cands, "keys": keys, "reason": reason,
                    "skip": skip})


def _utt_words(tr) -> int:
    return sum(len(u.words) for u in tr.utts) + len(tr.utts) if tr is not None else 0


def _send(m: dict) -> dict:
    return {k: v for k, v in m.items() if not k.startswith("_")}


async def _arm_b_once(folder: Path, turns: list[dict], speed: float, real, run_no: int, trace_fh=None) -> dict:
    split = SplitTransport(real, FakeTransport(bank_responder))
    em = ListEmitter()
    b = Brain(split, em, Config())
    b.start_background = False
    fires: dict[str, dict] = {}
    rows = {m["turn_id"]: m.get("_row") for m in turns}
    tracer = Tracer(trace_fh, run_no, rows)
    orig_ev = b._ev

    rejected: list[dict] = []

    def tap(ev: str, **fields) -> None:
        if ev == "nudge_fire":
            fires[fields.get("id")] = fields
        elif ev == "nudge_judge" and fields.get("pick") and fields.get("result") != "fired":
            rejected.append({"run": run_no, "row": rows.get(fields.get("turn")), "id": fields.get("pick"),
                             "reason": fields.get("result"), "quote": fields.get("quote")})
        tracer.on_ev(ev, fields)
        orig_ev(ev, **fields)
    b._ev = tap
    with _env(True):
        await b.handle({"type": "start", "session_dir": str(folder), "lang": "en"})
        await b.warmed()
    sent: dict[str, float] = {}
    t_first = turns[0]["t_audio_end"] if turns else 0.0
    t0 = time.monotonic()
    for m in turns:
        due = t0 + (m["t_audio_end"] - t_first) / speed
        await asyncio.sleep(max(0.0, due - time.monotonic()))
        sent[m["turn_id"]] = time.monotonic()
        before = _utt_words(b.nudges)
        await b.handle(_send(m))
        tracer.turn(b, m, before)
    try:
        await settle(b, timeout=15.0)
    except RuntimeError:
        pass
    out = []
    for e, t_recv in zip(em.events, em.times):
        if e.get("type") != "nudge":
            continue
        f = fires.get(e["id"], {})
        out.append({"run": run_no, "id": e["id"], "row": rows.get(e["turn_id"]), "turn_id": e["turn_id"],
                    "speaker": f.get("speaker"), "quote": f.get("quote"),
                    "latency_s": round(t_recv - sent[e["turn_id"]], 3) if e["turn_id"] in sent else None})
    cleared = [e["id"] for e in em.events if e.get("type") == "nudge_clear"]
    errors = [e for e in em.events if e.get("type") == "metric" and e.get("stage") == "nudge_error"]
    await b.shutdown()
    return {"fires": out, "rejected": rejected, "k_calls": split.k_calls, "cleared": cleared, "nudge_errors": errors}


def audio_minutes(turns: list[dict]) -> float:
    return round(((turns[-1]["t_audio_end"] - turns[0]["t_audio_end"]) if turns else 0.0) / 60.0, 2)


def arm_b(session: Path, speed: float, runs: int, trace: Path | None = None, transport_factory=None, judge: str = "sonnet") -> int:
    """`transport_factory`: tests pass a fake in place of the real API client."""
    turns = read_transcript(session)
    audio_min = audio_minutes(turns)
    if transport_factory is None:
        from verse_brain.apiroute import load_credentials
        from verse_brain.runtime.transport import AnthropicTransport

        def transport_factory():
            return AnthropicTransport(load_credentials())

    async def all_runs() -> list[dict]:
        real = transport_factory()   # one client, one event loop for every run
        fh = open(trace, "w", encoding="utf-8") if trace is not None else None
        out = []
        try:
            for r in range(1, runs + 1):
                with tempfile.TemporaryDirectory(prefix="verse-nudges-b-") as tmp:
                    with _judge_env(judge):
                        res = await _arm_b_once(_copy(session, Path(tmp), "session"), turns, speed, real, r, fh)
                out.append(res)
                for f in res["fires"]:
                    print(f"fire run={r} id={f['id']} row={f['row']} ({f['turn_id']}) speaker={f['speaker']} "
                          f"quote={json.dumps(f['quote'])} latency_s={f['latency_s']}", flush=True)
                for x in res["rejected"]:
                    print(f"reject run={r} row={x['row']} id={x['id']} reason={x['reason']}", flush=True)
                if res["nudge_errors"]:
                    print(f"run {r}: nudges turned off by an error: {res['nudge_errors'][0].get('reason')}", file=sys.stderr)
        finally:
            if fh is not None:
                fh.close()
            await real.aclose()
        return out

    results = asyncio.run(all_runs())
    k_total = sum(r["k_calls"] for r in results)
    fires = [f for r in results for f in r["fires"]]
    per_2min = round(k_total / runs / (audio_min / 2.0), 3) if audio_min > 0 and runs else None
    print(f"totals: runs={runs} judge={judge} speed={speed} fires={len(fires)} rejected={sum(len(r['rejected']) for r in results)} k_calls={k_total} "
          f"(per run {[r['k_calls'] for r in results]}) audio_min={audio_min} k_calls_per_2min={per_2min}")
    print(json.dumps({"arm": "B", "session": session.name, "judge": judge, "runs": runs, "speed": speed, "audio_min": audio_min,
                      "k_calls": k_total, "k_calls_per_run": [r["k_calls"] for r in results], "k_calls_per_2min": per_2min,
                      "fires": fires, "rejected": [x for r in results for x in r["rejected"]],
                      "cleared": [r["cleared"] for r in results]}, ensure_ascii=False))
    return 0


# --------------------------------------------------------------------------------------------- demo session
DEMO_TURNS = [
    ("r1", "remote", "Thanks for joining today. Could you start with a short intro?", 6.0),
    ("m1", "me", "Sure. I led an invoice extraction project called Lantern for two years.", 14.0),
    ("r2", "remote", "Nice. What tooling did the team use day to day?", 22.0),
    ("m2", "me", "Mostly Python, a small queue and a review screen for the operators.", 30.0),
    ("r3", "remote", "How did you handle fields the model was unsure about?", 41.0),
    ("m3", "me", "Low confidence fields went to an operator queue.", 48.0),
    ("r4", "remote", "Good. We will get to pay later, first tell me about the team.", 58.0),
    ("m4", "me", "It was four engineers and two operators.", 64.0),
    ("r5", "remote", "Okay, let's talk about the salary range for this role now.", 140.0),
    ("m5", "me", "Happy to. Before a number, a short story about the pilot.", 147.0),
    ("r6", "remote", "Sure, and what number did you have in mind?", 156.0),
    ("m6", "me", "I was thinking around 80k plus equity.", 162.0),
]

DEMO_NUDGES = [
    {"id": "n001", "title": "Pay story", "when": "pay, salary or the package is being discussed now", "keys": ["salary", "pay",
     "package", "compensat"], "who": "any", "until": "number", "after_s": 0.0,
     "say": ["Tell the pilot story before any number.", "Then give the range."], "ref": "prep:L40"},
    {"id": "n002", "title": "Ask about tools", "when": "their tools or stack are being discussed", "keys": ["tooling", "stack"],
     "who": "them", "until": None, "after_s": 0.0, "say": ["Ask which tracker they use today."], "ref": "prep:L48"},
]


def write_demo(dst: Path) -> None:
    src = BRAIN / "tests" / "fixtures" / "runtime" / "session"
    dst.mkdir(parents=True, exist_ok=True)
    for f in ("pack.md", "bank.jsonl", "meta.json"):
        shutil.copy2(src / f, dst / f)
    (dst / "transcript.jsonl").write_text("".join(json.dumps({"turn_id": tid, "speaker": sp, "text": text, "t_audio_end": t,
                                                              "lang": "en"}) + "\n" for tid, sp, text, t in DEMO_TURNS),
                                          encoding="utf-8")
    (dst / "nudges.jsonl").write_text("".join(json.dumps(r, sort_keys=True) + "\n" for r in DEMO_NUDGES), encoding="utf-8")
    print(f"wrote a synthetic session to {dst}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="run_nudges.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--arm", choices=("A", "B"), help="A: fake transport, nudges on vs off; B: real Haiku for tier K (paid)")
    ap.add_argument("--session", type=Path, help="session folder with pack.md, transcript.jsonl and nudges.jsonl")
    ap.add_argument("--speed", type=float, default=1.0, help="arm B: replay speed (audio seconds per wall second)")
    ap.add_argument("--runs", type=int, default=1, help="arm B: number of replays")
    ap.add_argument("--trace", type=Path, metavar="FILE", help="arm B: write one JSON line per nudge decision to FILE")
    ap.add_argument("--judge", choices=("sonnet", "haiku"), default="sonnet", help="arm B: the nudge judge model (VERSE_NUDGE_MODEL)")
    ap.add_argument("--write-demo", type=Path, metavar="DIR", help="write a small synthetic session to DIR and exit")
    a = ap.parse_args(argv)
    if a.write_demo is not None:
        write_demo(a.write_demo.expanduser())
        return 0
    if a.arm is None or a.session is None:
        ap.error("--arm and --session are required (or --write-demo DIR)")
    session = a.session.expanduser().resolve()
    check_session(session)
    if a.arm == "A":
        return arm_a(session)
    if a.speed <= 0 or a.runs < 1:
        ap.error("--speed must be > 0 and --runs >= 1")
    return arm_b(session, a.speed, a.runs, a.trace, judge=a.judge)


if __name__ == "__main__":
    sys.exit(main())
