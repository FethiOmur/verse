"""Per-session live-call directives: `call.json` in the session folder (optional).

A session without the file runs exactly as before: no request byte changes. With it, the directives below are appended to the
frozen system prompt of the session (one text block, so the cache layout and the breakpoints stay as they are) and a matched
bank entry is named in the uncached tail. Unknown keys and bad values are ignored; an unreadable file is the same as no file.

    {
      "card_lines": 2,                 # whole card at most N short lines: the SAY line and N-1 "- " lines (N from 1 to 3)
      "prefer_bank": true,             # a prepared bank entry that fits the question is the card, in its own words
      "numbers": "sources",            # "sources": numbers only from the session sources
                                       # "sources_n": same, and state n (the sample size) next to a measured figure
      "language": "en",                # cards in this language whatever the Language line says (en | it | tr)
      "tone": "calm, confident, never eager",   # free text (one line, at most 200 characters): the tone of every card
      "walkthrough_end": "14:07",      # Swift only: wall-clock time (24 h, local) for the time cue on the notch ...
      "minutes_from_start": 7          # ... or minutes after Start (the app reads both; the brain ignores them)
    }
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from ..owner import OWNER
from .protocol import LANGS

CALL_FILE = "call.json"
MAX_CARD_LINES = 3
MAX_TONE_CHARS = 200
NUMBERS_MODES = ("sources", "sources_n")
_LANG_NAME = {"en": "English", "it": "Italian", "tr": "Turkish"}


@dataclass(frozen=True)
class CallDirectives:
    card_lines: int | None = None
    prefer_bank: bool = False
    numbers: str | None = None
    language: str | None = None
    tone: str | None = None

    @property
    def active(self) -> bool:
        """Any directive that changes a request (the time cue is the app's)."""
        return bool(self.card_lines or self.prefer_bank or self.numbers or self.language or self.tone)

    def system_text(self, route: str) -> str | None:
        """The block appended to the system prompt of `route` (S, F, C: the fast text; D: the deep text); None without directives."""
        if not self.active:
            return None
        deep = route == "D"
        lines = [OWNER.fill("CALL DIRECTIVES (set by {owner} for this call; they win over the line counts and word limits above; "
                            "they do not apply to SUMMARIZE requests):")]
        n = self.card_lines
        if n:
            if deep:
                lines.append(f"- Card size: the card on his screen is at most {n} short line{'s' if n != 1 else ''} and the opener is "
                             "already on it. When the opener is right, write OPENER_OK and nothing else: no points. After "
                             "OPENER_WRONG write one point of at most 8 words (keywords) that gives the right direction.")
            elif n == 1:
                lines.append("- Card size: the whole card is ONE short line. Write the SAY line only (keywords, at most 10 words, at "
                             "most one number), no \"- \" lines, then the BANK line.")
            else:
                lines.append(f"- Card size: the whole card is at most {n} short lines: the SAY line and {n - 1} \"- \" "
                             f"line{'s' if n != 2 else ''} (keywords, at most 8 words each, at most one number in the whole card), then "
                             + OWNER.fill("the BANK line. Write fewer words, not full sentences: {owner} says the rest himself."))
        if self.prefer_bank:
            if deep:
                lines.append("- Prepared answers: when a PREPARED DEEP ANSWER is shown, take your points from it, in its words, cut to size.")
            else:
                lines.append("- Prepared answers: when an answer-bank entry fits the question (a PREPARED ANSWER block shows the one "
                             "that matched), the card is that entry: keep its wording, cut words to fit the card size, add no points of "
                             "your own, and write its id on the BANK line. Prefer the prepared wording to your own.")
        if self.numbers:
            lines.append("- Numbers: a number, date or name may appear only when the sources named in the rules above give it, in the "
                         "same form: never round, convert, add up or estimate. When no source has the figure, leave the number out.")
            if self.numbers == "sources_n":
                lines.append("- Sample size: when a measured figure is written and the source also gives how many cases it was measured "
                             "on (n), say n next to the figure. When no source gives n, leave it out; never invent one.")
        if self.language:
            lines.append(f"- Language: write every line in {_LANG_NAME[self.language]}, even when the Language line, the question "
                         "or a name is in another language.")
        if self.tone:
            lines.append(f"- Tone: {self.tone}. It changes the wording only, never the facts, the numbers or the line format.")
        return "\n".join(lines)


def parse_call(raw: object) -> CallDirectives | None:
    """The directives of a decoded `call.json`; None when it is not an object."""
    if not isinstance(raw, dict):
        return None
    n = raw.get("card_lines")
    card = n if isinstance(n, int) and not isinstance(n, bool) and 1 <= n <= MAX_CARD_LINES else None
    numbers = raw.get("numbers") if raw.get("numbers") in NUMBERS_MODES else None
    lang = raw.get("language") if isinstance(raw.get("language"), str) and raw.get("language") in LANGS else None
    tone = raw.get("tone")
    tone = " ".join(tone.split())[:MAX_TONE_CHARS].rstrip(" .") if isinstance(tone, str) else None
    return CallDirectives(card_lines=card, prefer_bank=raw.get("prefer_bank") is True, numbers=numbers, language=lang,
                          tone=tone or None)


def load_call(folder: Path) -> CallDirectives | None:
    """`<folder>/call.json`, or None when there is none, it is unreadable or it holds no usable directive."""
    try:
        d = parse_call(json.loads((folder / CALL_FILE).read_text(encoding="utf-8")))
    except (OSError, UnicodeDecodeError, ValueError):
        return None
    return d if d is not None and d.active else None


def bank_hint(rec: dict | None) -> str:
    """The PREPARED ANSWER block for the tail of a fast call: the matched bank entry as the card it would be."""
    if not rec:
        return ""
    lines = [f"PREPARED ANSWER [{rec.get('id', '')}] (matched this question; use it as the card):"]
    if rec.get("opener"):
        lines.append(f"SAY: {' '.join(str(rec['opener']).split())}")
    lines += [f"- {' '.join(str(p).split())}" for p in rec.get("points", [])]
    return "\n".join(lines) if len(lines) > 1 else ""
