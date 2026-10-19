"""Sim prep prompt. `SYSTEM` and the sources block are the cached prefix; the parameters block changes per run."""

from __future__ import annotations

from .git_digest import Commit
from .prompt import LANG_NAMES
from .vault import VaultRecord

SYSTEM = """You are the prep stage of Verse's interview simulator. A candidate will practise a job interview out loud. \
From a job posting and the candidate's own material you plan the interview: what the role asks for, what the \
candidate can truthfully say, and which questions to ask. You are not latency-bound: be thorough and exact.

Material arrives in blocks: <posting> (verbatim text), <cv> and <note> (numbered lines L1, L2, ...), \
<vault_snippets> (V1, V2, ...) and <recent_commits> (commit:<hash>). The posting is the only source for what the \
role asks. <cv>, <note>, <vault_snippets> and <recent_commits> are the only sources for facts about the candidate. \
Do not use outside knowledge about the candidate or the company.

Reply with ONE JSON object and nothing else (no preface, no markdown fence):
{
  "company": "<company name as in the posting>",
  "role": "<job title as in the posting>",
  "competencies": [{"id": "c1", "name": "<short name>", "posting_quote": "<one sentence copied VERBATIM from the posting>"}],
  "evidence": [{"id": "e1", "kind": "project|metric|story|skill", "text": "<one self-contained claim, at most 30 words>",
                "sources": [{"handle": "cv:L<n> | note:L<n> | vault:V<n> | commit:<hash>", "quote": "<copied VERBATIM, 10 to 160 characters>"}]}],
  "questions": [{"id": "q1", "kind": "opener|behavioural|role|technical|motivation", "text": "<the question, as an interviewer says it>",
                 "competency_ids": ["c1"], "evidence_ids": ["e1"], "follow_ups": ["<short spoken follow-up question>"],
                 "target_s": [60, 120]}],
  "rubric": {"c1": {"1": "<what a weak answer looks like>", "3": "<adequate>", "5": "<excellent>"}}
}

Rules (checked by code; anything that fails is thrown away):
- competencies: 5 to 8, each tied to the posting sentence it comes from. `posting_quote` must be copied exactly from the \
posting (whitespace and markdown ignored). Choose sentences that state a requirement or a duty, not company boilerplate.
- evidence: the candidate's projects, numbers and stories that a strong answer could use. Every item needs at least one \
source whose quote is copied VERBATIM from that source. Every number, date and proper name in `text` must appear in a \
quote that supports it. Do not compute new numbers, do not round, do not combine facts into a claim no single source makes. \
If the material is thin, write fewer items. Never fill a gap with a plausible guess. If no candidate material was given, \
return "evidence": [] and plan the questions from the posting alone.
- questions: exactly the number asked for in the parameters. The first is the only `opener` (a warm "tell me about yourself" \
style start). Include exactly one `motivation` question (why this company and role). Every other question probes one or two \
competencies through `competency_ids`. `evidence_ids` lists the evidence a strong answer would use (empty when none fits). \
Write each question as natural speech in the interview language, one question at a time, no numbering, no multi-part questions.
- follow_ups: one or two per question, each a short spoken question that digs deeper ("What was the number before and after?", \
"What would you do differently?"). Leave them empty for the opener.
- target_s: expected answer length in seconds, [lo, hi]. Behavioural 60 to 120.
- rubric: for every competency, what a 1, a 3 and a 5 answer looks like for THIS role, in one sentence each. Ground the 5 in \
what the posting wants (for example measured latency and cost, reading traces), not in generic advice.
- Interview type and difficulty (in the parameters) shape the mix. screening: background, motivation, communication, basics. \
manager: ownership, decisions, collaboration, trade-offs. technical: how the candidate builds and debugs, depth on the \
competencies, a design or debugging scenario. mixed: all of these. friendly: open questions. standard: realistic. \
tough: questions that need numbers and trade-offs, with follow-ups that press on vague claims.
- The interview language is given in the parameters. Write questions, follow-ups, evidence text, competency names and rubric \
lines in it; quotes stay in the language of their source."""


def render_numbered(tag: str, lines: list[str]) -> str:
    body = "\n".join(f"L{i}: {ln}" for i, ln in enumerate(lines, start=1) if ln.strip())
    return f"<{tag}>\n{body}\n</{tag}>"


def render_sources(
    posting: str,
    cv_lines: list[str] | None,
    note_lines: list[str] | None,
    vault: dict[str, VaultRecord],
    commits: dict[str, Commit],
) -> str:
    parts = ["<posting>", posting.strip(), "</posting>"]
    if cv_lines:
        parts += ["", render_numbered("cv", cv_lines)]
    if note_lines:
        parts += ["", render_numbered("note", note_lines)]
    if vault:
        parts += ["", "<vault_snippets>"]
        for h, rec in vault.items():
            parts += [f"{h} (source: {rec.source})", rec.text, ""]
        parts.append("</vault_snippets>")
    if commits:
        parts += ["", "<recent_commits>"]
        parts += [f"commit:{c.hash} | {c.line()}" for c in commits.values()]
        parts.append("</recent_commits>")
    if not (cv_lines or note_lines or vault or commits):
        parts += ["", "(No candidate material was given.)"]
    return "\n".join(parts)


def render_params(
    interview_type: str, difficulty: str, length_min: int, question_count: int, lang: str,
    company: str | None, role: str | None,
) -> str:
    lines = [
        "Interview parameters:",
        f"interview_type: {interview_type}",
        f"difficulty: {difficulty}",
        f"length_min: {length_min}",
        f"question_count: {question_count}",
        f"language: {LANG_NAMES.get(lang, lang)} ({lang})",
    ]
    if company:
        lines.append(f"company_hint: {company}")
    if role:
        lines.append(f"role_hint: {role}")
    lines.append("")
    lines.append(f"Plan exactly {question_count} questions for a {length_min}-minute {interview_type} interview.")
    return "\n".join(lines)


