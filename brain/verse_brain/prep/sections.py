"""Sectioned prep: split a long prep note into sections of about 12-18k chars, and merge the per-section results.

A section is a run of the note's top-level units (the units are cut at `---` rules and at `#` / `##` headings). The note's
header (everything before the first unit) goes into every section call, with its original line numbers, so the
`prep:L<n>` handles of every section point at the real line of the whole note. The note is never truncated: a unit
bigger than a section is cut again at blank lines, then at line ends.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass

from .ground import Dropped, Grounded
from .sources import norm

SECTION_TRIGGER_CHARS = 20_000  # a longer note is always sectioned
BIG_BANK_QUESTIONS = 40  # a bank bigger than this is sectioned once the note is more than BIG_BANK_MIN_CHARS long
BIG_BANK_MIN_CHARS = 8_000
SECTION_TARGET_CHARS = 15_000
SECTION_MAX_CHARS = 18_000
QUOTA_SLACK = 1.15  # per-section quotas add up to this much more than the bank, so dedupe losses do not leave it short
MAX_HEADER_CHARS = 6_000
NEAR_DUP_JACCARD = 0.9
NEAR_MIN_WORDS = 8
MIN_QUOTA = 4
MAX_QUOTA = 40

_RULE = re.compile(r"^\s*-{3,}\s*$")
_HEAD = re.compile(r"^(#{1,2})\s+\S")


@dataclass
class Section:
    index: int  # 1-based
    lines: list[tuple[int, str]]  # (original 1-based line number, text)
    quota: int = 0

    @property
    def chars(self) -> int:
        return sum(len(t) + 1 for _, t in self.lines)

    @property
    def span(self) -> tuple[int, int]:
        return (self.lines[0][0], self.lines[-1][0]) if self.lines else (0, 0)


def wants_sections(note_chars: int, max_questions: int) -> bool:
    return note_chars > SECTION_TRIGGER_CHARS or (max_questions > BIG_BANK_QUESTIONS and note_chars > BIG_BANK_MIN_CHARS)


def _units(lines: list[tuple[int, str]]) -> tuple[list[tuple[int, str]], list[list[tuple[int, str]]]]:
    """(header, units). The header is everything before the first separator; a level-1 title on the first non-blank line
    is part of the header, not a separator."""
    first = next((i for i, (_, t) in enumerate(lines) if t.strip()), len(lines))
    cuts = [i for i, (_, t) in enumerate(lines)
            if (_RULE.match(t) or _HEAD.match(t)) and not (i == first and _HEAD.match(t) and t.lstrip().startswith("# "))]
    if not cuts:
        return list(lines), []
    header = lines[: cuts[0]]
    units = [lines[a:b] for a, b in zip(cuts, cuts[1:] + [len(lines)])]
    return header, units


def _cut_unit(unit: list[tuple[int, str]], limit: int) -> list[list[tuple[int, str]]]:
    """Split a unit larger than `limit` chars: after a blank line once the piece is 60 % full, else at a line end."""
    pieces: list[list[tuple[int, str]]] = []
    cur: list[tuple[int, str]] = []
    size = 0
    for ln in unit:
        add = len(ln[1]) + 1
        if cur and size + add > limit:
            pieces.append(cur)
            cur, size = [], 0
        cur.append(ln)
        size += add
        if not ln[1].strip() and size >= limit * 0.6:
            pieces.append(cur)
            cur, size = [], 0
    if cur:
        pieces.append(cur)
    return pieces


def split_note(note: str, max_questions: int, *, target: int = SECTION_TARGET_CHARS,
               limit: int = SECTION_MAX_CHARS) -> tuple[list[tuple[int, str]], list[Section]]:
    """(header lines, sections). Without a long note or a big bank: no header and one section holding every line."""
    lines = list(enumerate(note.splitlines(), start=1))
    if not wants_sections(len(note), max_questions):
        return [], [Section(1, lines)]
    header, units = _units(lines)
    if sum(len(t) + 1 for _, t in header) > MAX_HEADER_CHARS:  # too big to repeat in every call: it is cut like any unit
        units = [lines[: len(header)], *units] if units else units
        header = []
    if not units:  # no heading or rule to cut at: the whole note is one unit and is cut at blank lines
        header, units = [], [lines]
    body_chars = sum(len(t) + 1 for _, t in lines[len(header):])
    n = max(math.ceil(len(note) / target) if len(note) > SECTION_TRIGGER_CHARS else 1,
            math.ceil(max_questions / BIG_BANK_QUESTIONS) if max_questions > BIG_BANK_QUESTIONS else 1, 1)
    budget = min(target, max(2_000, math.ceil(body_chars / n)))
    flat: list[list[tuple[int, str]]] = []
    for u in units:
        size = sum(len(t) + 1 for _, t in u)
        flat += _cut_unit(u, min(limit, budget)) if size > limit else [u]
    sections: list[list[tuple[int, str]]] = []
    cur: list[tuple[int, str]] = []
    size = 0
    for u in flat:
        usize = sum(len(t) + 1 for _, t in u)
        if cur and size + usize > budget:
            sections.append(cur)
            cur, size = [], 0
        cur += u
        size += usize
    if cur:
        sections.append(cur)
    tail_chars = sum(len(t) + 1 for _, t in sections[-1])
    if len(sections) > 1 and tail_chars < budget // 4 and tail_chars + sum(len(t) + 1 for _, t in sections[-2]) <= limit:
        tail = sections.pop()  # a tiny tail joins its neighbour
        sections[-1] += tail
    if len(sections) == 1:  # the note fits one call after all: the plain, unsectioned run
        return [], [Section(1, lines)]
    out = [Section(i, ls) for i, ls in enumerate(sections, start=1)]
    total = sum(s.chars for s in out) or 1
    for s in out:
        s.quota = min(MAX_QUOTA, max(MIN_QUOTA, math.ceil(max_questions * QUOTA_SLACK * s.chars / total)))
    return header, out


# ---------------------------------------------------------------------------------------------- merge

_STOP_PUNCT = re.compile(r"[^\w\s]", re.U)


def _tokens(q: str) -> frozenset[str]:
    return frozenset(_STOP_PUNCT.sub(" ", norm(q)).split())


def _near_duplicate(q: str, seen_tokens: list[frozenset[str]]) -> bool:
    """Word-set overlap of 0.9 or more between two questions of 8+ distinct words (a reorder or a filler word). Kept strict:
    two questions that differ in one name or number must both stay."""
    ta = _tokens(q)
    if len(ta) < NEAR_MIN_WORDS:
        return False
    return any(len(ta & tb) / len(ta | tb) >= NEAR_DUP_JACCARD for tb in seen_tokens if len(tb) >= NEAR_MIN_WORDS)


def merge_grounded(parts: list[Grounded], max_questions: int) -> Grounded:
    """Merge the grounded results of several sections (in note order) into one.

    Bank entries are interleaved by rank (every section's first, then every section's second, ...) so that the pack trim,
    which cuts from the end, does not take a whole late section first. Duplicates (same normalised question, or a
    near-identical one) keep the first and are recorded in `dropped`. Ids are renumbered b001.., f001.., g001..;
    `point_sources` follows the new bank ids. Facts dedupe by normalised text, glossary terms by normalised term."""
    out = Grounded()
    for p in parts:
        out.dropped += p.dropped
        for k, v in p.stats.items():
            if isinstance(v, (int, float)):
                out.stats[k] = out.stats.get(k, 0) + v
    seen_f: set[str] = set()
    for p in parts:
        for f in p.facts:
            key = norm(f["text"])
            if key in seen_f:
                continue
            seen_f.add(key)
            out.facts.append({**f, "id": f"f{len(out.facts) + 1:03d}"})
    seen_g: set[str] = set()
    for p in parts:
        for t in p.glossary:
            key = norm(t["term"])
            if key in seen_g:
                continue
            seen_g.add(key)
            out.glossary.append({**t, "id": f"g{len(out.glossary) + 1:03d}"})
    seen_q: set[str] = set()
    seen_tok: list[frozenset[str]] = []
    depth = max((len(p.bank) for p in parts), default=0)
    for rank in range(depth):
        for p in parts:
            if rank >= len(p.bank):
                continue
            b = p.bank[rank]
            nq = norm(b["question"])
            if nq in seen_q or _near_duplicate(b["question"], seen_tok):
                out.dropped.append(Dropped("entry", "duplicate", b["question"], "merge"))
                out.stats["entries_dropped_duplicate"] = out.stats.get("entries_dropped_duplicate", 0) + 1
                continue
            if len(out.bank) >= max_questions:
                out.dropped.append(Dropped("entry", "over_cap", b["question"], "merge"))
                out.stats["entries_dropped_over_cap"] = out.stats.get("entries_dropped_over_cap", 0) + 1
                continue
            seen_q.add(nq)
            seen_tok.append(_tokens(b["question"]))
            new_id = f"b{len(out.bank) + 1:03d}"
            out.point_sources[new_id] = p.point_sources.get(b["id"], {"points": [], "deep": []})
            out.bank.append({**b, "id": new_id})
    return out
