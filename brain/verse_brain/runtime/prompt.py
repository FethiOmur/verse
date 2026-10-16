"""Prompt layout per route (spec 5.8): frozen system -> meeting pack (breakpoint 1) -> finalized turns as
append-only blocks (breakpoint 2 on a turn, moved forward only every `BP2_EVERY` turns) -> the current text.

Everything before the tail is a pure function of (system, pack, finalized turns), so successive requests share
their prefix byte for byte. The tail (question, shown opener, bank candidate, language) is never cached.

Anytime calls (docs/specs/2026-10-16-verse-anytime-calls-design.md 2.2): with the me layer on, the system array gets a
second block, ABOUT OWNER (`me.md`, plus the STYLE GUIDE when the pack has none), carrying breakpoint 0. The system
text of that session also names ABOUT OWNER as grounding and says the meeting pack wins on conflict. An unprepared call
has an empty pack: its pack block is the fixed line `(none: unprepared call)`. Retrieved chunks of his files go into
the uncached tail as FROM USER'S FILES. With the me layer off and a real pack, every byte is what it was before.
"""

from __future__ import annotations

from dataclasses import dataclass

from ..prep.voice import VOICE_HEADING, render_voice_section

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
- Style: simple B1-B2 English, short easy words, spoken, not written like a report. When the meeting pack has a STYLE GUIDE section, follow it for tone and phrasing; it changes the wording only: it is not evidence, never cite it, and it never changes the facts or the line format.
- Never comment on the question itself (never say it is unclear, misheard or vague). The question comes from speech recognition: if a word looks misheard (for example "raid" for "rate"), answer the most likely intended question directly.
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
- Style: simple B1-B2 English, short easy words, spoken, not written like a report. When the meeting pack has a STYLE GUIDE section, follow it for tone and phrasing; it changes the wording only: it is not evidence, never cite it, and it never changes the facts or the line format.
- Never comment on the question itself (never say it is unclear, misheard or vague). The question comes from speech recognition: if a word looks misheard (for example "raid" for "rate"), answer the most likely intended question directly.
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

SYSTEMS = {"S": SYSTEM_FAST, "F": SYSTEM_FAST, "C": SYSTEM_FAST, "D": SYSTEM_DEEP}   # C shares F's system prompt: one cache entry

NO_PACK_LINE = "(none: unprepared call)"

# The me layer changes two rules of the base prompts (where numbers may come from, how D cites) and adds the conflict rule.
# Done by exact replacement, so an edit of the base text that breaks a rule fails at import, not silently in a call.
_ME_RULES = """

ABOUT OWNER is the second block of this system prompt: his permanent profile (experience, projects, skills, numbers, \
stories, what he is looking for), one line per item with an id like [m412]. It grounds your answers like the meeting \
pack does. When ABOUT OWNER and the MEETING PACK disagree, the MEETING PACK wins: it was built and checked for this \
meeting. When the MEETING PACK is the line "(none: unprepared call)", nothing was prepared for this call: answer from \
ABOUT OWNER, from FROM USER'S FILES (excerpts of his own notes, shown before the current question when there are \
any) and from the transcript, and write BANK: none. Never invent a fact about Alex that none of them states."""

_UNPREPARED_RULES = """

When the MEETING PACK is the line "(none: unprepared call)", nothing was prepared for this call: answer from the \
transcript and write BANK: none. Never invent a fact about Alex."""


def _swap(text: str, old: str, new: str) -> str:
    assert text.count(old) == 1, old
    return text.replace(old, new)


SYSTEM_FAST_ME = _swap(
    SYSTEM_FAST,
    "- Use numbers, dates and names only when they appear in the meeting pack. Never invent them.",
    "- Use numbers, dates and names only when they appear in the meeting pack, in ABOUT OWNER or in FROM THE OWNER'S "
    "FILES. Never invent them.") + _ME_RULES
SYSTEM_DEEP_ME = _swap(
    SYSTEM_DEEP,
    "- Use numbers, dates and names only when they appear in the meeting pack, and cite where they come from. If the "
    "pack does not support a claim, leave it out.",
    "- Use numbers, dates and names only when they appear in the meeting pack, in ABOUT OWNER or in FROM USER'S FILES, "
    "and cite where they come from (a pack id like f010 or b003, me:m412 for ABOUT OWNER, lib:<id> for FROM THE OWNER'S "
    "FILES). If none of them supports a claim, leave it out.") + _ME_RULES
