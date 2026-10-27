"""JSON-lines IPC with Swift (plan P1-2 interfaces) and the session-folder reader.

Brain -> Swift events are written one per line and flushed after every line. Extra keys beyond the plan's
schema are additive (e.g. `id`/`tier` on metric events, `turn_id`/`id` on status events).
"""

from __future__ import annotations

import json
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import IO, TYPE_CHECKING, Callable

if TYPE_CHECKING:
    from .call import CallDirectives

IN_TYPES = {"start", "partial", "turn", "bank_hit", "control"}
# Anytime calls (docs/specs/2026-10-16-verse-anytime-calls-design.md section 3), additive. Swift -> brain: `start` gains `mode`
# ("prepared"|"unprepared"), `route` ("meeting"|"phone"|"room"), `me` ({core,library,facts} paths, or null) and `room_auto`
# ("questions"|"off"); `partial`/`turn` gain an optional `lang` and may carry `speaker:"room"`; `control` gains
# `card_now`, `lang` (with `lang`) and `route` (with `route`, optional `room_auto` and `follow`: the route of the running call
# changed, the session goes on). Brain -> Swift: `notice{kind:"me_conflicts",items}` and `notice{kind:"me_missing"}`,
# `status ready` gains `me:{tokens,built_at}|null`, metric stages `me_retrieval` and `card_now`.
LANGS = {"en", "it", "tr"}
REMOTE_SPEAKERS = ("remote", "room")     # the room route's one mic is treated like the remote channel
NOTICE_KINDS = {"me_conflicts", "me_missing"}
# Interview simulation (plan S2, Shared contracts), additive: Swift -> brain `sim_start{session_dir,mode,voice}`,
# `answer{q_id,text,t_start,t_end,words,fillers}`, `control{action: skip|repeat|end}`, `spoken{id}`. The first
# message of a process decides its mode (runtime/__main__.py); the meeting Brain ignores the sim types.
SIM_IN_TYPES = {"sim_start", "answer", "spoken"}
SIM_CONTROL_ACTIONS = {"skip", "repeat", "end"}
# Follow my answer (docs/specs/2026-10-16-verse-follow-my-answer-design.md section 3), additive. Swift -> brain: `start.follow`
# (bool; absent = off) and `partial{speaker:"me"}` (the text of the owner's turn so far, cumulative like the remote partials).
# Brain -> Swift: `follow{turn_id,reason:"diverged"|"refresh",card_id}` followed by `delta{id=card_id,card_id,tier:"C"}`;
# `covered{turn_id,card_id,point}` (card_id "orig-<turn_id>" for the original F/S card, the C call id for a follow card;
# point = 0-based index among the card's "- " lines; D points are not counted); metric stages `follow_diverged`,
# `follow_card`, `follow_refresh`, `follow_covered`, `follow_end`.
FOLLOW_OUT_TYPES = {"follow", "covered"}

