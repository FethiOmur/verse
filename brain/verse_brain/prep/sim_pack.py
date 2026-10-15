"""sim_pack.md: the deterministic markdown render of sim.json (the sim runtime's cache prefix).

Same sim content (and the same voice profile text, V1) gives byte-identical output. Nothing per-run appears here: no session id, no timestamps, no token
usage, no posting hash. The runtime puts this file at cache breakpoint 1, so any drift would break the cache.
"""

from __future__ import annotations

from .voice import with_voice

QUESTION_KINDS = ("opener", "behavioural", "role", "technical", "motivation")
MIN_LENGTH_MIN, MAX_LENGTH_MIN = 5, 120


def question_count(length_min: int) -> int:
    """15 min -> 5, 30 -> 8, 45 -> 11 (one more question per 5 minutes), never fewer than 3."""
    return max(3, 5 + round((length_min - 15) / 5))


def _one_line(s: object) -> str:
    return " ".join(str(s).split())


def _src(s: dict) -> str:
    return f'{s["ref"]} "{_one_line(s["quote"])}"'


def render_sim_pack(sim: dict, voice: str | None = None) -> str:
    """`voice`: the candidate's voice profile text (prep/voice.py); appended as the last section. None: unchanged."""
    out: list[str] = ["## INTERVIEW"]
    out.append(f"Company: {_one_line(sim['company'])}")
    out.append(f"Role: {_one_line(sim['role'])}")
    out.append(f"Type: {sim['interview_type']} | Difficulty: {sim['difficulty']} | Length: {sim['length_min']} min | "
               f"Language: {sim['lang']}")
    out += ["", "## COMPETENCIES (what the posting asks for)"]
    for c in sim["competencies"]:
        out.append(f"[{c['id']}] {_one_line(c['name'])} | posting: \"{_one_line(c['posting_quote'])}\"")
    out += ["", "## CANDIDATE EVIDENCE (the only facts about the candidate; each is sourced)"]
    if sim["evidence"]:
        for e in sim["evidence"]:
            out.append(f"[{e['id']}] {e['kind']} | {_one_line(e['text'])}")
            for s in e["sources"]:
                out.append(f"    source: {_src(s)}")
    else:
        out.append("(none: no experience source was given or none could be verified; the candidate's answers cannot be "
                   "checked against their background)")
    out += ["", "## QUESTION PLAN"]
    for q in sim["questions"]:
        lo, hi = q["target_s"]
        out.append(f"[{q['id']}] {q['kind']} | {_one_line(q['text'])}")
        out.append(f"    competencies: {', '.join(q['competency_ids']) or '-'} | evidence: {', '.join(q['evidence_ids']) or '-'}"
                   f" | target: {lo}-{hi} s")
        for f in q["follow_ups"]:
            out.append(f"    follow-up: {_one_line(f)}")
    out += ["", "## RUBRIC"]
    for c in sim["competencies"]:
        r = sim["rubric"].get(c["id"])
        if not r:
            continue
        out.append(f"[{c['id']}] {_one_line(c['name'])}")
        for level in ("1", "3", "5"):
            if r.get(level):
                out.append(f"    {level}: {_one_line(r[level])}")
    return with_voice("\n".join(out) + "\n", voice, "sim")
