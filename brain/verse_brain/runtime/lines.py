"""Splits streamed model text into lines, forwarding display text word by word and holding control lines.

Display lines (`SAY: ...`, `- ...`) are forwarded as soon as their start cannot be a control token. Control lines
(`BANK: <id>|none`, `OPENER_OK`, `OPENER_WRONG`) are held until complete and reported through `on_control`, never
forwarded as text. With `hold_first_line`, nothing is forwarded until the first line is complete (D: the opener
verdict must reach Swift before any D text).
"""

from __future__ import annotations

from typing import Callable

CONTROL_TOKENS = ("BANK:", "OPENER_OK", "OPENER_WRONG")


class LineAssembler:
    def __init__(self, on_text: Callable[[str, bool, str], None], on_control: Callable[[str], None],
                 hold_first_line: bool = False) -> None:
        """on_text(chunk, line_done, full_line_so_far); on_control(line)."""
        self._on_text = on_text
        self._on_control = on_control
        self._cur = ""          # current line, all of it
        self._sent = 0          # chars of the current line already forwarded
        self._mode: str | None = None  # None = undecided, "ctrl", "text"
        self._hold = hold_first_line
        self.lines: list[str] = []

    def _classify(self) -> None:
        s = self._cur.lstrip()
        if not s:
            return
        if any(s.startswith(t) for t in CONTROL_TOKENS):
            self._mode = "ctrl"
        elif any(t.startswith(s) for t in CONTROL_TOKENS):
            return  # could still become a control token
        else:
            self._mode = "text"

    def _forward_partial(self) -> None:
        if self._mode == "text" and not self._hold and self._sent < len(self._cur):
            chunk = self._cur[self._sent:]
            self._sent = len(self._cur)
            self._on_text(chunk, False, self._cur)

    def _finish_line(self) -> None:
        line = self._cur.strip()
        cur = self._cur
        self._cur, self._mode = "", None
        sent, self._sent = self._sent, 0
        if not line:
            return
        self.lines.append(line)
        if any(line.startswith(t) for t in CONTROL_TOKENS):
            self._on_control(line)
            if self._hold:
                self._release_hold()
            return
        if self._hold:
            # first line was not a control line: forward it whole after the hold is lifted
            self._hold = False
            self._on_text(cur.rstrip(), True, line)
            return
        self._on_text(cur[sent:].rstrip() if sent < len(cur) else "", True, line)

    def _release_hold(self) -> None:
        self._hold = False

    def feed(self, text: str) -> None:
        parts = text.split("\n")
        for i, part in enumerate(parts):
            if part:
                self._cur += part
                if self._mode is None:
                    self._classify()
                self._forward_partial()
            if i < len(parts) - 1:
                if self._mode is None:
                    self._classify()
                self._finish_line()

    def close(self) -> None:
        if self._cur.strip():
            if self._mode is None:
                self._classify()
            self._finish_line()