# Brain -> Swift in a sim: `say{id,text,final}`, `listen{q_id}`, `coach{q_id,lines}`, `sim_progress{q_index,q_total}`
# (q_index is 1-based), `sim_report{path}`, plus `status` and `metric` as in meetings.
SIM_OUT_TYPES = {"say", "say_prefetch", "listen", "coach", "sim_progress", "sim_report"}
IN_TYPES |= SIM_IN_TYPES
# `turn.kind` (Swift VerseTurns): optional, absent from older senders. Anything else is treated as absent.
TURN_KINDS = {"question", "statement", "fragment"}
STATUS_STATES = {"warming", "ready", "offline", "rate_limited", "credit_exhausted", "refusal", "error"}
# Ask this meeting (docs/specs/2026-10-20-verse-five-features-design.md 3.2), additive. A process whose first message is `ask_start`
# is the chat runtime of one past session (runtime/ask.py). Swift -> brain: `ask_start{session_dir,owner_name,title,date,me,transcript,
# model}`, `ask{id,text,model}`, `control{action: cancel|stop|reset}`. Brain -> Swift: `status` (warming, ready with `context`),
# `ask_delta{id,q,text}`, `ask_done{id,q,model,usage,cost_usd,ms_first_token,ms_total,citations,stop_reason,cost_estimated}`,
# `ask_error{id,q,kind,message,retry_after}`. The meeting Brain ignores the ask types.
ASK_IN_TYPES = {"ask_start", "ask"}
ASK_OUT_TYPES = {"ask_delta", "ask_done", "ask_error"}
ASK_CONTROL_ACTIONS = {"cancel", "stop", "reset"}
ASK_MODELS = ("haiku", "sonnet", "opus")
ASK_ERROR_KINDS = {"credit_exhausted", "offline", "rate_limited", "overloaded", "auth", "refusal", "bad_request", "error"}
IN_TYPES |= ASK_IN_TYPES
# Memory index (docs/specs/2026-10-21-verse-memory-package-design.md 3.3), additive. A process whose first message is
# `memory_index_start{db,embed}` is the short-lived writer of the memory index (memory/indexer.py). Swift -> brain: `sync{sessions:
# [{name,fp,labels}]}`, `put{name,dir,fp,title,date,kind,lang,labels,rows}`, `drop{names}`, `end`. Brain -> Swift: `status` (ready with
# `context{sessions,chunks,vectors,embed}`, busy, done), `sync_plan{need,dropped,relabelled}`, `put_done{name,key,chunks,ms}`,
# `embed_progress{done,total}`, `index_error{name,kind,message}`. The meeting Brain ignores these types.
MEMORY_INDEX_IN_TYPES = {"memory_index_start", "sync", "put", "drop", "end"}
MEMORY_INDEX_OUT_TYPES = {"sync_plan", "put_done", "embed_progress", "index_error"}
MEMORY_INDEX_STATES = {"ready", "busy", "done"}
INDEX_ERROR_KINDS = {"unreadable", "bad_request", "db"}
IN_TYPES |= MEMORY_INDEX_IN_TYPES
# Memory Ask and the brief (spec 3.4, 3.5), additive. A process whose first message is `memory_ask_start{db,chat,owner_name,me,scope,model}`
# runs runtime/memory_ask.py (then `ask`, `control` as in Ask this meeting; `ask_done.citations` are objects); one whose first message is
# `brief_start{db,owner_name,entity,sessions,upcoming,lang,out,session_out,model}` runs memory/brief.py: one request, `brief_done{path,
# cost_usd,usage,points,dropped_uncited,ms_total}` or `brief_error{kind,message,retry_after}`, then the process ends.
MEMORY_ASK_IN_TYPES = {"memory_ask_start", "brief_start"}
BRIEF_OUT_TYPES = {"brief_done", "brief_error"}
BRIEF_ERROR_KINDS = ASK_ERROR_KINDS | {"no_sessions"}
IN_TYPES |= MEMORY_ASK_IN_TYPES


class Emitter:
    """Writes events to a text stream, one JSON object per line, flushed per line."""

    def __init__(self, out: IO[str] | None = None, tap: Callable[[dict], None] | None = None) -> None:
        self._out = out if out is not None else sys.stdout
        self._tap = tap

    def emit(self, ev: dict) -> None:
        if self._tap is not None:
            self._tap(ev)
        self._out.write(json.dumps(ev, ensure_ascii=False, separators=(",", ":")) + "\n")
        self._out.flush()

    # helpers
    def delta(self, id: str, turn_id: str, tier: str, text: str, line_done: bool, card_id: str | None = None) -> dict:
        ev = {"type": "delta", "id": id, "turn_id": turn_id, "tier": tier, "text": text, "line_done": line_done}
        if card_id is not None:       # tier C: the follow card this text belongs to (equal to `id`)
            ev["card_id"] = card_id
        return ev

    def status(self, state: str, message: str = "", **extra) -> None:
        assert state in STATUS_STATES, state
        self.emit({"type": "status", "state": state, "message": message, **extra})

    def notice(self, kind: str, **extra) -> None:
        assert kind in NOTICE_KINDS, kind
        self.emit({"type": "notice", "kind": kind, **extra})

    def metric(self, turn_id: str, stage: str, t: float | None = None, **extra) -> None:
        self.emit({"type": "metric", "turn_id": turn_id, "stage": stage, "t": time.time() if t is None else t, **extra})


