"""The session event log: `events.jsonl` in the session folder (docs/specs/2026-10-16-verse-anytime-calls-design.md 2.1).

A live call decides many things silently: whether a room text was Alex reading his card or the other person, whether it was a
question and why (a cue, the statement probe, nothing), which cards were shown and which were held or dropped. Before this log
the session folder held only `transcript.jsonl` and `spend.json`, so a card that came at the wrong moment, or did not come, could
not be explained afterwards. One JSON object per line, flushed per line, text only (the first 80 characters of a transcript text,
the first 60 of a card line, up to 240 of a finished card's lines in `card_done`; never audio). The log is a diagnosis aid: a write that fails is ignored and never reaches the call.
"""

from __future__ import annotations

import json
import time
from pathlib import Path

TEXT_CHARS = 80      # transcript text in a log line
CARD_CHARS = 60      # card line in a log line
CARD_FULL_CHARS = 240   # a line of the finished card (`card_done`): what the app's transcript shows under the row it answered


def clip(text: object, n: int = TEXT_CHARS) -> str:
    s = " ".join(str(text).split())
    return s if len(s) <= n else s[:n].rstrip() + "…"


class EventLog:
    """Append-only JSON lines. `EventLog(None)` (no session folder) keeps nothing."""

    def __init__(self, path: Path | None) -> None:
        self.path = path
        self._fh = None
        self.lines = 0

    def write(self, ev: str, **fields) -> None:
        if self.path is None:
            return
        rec = {"t": round(time.time(), 3), "ev": ev, **{k: v for k, v in fields.items() if v is not None}}
        try:
            if self._fh is None:
                self._fh = open(self.path, "a", encoding="utf-8")
            self._fh.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
            self._fh.flush()
            self.lines += 1
        except (OSError, ValueError, TypeError):
            pass

    def close(self) -> None:
        if self._fh is not None:
            try:
                self._fh.close()
            except OSError:
                pass
            self._fh = None
        self.path = None
