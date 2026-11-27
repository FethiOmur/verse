"""Post-call health report: did Verse misbehave in a finished call, and where.

    cd brain && .venv/bin/python -m verse_brain.runtime.report SESSION_DIR [--log PATH_TO_verse.log] [--out DIR] [--json]
                                                               [--late 3.0] [--gap 60] [--no-log]

Built only from what the session already recorded: `transcript.jsonl`, `events.jsonl` (runtime/events.py), `bank.jsonl`,
`meta.json`, `spend.json`, `nudges.jsonl` and the app's log (`~/Library/Logs/Verse/verse.log` unless `--log` / `--no-log`). No
model call, no network, nothing is written into the session folder. It writes `report.md` (plain language, most important first)
and `report.json` (the same findings under stable keys, so a later tool can diff two calls) into `--out` (default: a
`verse-report/<session>` folder under the system temp dir) and prints the Markdown (or, with `--json`, the JSON) to stdout.

A session folder may hold several runs (a rehearsal, then the real call; or a call stopped and started again): each `start` event
and each audio clock in the transcript (`t_wall - t_audio_end`, or `run_start`) opens a run, and turn ids are only unique within a
run. A `start` followed by a `history` replay before any turn is a brain restart inside the same run, not a new one.

Everything is read leniently: a missing file, a malformed line or a field of the wrong type is counted and skipped, never fatal.
Event types the report does not know are counted and listed at the end, so gaps in the tool stay visible.

What the session does not record cannot be checked; `BLIND_SPOTS` says what is missing and where it would be logged.
"""

from __future__ import annotations

import argparse
import bisect
import json
import math
import re
import statistics
import sys
import tempfile
import time
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from .events import clip

SCHEMA = 1
LATE_S = 3.0             # turn end -> first card line on screen
GAP_S = 60.0             # no transcript row for this long
BUDGET_WARN = 0.8        # share of the budget that counts as "near"
RUN_MERGE_S = 30.0       # a start event and an audio clock this close are one run
LOG_MATCH_S = 120.0      # a `start session=` log line this close to a run's start belongs to it
LOG_TAIL_S = 300.0       # without a `run ended` line the log window ends this long after the run's last event
CAUSE_WINDOW_S = 20.0    # log lines this soon after a turn may explain its missing card
SAID = 80
OPENER = 60
DEFAULT_LOG = Path("~/Library/Logs/Verse/verse.log").expanduser()

HIGH, MED, LOW = "high", "medium", "low"
SEV_ORDER = {HIGH: 0, MED: 1, LOW: 2}

# Every `ev` the brain writes to events.jsonl today (engine.py `_ev`, follow.py `_log`). Anything else is "not understood".
KNOWN_EVENTS = {
    "start", "turn", "probe", "card", "card_done", "card_suppressed", "card_held", "card_released", "own_card", "bank_verdict",
    "point_dropped", "room_gate", "room_text", "card_now", "card_mark", "regenerate", "lang_dominant", "route", "history",
    "follow_state", "follow_embed_state", "follow_diverged",
    "nudge_gate", "nudge_judge", "nudge_fire", "nudge_retire",
}
NORMAL_STATUS = {"warming", "ready", "restarting"}     # restarting is reported from the log's restart line itself
HIGH_STATUS = {"error", "offline", "credit_exhausted"}
OK_SUPPRESS = {"card_now_covers"}                      # the question was answered by a card-now card
ROUTES = ("meeting", "phone", "room")
ROOM_NUDGES_WHAT = ("ran on the microphone-only route; nudges are off on this route and the other side is not separated")
ROOM_MEETING_WHAT = ("a meeting app took the microphone after Start; the session stayed on the microphone-only route")
ROOM_ANSWERS_NOTE = "on the room route these may be the owner's own sentences"
_MEETING_DETECTED = re.compile(r"meeting detected in .* while a session runs")

BLIND_SPOTS = [
    {"signal": "first visible text of a card (metric stages fire / first_byte / first_delta / visible / done)",
     "effect": "time to card is measured to the first COMPLETE card line (`card` event), not to the first visible delta; "
               "it overstates the wait by the time one line takes to stream",
     "where": "engine.py Call._stage (sent to the app only through Emitter.metric); writing the stage to events.jsonl there "
              "(self.brain._ev('stage', ...)) would record it"},
    {"signal": "calls dropped by the client-side rate bucket (metric `dropped_rate_bucket`)",
     "effect": "a question with no card cannot be blamed on the bucket; S/F drops leave no trace at all",
     "where": "engine.py Brain._launch, the `dropped_rate_bucket` metric"},
    {"signal": "hedged calls and stop reasons (metric stages `hedge`, `done{stop_reason,hedged,usage}`)",
     "effect": "hedging and answer calls cut at max_tokens cannot be detected (only the K judge's stop is logged)",
     "where": "engine.py Call.run (`_stage('done', ...)`) and BrainSession hedge (`call._stage('hedge', ...)`)"},
    {"signal": "status events (offline, rate_limited, error, budget, refusal)",
     "effect": "only visible through verse.log (`brain status ...` lines); without the log they are not checked",
     "where": "engine.py Brain._status / _halt; not written to events.jsonl"},
    {"signal": "a meeting app taking the microphone after Start (the call stays on the microphone-only route)",
     "effect": "only visible through verse.log (`meeting detected in <app> while a session runs: no prompt`); without the log it is "
               "not checked",
     "where": "the app's own log; not written to events.jsonl"},
    {"signal": "opener_status (the model rejected the bank opener)",
     "effect": "a card whose opener was rejected cannot be detected",
     "where": "engine.py Call (`opener_status` event, emitted to the app only)"},
    {"signal": "call errors with their turn",
     "effect": "only from verse.log (`call <id> (<tier>) failed`), mapped to a turn when that call id left a card or probe event",
     "where": "engine.py Brain.on_call_error (log.warning only)"},
    {"signal": "spend per tier",
     "effect": "spend.json has one total per run; per-tier calls and cost cannot be split",
     "where": "engine.py Brain.on_call_done (cost per call is computed there, never logged)"},
    {"signal": "bank hits as the app saw them (`bank_hit` event)",
     "effect": "a bank match is visible only through `own_card` (its opener went on screen) and `bank_verdict`",
     "where": "engine.py Brain._bank_hit_embed / bank hit handling (emitted to the app only)"},
]


# ------------------------------------------------------------------------------------------------------------- helpers
def num(v: object) -> float | None:
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    f = float(v)
    return f if math.isfinite(f) else None


def text_of(v: object) -> str:
    if v is None:
        return ""
    return v if isinstance(v, str) else str(v)


def sid(v: object) -> str | None:
    """A turn or call id: a non-empty string, or None."""
    return v if isinstance(v, str) and v else None


def mmss(t: float | None) -> str:
    if t is None:
        return "--:--"
    t = max(0.0, t)
    return f"{int(t // 60):02d}:{int(t % 60):02d}"


def read_jsonl(path: Path) -> tuple[list[dict], int, bool]:
    """(objects, malformed line count, file present)."""
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
    except (OSError, ValueError):
        return [], 0, False
    rows: list[dict] = []
    bad = 0
    for ln in raw.splitlines():
        if not ln.strip():
            continue
        try:
            o = json.loads(ln)
        except ValueError:
            bad += 1
            continue
        if isinstance(o, dict):
            rows.append(o)
        else:
            bad += 1
    return rows, bad, True


def read_json(path: Path) -> dict | None:
    try:
        o = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except (OSError, ValueError):
        return None
    return o if isinstance(o, dict) else None


def pct(values: list[float], q: float) -> float | None:
    if not values:
        return None
    v = sorted(values)
    k = (len(v) - 1) * q
    lo, hi = math.floor(k), math.ceil(k)
    return v[lo] if lo == hi else v[lo] + (v[hi] - v[lo]) * (k - lo)


def r2(v: float | None) -> float | None:
    return None if v is None else round(v, 2)


def iso(t: float | None) -> str | None:
    if t is None:
        return None
    try:
        return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (OverflowError, OSError, ValueError):
        return None


def parse_iso(s: object) -> float | None:
    if not isinstance(s, str) or not s:
        return None
    try:
        d = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return d.timestamp()


