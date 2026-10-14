"""Grading: one Sonnet call over the sim pack and the transcript -> `grades.json`.

The model's output is data, never trusted: parsing is defensive, ids are checked against `sim.json`, and every
better-answer sentence that contains a number is kept only if each number appears in the text of an evidence item the
sentence cites. Numbers are compared as tokens (digits with thousands separators removed, plus spelled-out numbers
from two upward), so "211" does not match "11".
"""

from __future__ import annotations

import asyncio
import json
import re
from dataclasses import dataclass, field

from ..runtime.settings import SONNET, route_params
from ..runtime.transport import Offline, Overloaded, RateLimited, TransportError

MAX_TOKENS = 8000
RETRY_DELAY_S = 2.0          # one retry after a rate-limit / overload / offline error
EPHEMERAL = {"type": "ephemeral"}

SYSTEM = """You grade a practice job interview. You get the interview pack (competencies, the candidate's real \
evidence, planned questions, a 1-5 rubric per competency) and the transcript of the candidate's spoken answers \
(speech-to-text, so punctuation is approximate).

Rules:
- Score each competency 1-5 from the rubric lines, judging only what the candidate actually said. A competency no \
question touched gets no entry.
- "rubric_line" is the rubric line (1, 3 or 5) closest to the score you gave, copied from the pack.
- For each question the candidate answered: what was strong, what was missing, and a better answer of 1-4 first-person \
sentences. Build the better answer ONLY from the evidence items in the pack and cite each sentence with the ids of the \
evidence it uses. Never invent a number, date, name, employer or result: a number may appear in a sentence only if \
a cited evidence item contains it. If the pack has no usable evidence, leave better_answer empty.
- A skipped question or one without an answer gets empty lists.
- "practise_next": exactly three short, concrete things to practise, most important first.
- Do not praise by default. Be specific and fair.
Write only one JSON object, no markdown fence, no commentary."""

SCHEMA = """{"overall": 1-5,
 "competencies": {"c1": {"score": 1-5, "rubric_line": "...", "q_ids": ["q1"]}},
 "questions": [{"q_id": "q1", "strong": ["..."], "missing": ["..."],
                "better_answer": [{"sentence": "...", "evidence_ids": ["e1"]}]}],
 "practise_next": ["...", "...", "..."]}"""

TAIL = ("GRADE THE INTERVIEW. Answer language: @LANG@. Reply with one JSON object of exactly this shape:\n" + SCHEMA)

_NUM_WORDS = {
    "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
    "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
    "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100, "thousand": 1000, "million": 1_000_000,
}
_DIGITS = re.compile(r"(?<![A-Za-z\d])\d+(?:,\d{3})*(?:\.\d+)?")
_WORDS = re.compile(r"\b(" + "|".join(_NUM_WORDS) + r")\b", re.IGNORECASE)


def _canon(num: str) -> str:
    num = num.replace(",", "")
    if "." in num:
        num = num.rstrip("0").rstrip(".")
    return str(int(num)) if num.isdigit() else num


def numbers_in(text: str) -> set[str]:
    out = {_canon(m) for m in _DIGITS.findall(text or "")}
    out |= {str(_NUM_WORDS[w.lower()]) for w in _WORDS.findall(text or "")}
    return out


def number_supported(sentence: str, evidence_ids: list[str], evidence_text: dict[str, str]) -> bool:
    """True if the sentence has no number, or every number in it appears in the text of a cited evidence item."""
    need = numbers_in(sentence)
    if not need:
        return True
    have: set[str] = set()
    for eid in evidence_ids:
        have |= numbers_in(evidence_text.get(eid, ""))
    return need <= have


# ---------------------------------------------------------------- request

def transcript_text(sim: dict, results: dict) -> str:
    planned = {q["id"]: q for q in sim.get("questions", [])}
    lines = ["## TRANSCRIPT (candidate answers are speech-to-text)"]
    for rq in results.get("questions", []):
        qid = rq.get("q_id", "?")
        kind = planned.get(qid, {}).get("kind", "")
        lines.append(f"\n### {qid}" + (f" ({kind})" if kind else ""))
        for a in rq.get("asked", []):
            lines.append(f"Interviewer [{a.get('kind', 'question')}]: {' '.join(str(a.get('text', '')).split())}")
        answers = rq.get("answers", [])
        for a in answers:
            secs = max(0.0, float(a.get("t_end", 0)) - float(a.get("t_start", 0)))
            lines.append(f"Candidate ({secs:.0f} s, {a.get('words', 0)} words): {' '.join(str(a.get('text', '')).split())}")
        if rq.get("skipped"):
            lines.append("Candidate: (skipped)")
        elif not answers:
            lines.append("Candidate: (no answer)")
    cq = results.get("candidate_question")
    if cq and cq.get("text"):
        lines.append(f"\n### Candidate's closing question\nCandidate: {cq['text']}")
    return "\n".join(lines)


def build_request(pack: str, sim: dict, results: dict, model: str = SONNET) -> dict:
    req = route_params("D", max_tokens=MAX_TOKENS)
    req["model"] = model
    req["system"] = [{"type": "text", "text": SYSTEM}]
    req["messages"] = [{"role": "user", "content": [
        {"type": "text", "text": "INTERVIEW PACK\n\n" + pack + "\n", "cache_control": dict(EPHEMERAL)},
        {"type": "text", "text": transcript_text(sim, results)},
        {"type": "text", "text": TAIL.replace("@LANG@", str(sim.get("lang", "en")))},
    ]}]
    return req