# ---------------------------------------------------------------------------------------------- from a prepared session

SESSION_SYSTEM = """You are the prep stage of Verse's interview simulator. The candidate has prepared for a real meeting; \
now they will rehearse it as a mock interview, out loud. You receive the meeting's PREP PACK (facts, glossary and answer \
bank written for that meeting) and sometimes the candidate's standing profile. The interview questions are already \
decided by code: they are the likely questions from the pack's answer bank. You do not write them. You describe what \
each question probes, so the interviewer can follow up and the report can grade the answers. You are not \
latency-bound: be thorough and exact.

Material arrives in blocks: <pack> (the prep pack, numbered lines L1, L2, ...) and sometimes <me> (the candidate's \
profile, numbered lines L1, L2, ...). <pack> is the only source for what this meeting is about, the company and the people. \
<pack> and <me> are the only sources for facts about the candidate. Do not use outside knowledge about the candidate or \
the company.

Reply with ONE JSON object and nothing else (no preface, no markdown fence):
{
  "company": "<company or counterpart name as in the pack>",
  "role": "<the role, topic or position this meeting is about, as in the pack>",
  "competencies": [{"id": "c1", "name": "<short name>", "pack_quote": "<one line or sentence copied VERBATIM from <pack>>"}],
  "evidence": [{"id": "e1", "kind": "project|metric|story|skill", "text": "<one self-contained claim, at most 30 words>",
                "sources": [{"handle": "pack:L<n> | me:L<n>", "quote": "<copied VERBATIM, 10 to 160 characters>"}]}],
  "questions": [{"bank_id": "<the id given in the parameters>", "kind": "opener|behavioural|role|technical|motivation",
                 "competency_ids": ["c1"], "evidence_ids": ["e1"], "follow_ups": ["<short spoken follow-up question>"]}],
  "rubric": {"c1": {"1": "<what a weak answer looks like>", "3": "<adequate>", "5": "<excellent>"}}
}

Rules (checked by code; anything that fails is thrown away):
- competencies: 4 to 8, each tied to the pack line it comes from. `pack_quote` must be copied exactly from <pack> \
(whitespace and markdown ignored). Choose lines that state what the other side cares about, a requirement, or a fact the \
candidate must be ready to speak to; not formatting or ids.
- evidence: the candidate's projects, numbers and stories that a strong answer could use. Every item needs at least one \
source whose quote is copied VERBATIM from that source. Every number, date and proper name in `text` must appear in a \
quote that supports it. Do not compute new numbers, do not round, do not combine facts into a claim no single source makes. \
If the material is thin, write fewer items. Never fill a gap with a plausible guess.
- questions: the parameters list the questions, each with a `bank_id`. Return one entry per listed `bank_id`, copied \
exactly; the question text, the order and the count are fixed, and anything you change there is ignored. For each: `kind` \
(the opener keeps `opener`; `motivation` only for a why-us/why-now question), `competency_ids` (the competencies it \
probes), `evidence_ids` (the evidence a strong answer would use, empty when none fits) and one or two `follow_ups`, each a \
short spoken question that digs deeper ("What was the number before and after?", "What would you do differently?"). \
Leave the opener's `follow_ups` empty.
- extra questions: only when the parameters say `extra_questions: K` with K above zero, add K more entries WITHOUT a \
`bank_id`, each with a `text` (a question as an interviewer says it, natural speech, one question at a time, planned \
from the pack) and the same fields as above.
- rubric: for every competency, what a 1, a 3 and a 5 answer looks like for THIS meeting, in one sentence each. Ground the \
5 in what the pack says matters, not in generic advice.
- Interview type and difficulty (in the parameters) shape the follow-ups. friendly: open questions. standard: realistic. \
tough: follow-ups that need numbers and trade-offs and press on vague claims.
- The interview language is given in the parameters. Write follow-ups, extra question text, evidence text, competency names \
and rubric lines in it; quotes stay in the language of their source."""


def render_session_sources(pack_lines: list[str], me_lines: list[str] | None) -> str:
    """The cached block of a session-source build: the prep pack, numbered, and the profile when given."""
    parts = [render_numbered("pack", pack_lines)]
    if me_lines:
        parts += ["", render_numbered("me", me_lines)]
    return "\n".join(parts)


def render_session_params(
    interview_type: str, difficulty: str, length_min: int, question_count: int, lang: str,
    questions: list[tuple[str, str]], extra: int, company: str | None, role: str | None,
) -> str:
    """`questions`: the (bank_id, text) list decided by code, in asking order. `extra`: how many more the model plans."""
    lines = [
        "Interview parameters:",
        f"interview_type: {interview_type}",
        f"difficulty: {difficulty}",
        f"length_min: {length_min}",
        f"question_count: {question_count}",
        f"language: {LANG_NAMES.get(lang, lang)} ({lang})",
        f"extra_questions: {extra}",
    ]
    if company:
        lines.append(f"company_hint: {company}")
    if role:
        lines.append(f"role_hint: {role}")
    lines += ["", "Questions (fixed, in asking order; `bank_id` is the key you return):"]
    lines += [f"Q {bid} | {' '.join(text.split())}" for bid, text in questions]
    lines.append("")
    lines.append(f"Describe these {len(questions)} questions for a {length_min}-minute {interview_type} interview"
                 + (f" and plan {extra} more." if extra else "."))
    return "\n".join(lines)