# ------------------------------------------------------------------------------------------------------------- model
@dataclass
class Turn:
    tid: str
    speaker: str = ""
    text: str = ""
    kind: str | None = None
    addressee: str | None = None
    t_audio: float | None = None         # seconds since the run's audio started (speech end)
    t_end_wall: float | None = None      # speech end on the wall clock
    in_transcript: bool = False
    ev_turn: dict | None = None
    probe: str | None = None
    probe_error: str | None = None
    probe_discarded: bool = False
    probe_id: str | None = None
    suppressed: list[dict] = field(default_factory=list)
    held: bool = False
    released: bool = False
    cards: list[dict] = field(default_factory=list)
    card_done: list[dict] = field(default_factory=list)
    own_bank: dict | None = None
    verdicts: list[dict] = field(default_factory=list)
    nudges: list[str] = field(default_factory=list)

    @property
    def brain_kind(self) -> str | None:
        k = self.ev_turn.get("kind") if self.ev_turn else None
        k = k if isinstance(k, str) else None
        return k or self.kind

    @property
    def remote(self) -> bool:
        return self.speaker in ("remote", "room")

    @property
    def question(self) -> bool:
        if self.probe == "question":
            return True
        k = self.brain_kind
        if k == "question":
            return True
        return k is None and bool(self.ev_turn and self.ev_turn.get("cue") is True)

    @property
    def to_owner(self) -> bool:
        return self.addressee != "other"

    @property
    def recv_wall(self) -> float | None:
        return num(self.ev_turn.get("t")) if self.ev_turn else None


@dataclass
class Run:
    index: int
    anchor: float | None
    audio0: float | None = None
    audio0_known: bool = False
    events: list[dict] = field(default_factory=list)
    rows: list[dict] = field(default_factory=list)
    turns: dict[str, Turn] = field(default_factory=dict)
    order: list[str] = field(default_factory=list)
    calls: dict[str, str] = field(default_factory=dict)     # call id -> turn id
    restarts: list[dict] = field(default_factory=list)
    starts: int = 0
    mode: str | None = None              # from the run's first `start` event
    route_start: str | None = None       # route in that `start` event
    route: str | None = None             # route now: the last `start` / `route` event
    regens: list[dict] = field(default_factory=list)
    marks: list[dict] = field(default_factory=list)
    card_now: list[dict] = field(default_factory=list)
    gates: list[dict] = field(default_factory=list)
    judges: list[dict] = field(default_factory=list)
    fires: list[dict] = field(default_factory=list)
    retires: list[dict] = field(default_factory=list)
    points_dropped: int = 0
    dup_rows: int = 0
    last_wall: float | None = None

    def turn(self, tid: str) -> Turn:
        t = self.turns.get(tid)
        if t is None:
            t = self.turns[tid] = Turn(tid)
            self.order.append(tid)
        return t

    def audio_at(self, wall: float | None) -> float | None:
        if wall is None or self.audio0 is None:
            return None
        return wall - self.audio0

    def turn_audio(self, t: Turn) -> float | None:
        if t.t_audio is not None:
            return t.t_audio
        return self.audio_at(t.recv_wall)

    def turn_at(self, wall: float) -> Turn | None:
        """The newest turn that had ended (or reached the brain) by `wall`."""
        best, best_t = None, None
        for tid in self.order:
            t = self.turns[tid]
            tw = t.t_end_wall if t.t_end_wall is not None else t.recv_wall
            if tw is not None and tw <= wall and (best_t is None or tw >= best_t):
                best, best_t = t, tw
        return best


class Findings:
    def __init__(self) -> None:
        self.items: list[dict] = []
        self._keys: set[str] = set()

    def add(self, kind: str, severity: str, what: str, *, run: Run | None = None, turn: Turn | None = None,
            t_audio: float | None = None, said: str | None = None, key: str | None = None, **details) -> dict | None:
        if turn is not None and run is not None and t_audio is None:
            t_audio = run.turn_audio(turn)
        k = key or f"{kind}:{run.index if run else 0}:{turn.tid if turn else ''}:{r2(t_audio)}:{what[:40]}"
        if k in self._keys:
            return None
        self._keys.add(k)
        item = {"id": k, "kind": kind, "severity": severity, "run": run.index if run else None,
                "turn": turn.tid if turn else None, "speaker": turn.speaker if turn else None,
                "t_audio": r2(t_audio), "time": mmss(t_audio),
                "said": clip(said if said is not None else (turn.text if turn else ""), SAID) or None,
                "what": what, "details": {k2: v for k2, v in details.items() if v is not None}}
        self.items.append(item)
        return item


# ------------------------------------------------------------------------------------------------------------- runs
def _row_wall(r: dict) -> tuple[float | None, float | None]:
    """(speech end on the wall clock, the run's audio zero) of a transcript row, when it carries the clocks."""
    ta = num(r.get("t_audio_end"))
    tw = num(r.get("t_wall"))
    rs = num(r.get("run_start"))
    if tw is None and rs is not None and ta is not None:
        tw = rs + ta
    if rs is None and tw is not None and ta is not None:
        rs = tw - ta
    return tw, rs


def _restart_starts(events: list[dict]) -> set[int]:
    """Indexes of `start` events that are a brain restart: a `history` replay comes before the next `turn`."""
    out: set[int] = set()
    for i, e in enumerate(events):
        if e.get("ev") != "start":
            continue
        for e2 in events[i + 1:]:
            ev = e2.get("ev")
            if ev in ("turn", "start"):
                break
            if ev == "history":
                out.add(i)
                break
    return out


def build_runs(events: list[dict], rows: list[dict]) -> list[Run]:
    restarts = _restart_starts(events)
    anchors: list[tuple[float, float | None]] = []      # (wall time, audio zero if known)
    for i, e in enumerate(events):
        t = num(e.get("t"))
        if e.get("ev") == "start" and t is not None and i not in restarts:
            anchors.append((t, None))
    for r in rows:
        _, rs = _row_wall(r)
        if rs is not None:
            anchors.append((rs, rs))
    anchors.sort(key=lambda a: a[0])
    groups: list[list[tuple[float, float | None]]] = []
    for a in anchors:
        if groups and a[0] - groups[-1][0][0] <= RUN_MERGE_S:
            groups[-1].append(a)
        else:
            groups.append([a])
    runs: list[Run] = []
    for g in groups:
        run = Run(len(runs) + 1, g[0][0])
        zeros = [z for _, z in g if z is not None]
        if zeros:
            run.audio0, run.audio0_known = statistics.median(zeros), True
        runs.append(run)
    if not runs:
        runs.append(Run(1, None))
    starts = [r.anchor if r.anchor is not None else -math.inf for r in runs]

    def at(t: float | None, default: int) -> int:
        if t is None:
            return default
        return max(0, bisect.bisect_right(starts, t + 2.0) - 1)

    cur = 0
    for e in events:
        cur = at(num(e.get("t")), cur)
        runs[cur].events.append(e)

    walled = [r for r in rows if _row_wall(r)[0] is not None]
    if len(walled) == len(rows):
        for r in rows:
            runs[at(_row_wall(r)[0], 0)].rows.append(r)
    else:
        _assign_rows_by_text(runs, rows, at)
    return runs


def _assign_rows_by_text(runs: list[Run], rows: list[dict], at) -> None:
    """Rows without wall clocks (older sessions): a row whose turn id and clipped text match a `turn` event belongs to that
    event's run; the others follow the nearest matched row of the same audio segment (a new segment starts where t_audio_end
    falls back)."""
    index: dict[tuple[str, str], int] = {}
    for run in runs:
        for e in run.events:
            if e.get("ev") == "turn" and sid(e.get("turn")):
                index.setdefault((e["turn"], text_of(e.get("text"))), run.index - 1)
    seg, prev_ta = 0, None
    segs: list[int] = []
    owner: list[int | None] = []
    for r in rows:
        ta = num(r.get("t_audio_end"))
        if ta is not None and prev_ta is not None and ta < prev_ta - 5.0:
            seg += 1
        if ta is not None:
            prev_ta = ta
        segs.append(seg)
        tw = _row_wall(r)[0]
        if tw is not None:
            owner.append(at(tw, 0))
            continue
        owner.append(index.get((text_of(r.get("turn_id")), clip(text_of(r.get("text"))))))
    seg_run: dict[int, int] = {}
    for s, o in zip(segs, owner):
        if o is not None:
            seg_run.setdefault(s, o)
    last = 0
    for i, r in enumerate(rows):
        o = owner[i]
        if o is None:
            o = seg_run.get(segs[i], last)
        last = o
        runs[min(o, len(runs) - 1)].rows.append(r)