SYSTEMS_ME = {"S": SYSTEM_FAST_ME, "F": SYSTEM_FAST_ME, "C": SYSTEM_FAST_ME, "D": SYSTEM_DEEP_ME}
SYSTEMS_UNPREPARED = {"S": SYSTEM_FAST + _UNPREPARED_RULES, "F": SYSTEM_FAST + _UNPREPARED_RULES,
                      "C": SYSTEM_FAST + _UNPREPARED_RULES, "D": SYSTEM_DEEP + _UNPREPARED_RULES}

ABOUT_HEADER = ("ABOUT OWNER (his permanent profile; cite a line as me:<id>, for example me:m412. The MEETING PACK wins "
                "when it disagrees with this)")


SPEAKER_LABEL = {"remote": "Other side", "me": "Alex", "room": "Room"}
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
    if not pack.strip():     # an unprepared call: a fixed line, so the block is the same bytes in every session
        pack = NO_PACK_LINE
    content: list[dict] = [{"type": "text", "text": PACK_HEADER + pack + TRANSCRIPT_HEADER, "cache_control": dict(EPHEMERAL)}]
    bp2 = bp2_index(len(turns))
    for i, t in enumerate(turns):
        blk = {"type": "text", "text": turn_block_text(t)}
        if i == bp2:
            blk["cache_control"] = dict(EPHEMERAL)
        content.append(blk)
    content.append({"type": "text", "text": tail})
    return [{"role": "user", "content": content}]


def render_about_block(core: str, voice: str | None = None) -> str:
    """The ABOUT OWNER system block: `me.md` as is, then the STYLE GUIDE when the caller passes the voice profile (only
    when the pack has none). A pure function of its inputs: the same files give the same bytes in every session."""
    text = ABOUT_HEADER + "\n\n" + core.strip() + "\n"
    if voice:
        text += "\n" + render_voice_section(voice, "meeting")
    return text


def pack_has_style_guide(pack: str) -> bool:
    return VOICE_HEADING in pack


def system_blocks(route: str, about: str | None = None, unprepared: bool = False) -> list[dict]:
    """The frozen system prompt. With `about` (the me layer on) the text names ABOUT OWNER and a second block carries it,
    with breakpoint 0. Without it and with a real pack, the result is what it always was."""
    if about is not None:
        return [{"type": "text", "text": SYSTEMS_ME[route]},
                {"type": "text", "text": about, "cache_control": dict(EPHEMERAL)}]
    if unprepared:
        return [{"type": "text", "text": SYSTEMS_UNPREPARED[route]}]
    return [{"type": "text", "text": SYSTEMS[route]}]


LANG_NAME = {"en": "English", "it": "Italian", "tr": "Turkish"}


FILES_HEADER = "FROM USER'S FILES (excerpts of his own notes; cite a chunk as lib:<id>):"


def files_block(chunks: list[tuple[str, str, str]]) -> str:
    """Retrieved chunks of his files for the uncached tail: (chunk id, source, text) each. Empty for no chunks."""
    if not chunks:
        return ""
    return "\n".join([FILES_HEADER, *(f"[lib:{cid}] ({src}) {' '.join(text.split())}" for cid, src, text in chunks)])


def _files(files: str) -> str:
    return files + "\n" if files else ""


def fast_tail(question: str, lang: str, final: bool, files: str = "") -> str:
    state = "finished" if final else "still being spoken, may be cut off"
    return (f"Language: {LANG_NAME.get(lang, lang)}\n{_files(files)}"
            f"CURRENT QUESTION ({state}): {' '.join(question.split())}")


def card_now_tail(text: str, lang: str, final: bool, files: str = "") -> str:
    """F call for the card-now key: he asks for a card for what the other side said last, question or not. The gates (cue,
    kind, addressee) are skipped, so the instruction says so; the answer format of the system prompt stays."""
    state = "finished" if final else "still being spoken, may be cut off"
    return (f"Language: {LANG_NAME.get(lang, lang)}\n{_files(files)}"
            "CARD NOW. Alex pressed the card key: he wants something to say to the words below at once, even when they "
            "are not phrased as a question. If they are a remark or a request, give him what he can say next. The answer "
            "format above applies: SAY, two \"- \" lines, BANK.\n"
            f"CURRENT QUESTION ({state}): {' '.join(text.split())}")


STATEMENT_SAY_WORDS = 12