class ListEmitter(Emitter):
    """Test emitter: keeps events (with a monotonic receive time) instead of writing them."""

    def __init__(self) -> None:
        self.events: list[dict] = []
        self.times: list[float] = []

    def emit(self, ev: dict) -> None:
        self.events.append(ev)
        self.times.append(time.monotonic())

    def of(self, type_: str, **match) -> list[dict]:
        return [e for e in self.events if e["type"] == type_ and all(e.get(k) == v for k, v in match.items())]


def msg_lang(msg: dict) -> str | None:
    """The optional `lang` of a partial or turn: "en" | "it" | "tr", or None (use the session's)."""
    v = msg.get("lang")
    return v if isinstance(v, str) and v in LANGS else None


def turn_kind(msg: dict) -> str | None:
    """The `kind` of a `turn` message: "question" | "statement" | "fragment", or None when missing or unknown
    (None keeps the question behaviour)."""
    k = msg.get("kind")
    return k if isinstance(k, str) and k in TURN_KINDS else None


def parse_line(line: str) -> dict | None:
    line = line.strip()
    if not line:
        return None
    msg = json.loads(line)
    if not isinstance(msg, dict) or msg.get("type") not in IN_TYPES:
        raise ValueError(f"unknown message type: {msg.get('type') if isinstance(msg, dict) else type(msg).__name__}")
    return msg


@dataclass
class Session:
    path: Path
    pack: str
    bank: dict[str, dict] = field(default_factory=dict)
    meta: dict = field(default_factory=dict)
    brief: str = ""          # brief.md (memory/brief.py): "PAST MEETINGS WITH <name> ..." for the live model; empty when there is none
    call: "CallDirectives | None" = None   # call.json (runtime/call.py CallDirectives): per-session live-call directives; None when there is none

    @property
    def pack_for_model(self) -> str:
        """The pack as the prompt layout receives it: with a brief, the pack and a blank line and the brief block; without one, the
        pack itself (every request byte is what it was)."""
        return self.pack if not self.brief else self.pack.rstrip() + "\n\n" + self.brief


def load_session(session_dir: str | Path) -> Session:
    """Reads the P1-1 session folder contract. Tolerates P1-1's extra meta keys and 1-3 points per entry."""
    p = Path(session_dir).expanduser()
    pack = (p / "pack.md").read_text(encoding="utf-8")
    bank: dict[str, dict] = {}
    bank_file = p / "bank.jsonl"
    if bank_file.exists():
        for ln in bank_file.read_text(encoding="utf-8").splitlines():
            if ln.strip():
                rec = json.loads(ln)
                bank[rec["id"]] = rec
    meta_file = p / "meta.json"
    meta = json.loads(meta_file.read_text(encoding="utf-8")) if meta_file.exists() else {}
    from .call import load_call

    return Session(p, pack, bank, meta, _read_brief(p), load_call(p))


def _read_brief(folder: Path) -> str:
    """`brief.md`, at most BRIEF_PACK_CHARS characters (cut at a whole line); "" when missing or not UTF-8."""
    from .settings import BRIEF_PACK_CHARS

    try:
        text = (folder / "brief.md").read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return ""
    text = text.strip()
    if len(text) > BRIEF_PACK_CHARS:
        text = text[:BRIEF_PACK_CHARS]
        cut = text.rfind("\n")
        text = text[:cut] if cut > 0 else text
    return text.rstrip()
