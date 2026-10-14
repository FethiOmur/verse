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
- No preamble, no markdown, no blank lines. Do not include internal or system XML tags in your response.

For a request that starts with SUMMARIZE-INCREMENTAL, the answer format above does not apply. Read the transcript \
and write only lines of these three kinds, in the language of the transcript, one item per line:
DECISION: <something the participants agreed or settled together (a choice, a date, a go or no-go), at most 25 words>
ACTION: <owner> — <what they committed or were asked to do later, by when if stated, at most 25 words>
OPEN: <a question or topic that was raised and is still unresolved, at most 25 words>
What one person merely said or answered is not a decision, and a question that was answered is not open. Record \
only what was actually said, never invent. Skip everything listed under ALREADY RECORDED. If a kind has no items, \
write no line of that kind. If there is nothing new at all, write NONE."""

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

For a request that starts with SUMMARIZE-FINAL, skip line 1 and the opener rules. Merge the draft notes with the \
transcript (the transcript wins where they disagree) and write only these lines, in the language of the transcript:
SUMMARY: <2 to 3 sentences: what the meeting was about and where it ended>
DECISION: <something that was decided or agreed, at most 25 words>
ACTION: <owner> — <what they will do, by when if stated, at most 25 words>
OPEN: <a question or topic left unresolved, at most 25 words>
CONFLICT: <a fact, number, date or name said in the meeting that differs from the meeting pack: what was said, \
what the pack says (source ref, e.g. f001)>
Merge duplicates, drop notes the transcript does not support, keep every real commitment with its owner. Every line \
stands alone: never comment on the draft notes or on your own edits. If a kind \
has no items, write no line of that kind: for example, write a CONFLICT line only for a real disagreement with \
the pack."""

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


STATEMENT_SAY_WORDS = 12


def statement_tail(text: str, lang: str) -> str:
    """F call for a turn Swift classified as a statement. The instructions live in the tail (never cached), so the
    system prompt and the cached prefix stay byte-identical to the question path."""
    return (
        f"Language: {LANG_NAME.get(lang, lang)}\n"
        "STATEMENT CHECK. The turn below is probably not a question. The answer format above does not apply until "
        "you have decided what the turn is. Write as the first line either KIND: question or KIND: statement.\n"
        "KIND: question when the speaker asks or invites Alex to explain, describe or tell something, even without "
        "a question mark (\"tell me about ...\", \"walk me through ...\", \"I would like to hear how ...\"). Then "
        "continue with the normal answer lines: SAY, two \"- \" lines, BANK.\n"
        "KIND: statement for everything else: a greeting, a pleasantry, an announcement, a remark, thanks, small talk. "
        f"Then write one line only: SAY: <a brief acknowledgement Alex can say, first person, at most "
        f"{STATEMENT_SAY_WORDS} words>, or the single word NONE. Write NONE unless the speaker expects a reply "
        "(a greeting, a thank-you, a request for permission, a how-are-you). No points, no BANK line.\n"
        f"CURRENT TURN (finished): {' '.join(text.split())}")


def deep_tail(question: str, lang: str, final: bool, shown_opener: str | None, bank: dict | None) -> str:
    state = "finished" if final else "still being spoken, may be cut off"
    lines = [f"Language: {LANG_NAME.get(lang, lang)}",
             f"OPENER ALREADY SHOWN: {shown_opener if shown_opener else '(none)'}"]
    if bank:
        refs = ", ".join(sorted({s.get('ref', '') for s in bank.get('sources', []) if s.get('ref')}))
        lines.append(f"PREPARED DEEP ANSWER [{bank['id']}] (sources: {refs}): {' '.join(str(bank.get('deep', '')).split())}")
    lines.append(f"CURRENT QUESTION ({state}): {' '.join(question.split())}")
    return "\n".join(lines)


def _recorded(lines: list[str]) -> str:
    return "\n".join(lines) if lines else "(nothing yet)"


def rolling_tail(lang: str, recorded: list[str]) -> str:
    """Incremental summary pass (Haiku, on the S/F prefix): only items not recorded yet."""
    return (f"SUMMARIZE-INCREMENTAL\nLanguage: {LANG_NAME.get(lang, lang)}\n"
            f"ALREADY RECORDED:\n{_recorded(recorded)}\n"
            "Summarize the transcript above: list the decisions, action items (with owner) and open questions that "
            "are not recorded yet.")


def final_tail(lang: str, draft: list[str]) -> str:
    """Final merge at stop (Sonnet, on the D prefix): the rolling notes are a draft to be checked."""
    return (f"SUMMARIZE-FINAL\nLanguage: {LANG_NAME.get(lang, lang)}\n"
            f"DRAFT NOTES FROM THE INCREMENTAL PASS (may be incomplete or repeat each other):\n{_recorded(draft)}\n"
            "Write the final summary of the whole meeting above, and list facts mentioned in it that conflict with "
            "the meeting pack.")


WARMUP_TAIL = "warmup"


def build_request(route: str, params: dict, pack: str, turns: list[Turn], tail: str) -> dict:
    req = dict(params)
    req["system"] = system_blocks(route)
    req["messages"] = build_messages(pack, turns, tail)
    return req