def fill_run(run: Run, unknown: Counter) -> None:
    for r in run.rows:
        tid = sid(r.get("turn_id"))
        if tid is None:
            continue
        if tid in run.turns and run.turns[tid].in_transcript:
            run.dup_rows += 1
            continue
        t = run.turn(tid)
        t.in_transcript = True
        t.speaker = text_of(r.get("speaker"))
        t.text = text_of(r.get("text"))
        k = r.get("kind")
        t.kind = k if isinstance(k, str) else None
        a = r.get("addressee")
        t.addressee = a if isinstance(a, str) else None
        t.t_audio = num(r.get("t_audio_end"))
        t.t_end_wall = _row_wall(r)[0]
    for e in run.events:
        ev = e.get("ev")
        t_ev = num(e.get("t"))
        if t_ev is not None:
            run.last_wall = t_ev if run.last_wall is None else max(run.last_wall, t_ev)
        tid = sid(e.get("turn"))
        if not isinstance(ev, str) or ev not in KNOWN_EVENTS:
            unknown[ev if isinstance(ev, str) else f"<{type(ev).__name__}>"] += 1
            continue
        if ev == "start":
            run.starts += 1
            if run.starts == 1:
                run.mode = e.get("mode") if isinstance(e.get("mode"), str) else None
                run.route_start = run.route = e.get("route") if e.get("route") in ROUTES else None
        elif ev == "route":
            if e.get("route") in ROUTES:
                run.route = e["route"]
        elif ev == "history":
            run.restarts.append(e)
        elif ev == "turn" and tid:
            t = run.turn(tid)
            if t.ev_turn is None:
                t.ev_turn = e
            if not t.in_transcript:
                t.speaker = text_of(e.get("speaker")) or t.speaker
                t.text = t.text or text_of(e.get("text"))
        elif ev == "probe" and tid:
            t = run.turn(tid)
            v = e.get("verdict")
            t.probe = v if isinstance(v, str) else None
            t.probe_id = sid(e.get("id"))
            if t.probe == "none":
                t.probe_error = text_of(e.get("error")) or None
                t.probe_discarded = e.get("discarded") is True
            if t.probe_id:
                run.calls.setdefault(t.probe_id, tid)
        elif ev in ("card", "card_done") and tid:
            t = run.turn(tid)
            (t.cards if ev == "card" else t.card_done).append(e)
            if sid(e.get("id")):
                run.calls.setdefault(e["id"], tid)
        elif ev == "own_card" and tid:
            t = run.turn(tid)
            if t.own_bank is None:
                t.own_bank = e
        elif ev == "bank_verdict" and tid:
            run.turn(tid).verdicts.append(e)
        elif ev == "card_suppressed" and tid:
            run.turn(tid).suppressed.append(e)
        elif ev == "card_held" and tid:
            run.turn(tid).held = True
        elif ev == "card_released" and tid:
            run.turn(tid).released = True
        elif ev == "point_dropped":
            run.points_dropped += 1
        elif ev == "regenerate":
            run.regens.append(e)
        elif ev == "card_mark":
            run.marks.append(e)
        elif ev == "card_now":
            run.card_now.append(e)
        elif ev == "nudge_gate":
            run.gates.append(e)
        elif ev == "nudge_judge":
            run.judges.append(e)
            if sid(e.get("call")) and tid:
                run.calls.setdefault(e["call"], tid)
        elif ev == "nudge_fire":
            run.fires.append(e)
            if tid and sid(e.get("id")):
                run.turn(tid).nudges.append(e["id"])
        elif ev == "nudge_retire":
            run.retires.append(e)
    if run.audio0 is None:      # no clock in the transcript: estimate audio zero from turns that reached the brain
        est = [t.recv_wall - t.t_audio for t in run.turns.values() if t.recv_wall is not None and t.t_audio is not None]
        if est:
            run.audio0 = statistics.median(est)
        elif run.anchor is not None:
            run.audio0 = run.anchor
    if run.audio0 is not None:
        for t in run.turns.values():
            if t.t_end_wall is None and t.t_audio is not None and run.audio0_known:
                t.t_end_wall = run.audio0 + t.t_audio


# ------------------------------------------------------------------------------------------------------------- per-turn facts
def first_card(t: Turn, bank: dict[str, dict]) -> dict | None:
    """The first thing shown for this turn: {t, tier, id, opener}."""
    cands: list[tuple[float, str, str | None, dict]] = []
    for c in t.cards:
        tc = num(c.get("t"))
        if tc is not None:
            cands.append((tc, text_of(c.get("tier")) or "?", sid(c.get("id")), c))
    if t.own_bank is not None and num(t.own_bank.get("t")) is not None:
        cands.append((num(t.own_bank.get("t")), "P", None, t.own_bank))
    if not cands:
        if t.cards:                     # cards without a usable time
            c = t.cards[0]
            return {"t": None, "tier": text_of(c.get("tier")) or "?", "id": sid(c.get("id")), "opener": _opener(t, c, bank)}
        return None
    tc, tier, cid, src = min(cands, key=lambda c: c[0])
    return {"t": tc, "tier": tier, "id": cid, "opener": _opener(t, src, bank)}


def _opener(t: Turn, src: dict, bank: dict[str, dict]) -> str:
    if src.get("ev") == "own_card":
        rec = bank.get(text_of(src.get("bank")), {})
        return clip(text_of(rec.get("opener")) or f"bank {text_of(src.get('bank'))}", OPENER)
    cid = src.get("id")
    for d in t.card_done:
        if d.get("id") == cid and text_of(d.get("say")):
            return clip(text_of(d.get("say")), OPENER)
    for d in t.card_done:
        if text_of(d.get("say")):
            return clip(text_of(d.get("say")), OPENER)
    return clip(text_of(src.get("text")), OPENER)


def latency(t: Turn, fc: dict | None) -> tuple[float | None, str | None]:
    """(seconds from the turn's end to its first card line, basis "speech_end" | "turn_received")."""
    if fc is None or fc["t"] is None:
        return None, None
    if t.t_end_wall is not None:
        return fc["t"] - t.t_end_wall, "speech_end"
    if t.recv_wall is not None:
        return fc["t"] - t.recv_wall, "turn_received"
    return None, None


def bank_of(t: Turn) -> dict | None:
    if t.own_bank is not None:
        b = text_of(t.own_bank.get("bank")) or None
    elif t.verdicts:
        b = text_of(t.verdicts[0].get("bank")) or None
    else:
        return None
    contradicted = any(v.get("agree") is False for v in t.verdicts)
    return {"id": b, "contradicted": contradicted}


# ------------------------------------------------------------------------------------------------------------- the log
_LOG_LINE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z)\s(.*)$")
_CALL_FAILED = re.compile(r"\bcall ([a-z]\d{3,})\s*\(([A-Z])\) failed:\s*(.*)$")
_STATUS = re.compile(r"^brain status (\S+)\s*(.*)$")
_EXC = re.compile(r"\b[A-Z]\w*(?:Error|Exception)\b")
_LEVEL = re.compile(r"\b(WARNING|ERROR|CRITICAL)\b")


def read_log(path: Path) -> list[tuple[float, str]] | None:
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
    except (OSError, ValueError):
        return None
    out: list[tuple[float, str]] = []
    for ln in raw.splitlines():
        m = _LOG_LINE.match(ln)
        if not m:
            continue
        t = parse_iso(m.group(1))
        if t is not None:
            out.append((t, m.group(2)))
    return out


