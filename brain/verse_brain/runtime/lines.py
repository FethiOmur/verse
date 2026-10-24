"""Splits streamed model text into lines, forwarding display text word by word and holding control lines.

Display lines (`SAY: ...`, `- ...`) are forwarded as soon as their start cannot be a control token. Control lines
(`BANK: <id>|none`, `KIND: question|statement`, `OPENER_OK`, `OPENER_WRONG`) are held until complete and reported through `on_control`, never
forwarded as text. With `hold_first_line`, nothing is forwarded until the first line is complete (D: the opener
verdict must reach Swift before any D text).
"""

from __future__ import annotations

import re
from typing import Callable

CONTROL_TOKENS = ("BANK:", "KIND:", "OPENER_OK", "OPENER_WRONG")

# What a model writes when it has nothing to say ("write NONE", "or the single word NONE" in the prompts, a bank-style
# "none"). A line that is only one of these (optionally behind `SAY:` / `- `, in brackets or quotes, with a closing
# full stop) is a sentinel: it is never shown. A sentence that merely starts with one ("None of the pilots failed.")
# is not.
SENTINELS = ("none", "null", "n/a", "skip")
_MARKER = re.compile(r"^(?:SAY\s*:|[-\u2022*])\s*", re.IGNORECASE)
_OPEN = "([{<\"'`*_"
_CLOSE = ".!:;,)]}>\"'`*_ "


def _after_marker(line: str) -> str:
    return _MARKER.sub("", line.strip(), count=1)


def is_sentinel(line: str) -> bool:
    """True when the whole line is a "nothing to say" sentinel (case, brackets, quotes and a closing full stop ignored)."""
    core = _after_marker(line).strip().lstrip(_OPEN).rstrip(_CLOSE).strip().lower()
    return core in SENTINELS


def could_become_sentinel(partial: str) -> bool:
    """True when the unfinished line so far may still turn out to be a sentinel, so nothing of it may be shown yet: a bare
    `SAY:` / `- ` marker, or a body that is a prefix of a sentinel (`N`, `NO`, `NON`, `NONE`, `none.`). `No, not yet` is
    already clear of it at the comma."""
    s = partial.strip()
    if not s:
        return False
    rest = _after_marker(s).strip()
    if rest != s and not rest:
        return True                         # a marker with nothing behind it yet
    body = rest.lower().lstrip(_OPEN)
    if rest and not body:
        return True                         # only an opening bracket or quote so far
    core = body.rstrip(_CLOSE)
    return bool(core) and any(w.startswith(core) for w in SENTINELS)


# A point that talks about the preparation instead of being something the owner can say ("The pack has no stated reason for the
# school. Say what is true ...", live English call, 17 Oct). It is never shown: the prompts forbid it and this is the net.
_META = re.compile(
    r"\b(?:the|this|these|that|your|his|my)\s+(?:meeting\s+)?(?:pack|notes|profile|prep|preparation|bank|grounding)\b"
    r"|\bmeeting\s+pack\b|\b(?:no|not|isn'?t|aren'?t|wasn'?t)\s+(?:stated|specified|mentioned|provided|given)\b"
    r"|\bnot\s+(?:in|on)\s+the\s+(?:pack|notes|profile)\b|\bsay\s+what\s+is\s+true\b|\bnothing\s+(?:in|from)\s+the\s+(?:pack|notes|profile)\b"
    r"|\b(?:il|nel|dal|nelle|le)\s+(?:pacchetto|note|profilo)\b|\bnon\s+(?:è|e)\s+(?:indicat|specificat)\w*"
    r"|\b(?:paket|notlar|profil)\w*\s+(?:de|da|te|ta)?\s*(?:belirtilmemi|yok)\w*",
    re.IGNORECASE)


def is_meta(line: str) -> bool:
    """True when a card point talks about the pack, the notes or the profile, or tells the owner what to do, instead of giving him
    something to say."""
    return bool(_META.search(_after_marker(line)))


class LineAssembler:
    def __init__(self, on_text: Callable[[str, bool, str], None], on_control: Callable[[str], None],
                 hold_first_line: bool = False, on_sentinel: Callable[[str], None] | None = None,
                 on_drop: Callable[[str], None] | None = None) -> None:
        """on_text(chunk, line_done, full_line_so_far); on_control(line); on_sentinel(line) for a dropped sentinel; `on_drop(line)`
        for a point line that talks about the preparation (`is_meta`): a "- " line is held until it is complete when `on_drop` is set,
        so that such a line can be dropped before anything of it is shown."""
        self._on_drop = on_drop
        self._on_sentinel = on_sentinel
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
        if self._on_drop is not None and self._cur.lstrip().startswith("- "):
            return                    # a point is shown whole, once it is known not to be about the preparation
        if self._mode == "text" and not self._hold and self._sent < len(self._cur) and not could_become_sentinel(self._cur):
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
        if is_sentinel(line):
            # "NONE" and friends: nothing of the line was forwarded (it was held while it could still be one). The
            # first-line hold stays: the next line is the first one that counts.
            if self._on_sentinel is not None:
                self._on_sentinel(line)
            return
        if self._on_drop is not None and line.startswith("- ") and is_meta(line):
            self._on_drop(line)
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