def statement_tail(text: str, lang: str, files: str = "") -> str:
    """F call for a turn Swift classified as a statement. The instructions live in the tail (never cached), so the
    system prompt and the cached prefix stay byte-identical to the question path."""
    return (
        f"Language: {LANG_NAME.get(lang, lang)}\n{_files(files)}"
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


def follow_tail(question: str, lang: str, his_words: str, card: list[str], said: list[str], now_card: list[str] | None,
                reason: str, me_on: bool = False) -> str:
    """C call (follow my answer). Alex is answering in his own direction; write the card he needs next. The instructions
    live in the tail (never cached), so the system prompt and the cached prefix stay byte-identical to F's.

    `card`: the original card as lines ("SAY: ...", "- ..."); `said`: the card points he has already covered (they are not
    to be repeated); `now_card`: the follow card on screen at a refresh (None at the first switch)."""
    lines = [
        f"Language: {LANG_NAME.get(lang, lang)}",
        "FOLLOW MY ANSWER. Alex is answering the question below in his own direction, not by reading the card. Do not "
        "answer the question again. Continue HIS line. The answer format above changes: write exactly these lines and "
        "nothing else (no BANK line):",
        "SAY: <ONE sentence that picks up exactly where his last words stopped and carries his line one step further, first "
        "person, spoken style, at most 20 words>",
        "- <a point he has not said yet and fits his topic, at most 18 words>   (2 or 3 such lines; fewer, or none, when the "
        "meeting pack has nothing grounded for his topic)",
        "Rules: never contradict what he said. Stay on his topic. Every number, date and name in a point must come from "
        "the meeting pack (bank, facts, evidence); a point the pack cannot support is left out. When the pack has "
        "nothing for his topic, write the SAY line alone, with no invented fact. Never offer something he has already "
        "said, not even in other words: read WHAT OWNER HAS SAID SO FAR first and write only what is new. Start the SAY "
        "with the content, not with a reaction word (no \"Right\", \"Yes\", \"Exactly\", \"Well\"). Follow the "
        "STYLE GUIDE for tone. No comment on the card, on the question or on him.",
        f"CURRENT QUESTION (finished): {' '.join(question.split())}",
        f"WHAT OWNER HAS SAID SO FAR: {' '.join(his_words.split()) or '(nothing yet)'}",
        "THE CARD HE DID NOT FOLLOW:",
        *(card or ["(none)"]),
    ]
    if said:
        lines += ["ALREADY SAID (struck through for him):", *[f"- {x}" for x in said]]
    if now_card:
        lines += ["THE FOLLOW CARD ON HIS SCREEN NOW (it is replaced by yours: new SAY sentence, new points, nothing from it):",
                  *now_card]
    lines.append("Reason for this card: " + ("he went off the card" if reason == "diverged" else "he has said more since the last follow card"))
    text = "\n".join(lines)
    if me_on:    # the me layer is grounding too (system prompt): the sentences about the pack name it as well
        text = text.replace("the meeting pack has nothing grounded for his topic", "the meeting pack and ABOUT OWNER have nothing grounded for his topic")
        text = text.replace("must come from the meeting pack (bank, facts, evidence)", "must come from the meeting pack (bank, facts, evidence), ABOUT OWNER or FROM USER'S FILES")
        text = text.replace("When the pack has nothing for his topic", "When none of them has anything for his topic")
        text = text.replace("a point the pack cannot support", "a point they cannot support")
    return text


def deep_tail(question: str, lang: str, final: bool, shown_opener: str | None, bank: dict | None, files: str = "") -> str:
    state = "finished" if final else "still being spoken, may be cut off"
    lines = [f"Language: {LANG_NAME.get(lang, lang)}",
             f"OPENER ALREADY SHOWN: {shown_opener if shown_opener else '(none)'}"]
    if bank:
        refs = ", ".join(sorted({s.get('ref', '') for s in bank.get('sources', []) if s.get('ref')}))
        lines.append(f"PREPARED DEEP ANSWER [{bank['id']}] (sources: {refs}): {' '.join(str(bank.get('deep', '')).split())}")
    if files:
        lines.append(files)
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


def build_request(route: str, params: dict, pack: str, turns: list[Turn], tail: str, about: str | None = None) -> dict:
    req = dict(params)
    req["system"] = system_blocks(route, about, unprepared=not pack.strip())
    req["messages"] = build_messages(pack, turns, tail)
    return req
