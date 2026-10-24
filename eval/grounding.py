"""Grounding check for suggestion lines (spec section 9: no number, date or name that is absent from the cited source).

`claims(line)` pulls the numbers, years/dates and proper names out of one SAY line or bullet. `corpus_text(session_dir)`
builds the text they are checked against: the pack, plus the quoted sources in bank/facts/glossary. A claim that is not
in the corpus is "unresolved" and goes to the independent Haiku judge (judge.py). Stdlib only.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

NUMBER_WORDS = {"zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
                "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14", "fifteen": "15",
                "twenty": "20", "thirty": "30", "forty": "40", "fifty": "50", "hundred": "100"}
MONTHS = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
WEEKDAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
# Capitalised words that are not names: sentence starters, pronouns, generic terms the model uses.
COMMON_CAPS = {
    "i", "i'm", "i've", "i'd", "i'll", "it", "its", "it's", "the", "a", "an", "and", "but", "so", "yes", "no", "sure", "okay", "ok", "that", "this",
    "my", "we", "you", "your", "our", "they", "their", "he", "she", "there", "here", "what", "when", "where", "why", "how", "which", "who",
    "happy", "good", "great", "thanks", "thank", "now", "then", "also", "one", "two", "three", "for", "in", "on", "at", "to", "of", "with",
    "as", "if", "not", "is", "are", "was", "were", "do", "did", "does", "have", "has", "had", "can", "could", "would", "should", "will",
    "let", "let's", "mostly", "first", "second", "third", "because", "since", "while", "after", "before", "most", "some", "all", "any",
    "llm", "llms", "ai", "eur", "gross", "q1", "q2", "q3", "q4", "ceo", "cto", "vp", "ci", "api", "ml", "sql", "eta", "user",
    "english", "italian", "turkish", "european",
}


def norm_num(s: str) -> str:
    s = s.lower().replace(",", "").rstrip(".%")
    return NUMBER_WORDS.get(s, s)


def claims(line: str) -> dict[str, list[str]]:
    """Numbers (as normalised strings), dates (months, weekdays, 4-digit years) and capitalised names in a line."""
    text = re.sub(r"^(SAY:|-)\s*", "", line.strip())
    nums = [norm_num(m) for m in re.findall(r"\d[\d,]*(?:\.\d+)?%?", text)]
    words = re.findall(r"[A-Za-z][A-Za-z'\-]*", text)
    for w in words:
        if w.lower() in NUMBER_WORDS and w.lower() not in ("one",):
            nums.append(NUMBER_WORDS[w.lower()])
    dates = [w.lower() for w in words if w.lower() in MONTHS or w.lower() in WEEKDAYS]
    names: list[str] = []
    # capitalised tokens that are not the first word of a sentence and not common words
    for m in re.finditer(r"(?<![.!?]\s)(?<!^)\b([A-Z][a-zA-Z\-]+(?:\s+[A-Z][a-zA-Z\-]+)*)", text):
        tok = m.group(1)
        parts = [p for p in tok.split() if p.lower() not in COMMON_CAPS and p.lower() not in MONTHS and p.lower() not in WEEKDAYS]
        if parts:
            names.append(" ".join(parts))
    return {"numbers": sorted(set(nums)), "dates": sorted(set(dates)), "names": sorted(set(names))}


def corpus_text(session_dir: Path) -> str:
    parts = [(session_dir / "pack.md").read_text(encoding="utf-8")]
    for fn in ("bank.jsonl", "facts.jsonl", "glossary.jsonl"):
        f = session_dir / fn
        if not f.exists():
            continue
        for ln in f.read_text(encoding="utf-8").splitlines():
            if not ln.strip():
                continue
            try:
                rec = json.loads(ln)
            except json.JSONDecodeError:
                continue
            for s in rec.get("sources", []):
                if s.get("quote"):
                    parts.append(s["quote"])
    return "\n".join(parts)


def _corpus_numbers(corpus: str) -> set[str]:
    nums = {norm_num(m) for m in re.findall(r"\d[\d,]*(?:\.\d+)?%?", corpus)}
    for w in re.findall(r"[A-Za-z]+", corpus.lower()):
        if w in NUMBER_WORDS:
            nums.add(NUMBER_WORDS[w])
    return nums


def unresolved(line: str, corpus: str, question: str = "") -> dict[str, list[str]]:
    """Claims in `line` that appear neither in the corpus nor in the question that was asked."""
    c = claims(line)
    low = corpus.lower()
    qlow = question.lower()
    cn = _corpus_numbers(corpus)
    qn = {norm_num(m) for m in re.findall(r"\d[\d,]*(?:\.\d+)?%?", question)}
    out = {
        "numbers": [n for n in c["numbers"] if n not in cn and n not in qn],
        "dates": [d for d in c["dates"] if d not in low and d not in qlow],
        "names": [n for n in c["names"] if n.lower() not in low and n.lower() not in qlow],
    }
    return {k: v for k, v in out.items() if v}


def assemble_lines(deltas: list[dict]) -> dict[str, list[str]]:
    """Rebuilds complete lines per call id from `delta` events (text chunks, `line_done` closes a line)."""
    cur: dict[str, str] = {}
    lines: dict[str, list[str]] = {}
    for d in deltas:
        i = d["id"]
        cur[i] = cur.get(i, "") + d.get("text", "")
        if d.get("line_done"):
            lines.setdefault(i, []).append(cur.pop(i).strip())
    return lines


def suggestion_lines(lines: list[str]) -> list[str]:
    return [ln for ln in lines if ln.startswith("SAY:") or ln.startswith("- ")]
