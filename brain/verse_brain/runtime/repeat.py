"""Repeat guard for follow cards (spec 2026-10-29): a new line that says what the screen or the owner already said is not shown.

Evidence: in one answer of a live call the follow tier wrote four cards in 25 seconds, each restating "the big calls are mine to
make" with the same two points in other words. The prompt already told the model not to; the model did not listen. This is the net
in code: every line of a new follow card is compared with

    * every line that reached his screen this turn (the original card, the detail lines, every earlier follow card), and
    * the last sentences of his own answer in this turn,

and a line is a repeat when EITHER

    * the cosine of the two lines' embeddings (the follow machine's own EmbeddingGemma path, same prefix, same vector cache) is
      at least `RepeatParams.embed_dup` (0.86), or
    * they share at least `lex_dup` (0.6) of the content stems of the shorter one (follow.py's tokenizer and stemmer; the shorter
      one needs `lex_min_stems` stems, so a three-word line is not matched on one stray word).

0.86 is set on EmbeddingGemma 270M with the "sentence similarity" prefix: paraphrases of one idea scored 0.85 to 0.94, two different
facts about the same topic 0.78 to 0.84, unrelated lines 0.74 to 0.80 (`docs/follow-tuning.md`, "Repeats"; thirteen hand-written pairs).
Without the embedding path (model missing, still loading, failed, other language) only the lexical rule runs.

Pure functions: the engine hands them vectors it computed on the embedding thread.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from operator import mul
from typing import Callable, Sequence

from .follow import content_stems, unit


@dataclass(frozen=True)
class RepeatParams:
    embed_dup: float = 0.86          # cosine at or above which two lines are the same idea
    lex_dup: float = 0.60            # share of the shorter line's content stems found in the other
    lex_min_stems: int = 3           # the shorter line needs this many content stems for the lexical rule to apply
    his_chunks: int = 8              # how many of the last sentences of his answer are compared
    chunk_words: int = 14            # a sentence longer than this (or text without punctuation) is cut into pieces of this size


_SENT = re.compile(r"(?<=[.!?])\s+")


def his_chunks(text: str, p: RepeatParams | None = None) -> list[str]:
    """The last sentences of his answer, as short comparable pieces (ASR text often has no punctuation: pieces of `chunk_words`)."""
    p = p or RepeatParams()
    out: list[str] = []
    for sent in _SENT.split(" ".join(text.split())):
        words = sent.split()
        if len(words) < 3:
            continue
        if len(words) <= p.chunk_words * 3 // 2:
            out.append(sent)
        else:
            out += [" ".join(words[i:i + p.chunk_words]) for i in range(0, len(words), p.chunk_words)
                    if len(words[i:i + p.chunk_words]) >= 3]
    return out[-p.his_chunks:]


def lex_overlap(a: str, b: str, p: RepeatParams | None = None) -> float:
    """Share of the shorter line's content stems that the other line has; 0 when the shorter one has fewer than `lex_min_stems`."""
    p = p or RepeatParams()
    sa, sb = content_stems(a), content_stems(b)
    small = min(len(sa), len(sb))
    if small < p.lex_min_stems:
        return 0.0
    return len(sa & sb) / small


def cosine(a: Sequence[float], b: Sequence[float]) -> float:
    return sum(map(mul, a, b))


def embed_all(embed: Callable[[str], list[float]], texts: Sequence[str], cache: dict[str, list[float]], prefix: str = "") -> dict[str, list[float]]:
    """Unit vectors of `texts`, from `cache` or `embed` (runs on the embedding thread; the cache is touched there only)."""
    out: dict[str, list[float]] = {}
    for t in texts:
        v = cache.get(t)
        if v is None:
            v = cache[t] = unit(embed(prefix + t))
        out[t] = v
    return out


def find_repeat(text: str, refs: Sequence[str], vecs: dict[str, list[float]] | None = None,
                p: RepeatParams | None = None) -> tuple[str, str, float] | None:
    """(the reference line, "same" | "lex" | "embed", the score) of the first line in `refs` that `text` repeats; None when it is new.
    `vecs`: unit vectors by text (None or missing texts: the lexical rule alone)."""
    p = p or RepeatParams()
    tv = vecs.get(text) if vecs else None
    for ref in refs:
        if not ref:
            continue
        if ref == text:
            return ref, "same", 1.0
        lex = lex_overlap(text, ref, p)
        if lex >= p.lex_dup:
            return ref, "lex", lex
        rv = vecs.get(ref) if vecs else None
        if tv is not None and rv is not None:
            c = cosine(tv, rv)
            if c >= p.embed_dup:
                return ref, "embed", c
    return None


def filter_card(say: str | None, points: Sequence[str], refs: Sequence[str], vecs: dict[str, list[float]] | None = None,
                p: RepeatParams | None = None) -> tuple[bool, list[str], list[tuple[str, str, str, float]]]:
    """The new follow card against what is already shown: (keep the SAY line, the points to keep, the repeats found).

    A SAY line that repeats drops the whole card (it is the continuation of his line: when it restates, the card is stale). A point
    that repeats a shown line, his words, the new SAY line or an earlier point of the same card is dropped on its own. A card
    without a SAY line (the model wrote points only) is judged by its points. Each repeat is (kind, line, matched, score)."""
    found: list[tuple[str, str, str, float]] = []
    seen = list(refs)
    keep_say = False
    if say:
        hit = find_repeat(say, seen, vecs, p)
        if hit is not None:
            found.append(("say", say, hit[0], round(hit[2], 3)))
            return False, [], found
        keep_say = True
        seen.append(say)
    kept: list[str] = []
    for pt in points:
        hit = find_repeat(pt, seen, vecs, p)
        if hit is not None:
            found.append(("point", pt, hit[0], round(hit[2], 3)))
            continue
        kept.append(pt)
        seen.append(pt)
    return keep_say, kept, found
