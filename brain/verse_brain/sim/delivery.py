"""Delivery numbers from `sim_results.json` answers: pace, filler words, pauses, answer length.

An answer is `{"text", "t_start", "t_end", "words", "fillers"}`. The transcript has answer-level times only (no word
timings), so a "pause" here is the gap between one answer ending and the next answer of the same question starting.
"""

from __future__ import annotations

import re

FILLERS = {
    "en": ("um", "uh", "like", "you know", "sort of", "kind of", "basically", "actually"),
}


def _pattern(lang: str) -> re.Pattern | None:
    words = FILLERS.get(lang)
    if not words:
        return None
    alts = "|".join(r"\s+".join(map(re.escape, w.split())) for w in sorted(words, key=len, reverse=True))
    return re.compile(rf"(?<![\w'])(?:{alts})(?![\w'])", re.IGNORECASE)


_PATTERNS: dict[str, re.Pattern | None] = {}


def filler_count(text: str, lang: str = "en") -> int:
    """Filler words in `text`, word-boundary and case-insensitive. Languages without a list count 0."""
    if lang not in _PATTERNS:
        _PATTERNS[lang] = _pattern(lang)
    pat = _PATTERNS[lang]
    return len(pat.findall(text or "")) if pat else 0


def answer_seconds(answers: list[dict]) -> float:
    """Total speaking time: the sum of t_end - t_start over the answers (negative spans count as 0)."""
    return round(sum(max(0.0, float(a.get("t_end", 0.0)) - float(a.get("t_start", 0.0))) for a in answers), 3)


def word_total(answers: list[dict]) -> int:
    return sum(int(a.get("words") or len((a.get("text") or "").split())) for a in answers)


def wpm(answers: list[dict]) -> float:
    """Words per minute over answer time, one decimal. 0.0 without any answer time."""
    secs = answer_seconds(answers)
    if secs <= 0:
        return 0.0
    return round(word_total(answers) / secs * 60.0, 1)


def longest_pause(answers: list[dict]) -> float:
    """Longest gap (seconds, one decimal) between an answer's t_end and the next answer's t_start. 0.0 for fewer than two."""
    ordered = sorted(answers, key=lambda a: float(a.get("t_start", 0.0)))
    gaps = [float(b.get("t_start", 0.0)) - float(a.get("t_end", 0.0)) for a, b in zip(ordered, ordered[1:])]
    return round(max(gaps), 1) if gaps and max(gaps) > 0 else 0.0


def length_status(seconds: float, target_s) -> str | None:
    """'short' | 'on_target' | 'long' against `[lo, hi]` seconds; None without an answer or a target."""
    if seconds <= 0 or not target_s or len(target_s) != 2:
        return None
    lo, hi = target_s
    return "short" if seconds < lo else "long" if seconds > hi else "on_target"