# ---------------------------------------------------------------- parsing

def _extract_json(raw: str) -> dict | None:
    if not raw:
        return None
    dec = json.JSONDecoder()
    pos = raw.find("{")
    while pos != -1:
        try:
            obj, _ = dec.raw_decode(raw, pos)
        except ValueError:
            pos = raw.find("{", pos + 1)
            continue
        if isinstance(obj, dict):
            return obj
        pos = raw.find("{", pos + 1)
    return None


def _score(v) -> int | None:
    try:
        return max(1, min(5, int(round(float(v)))))
    except (TypeError, ValueError):
        return None


def _strs(v) -> list[str]:
    if not isinstance(v, list):
        return []
    return [" ".join(x.split()) for x in v if isinstance(x, str) and x.strip()]


def _ids(v, known: set[str]) -> list[str]:
    out: list[str] = []
    for x in v if isinstance(v, list) else []:
        if isinstance(x, str) and x in known and x not in out:
            out.append(x)
    return out


def parse_grades(raw: str, sim: dict) -> dict | None:
    """Validated `grades.json` content, or None when the output holds no usable grading object."""
    obj = _extract_json(raw)
    if obj is None or not any(k in obj for k in ("overall", "competencies", "questions")):
        return None
    comp_ids = [c["id"] for c in sim.get("competencies", [])]
    q_ids = {q["id"] for q in sim.get("questions", [])}
    ev_text = {e["id"]: e.get("text", "") for e in sim.get("evidence", [])}

    comps: dict[str, dict] = {}
    raw_comps = obj.get("competencies") if isinstance(obj.get("competencies"), dict) else {}
    for cid in comp_ids:
        c = raw_comps.get(cid)
        if not isinstance(c, dict) or _score(c.get("score")) is None:
            continue
        comps[cid] = {"score": _score(c.get("score")), "rubric_line": " ".join(str(c.get("rubric_line", "")).split()),
                      "q_ids": _ids(c.get("q_ids"), q_ids)}

    dropped = 0
    questions: list[dict] = []
    seen: set[str] = set()
    for q in obj.get("questions") if isinstance(obj.get("questions"), list) else []:
        if not isinstance(q, dict) or q.get("q_id") not in q_ids or q["q_id"] in seen:
            continue
        seen.add(q["q_id"])
        better: list[dict] = []
        for b in q.get("better_answer") if isinstance(q.get("better_answer"), list) else []:
            if not isinstance(b, dict) or not isinstance(b.get("sentence"), str) or not b["sentence"].strip():
                continue
            sentence = " ".join(b["sentence"].split())
            eids = _ids(b.get("evidence_ids"), set(ev_text))
            if number_supported(sentence, eids, ev_text):
                better.append({"sentence": sentence, "evidence_ids": eids})
            else:
                dropped += 1
        questions.append({"q_id": q["q_id"], "strong": _strs(q.get("strong")), "missing": _strs(q.get("missing")),
                          "better_answer": better})

    overall = _score(obj.get("overall"))
    if overall is None and comps:
        overall = _score(sum(c["score"] for c in comps.values()) / len(comps))
    return {"overall": overall, "competencies": comps, "questions": questions,
            "practise_next": _strs(obj.get("practise_next"))[:3], "dropped_sentences": dropped}


# ---------------------------------------------------------------- the call

@dataclass
class GradeOutcome:
    grades: dict | None
    usage: dict = field(default_factory=dict)
    error: str | None = None


def _add_usage(total: dict, u: dict) -> None:
    for k, v in (u or {}).items():
        if isinstance(v, int):
            total[k] = total.get(k, 0) + v


async def _one_call(transport, request: dict) -> tuple[str, dict]:
    stream = await transport.open_stream("D", request, 0)
    text: list[str] = []
    usage: dict = {}
    try:
        async for ev in stream:
            if ev.kind == "text":
                text.append(ev.text)
            elif ev.kind == "stop":
                usage = dict(ev.usage)
    finally:
        await stream.aclose()
    return "".join(text), usage


async def grade_session(sim: dict, results: dict, pack: str, transport, model: str = SONNET) -> GradeOutcome:
    """Up to two attempts: a retry after a transient transport error, or after output that does not parse."""
    request = build_request(pack, sim, results, model)
    usage: dict = {}
    error = "no attempt"
    for attempt in range(2):
        try:
            raw, u = await _one_call(transport, request)
        except (RateLimited, Overloaded, Offline) as e:
            error = f"{e.kind}: {e}"
            if attempt == 0:
                await asyncio.sleep(min(e.retry_after if e.retry_after is not None else RETRY_DELAY_S, 8.0))
            continue
        except TransportError as e:
            return GradeOutcome(None, usage, f"{e.kind}: {e}")
        _add_usage(usage, u)
        grades = parse_grades(raw, sim)
        if grades is not None:
            return GradeOutcome(grades, usage, None)
        error = "the model's output held no usable grading object"
    return GradeOutcome(None, usage, error)