def log_window(lines: list[tuple[float, str]], name: str, run: Run) -> tuple[list[tuple[float, str]], dict]:
    info: dict = {"found": False}
    if run.anchor is None:
        info["note"] = "the run has no start time; the log cannot be matched"
        return [], info
    starts = [(i, t) for i, (t, msg) in enumerate(lines)
              if msg.startswith("start session=") and msg[len("start session="):].split(" ")[0] == name
              and abs(t - run.anchor) <= LOG_MATCH_S]
    end_wall = (run.last_wall or run.anchor) + LOG_TAIL_S
    if starts:
        i0, t0 = min(starts, key=lambda s: abs(s[1] - run.anchor))
        info.update(found=True, start=iso(t0))
    else:
        t0 = run.anchor - 5.0
        i0 = bisect.bisect_left([t for t, _ in lines], t0)
        info["note"] = f"no 'start session={name}' line near this run in the log; used the run's own time span"
    out: list[tuple[float, str]] = []
    for t, msg in lines[i0:]:
        if out and msg.startswith("start session="):
            break
        if not starts and t > end_wall:
            break
        out.append((t, msg))
        if msg.startswith("run ended code="):
            info["end"] = iso(t)
            break
    info["lines"] = len(out)
    return out, info


def check_route_nudges(run: Run, ndefs: list[dict], f: Findings) -> bool:
    """A prepared run that ended on the microphone-only route cannot run nudges: flag it when nudges were defined for the session.
    A run with nudge events, or one that moved to another route, did run them."""
    if run.mode != "prepared" or run.route != "room" or not ndefs:
        return False
    if run.gates or run.judges or run.fires:
        return False
    f.add("room_route_nudges", HIGH, ROOM_NUDGES_WHAT, run=run, said="", key=f"room_route_nudges:{run.index}",
          nudges_defined=len(ndefs), route=run.route, mode=run.mode)
    return True


def check_route_log(win: list[tuple[float, str]], run: Run, f: Findings) -> None:
    """The app log says a meeting app was detected while this session ran, yet the run's route is still the room route."""
    if run.route != "room":
        return
    for t, msg in win:
        if _MEETING_DETECTED.search(msg):
            f.add("meeting_took_microphone", HIGH, ROOM_MEETING_WHAT, run=run, t_audio=run.audio_at(t), said="",
                  key=f"meeting_took_microphone:{run.index}", source="verse.log", log_line=clip(msg, 160))
            return


def check_log(win: list[tuple[float, str]], run: Run, f: Findings) -> list[dict]:
    """Restarts, crashes, status events and call errors in the run's log window. Returns the items that may explain a missing
    card ({wall, turn, what})."""
    causes: list[dict] = []
    warn_seen: Counter = Counter()
    warn_first: dict[str, tuple[float, str]] = {}
    for t, msg in win:
        audio = run.audio_at(t)
        near = run.turn_at(t)
        if "ended unexpectedly" in msg or "restarted brain" in msg or "cannot serve this call" in msg:
            sev_kind = "brain_crash" if ("did not become ready" in msg or "cannot serve" in msg or "times" in msg) else "brain_restart"
            f.add(sev_kind, HIGH, f"the app's log says: {clip(msg, 160)}", run=run, turn=near, t_audio=audio,
                  said=near.text if near else "", source="verse.log")
            causes.append({"wall": t, "turn": None, "what": clip(msg, 120)})
            continue
        if msg.startswith("run ended code="):
            code = msg[len("run ended code="):].strip()
            if code not in ("0", ""):
                f.add("run_failed", HIGH, f"the run ended with exit code {code}", run=run, t_audio=audio, said="", source="verse.log")
            continue
        m = _STATUS.match(msg)
        if m:
            state, message = m.group(1), m.group(2)
            if state in NORMAL_STATUS:
                continue
            kind = "budget" if "budget" in message.lower() else f"status_{state}"
            sev = HIGH if (state in HIGH_STATUS or kind == "budget") else MED
            f.add(kind, sev, f"status {state}: {clip(message, 140)}", run=run, turn=near, t_audio=audio,
                  said=near.text if near else "", source="verse.log", wall=iso(t))
            causes.append({"wall": t, "turn": None, "what": f"status {state}: {clip(message, 100)}"})
            continue
        if not msg.startswith("[brain]"):
            continue
        m = _CALL_FAILED.search(msg)
        if m:
            cid, tier, why = m.group(1), m.group(2), m.group(3)
            tid = run.calls.get(cid)
            turn = run.turns.get(tid) if tid else near
            kind = "nudge_call_error" if tier == "K" else "call_error"
            f.add(kind, MED, f"{tier} call {cid} failed: {clip(why, 140)}", run=run, turn=turn,
                  t_audio=run.turn_audio(turn) if turn else audio, key=f"call_error:{run.index}:{cid}",
                  said=turn.text if turn else "", call=cid, tier=tier, source="verse.log",
                  turn_from=("call id" if tid else "time" if turn else None))
            causes.append({"wall": t, "turn": tid, "what": f"{tier} call {cid} failed: {clip(why, 80)}"})
            continue
        lvl = _LEVEL.search(msg)
        body = msg[lvl.end():].strip() if lvl else msg
        if "Traceback (most recent call last)" in msg or (lvl and lvl.group(1) in ("ERROR", "CRITICAL")):
            f.add("brain_error", HIGH, f"the brain logged an error: {clip(body, 160)}", run=run, turn=near, t_audio=audio,
                  said=near.text if near else "", source="verse.log")
            causes.append({"wall": t, "turn": None, "what": clip(body, 100)})
            continue
        if lvl and lvl.group(1) == "WARNING":
            norm = re.sub(r"\d+", "N", body)[:120]
            warn_seen[norm] += 1
            warn_first.setdefault(norm, (t, body))
    for norm, n in warn_seen.items():
        t, body = warn_first[norm]
        degraded = bool(_EXC.search(body)) and "ping error" not in body and "keep-alive" not in body
        f.add("brain_degraded" if degraded else "brain_warning", MED if degraded else LOW,
              f"brain warning{f' (x{n})' if n > 1 else ''}: {clip(body, 160)}", run=run, t_audio=run.audio_at(t), said="",
              key=f"warn:{run.index}:{norm}", source="verse.log", count=n)
    return causes


# ------------------------------------------------------------------------------------------------------------- nudges
def read_nudge_defs(path: Path) -> tuple[list[dict], int, bool]:
    rows, bad, present = read_jsonl(path)
    out = []
    for r in rows:
        nid = sid(r.get("id"))
        if nid:
            out.append({"id": nid, "title": clip(text_of(r.get("title")) or "Nudge", 60),
                        "until": r.get("until") if isinstance(r.get("until"), str) else None})
    return out, bad, present


