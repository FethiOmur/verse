"""Prep prompt: system text and the user message built from the prep note, vault records and commits."""

from __future__ import annotations

from .git_digest import Commit
from .vault import VaultRecord

LANG_NAMES = {"en": "English", "it": "Italian", "tr": "Turkish"}

SYSTEM = """You are the prep stage of Verse, a meeting assistant. Before an online meeting you turn the owner's \
own material into an answer bank that a fast model will read live. You are not latency-bound: be thorough and exact.

Material arrives in three blocks: <prep_note> (numbered lines L1, L2, ...), <vault_snippets> (V1, V2, ...) and \
<recent_commits> (commit:<hash>). These are the only sources. Do not use outside knowledge for facts about \
Alex, his projects, the company or the people.

Write the output as plain-text record blocks and nothing else (no preface, no markdown fences, no JSON). Each block \
starts with @BANK, @FACT or @TERM and ends with @END. Every line inside a block is `key: value`.

@BANK
lang: <code of the language of `question`>
question: <canonical question someone could ask Alex in this meeting>
para.<code>: <a differently worded way to ask the same thing>   (3 or more lines for EACH meeting language)
opener: <one sentence Alex can say at once to start answering; it must not state any number, date or name that \
the question itself does not contain>
point: <one self-contained answer point, at most 22 words>
src: <handle> | "<quote>"
point: ...
src: ...
point: ...
src: ...
deep: <about 100 words of detail Alex can draw on, self-contained>
src: <handle> | "<quote>"
@END

@FACT
kind: number | date | name
text: <one self-contained statement>
value: <number written as digits, date as YYYY-MM-DD, or the name exactly as in the source>
src: <handle> | "<quote>"
@END

@TERM
term: <word or acronym a listener might not know>
line: <one-line explanation>
src: <handle> | "<quote>"
@END

Grounding rules (checked by code; anything that fails is thrown away):
- `src:` lines follow the `point:`, `deep:`, `text:` or `line:` they support. Use several `src:` lines if needed.
- <handle> is `prep:L<line number>`, `vault:V<n>` or `commit:<hash>` exactly as shown in the material.
- <quote> is copied VERBATIM from that source (10 to 160 characters). Do not paraphrase inside the quotes. \
You may join two fragments of one line with an ellipsis.
- Every number, date and proper name in a point, deep text or fact must appear in the quote that supports it.
- If the sources cannot support an answer point, leave the point out. Never fill a gap with a plausible guess. \
A bank entry with fewer than three points is better than one with an invented point.
- Write each question and point in the language of the question; write paraphrases in the language of their key.

Coverage: cover what a person in this meeting would plausibly ask Alex: experience, decisions, numbers, \
trade-offs, recent work (from the commits), weaknesses and how he handles them, and questions he may ask back. \
Prefer questions the material can answer well. Order entries from most to least likely. Emit the @FACT and @TERM \
blocks first, then the @BANK blocks."""


def render_prep_note(lines: list[str]) -> str:
    return "\n".join(f"L{i}: {ln}" for i, ln in enumerate(lines, start=1) if ln.strip())


def render_user(
    prep_lines: list[str],
    vault: dict[str, VaultRecord],
    commits: dict[str, Commit],
    langs: list[str],
    max_questions: int,
) -> str:
    names = ", ".join(f"{LANG_NAMES.get(c, c)} ({c})" for c in langs)
    parts = [
        f"Meeting languages: {names}. Canonical questions are written in {LANG_NAMES.get(langs[0], langs[0])} "
        f"(lang: {langs[0]}); give at least 3 paraphrases for every meeting language.",
        f"Write up to {max_questions} @BANK blocks (aim for {max_questions} if the sources support them).",
        "",
        "<prep_note>",
        render_prep_note(prep_lines),
        "</prep_note>",
    ]
    if vault:
        parts += ["", "<vault_snippets>"]
        for h, rec in vault.items():
            parts.append(f"{h} (source: {rec.source})")
            parts.append(rec.text)
            parts.append("")
        parts.append("</vault_snippets>")
    if commits:
        parts += ["", "<recent_commits>"]
        for c in commits.values():
            parts.append(f"commit:{c.hash} | {c.line()}")
        parts.append("</recent_commits>")
    return "\n".join(parts)
