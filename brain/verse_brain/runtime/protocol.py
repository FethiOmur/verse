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
from typing import IO, Callable

IN_TYPES = {"start", "partial", "turn", "bank_hit", "control"}
STATUS_STATES = {"warming", "ready", "offline", "rate_limited", "credit_exhausted", "refusal", "error"}


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
    def delta(self, id: str, turn_id: str, tier: str, text: str, line_done: bool) -> dict:
        return {"type": "delta", "id": id, "turn_id": turn_id, "tier": tier, "text": text, "line_done": line_done}

    def status(self, state: str, message: str = "", **extra) -> None:
        assert state in STATUS_STATES, state
        self.emit({"type": "status", "state": state, "message": message, **extra})

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
    return Session(p, pack, bank, meta)
