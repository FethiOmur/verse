"""Prompt layout per route (spec 5.8): frozen system -> meeting pack (breakpoint 1) -> finalized turns as
append-only blocks (breakpoint 2 on a turn, moved forward only every `BP2_EVERY` turns) -> the current text.

Everything before the tail is a pure function of (system, pack, finalized turns), so successive requests share
their prefix byte for byte. The tail (question, shown opener, bank candidate, language) is never cached.
"""

from __future__ import annotations

from dataclasses import dataclass

BP2_EVERY = 4
EPHEMERAL = {"type": "ephemeral"}

SYSTEM_FAST = """You are Verse, a live meeting assistant for Alex. Alex is on a call (an interview or a meeting). \
Someone asked him a question; you give him words he can say right now.

You get a MEETING PACK (facts, glossary, a prepared answer bank with ids, snippets), the transcript so far, and \
the current question. The question comes from live speech recognition and may be unfinished.

Write exactly these lines in plain text and nothing else:
SAY: <one short sentence Alex can say at once, first person, spoken style, at most 20 words>
- <a concrete supporting point, at most 18 words>
- <a second point, at most 18 words>
BANK: <the id of the answer-bank entry that answers this question, or none>

Rules:
- Use numbers, dates and names only when they appear in the meeting pack. Never invent them.
- Write exactly two "- " lines, never more, then the BANK line. The BANK line is required.
- When an answer-bank entry fits the question, reuse its opener and its two most relevant points, shortened if \
needed.
- Answer in the language named with the question.
- No preamble, no markdown, no blank lines. Do not include internal or system XML tags in your response."""

SYSTEM_DEEP = """You are the deep tier of Verse, a live meeting assistant for Alex. Alex is on a call. A short \
opener has already been shown to him for the current question; you add detail points he can read and say.

You get a MEETING PACK (facts, glossary, a prepared answer bank with ids, snippets), the transcript so far, the \
opener already shown, sometimes a prepared deep answer, and the current question (from live speech recognition, \
possibly unfinished).

For a question, write in plain text:
Line 1: OPENER_OK if the shown opener fits this question, or OPENER_WRONG if it is wrong for it. Write OPENER_OK \
when no opener is shown.
Then 2 to 4 lines, each: - <a self-contained detail point, at most 25 words> (<source ref, e.g. prep:L14, f010, \
b003>)

Rules:
- Do not repeat the opener. Each point must make sense on its own; do not continue the opener's sentence.
- After OPENER_WRONG, the first point gives the right direction for the actual question.
- Use numbers, dates and names only when they appear in the meeting pack, and cite where they come from. If the \
pack does not support a claim, leave it out.
- Answer in the language named with the question.
- No preamble, no markdown, no blank lines. Do not include internal or system XML tags in your response.

For a request that starts with SUMMARIZE, skip line 1 and write only "- " lines: the action items and \
commitments from the transcript (who does what, by when if stated), at most 8."""

SYSTEMS = {"S": SYSTEM_FAST, "F": SYSTEM_FAST, "D": SYSTEM_DEEP}

SPEAKER_LABEL = {"remote": "Other side", "me": "Alex"}
PACK_HEADER = "MEETING PACK\n\n"
TRANSCRIPT_HEADER = "\n## TRANSCRIPT SO FAR (finalized turns follow, one block each)\n"


@dataclass(frozen=True)
class Turn:
    turn_id: str
    speaker: str
    text: str


def turn_block_text(t: Turn) -> str:
    return f"[{SPEAKER_LABEL.get(t.speaker, t.speaker)}] {' '.join(t.text.split())}"


def bp2_index(n_turns: int, every: int = BP2_EVERY) -> int | None:
    """Index of the turn block carrying breakpoint 2: the last turn of the newest complete group of `every`."""
    k = (n_turns // every) * every
    return k - 1 if k > 0 else None


def build_messages(pack: str, turns: list[Turn], tail: str) -> list[dict]:
    content: list[dict] = [{"type": "text", "text": PACK_HEADER + pack + TRANSCRIPT_HEADER, "cache_control": dict(EPHEMERAL)}]
    bp2 = bp2_index(len(turns))
    for i, t in enumerate(turns):
        blk = {"type": "text", "text": turn_block_text(t)}
        if i == bp2:
            blk["cache_control"] = dict(EPHEMERAL)
        content.append(blk)
    content.append({"type": "text", "text": tail})
    return [{"role": "user", "content": content}]


def system_blocks(route: str) -> list[dict]:
    return [{"type": "text", "text": SYSTEMS[route]}]


LANG_NAME = {"en": "English", "it": "Italian", "tr": "Turkish"}


def fast_tail(question: str, lang: str, final: bool) -> str:
    state = "finished" if final else "still being spoken, may be cut off"
    return f"Language: {LANG_NAME.get(lang, lang)}\nCURRENT QUESTION ({state}): {' '.join(question.split())}"


def deep_tail(question: str, lang: str, final: bool, shown_opener: str | None, bank: dict | None) -> str:
    state = "finished" if final else "still being spoken, may be cut off"
    lines = [f"Language: {LANG_NAME.get(lang, lang)}",
             f"OPENER ALREADY SHOWN: {shown_opener if shown_opener else '(none)'}"]
    if bank:
        refs = ", ".join(sorted({s.get('ref', '') for s in bank.get('sources', []) if s.get('ref')}))
        lines.append(f"PREPARED DEEP ANSWER [{bank['id']}] (sources: {refs}): {' '.join(str(bank.get('deep', '')).split())}")
    lines.append(f"CURRENT QUESTION ({state}): {' '.join(question.split())}")
    return "\n".join(lines)


SUMMARIZE_TAIL = "SUMMARIZE the transcript above into action items."
WARMUP_TAIL = "warmup"


def build_request(route: str, params: dict, pack: str, turns: list[Turn], tail: str) -> dict:
    req = dict(params)
    req["system"] = system_blocks(route)
    req["messages"] = build_messages(pack, turns, tail)
    return req
