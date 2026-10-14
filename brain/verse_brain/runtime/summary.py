"""F2 incremental summary: model-line parsing, the dedupe-merged running list, and the `summary.md` renderer.

The rolling pass (Haiku, S/F tuple) and the final pass (Sonnet, D tuple) both answer in plain-text lines:

    SUMMARY: <2-3 sentences>                   (final pass only)
    DECISION: <what was decided>
    ACTION: <owner> — <what, by when if stated>
    OPEN: <an unresolved question>
    CONFLICT: <a fact said in the meeting that differs from the fact sheet>   (final pass only)

`Running` keeps one list per kind and drops repeats by normalised text (case, punctuation and spacing ignored).
"""

from __future__ import annotations

import re
import time
import unicodedata
from dataclasses import dataclass, field

KINDS = ("SUMMARY", "DECISION", "ACTION", "OPEN", "CONFLICT")
MAX_ITEMS = 40  # per list: keeps the "already recorded" tail of the next pass bounded

_LINE = re.compile(r"^[\W_]*(SUMMARY|DECISION|ACTION|OPEN|CONFLICT)\s*[*_]*\s*:\s*[*_]*\s*(.*?)[\s*_]*$",
                   re.IGNORECASE | re.DOTALL)
_SEP = re.compile(r"\s+[-–—]{1,2}\s+")


def norm(text: str) -> str:
    """Dedupe key: NFKC, case-folded, punctuation and dashes dropped, whitespace collapsed."""
    s = unicodedata.normalize("NFKC", text).casefold()
    s = re.sub(r"[^\w\s]|_", " ", s)
    return " ".join(s.split())


def canon_action(text: str) -> str:
    """`<owner> — <item>` with one canonical separator; an owner-less action gets `Unassigned`."""
    if _SEP.search(text):
        return _SEP.sub(" — ", text, count=1)
    return f"Unassigned — {text}"


def parse_line(line: str) -> tuple[str, str] | None:
    """(KIND, text) for a summary line, None for anything else (NONE, chatter, empty items)."""
    m = _LINE.match(line.strip())
    if not m:
        return None
    kind, text = m.group(1).upper(), " ".join(m.group(2).split())
    if not text or text.casefold().rstrip(".") == "none":
        return None
    if kind == "ACTION":
        text = canon_action(text)
    return kind, text


@dataclass
class Running:
    decisions: list[str] = field(default_factory=list)
    actions: list[str] = field(default_factory=list)
    open: list[str] = field(default_factory=list)
    conflicts: list[str] = field(default_factory=list)
    text: str = ""

    _FIELD = {"DECISION": "decisions", "ACTION": "actions", "OPEN": "open", "CONFLICT": "conflicts"}

    def _items(self, kind: str) -> list[str]:
        return getattr(self, self._FIELD[kind])

    def add(self, kind: str, text: str) -> bool:
        """Add one item unless its normalised text is already in that list. True if the list changed."""
        if kind == "SUMMARY":
            changed = text != self.text
            self.text = text
            return changed
        items = self._items(kind)
        key = norm(text)
        if not key or len(items) >= MAX_ITEMS or any(norm(x) == key for x in items):
            return False
        items.append(text)
        return True

    def merge_lines(self, parsed: list[tuple[str, str]]) -> bool:
        changed = False
        for kind, text in parsed:
            if kind == "SUMMARY":  # the rolling pass has no summary line; only the final pass sets the text
                self.text = text
            else:
                changed |= self.add(kind, text)
        return changed

    def lists(self) -> dict:
        return {"decisions": list(self.decisions), "actions": list(self.actions), "open": list(self.open)}

    def is_empty(self) -> bool:
        return not (self.decisions or self.actions or self.open or self.conflicts or self.text)

    def copy(self) -> "Running":
        return Running(list(self.decisions), list(self.actions), list(self.open), list(self.conflicts), self.text)

    def as_lines(self) -> list[str]:
        """The running list as model-format lines (the 'already recorded' / 'draft notes' block of a tail)."""
        return ([f"DECISION: {x}" for x in self.decisions] + [f"ACTION: {x}" for x in self.actions]
                + [f"OPEN: {x}" for x in self.open])


def parse_lines(lines: list[str]) -> list[tuple[str, str]]:
    return [p for p in (parse_line(ln) for ln in lines) if p is not None]


def render_markdown(r: Running, *, text: str, meta: dict, note: str | None) -> str:
    """`summary.md`. `note` marks a draft (the Sonnet merge did not complete) and says why."""
    stamp = time.strftime("%Y-%m-%d %H:%M", time.localtime())
    bits = [f"generated {stamp}"]
    if meta.get("session"):
        bits.append(f"session {meta['session']}")
    if meta.get("turns") is not None:
        bits.append(f"{meta['turns']} finalized turns")
    if meta.get("model"):
        bits.append(f"merged by {meta['model']}" if note is None else f"rolling notes from {meta['model']}")
    out = ["# Meeting summary", "", "_" + " · ".join(bits) + "_", ""]
    if note:
        out += [f"> DRAFT: {note}", ""]

    def section(title: str, items: list[str]) -> None:
        out.extend([f"## {title}", ""])
        out.extend(f"- {x}" for x in items) if items else out.append("- (none)")
        out.append("")

    out += ["## Summary", "", text.strip() if text.strip() else "(not available)", ""]
    section("Decisions", r.decisions)
    section("Actions", r.actions)
    section("Open questions", r.open)
    section("Conflicts with the fact sheet", r.conflicts)
    return "\n".join(out).rstrip() + "\n"