def nudge_section(run: Run, f: Findings) -> dict:
    def at_turn(e: dict) -> tuple[Turn | None, float | None]:
        tid = sid(e.get("turn"))
        t = run.turns.get(tid) if tid else None
        if t is not None:
            return t, run.turn_audio(t)
        return None, run.audio_at(num(e.get("t")))

    def ids(v: object) -> list[str]:
        return [x for x in v if isinstance(x, str)] if isinstance(v, list) else []

    gates, judges, fires, retires = [], [], [], []
    skipped: Counter = Counter()
    for e in run.gates:
        t, a = at_turn(e)
        sk = e.get("skipped")
        skipped[text_of(sk) if sk else "launched"] += 1
        gates.append({"turn": sid(e.get("turn")), "time": mmss(a), "t_audio": r2(a), "speaker": e.get("speaker"),
                      "candidates": ids(e.get("candidates")), "keys": ids(e.get("keys")), "reason": e.get("reason"),
                      "skipped": text_of(sk) or None})
    for e in run.judges:
        t, a = at_turn(e)
        result = text_of(e.get("result")) or "?"
        pick = sid(e.get("pick"))
        row = {"turn": sid(e.get("turn")), "time": mmss(a), "t_audio": r2(a), "call": sid(e.get("call")),
               "candidates": ids(e.get("candidates")), "result": result, "pick": pick,
               "quote": text_of(e.get("quote")) or None, "age_s": num(e.get("age_s")), "stop": e.get("stop"),
               "raw": text_of(e.get("raw")) or None, "window": text_of(e.get("window")) or None}
        judges.append(row)
        if result.startswith("error"):
            f.add("nudge_call_error", MED, f"nudge check {row['call'] or ''} failed ({result})", run=run, turn=t, t_audio=a,
                  key=f"call_error:{run.index}:{row['call']}" if row["call"] else None, call=row["call"])
        elif result == "discarded":
            f.add("nudge_discarded", LOW, "nudge check was discarded before it answered", run=run, turn=t, t_audio=a,
                  call=row["call"])
        elif pick and result != "fired":
            f.add("nudge_rejected", LOW, f"judge picked {pick} but the code rejected it: {result}", run=run, turn=t, t_audio=a,
                  pick=pick, reason=result, quote=row["quote"], raw=row["raw"])
        if row["stop"] == "max_tokens":
            f.add("k_max_tokens", MED, "nudge check hit max_tokens", run=run, turn=t, t_audio=a, call=row["call"])
    for e in run.fires:
        t, a = at_turn(e)
        fires.append({"id": sid(e.get("id")), "turn": sid(e.get("turn")), "time": mmss(a), "t_audio": r2(a),
                      "speaker": e.get("speaker"), "quote": text_of(e.get("quote")) or None, "title": e.get("title")})
    for e in run.retires:
        t, a = at_turn(e)
        retires.append({"id": sid(e.get("id")), "turn": sid(e.get("turn")), "time": mmss(a), "t_audio": r2(a),
                        "why": e.get("why"), "cleared": e.get("cleared") is True, "history": e.get("history") is True})
    walls = sorted(w for w in (num(e.get("t")) for e in run.judges) if w is not None)
    peak = 0
    j = 0
    for i, w in enumerate(walls):
        while walls[j] < w - 60.0:
            j += 1
        peak = max(peak, i - j + 1)
    dur = run_duration(run)
    return {"gates": gates, "gate_outcomes": dict(skipped), "judges": judges, "fires": fires, "retires": retires,
            "k_calls": len(run.judges), "k_per_min": r2(len(run.judges) / (dur / 60.0)) if dur and dur > 0 else None,
            "k_peak_per_min": peak}


def run_duration(run: Run) -> float | None:
    ends = [t.t_audio for t in run.turns.values() if t.t_audio is not None]
    if ends:
        return max(ends)
    if run.last_wall is not None and run.audio0 is not None:
        return run.last_wall - run.audio0
    return None


# ------------------------------------------------------------------------------------------------------------- spend
def spend_runs(spend: dict | None) -> list[dict]:
    """spend.json `runs`, one entry per `started_at` (older files repeat a run with growing totals: the largest counts)."""
    if not spend or not isinstance(spend.get("runs"), list):
        return []
    by: dict[str, dict] = {}
    for r in spend["runs"]:
        if not isinstance(r, dict):
            continue
        cost = num(r.get("cost_usd"))
        if cost is None:
            continue
        kind = r.get("kind") if isinstance(r.get("kind"), str) else None
        key = f"{text_of(r.get('started_at'))}|{kind or ''}"
        cur = by.get(key)
        if cur is None or cost > cur["cost_usd"]:
            by[key] = {"started_at": text_of(r.get("started_at")) or None, "kind": kind, "cost_usd": cost,
                       "t": parse_iso(r.get("started_at"))}
    return sorted(by.values(), key=lambda r: (r["t"] is None, r["t"] or 0))


# ------------------------------------------------------------------------------------------------------------- analysis
def analyze(session_dir: str | Path, *, log_path: str | Path | None = None, late_s: float = LATE_S,
            gap_s: float = GAP_S) -> dict:
    """The whole report as a dict (what report.json holds)."""
    sdir = Path(session_dir).expanduser()
    name = sdir.name
    internal: list[str] = []
    events, ev_bad, ev_present = read_jsonl(sdir / "events.jsonl")
    rows, tr_bad, tr_present = read_jsonl(sdir / "transcript.jsonl")
    bank_rows, bank_bad, _ = read_jsonl(sdir / "bank.jsonl")
    bank = {r["id"]: r for r in bank_rows if sid(r.get("id"))}
    meta = read_json(sdir / "meta.json") or {}
    spend = read_json(sdir / "spend.json")
    ndefs, nd_bad, nd_present = read_nudge_defs(sdir / "nudges.jsonl")
    f = Findings()
    unknown: Counter = Counter()

    runs = build_runs(events, rows)
    for run in runs:
        fill_run(run, unknown)

    log_lines = None
    log_info: dict = {"path": str(log_path) if log_path else None}
    if log_path is None:
        log_info["status"] = "not used"
    else:
        log_lines = read_log(Path(log_path).expanduser())
        log_info["status"] = "read" if log_lines is not None else "missing"

    budget = num(meta.get("budget_usd"))
    sp_runs = [r for r in spend_runs(spend) if r["kind"] in (None, "call")]
    used_sp: set[int] = set()

    run_out: list[dict] = []
    all_lat: list[float] = []
    totals_speakers: Counter = Counter()
    totals_cards: Counter = Counter()
    totals_calls: Counter = Counter()
    q_total = q_carded = 0
    route_flagged: list[int] = []
    for run in runs:
        try:
            ro = analyze_run(run, name, sdir, bank, f, late_s, gap_s, log_lines, log_info)
            if check_route_nudges(run, ndefs, f):
                route_flagged.append(run.index)
        except Exception as e:  # noqa: BLE001 - a bug here must not lose the rest of the report
            internal.append(f"run {run.index}: {type(e).__name__}: {e}")
            ro = {"index": run.index, "error": f"{type(e).__name__}: {e}"}
        # spend for this run
        sp = None
        if run.anchor is not None:
            best = None
            for i, s in enumerate(sp_runs):
                if i in used_sp or s["t"] is None:
                    continue
                d = abs(s["t"] - run.anchor)
                if d <= LOG_MATCH_S and (best is None or d < best[0]):
                    best = (d, i)
            if best is not None:
                used_sp.add(best[1])
                sp = sp_runs[best[1]]["cost_usd"]
        ro["spend_usd"] = r2(sp) if sp is None else round(sp, 4)
        if sp is not None and budget:
            if sp >= budget:
                f.add("budget_exceeded", HIGH, f"spent ${sp:.2f} of the ${budget:.2f} budget", run=run, said="",
                      key=f"budget:{run.index}", spend_usd=round(sp, 4), budget_usd=budget)
            elif sp >= BUDGET_WARN * budget:
                f.add("budget_near", MED, f"spent ${sp:.2f}, {sp / budget:.0%} of the ${budget:.2f} budget", run=run, said="",
                      key=f"budget:{run.index}", spend_usd=round(sp, 4), budget_usd=budget)
        run_out.append(ro)
        tot = ro.get("totals") or {}
        totals_speakers.update(tot.get("turns_by_speaker") or {})
        totals_cards.update(tot.get("cards_by_tier") or {})
        totals_calls.update(tot.get("calls_seen_by_tier") or {})
        q_total += tot.get("questions_to_owner", 0)
        q_carded += tot.get("questions_with_card", 0)
        all_lat += ro.get("_lat", [])
        ro.pop("_lat", None)

    # nudges: whole session
    fired_ids = {x["id"] for ro in run_out for x in (ro.get("nudges") or {}).get("fires", []) if x.get("id")}
    retired_ids = {x["id"] for ro in run_out for x in (ro.get("nudges") or {}).get("retires", []) if x.get("id")}
    never = [dict(d, retired=d["id"] in retired_ids) for d in ndefs if d["id"] not in fired_ids]
    if route_flagged and not fired_ids:      # nothing could fire on that route: one line instead of one note per nudge
        f.add("nudges_not_run", LOW, f"nudges could not run on this route ({len(never)} defined, none fired)", said="",
              key="nudges_not_run")
        never_notes: list[dict] = []
    else:
        never_notes = never
    for d in never_notes:
        f.add("nudge_never_fired", LOW, f"nudge {d['id']} ({d['title']}) never fired" + (" (retired by a number)" if d["retired"] else ""),
              said="", key=f"never:{d['id']}", nudge=d["id"])

    spend_total = sum(s["cost_usd"] for s in sp_runs) if sp_runs else None
    items = sorted(f.items, key=lambda p: (SEV_ORDER[p["severity"]], p["run"] or 0,
                                           p["t_audio"] if p["t_audio"] is not None else 1e12))
    problems = [p for p in items if p["severity"] in (HIGH, MED)]
    notes = [p for p in items if p["severity"] == LOW]
    n_high = sum(1 for p in problems if p["severity"] == HIGH)
    n_med = len(problems) - n_high
    line = (f"PROBLEMS FOUND: {n_high} high, {n_med} medium" if problems else "OK: no problems found") + f" ({len(notes)} notes)"
    malformed = {k: v for k, v in (("events.jsonl", ev_bad), ("transcript.jsonl", tr_bad), ("bank.jsonl", bank_bad),
                                   ("nudges.jsonl", nd_bad)) if v}
    return {
        "schema": SCHEMA,
        "session": name,
        "session_dir": str(sdir),
        "generated_at": iso(time.time()),
        "thresholds": {"card_late_s": late_s, "transcript_gap_s": gap_s, "budget_warn_share": BUDGET_WARN},
        "verdict": {"ok": not problems, "high": n_high, "medium": n_med, "notes": len(notes), "line": line},
        "counts_by_kind": dict(sorted(Counter(p["kind"] for p in items).items())),
        "problems": problems,
        "notes": notes,
        "runs": run_out,
        "nudges": {"defined": ndefs, "never_fired": never, "file_present": nd_present},
        "totals": {
            "runs": len(runs),
            "turns_by_speaker": dict(sorted(totals_speakers.items())),
            "questions_to_owner": q_total,
            "questions_with_card": q_carded,
            "cards_by_tier": dict(sorted(totals_cards.items())),
            "calls_seen_by_tier": dict(sorted(totals_calls.items())),
            "time_to_card_s": {"median": r2(statistics.median(all_lat)) if all_lat else None, "p90": r2(pct(all_lat, 0.9)),
                               "n": len(all_lat)},
            "spend_usd": round(spend_total, 4) if spend_total is not None else None,
            "budget_usd": budget,
            "spend_per_tier": None,
        },
        "reproduce": reproduce(items, runs, sdir, name),
        "log": log_info,
        "inputs": {"events.jsonl": ev_present, "transcript.jsonl": tr_present, "nudges.jsonl": nd_present,
                   "meta.json": bool(meta), "spend.json": spend is not None, "bank_entries": len(bank)},
        "blind_spots": BLIND_SPOTS,
        "not_understood": {"event_types": dict(sorted(unknown.items())), "malformed_lines": malformed},
        "internal_errors": internal,
    }


