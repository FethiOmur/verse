"""Card size follows the question (spec 2026-10-29): the size of the answer the owner should actually give.

A deterministic class of the question text, computed in the brain and passed to the model in the uncached tail as a rule; the
point cap is also enforced when the lines are parsed (runtime/engine.py `Call._on_text`), so a model that ignores the rule still
cannot put more on the screen than the class allows.

    short   small talk, a greeting, a logistics check ("can you hear me?", "are you ready?"): the SAY line only, no points;
            the deep tier (D) is not fired.
    normal  an ordinary question: SAY (<= 20 words) and one or two points. This is the shape of every card before the classes.
    deep    "walk me through", "tell me about", "how did you design ...", a behavioural question, or a long multi-part
            question: a longer SAY (<= 32 words) and the full set of points (F two, D up to four).

The class is a lexicon, not a model: a question matches `deep` first (a turn that holds a greeting AND a real question is a real
question), then `short` (only for turns of <= SHORT_MAX_WORDS words), else `normal`. English, Italian and Turkish.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

SIZES = ("short", "normal", "deep")
SHORT_MAX_WORDS = 10          # a turn longer than this is never small talk
SHORT_ANY_WORDS = 3           # ... and one this short ("right?", "okay?") always is
DEEP_MIN_WORDS = 28           # a question this long asks for several things at once


@dataclass(frozen=True)
class SizeRule:
    say_words: int            # the SAY line, in words (stated to the model; not enforced in code)
    f_points: int             # points on an S/F card: the cap applied when the lines are parsed
    d_points: int             # points D may add (0: D is not fired)


RULES = {
    "short": SizeRule(say_words=10, f_points=0, d_points=0),
    "normal": SizeRule(say_words=20, f_points=2, d_points=2),
    "deep": SizeRule(say_words=32, f_points=2, d_points=4),
}
FOLLOW_POINTS = 3             # a follow card (C) writes "2 or 3" points: the cap


def _rx(*parts: str) -> re.Pattern[str]:
    return re.compile("|".join(parts), re.IGNORECASE)


_DEEP = _rx(
    # English
    r"\b(?:walk|talk|take)\s+(?:me|us)\s+through\b",
    # "tell me about", also with words between ("tell me briefly / a bit / a little more about"): the owner wants the real answer
    # even when the asker says "briefly" (29 Oct)
    r"\btell\s+(?:me|us)(?:\s+[\w']+){0,3}?\s+about\b", r"\babout\s+(?:yourself|your\s+(?:background|career|journey|experience|"
    r"story|path|profile|role|work))\b", r"\bintroduce\s+yourself\b", r"\bwho\s+are\s+you$", r"\byour\s+background\b", r"\bdescribe\b", r"\bexplain\b",
    r"\belaborate\b", r"\bgive\s+(?:me|us)\s+an?\s+(?:example|overview|summary)\b", r"\bfor\s+example\b",
    r"\ba\s+time\s+(?:when|that|you)\b", r"\b(?:situation|instance|moment)\s+(?:where|when|in which)\b",
    r"\bhow\s+did\s+you\s+(?:design|build|architect|approach|decide|handle|structure|implement|solve|manage|work|make|choose|"
    r"test|measure|ensure|set\s+up|organi[sz]e|split|plan|debug|deal)\b",
    r"\bhow\s+(?:would|do|can|could)\s+you\s+(?:approach|handle|decide|design|build|prioriti[sz]e|ensure|manage|structure|"
    r"scale|test|measure|solve|deal|split|organi[sz]e|work)\b",
    r"\bwhy\s+(?:did|would|do)\s+you\s+(?:choose|decide|pick|build|use|go|opt|prefer|select)\b",
    r"\bwhat\s+(?:was|is|were)\s+(?:the|your)\s+(?:approach|architecture|design|biggest|hardest|toughest|most\s+\w+|process|"
    r"reasoning|strategy|thinking)\b",
    r"\barchitecture\b", r"\btrade-?offs?\b", r"\bend[- ]to[- ]end\b", r"\bunder\s+the\s+hood\b", r"\bin\s+detail\b",
    r"\bstep[- ]by[- ]step\b", r"\b(?:biggest|hardest|toughest)\s+(?:challenge|problem|mistake|failure)\b",
    r"\b(?:conflict|disagreement|failure|mistake|weakness)\b",
    # Italian
    r"\b(?:raccontami|raccontaci|spiegami|spiegaci|descrivimi|descrivici|parlami|parlaci)\b",
    r"\bmi\s+(?:pu[oò]|puoi)\s+(?:raccontare|spiegare|descrivere)\b", r"\bcome\s+ha(?:i|\b)\s+(?:progettato|costruito|gestito|"
    r"affrontato|risolto|deciso|scelto|organizzato|strutturato|implementato)\b", r"\bperch[eé]\s+ha(?:i|\b)\s+(?:scelto|deciso|"
    r"usato|preferito)\b", r"\barchitettura\b", r"\bun\s+esempio\b", r"\buna\s+volta\s+in\s+cui\b", r"\bpasso\s+(?:dopo|per)\s+passo\b",
    # Turkish
    r"\banlat\w*", r"\ba[cç][iı]kla\w*", r"\bnas[iı]l\s+(?:tasarla|in[sş]a|geli[sş]tir|[cç][oö]z|karar|yap|y[oö]net|ele\s+al)\w*",
    r"\bneden\s+(?:se[cç]|karar|tercih|kullan)\w*", r"\bmimari\w*", r"\b[oö]rnek\s+ver\w*", r"\bad[iı]m\s+ad[iı]m\b", r"\bbir\s+(?:kez|zaman)\w*\s+(?:ne\s+zaman|sana|size)\b",
)

_SHORT = _rx(
    # English: hearing, seeing, connection, readiness, pleasantries
    r"\b(?:can|could|do|does|did|will|would)\s+(?:you|u)\s+(?:still\s+|now\s+)?(?:hear|see)\b", r"\bhear\s+(?:me|us|it)\b",
    r"\bsee\s+(?:me|us|my\s+screen|the\s+screen|my\s+slides?)\b", r"\b(?:is|are)\s+(?:my|the|our)\s+(?:audio|sound|video|"
    r"camera|mic|microphone|connection|internet|screen)\b", r"\b(?:audio|sound|video|connection)\s+(?:ok|okay|fine|good|clear)\b",
    r"\bcan\s+you\s+(?:share|unmute)\b", r"\b(?:i'?m|i\s+am)\s+(?:muted|frozen)\b", r"\byou(?:'re|\s+are)\s+(?:on\s+mute|muted|"
    r"frozen|breaking\s+up|cutting\s+out)\b", r"\bare\s+you\s+(?:there|ready|with\s+us)\b", r"\b(?:still|you)\s+there\b",
    r"\b(?:ready|good)\s+(?:to|for)\s+(?:start|begin|go)\b", r"\bshall\s+we\s+(?:start|begin)\b", r"\bcan\s+we\s+(?:start|begin)\b",
    r"\bis\s+(?:that|this|it)\s+(?:ok|okay|fine|alright|all\s+right)\b", r"\bdoes\s+(?:that|this|it)\s+(?:work|make\s+sense)\b",
    r"\b(?:one|a)\s+(?:moment|second|sec|minute)\b", r"\bgot\s+a\s+(?:minute|moment|second)\b",
    r"\bgood\s+time\b",
    # Italian
    r"\bmi\s+(?:senti|sente|sentite|vedi|vede|vedete)\b", r"\bsi\s+sente\b", r"\bci\s+sei\b", r"\b(?:tutto|va)\s+bene\b",
    # Turkish
    r"\b(?:beni|bizi)\s+duy\w*", r"\bduy(?:uyor|abiliyor)\w*", r"\bsesim\b", r"\bg[oö]r(?:uyor|ebiliyor)\w*\s+mu\w*",
    r"\bekran[iı]m[iı]?\s+g[oö]r\w*", r"\bhaz[iı]r\s+m[iı]s[iı]n\w*", r"\bba[sş]layal[iı]m\b",
)

# Greetings and pleasantries: small talk only when that is all the turn is (a greeting in front of a real question is no reason to
# shrink the card).
GREETING_MAX_WORDS = 5
_GREETING = _rx(
    r"\b(?:hello|hi|hey|welcome|thanks|thank\s+you|bye|goodbye|take\s+care|good\s+(?:morning|afternoon|evening))\b",
    r"\bhow\s+(?:are\s+you|are\s+things|is\s+it\s+going|was\s+your\s+(?:day|weekend))\b", r"\bhow's\s+it\s+going\b",
    r"\bnice\s+to\s+(?:meet|see)\s+you\b",
    r"\bcome\s+(?:stai|sta|state|va)\b", r"\b(?:ciao|buongiorno|buonasera|salve|grazie|pronto|prego)\b",
    r"\b(?:merhaba|g[uü]nayd[iı]n|iyi\s+g[uü]nler|te[sş]ekk[uü]r\w*)\b", r"\bnas[iı]ls[iı]n\w*",
)


def _words(text: str) -> list[str]:
    return re.findall(r"[\w']+", text.lower())


def card_size(text: str, lang: str = "en") -> str:  # noqa: ARG001 - the lexicon holds all three languages
    """The size class of the question `text`: "short", "normal" or "deep". Empty text is "normal" (the old card)."""
    words = _words(text)
    if not words:
        return "normal"
    flat = " ".join(words)
    if _DEEP.search(flat) or len(words) >= DEEP_MIN_WORDS:
        return "deep"
    if len(words) <= SHORT_ANY_WORDS or (len(words) <= SHORT_MAX_WORDS and _SHORT.search(flat)) \
            or (len(words) <= GREETING_MAX_WORDS and _GREETING.search(flat)):
        return "short"
    return "normal"


def points_cap(size: str, tier: str, card_lines: int | None = None) -> int:
    """How many "- " lines a card of `size` may show for `tier` (S/F/probe, D, C). `card_lines` is the session's call.json cap:
    the whole card is that many lines, the SAY included."""
    rule = RULES.get(size, RULES["normal"])
    if tier == "C":
        return FOLLOW_POINTS
    if tier == "D":
        return rule.d_points
    cap = rule.f_points
    if size == "deep":                # a real question gets the full card whatever the session's card_lines says (owner, 29 Oct)
        return cap
    return min(cap, max(card_lines - 1, 0)) if card_lines else cap


def size_line(size: str | None, card_lines: int | None = None) -> str:
    """The rule for the tail of an F/S call (and the escalated statement probe); "" when `size` is None (no class: bytes as before).
    With a `card_lines` directive in the system prompt the directive wins and only the tightening to `short` is stated."""
    if size is None or size not in RULES:
        return ""
    rule = RULES[size]
    if size == "short":
        return ("CARD SIZE: SHORT. This is small talk or a logistics check, not a question that needs an answer card. Write the SAY "
                f"line only: one short spoken line, at most {rule.say_words} words. No \"- \" lines (this overrides the two-points "
                "rule above). Then the BANK line.\n")
    if card_lines and size == "normal":
        return ""
    if size == "normal":
        return (f"CARD SIZE: NORMAL. The SAY line (at most {rule.say_words} words) and one or two \"- \" lines: write the second only "
                "when it adds something the first does not. This overrides the two-points rule above. Then the BANK line.\n")
    over = " This overrides the card-size directive above: a question like this gets the full card." if card_lines else ""
    return (f"CARD SIZE: DEEP. This question asks for a real answer. The SAY line may be up to {rule.say_words} words (two short "
            f"sentences are fine) and both \"- \" lines should be full, concrete points.{over} Then the BANK line.\n")


def deep_size_line(size: str | None) -> str:
    """The rule for the tail of a D call."""
    if size is None or size not in RULES:
        return ""
    n = RULES[size].d_points
    if size == "deep":
        return ("CARD SIZE: DEEP. This question asks for a real answer: write 2 to 4 detail points, never OPENER_OK alone (this "
                "overrides a card-size directive above).\n")
    return f"CARD SIZE: {size.upper()}. Write at most {n} detail point{'s' if n != 1 else ''} (this overrides the 2 to 4 above).\n"
