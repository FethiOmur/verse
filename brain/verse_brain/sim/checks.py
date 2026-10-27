"""Per-answer checks for a sim with an interviewer persona (opt-in): length against the answer target, clarity, over-eager
phrasing, and numbers or names the session's sources do not support. Deterministic: no model call, no clock.

`answer_checks` returns plain data (stored in `sim_results.json` and the report); `check_lines` turns it into the short English
lines of the live coach note. The sources are the evidence items of the sim (text and quoted source lines) and the posting or
source pack text: a figure in an answer that appears in none of them is flagged as unsupported, not as wrong.
"""

from __future__ import annotations

import re

from . import delivery
from .grade import numbers_in

OVER_EAGER = (
    r"\bI(?:'d| would)? (?:really |truly |absolutely |just )?(?:love|adore) to\b",
    r"\bI(?:'m| am) (?:so |really |very |extremely |super |incredibly )?(?:excited|thrilled|eager|passionate|dying)\b",
    r"\bI (?:really |truly |desperately |absolutely )(?:want|need) (?:this|to join|to work|the job|the role|the position)\b",
    r"\b(?:dream (?:job|company|role|position)|would be (?:a |an )?(?:dream|honou?r|privilege))\b",
    r"\bI(?:'d| would) do anything\b",
    r"\bcan(?:'t|not) wait\b",
    r"\b(?:so|really|truly|extremely|incredibly) (?:grateful|honou?red|thrilled|excited)\b",
)
_EAGER = [re.compile(p, re.IGNORECASE) for p in OVER_EAGER]
_INTENSIFIERS = re.compile(r"\b(?:really|absolutely|totally|extremely|incredibly|super|amazing|awesome|fantastic)\b", re.IGNORECASE)
MAX_INTENSIFIERS = 3
MAX_FILLERS = 3
FAST_WPM = 175
_NAME = re.compile(r"[A-Z][A-Za-z0-9+#]{2,}(?:\.[A-Za-z]{1,3})?")
_SENTENCE = re.compile(r"(?<=[.!?])\s+")
_NOT_NAMES = {"i", "i'm", "i've", "i'd", "i'll", "english", "italian", "turkish", "german", "french", "spanish", "europe", "european",
              "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march", "april",
              "may", "june", "july", "august", "september", "october", "november", "december", "yes", "okay", "thanks", "thank"}
_WORD = re.compile(r"[\w']+", re.UNICODE)


def _sources(evidence: list[dict], extra: str) -> str:
    parts = [extra or ""]
    for e in evidence or []:
        parts.append(str(e.get("text", "")))
        parts += [str(s.get("quote", "")) for s in e.get("sources", [])]
    return "\n".join(parts)


def _names(text: str, allowed_words: set[str]) -> list[str]:
    out: list[str] = []
    for sentence in _SENTENCE.split(text):
        for m in _NAME.finditer(sentence):
            if m.start() == 0 or not sentence[:m.start()].strip():     # a sentence starts with a capital anyway
                continue
            w = m.group(0)
            if w.lower() in _NOT_NAMES or w.lower() in allowed_words or w in out:
                continue
            out.append(w)
    return out


def answer_checks(answers: list[dict], target_s, *, evidence: list[dict], source_text: str = "", lang: str = "en") -> dict:
    """The checks for one question's answers. `target_s`: `[lo, hi]` seconds. `evidence`: sim.json evidence items."""
    from ..runtime.sim import is_vague      # lazy: the sim runtime imports this module

    text = " ".join(str(a.get("text", "")) for a in answers)
    secs = delivery.answer_seconds(answers)
    allowed = _sources(evidence, source_text)
    allowed_words = {w.lower() for w in _WORD.findall(allowed)}
    nums = sorted(numbers_in(text) - numbers_in(allowed), key=lambda x: (len(x), x))
    return {
        "seconds": round(secs, 1), "target_s": target_s, "length": delivery.length_status(secs, target_s),
        "wpm": delivery.wpm(answers), "fillers": delivery.filler_count(text, lang),
        "vague": is_vague(text) if text.strip() else [],
        "eager": [m.group(0) for p in _EAGER for m in [p.search(text)] if m][:3],
        "intensifiers": len(_INTENSIFIERS.findall(text)),
        "unsupported_numbers": nums[:5],
        "unsupported_names": _names(text, allowed_words)[:4] if lang == "en" else [],
    }


def check_lines(c: dict) -> list[str]:
    """The flagged points as short English lines, length first. A clean answer still gets its length line."""
    out: list[str] = []
    t = c.get("target_s")
    if c.get("length") and t:
        s, lo, hi = round(c["seconds"]), t[0], t[1]
        out.append({"short": f"Length: {s} s, under the {lo}-{hi} s target; add one concrete point.",
                    "long": f"Length: {s} s, over the {lo}-{hi} s target; give the answer first, then stop.",
                    "on_target": f"Length: {s} s, on the {lo}-{hi} s target."}[c["length"]])
    if c.get("eager") or c.get("intensifiers", 0) > MAX_INTENSIFIERS:
        said = "; ".join(f"\"{x}\"" for x in c.get("eager", [])) or f"{c['intensifiers']} enthusiasm words"
        out.append(f"Tone: eager phrasing ({said}); say it level and confident.")
    clarity = []
    if c.get("vague"):
        clarity.append("; ".join(c["vague"]))
    if c.get("fillers", 0) >= MAX_FILLERS:
        clarity.append(f"{c['fillers']} filler words")
    if c.get("wpm", 0) > FAST_WPM:
        clarity.append(f"fast pace ({round(c['wpm'])} wpm)")
    if clarity:
        out.append("Clarity: " + ", ".join(clarity) + ".")
    bits = []
    if c.get("unsupported_numbers"):
        bits.append("numbers " + ", ".join(c["unsupported_numbers"]))
    if c.get("unsupported_names"):
        bits.append("names " + ", ".join(c["unsupported_names"]))
    if bits:
        out.append("Not in your sources: " + "; ".join(bits) + ". Say only what you can back up.")
    return out