def analyze_run(run: Run, name: str, sdir: Path, bank: dict[str, dict], f: Findings, late_s: float, gap_s: float,
                log_lines: list[tuple[float, str]] | None, log_info: dict) -> dict:
    # the log first: its call errors and status lines explain missing cards
    causes: list[dict] = []
    rlog: dict = {}
    if log_lines is not None:
        win, rlog = log_window(log_lines, name, run)
        causes = check_log(win, run, f)
        check_route_log(win, run, f)
    else:
        rlog = {"found": False, "note": "no log" if log_info.get("status") == "not used" else "log file missing"}

    log_restarts = sum(1 for p in f.items if p["run"] == run.index and p["kind"] in ("brain_restart", "brain_crash"))
    for i, e in enumerate(run.restarts):
        if i < log_restarts:
            continue           # the log already reported this restart
        a = run.audio_at(num(e.get("t")))
        near = run.turn_at(num(e.get("t"))) if num(e.get("t")) is not None else None
        f.add("brain_restart", HIGH, f"the brain restarted mid-call (history replay of {text_of(e.get('turns')) or '?'} turns)",
              run=run, turn=near, t_audio=a, said=near.text if near else "", source="events.jsonl")

    timeline: list[dict] = []
    lats: list[float] = []
    speakers: Counter = Counter()
    cards_by_tier: Counter = Counter()
    calls_seen: set[str] = set()
    q_owner = q_card = 0
    for tid in run.order:
        t = run.turns[tid]
        if t.in_transcript:
            speakers[t.speaker or "?"] += 1
        for c in t.cards:
            if sid(c.get("id")):
                calls_seen.add(c["id"])
        for d in t.card_done:
            if sid(d.get("id")):
                calls_seen.add(d["id"])
        if t.probe_id:
            calls_seen.add(t.probe_id)
        fc = first_card(t, bank)
        if fc is not None:
            per_call: dict[str, str] = {}
            for i, c in enumerate(t.cards):
                per_call.setdefault(sid(c.get("id")) or f"?{i}", text_of(c.get("tier")) or "?")
            cards_by_tier.update(per_call.values())
            if t.own_bank is not None:
                cards_by_tier["P"] += 1
        if not t.remote:
            continue
        lat, basis = latency(t, fc)
        b = bank_of(t)
        audio = run.turn_audio(t)
        if t.addressee == "other" and fc is not None:
            f.add("card_for_other", MED, f"a card ({fc['tier']}) was shown for a turn addressed to someone else", run=run,
                  turn=t, card=fc["id"], opener=fc["opener"])
        for v in t.verdicts:
            if v.get("agree") is False:
                f.add("bank_contradicted", MED, f"bank match {text_of(v.get('bank'))} was contradicted by the answer call "
                      f"(it said {text_of(v.get('said')) or 'none'})", run=run, turn=t, bank=text_of(v.get("bank")) or None,
                      said_bank=text_of(v.get("said")) or None, via=v.get("via"), reason=v.get("reason"))
        probe_failed = t.probe == "none" and bool(t.probe_error)
        if probe_failed:
            # the statement probe is the only check of whether a statement-shaped turn was a question for him
            key = f"call_error:{run.index}:{t.probe_id}" if t.probe_id else None
            logged = next((p for p in f.items if key and p["id"] == key), None)
            what = f"statement probe {t.probe_id or ''} failed ({t.probe_error})"
            if fc is None and t.to_owner:
                what += ": the turn was never checked for a question and no card was shown"
            if logged is not None:
                logged["details"]["log_message"] = logged["what"]
                logged.update(kind="probe_failed" if fc is None else "call_error", what=what)
            else:
                f.add("probe_failed" if fc is None else "call_error", MED, what, run=run, turn=t, key=key, call=t.probe_id,
                      source="events.jsonl")
        elif t.probe == "none" and not t.probe_discarded:
            f.add("probe_no_verdict", LOW, "the statement probe gave no verdict", run=run, turn=t, call=t.probe_id)
        if not (t.question or fc is not None or probe_failed):
            continue
        nudge_here = ", ".join(t.nudges) or None
        row = {"turn": tid, "time": mmss(audio), "t_audio": r2(audio), "text": clip(t.text, SAID), "addressee": t.addressee,
               "kind": t.brain_kind, "probe": t.probe, "question": t.question, "card": fc["opener"] if fc else None, "tier": fc["tier"] if fc else None,
               "card_id": fc["id"] if fc else None, "s_to_card": r2(lat), "latency_basis": basis,
               "s_turn_to_brain": r2(t.recv_wall - t.t_end_wall) if t.recv_wall is not None and t.t_end_wall is not None else None,
               "bank": b["id"] if b else None, "bank_contradicted": b["contradicted"] if b else None, "nudge": nudge_here,
               "suppressed": [text_of(s.get("reason")) for s in t.suppressed] or None}
        timeline.append(row)
        if not t.to_owner or not t.question:
            continue
        q_owner += 1
        if fc is not None:
            q_card += 1
            if lat is not None:
                lats.append(lat)
                if lat > late_s:
                    split = (f"; the turn reached the brain {row['s_turn_to_brain']:.1f} s after speech ended"
                             if row["s_turn_to_brain"] is not None else "")
                    f.add("card_late", MED, f"first card line {lat:.1f} s after the turn ended (limit {late_s:g} s){split}",
                          run=run, turn=t, s_to_card=r2(lat), basis=basis, tier=fc["tier"], card=fc["id"],
                          s_turn_to_brain=row["s_turn_to_brain"])
            continue
        reasons = [text_of(s.get("reason")) for s in t.suppressed]
        if any(r in OK_SUPPRESS for r in reasons):
            row["card"] = "(answered by card-now)"
            row["tier"] = "now"
            continue
        ref = t.t_end_wall if t.t_end_wall is not None else t.recv_wall
        hint = [c["what"] for c in causes
                if c["turn"] == tid or (c["turn"] is None and ref is not None and ref - 1.0 <= c["wall"] <= ref + CAUSE_WINDOW_S)]
        if reasons or t.held:
            why = ", ".join(r for r in reasons if r) or ("held, never released" if not t.released else "held")
            f.add("question_suppressed", MED, f"question to you got no card: suppressed ({why})", run=run, turn=t,
                  reasons=reasons or None, held=t.held or None, causes=hint or None)
        else:
            f.add("question_no_card", HIGH, "question to you got no card" + (f" (likely: {hint[0]})" if hint else
                  " and no error was recorded for it"), run=run, turn=t, turn_kind=t.brain_kind, probe=t.probe, causes=hint or None)

    # calls seen through nudge checks
    for e in run.judges:
        if sid(e.get("call")):
            calls_seen.add(e["call"])

    # owner reactions
    for e in run.regens:
        of = sid(e.get("of"))
        t = run.turns.get(of) if of else None
        f.add("owner_regenerated", LOW, f"you asked for a new card ({text_of(e.get('turn'))})", run=run, turn=t,
              t_audio=None if t else run.audio_at(num(e.get("t"))), said=t.text if t else "")
    for e in run.marks:
        if e.get("mark") == "bad":
            tid = sid(e.get("turn"))
            t = run.turns.get(tid) if tid else None
            f.add("card_marked_bad", MED, f"you marked card {text_of(e.get('card'))} bad", run=run, turn=t,
                  t_audio=None if t else run.audio_at(num(e.get("t"))),
                  said=t.text if t else text_of(e.get("question")), card=text_of(e.get("card")) or None)

    # transcript gaps
    ends = sorted((t.t_audio, t.tid) for t in run.turns.values() if t.in_transcript and t.t_audio is not None)
    gaps = []
    for (a0, t0), (a1, t1) in zip(ends, ends[1:]):
        if a1 - a0 > gap_s:
            gaps.append({"from": mmss(a0), "to": mmss(a1), "s": r2(a1 - a0), "after_turn": t0, "before_turn": t1})
            f.add("transcript_gap", MED, f"no transcript row for {a1 - a0:.0f} s ({mmss(a0)} to {mmss(a1)})", run=run,
                  t_audio=a0, said="", key=f"gap:{run.index}:{t0}:{t1}", after_turn=t0, before_turn=t1, s=r2(a1 - a0))

    nud = nudge_section(run, f)
    dur = run_duration(run)
    calls_by_tier = Counter(c[0].upper() for c in calls_seen if c and c[0].isalpha())
    return {
        "index": run.index,
        "started_at": iso(run.anchor),
        "audio_clock": "transcript" if run.audio0_known else ("estimated" if run.audio0 is not None else "none"),
        "duration_s": r2(dur),
        "duration": mmss(dur),
        "starts": run.starts,
        "route": run.route,
        "route_start": run.route_start,
        "brain_restarts": len(run.restarts),
        "log": rlog,
        "timeline": timeline,
        "gaps": gaps,
        "nudges": nud,
        "totals": {
            "turns_by_speaker": dict(sorted(speakers.items())),
            "questions_to_owner": q_owner,
            "questions_with_card": q_card,
            "cards_by_tier": {k: v for k, v in sorted(cards_by_tier.items()) if v},
            "calls_seen_by_tier": dict(sorted(calls_by_tier.items())),
            "time_to_card_s": {"median": r2(statistics.median(lats)) if lats else None, "p90": r2(pct(lats, 0.9)), "n": len(lats)},
            "points_dropped": run.points_dropped,
            "duplicate_transcript_rows": run.dup_rows,
        },
        "_lat": lats,
    }


# ------------------------------------------------------------------------------------------------------------- reproduce
def _dq(s: str) -> str:
    """A double-quoted shell word."""
    return '"' + re.sub(r'(["\\$`])', r"\\\1", s) + '"'


NUDGE_KINDS = {"nudge_rejected", "nudge_call_error", "nudge_discarded", "k_max_tokens", "nudge_never_fired"}


def reproduce(items: list[dict], runs: list[Run], sdir: Path, name: str) -> list[dict]:
    out: list[dict] = []
    seen: set[tuple] = set()
    by_run = {r.index: r for r in runs}
    nudge_cmd_added = False
    for p in items:
        if p["kind"] in NUDGE_KINDS:
            if not nudge_cmd_added:
                nudge_cmd_added = True
                out.append({"for": "nudges", "turn": None, "run": None,
                            "commands": [f"cd brain && .venv/bin/python ../eval/run_nudges.py --arm B --session {_dq(str(sdir))} "
                                         f"--trace \"${{TMPDIR:-/tmp}}/{re.sub(r'[^A-Za-z0-9._-]', '_', name)}-nudge-trace.jsonl\""],
                            "note": "paid: the nudge judge runs on the real API; every other tier is fake"})
            continue
        run = by_run.get(p["run"]) if p["run"] else None
        t = run.turns.get(p["turn"]) if (run and p["turn"]) else None
        if t is None or not t.remote or not t.text.strip():
            continue
        key = (p["run"], t.tid)
        if key in seen:
            continue
        seen.add(key)
        note = "replays the line against the prepared session in the running app (without the call's earlier turns)"
        if not t.in_transcript:
            note += "; the transcript has no row for this turn, so the line is the first 80 characters from events.jsonl"
        out.append({"for": p["kind"], "turn": t.tid, "run": p["run"], "time": p["time"],
                    "commands": [f"app/scripts/rehearse.sh them {_dq(t.text)} {_dq(name)}"], "note": note})
    return out


# ------------------------------------------------------------------------------------------------------------- markdown
def _cell(v: object) -> str:
    s = "" if v is None else str(v)
    return s.replace("|", "\\|").replace("\n", " ") or " "


def render_markdown(rep: dict) -> str:
    L: list[str] = []
    v = rep["verdict"]
    multi = rep["totals"]["runs"] > 1
    L.append(f"# Verse call report: {rep['session']}")
    L.append("")
    L.append(f"**{v['line']}**")
    L.append("")
    tot = rep["totals"]
    durs = ", ".join(f"run {r['index']} {r.get('duration', '--:--')}" for r in rep["runs"])
    L.append(f"Session folder: `{rep['session_dir']}` · runs: {tot['runs']} ({durs})")
    lg = rep["log"]
    if lg.get("status") == "read":
        found = [r for r in rep["runs"] if (r.get("log") or {}).get("found")]
        L.append(f"App log: `{lg['path']}` (call window found for {len(found)} of {len(rep['runs'])} runs)")
    elif lg.get("status") == "missing":
        L.append(f"App log: **missing** at `{lg['path']}`: brain restarts, call errors, status events (offline, rate "
                 "limited, error, budget) and a meeting app taking the microphone could not be checked.")
    else:
        L.append("App log: not used (`--no-log`): brain restarts, call errors, status events and a meeting app taking the "
                 "microphone were not checked.")
    th = rep["thresholds"]
    L.append(f"Thresholds: card later than {th['card_late_s']:g} s · transcript gap over {th['transcript_gap_s']:g} s")
    if rep.get("internal_errors"):
        L.append("")
        L.append("**The report itself hit errors (parts may be missing):** " + "; ".join(rep["internal_errors"]))
    L.append("")

    def item(p: dict) -> str:
        where = f"{p['time']}" + (f" (run {p['run']})" if multi and p["run"] else "")
        turn = f" · {p['turn']}" if p["turn"] else ""
        said = f" · \"{p['said']}\"" if p["said"] else ""
        cause = ""
        c = p["details"].get("causes")
        if c and p["kind"] == "question_suppressed":
            cause = f" Possibly related: {'; '.join(c[:2])}."
        return f"- **[{p['severity']}] {where}{turn}** · {p['what']}{said}{cause}"

    L.append("## Problems")
    L.append("")
    if rep["problems"]:
        L += [item(p) for p in rep["problems"]]
    else:
        L.append("None found in what the session recorded (see \"What this report cannot see\").")
    L.append("")
    if rep["notes"]:
        L.append("## Notes")
        L.append("")
        L += [item(p) for p in rep["notes"]]
        L.append("")

    for r in rep["runs"]:
        if "timeline" not in r:
            continue
        L.append(f"## Questions from the other side" + (f" · run {r['index']} ({r.get('started_at') or '?'})" if multi else ""))
        L.append("")
        if not r["timeline"]:
            L.append("No questions from the other side in this run.")
            L.append("")
            continue
        basis = {x["latency_basis"] for x in r["timeline"] if x["latency_basis"]}
        L.append("| time | turn | question | to | card shown (opener) | tier | s to card | bank | nudge |")
        L.append("|---|---|---|---|---|---|---|---|---|")
        for x in r["timeline"]:
            card = x["card"] or ("**none**" if x["addressee"] != "other" else "none (not for you)")
            if not x["card"] and x["suppressed"]:
                card += f" ({', '.join(s for s in x['suppressed'] if s)})"
            bank = (x["bank"] or "") + (" (contradicted)" if x["bank_contradicted"] else "")
            s = "" if x["s_to_card"] is None else f"{x['s_to_card']:.1f}"
            L.append("| " + " | ".join(_cell(c) for c in (x["time"], x["turn"], x["text"], x["addressee"] or "?", card,
                                                          x["tier"] or "", s, bank, x["nudge"] or "")) + " |")
        L.append("")
        if "room" in (r.get("route"), r.get("route_start")):
            L.append(f"_{ROOM_ANSWERS_NOTE}._")
            L.append("")
        if "turn_received" in basis:
            L.append("_s to card for turns without a wall clock in the transcript is measured from when the turn reached the "
                     "brain, not from the end of speech._")
            L.append("")

    nd = rep["nudges"]
    any_nudge = nd["defined"] or any((r.get("nudges") or {}).get("judges") or (r.get("nudges") or {}).get("gates")
                                     for r in rep["runs"])
    L.append("## Nudges")
    L.append("")
    if not any_nudge:
        L.append("No nudges in this session (no `nudges.jsonl` and no nudge events).")
        L.append("")
    else:
        L.append(f"Defined: {len(nd['defined'])} · never fired: "
                 + (", ".join(f"{d['id']} ({d['title']})" + (" retired" if d["retired"] else "") for d in nd["never_fired"]) or "none"))
        L.append("")
        for r in rep["runs"]:
            n = r.get("nudges") or {}
            if not (n.get("judges") or n.get("gates") or n.get("fires") or n.get("retires")):
                continue
            hdr = f"Run {r['index']}: " if multi else ""
            L.append(f"{hdr}K calls: {n['k_calls']}"
                     + (f" ({n['k_per_min']:.2f}/min, peak {n['k_peak_per_min']} in one minute)" if n.get("k_per_min") is not None else "")
                     + " · gate outcomes: " + (", ".join(f"{k} {v}" for k, v in sorted(n["gate_outcomes"].items())) or "none"))
            L.append("")
            if n["fires"]:
                L.append("Fired:")
                L += [f"- {x['time']} · {x['id']} {x['title'] or ''} · {x['speaker'] or '?'}: \"{x['quote'] or ''}\"" for x in n["fires"]]
                L.append("")
            if n["retires"]:
                L.append("Retired by a number:")
                L += [f"- {x['time']} · {x['id']}" + (" (taken off screen)" if x["cleared"] else "") for x in n["retires"]]
                L.append("")
            if n["judges"]:
                L.append("| time | turn | candidates | decision | pick | quote | judge said |")
                L.append("|---|---|---|---|---|---|---|")
                for x in n["judges"]:
                    L.append("| " + " | ".join(_cell(c) for c in (x["time"], x["turn"], ",".join(x["candidates"]), x["result"],
                                                                  x["pick"] or "", x["quote"] or "", clip(x["raw"] or "", 120))) + " |")
                L.append("")

    L.append("## Totals")
    L.append("")
    sp = ", ".join(f"{k} {v}" for k, v in tot["turns_by_speaker"].items()) or "none"
    L.append(f"- Turns: {sp}")
    L.append(f"- Questions to you: {tot['questions_to_owner']}, with a card: {tot['questions_with_card']}")
    L.append(f"- Cards by tier: " + (", ".join(f"{k} {v}" for k, v in tot["cards_by_tier"].items()) or "none")
             + " (P = bank opener shown before the model answered)")
    tc = tot["time_to_card_s"]
    L.append(f"- Time to first card line: median {tc['median'] if tc['median'] is not None else '-'} s, "
             f"p90 {tc['p90'] if tc['p90'] is not None else '-'} s over {tc['n']} cards")
    L.append(f"- Calls seen by tier: " + (", ".join(f"{k} {v}" for k, v in tot["calls_seen_by_tier"].items()) or "none")
             + " (only calls that left a card, probe or nudge-check event; failed or discarded S/F calls leave none)")
    if tot["spend_usd"] is not None:
        b = f" of a ${tot['budget_usd']:.2f} budget per run" if tot["budget_usd"] else ""
        per = ", ".join(f"run {r['index']} ${r['spend_usd']:.2f}" for r in rep["runs"] if r.get("spend_usd") is not None)
        L.append(f"- Spend: ${tot['spend_usd']:.2f}{b}" + (f" ({per})" if per else "") + "; per tier: not recorded")
    else:
        L.append("- Spend: no spend.json")
    L.append("")

    L.append("## How to reproduce")
    L.append("")
    if not rep["reproduce"]:
        L.append("Nothing to reproduce.")
    for x in rep["reproduce"]:
        label = f"{x['time']} {x['turn']} ({x['for']})" if x["turn"] else x["for"]
        L.append(f"- {label}: " + " ; ".join(f"`{c}`" for c in x["commands"]) + f" · {x['note']}")
    L.append("")

    L.append("## What this report cannot see")
    L.append("")
    for b in rep["blind_spots"]:
        L.append(f"- {b['signal']}: {b['effect']}. Would be logged in {b['where']}.")
    L.append("")
    nu = rep["not_understood"]
    if nu["event_types"] or nu["malformed_lines"]:
        L.append("## Not understood")
        L.append("")
        for k, n in nu["event_types"].items():
            L.append(f"- not understood: {n} events of type {k}")
        for k, n in nu["malformed_lines"].items():
            L.append(f"- malformed: {n} lines in {k}")
        L.append("")
    return "\n".join(L)


# ------------------------------------------------------------------------------------------------------------- CLI
def _inside(child: Path, parent: Path) -> bool:
    try:
        child.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m verse_brain.runtime.report", description=__doc__.split("\n\n")[0])
    ap.add_argument("session", type=Path, help="the finished session folder")
    ap.add_argument("--log", type=Path, help=f"the app's log (default {DEFAULT_LOG} when it exists)")
    ap.add_argument("--no-log", action="store_true", help="do not read the app's log")
    ap.add_argument("--out", type=Path, help="folder for report.md and report.json (default: <tmp>/verse-report/<session>)")
    ap.add_argument("--json", action="store_true", help="print report.json instead of the Markdown")
    ap.add_argument("--late", type=float, default=LATE_S, help=f"seconds from turn end to the first card line (default {LATE_S})")
    ap.add_argument("--gap", type=float, default=GAP_S, help=f"seconds without a transcript row (default {GAP_S:g})")
    a = ap.parse_args(argv)
    sdir = a.session.expanduser()
    if not sdir.is_dir():
        print(f"not a folder: {sdir}", file=sys.stderr)
        return 2
    out = (a.out or Path(tempfile.gettempdir()) / "verse-report" / sdir.name).expanduser()
    if _inside(out, sdir):
        print("refusing to write the report into the session folder; pass --out somewhere else", file=sys.stderr)
        return 2
    log = None if a.no_log else (a.log if a.log is not None else DEFAULT_LOG)
    rep = analyze(sdir, log_path=log, late_s=a.late, gap_s=a.gap)
    md = render_markdown(rep)
    out.mkdir(parents=True, exist_ok=True)
    (out / "report.md").write_text(md + "\n", encoding="utf-8")
    (out / "report.json").write_text(json.dumps(rep, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    sys.stdout.write((json.dumps(rep, ensure_ascii=False, indent=1) if a.json else md) + "\n")
    print(f"wrote {out / 'report.md'} and {out / 'report.json'}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
