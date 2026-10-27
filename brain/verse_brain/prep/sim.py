"""S1: interview-simulation prep. A job posting plus the candidate's own material -> a session folder with
`posting.txt`, `sim.json` (competencies, sourced evidence, question plan, rubric) and `sim_pack.md`.

A second source (spec 2026-10-20 section 2.4, `build_sim_from_session`): a prepared MEETING session instead of a posting. The
questions are decided by code (the opener, then the session's `bank.jsonl` entries in bank order, cut to `question_count`);
the model only writes competencies, evidence, rubric and per question the kind, links and follow-ups. The pack is the
quoted source (`source_pack.md` replaces `posting.txt`) and the profile (`me.md`) may add evidence.

Contract: docs/plans/2026-10-14-verse-interview-sim.md (Shared contracts). One Sonnet call (system prompt and sources are
cache-marked) returns a JSON plan; code then checks it. Competencies must quote the posting; every evidence item needs at
least one source whose quote is really in that source and whose numbers appear in the quotes. What fails is dropped and
named in `warnings`. Ids are renumbered after the drops, so references never dangle.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import re
import shutil
import sys
import unicodedata
from datetime import datetime
from pathlib import Path
from typing import Protocol

from .git_digest import Commit, GitError, read_commits
from .keychain import read_api_key
from .model import PREP_MODEL, AnthropicPrepModel, ModelOutput, PrepError, Usage
from .pipeline import MAX_VAULT_SEED_RECORDS, seed_queries
from .sim_persona import apply_persona
from .sim_pack import MAX_LENGTH_MIN, MIN_LENGTH_MIN, QUESTION_KINDS, question_count, render_sim_pack
from .sim_prompt import (SESSION_SYSTEM, SYSTEM, render_params, render_session_params, render_session_sources,
                         render_sources)
from .sources import MAX_QUOTE_CHARS, MIN_QUOTE_CHARS, SourceBook, norm, numbers_in
from .vault import Vault, VaultError, VaultRecord
from .voice import load_voice, sha256_text, strip_voice

INTERVIEW_TYPES = ("screening", "manager", "technical", "mixed")
DIFFICULTIES = ("friendly", "standard", "tough")
EVIDENCE_KINDS = ("project", "metric", "story", "skill")
MAX_POSTING_CHARS = 40_000
MAX_CV_CHARS = 40_000
MAX_NOTE_CHARS = 20_000
MAX_PACK_CHARS = 120_000       # a meeting pack is capped near 12k tokens by prep; this is a sanity limit
MAX_ME_CHARS = 60_000
MIN_BANK_FOR_CODE_QUESTIONS = 3
MAX_COMPETENCIES = 8
MAX_FOLLOW_UPS = 2
MAX_OUTPUT_TOKENS = 32_000
DEFAULT_TARGET_S = {"opener": [30, 90], "behavioural": [60, 120], "role": [60, 120], "technical": [60, 150], "motivation": [30, 90]}
OPENER_TEXT = "To start, could you tell me a little about yourself and what you have been working on lately?"


# ---------------------------------------------------------------------------------------------- inputs


def _read_bytes(path: Path, what: str) -> bytes:
    try:
        return Path(path).expanduser().read_bytes()
    except OSError as e:
        raise PrepError(f"cannot read {what}: {e.strerror or e}") from e


def _decode(raw: bytes, what: str) -> str:
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        raise PrepError(f"{what} is not valid UTF-8 text") from None


def read_cv(path: Path) -> str:
    """CV text from .pdf (pypdf, BSD-3) or .txt/.md."""
    p = Path(path).expanduser()
    suffix = p.suffix.lower()
    if suffix not in (".pdf", ".txt", ".md"):
        raise PrepError(f"unsupported CV type {suffix or '(none)'}: use .pdf, .txt or .md")
    raw = _read_bytes(p, "CV")
    if suffix != ".pdf":
        text = _decode(raw, "CV")
    else:
        try:
            import io

            from pypdf import PdfReader

            reader = PdfReader(io.BytesIO(raw))
            if reader.is_encrypted:
                raise PrepError("the CV PDF is password-protected; export an unprotected copy or use a .txt file")
            text = "\n".join((page.extract_text() or "") for page in reader.pages)
        except PrepError:
            raise
        except ImportError:
            raise PrepError("pypdf is not installed (pip install pypdf), or give the CV as .txt/.md") from None
        except Exception as e:  # noqa: BLE001
            raise PrepError(f"cannot read the CV PDF: {type(e).__name__}") from None
    if not text.strip():
        raise PrepError("the CV has no text (a scanned PDF?); export it with text or use a .txt file")
    if len(text) > MAX_CV_CHARS:
        raise PrepError(f"CV is {len(text)} chars; the limit is {MAX_CV_CHARS}. Shorten it instead of truncating.")
    return text


def _read_note(path: Path) -> str:
    text = _decode(_read_bytes(path, "note"), "note")
    if not text.strip():
        raise PrepError("the about-me note is empty")
    if len(text) > MAX_NOTE_CHARS:
        raise PrepError(f"note is {len(text)} chars; the limit is {MAX_NOTE_CHARS}")
    return text


# ---------------------------------------------------------------------------------------------- model


class SimPrepModel(Protocol):
    model: str

    async def generate_sim(self, system: str, sources: str, params: str, max_tokens: int) -> ModelOutput: ...


class AnthropicSimModel(AnthropicPrepModel):
    """Sonnet through the prep client. The system prompt and the sources block carry cache_control, so a second build
    for the same posting and CV (another type, difficulty or length) reads them from the cache."""

    async def generate_sim(self, system: str, sources: str, params: str, max_tokens: int) -> ModelOutput:
        parts: list[str] = []
        shown = 0
        async with self._client.messages.stream(
            model=self.model,
            max_tokens=max_tokens,
            system=[{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
            messages=[{"role": "user", "content": [
                {"type": "text", "text": sources, "cache_control": {"type": "ephemeral"}},
                {"type": "text", "text": params},
            ]}],
            thinking={"type": "adaptive"},
            output_config={"effort": "high"},
        ) as stream:
            async for chunk in stream.text_stream:
                parts.append(chunk)
                if self._progress:
                    n = sum(map(len, parts))
                    if n - shown >= 4000:
                        shown = n
                        print(f"  ... {n} chars", file=sys.stderr, flush=True)
            final = await stream.get_final_message()
        u = final.usage
        usage = Usage(
            input=u.input_tokens or 0,
            output=u.output_tokens or 0,
            cache_read=getattr(u, "cache_read_input_tokens", 0) or 0,
            cache_write=getattr(u, "cache_creation_input_tokens", 0) or 0,
        )
        if final.stop_reason == "refusal":
            raise PrepError("the model refused the sim prep request (stop_reason=refusal)")
        return ModelOutput("".join(parts), usage, final.stop_reason)


_NUMBERED = re.compile(r"^L(\d+): (.*)$")
_PARAM = re.compile(r"^(\w+): (.*)$")


class FakeSimModel:
    """Deterministic offline stand-in (`--fake`). It only quotes lines it was given, so its plan always grounds."""

    model = "fake"

    async def generate_sim(self, system: str, sources: str, params: str, max_tokens: int) -> ModelOutput:
        if "<pack>" in sources:
            return self._session_plan(sources, params)
        posting = _block(sources, "posting")
        p = {m[1]: m[2] for ln in params.splitlines() if (m := _PARAM.match(ln))}
        n = int(p.get("question_count", "8"))
        itype = p.get("interview_type", "mixed")
        name_lines = [ln.strip() for ln in posting.splitlines() if ln.strip()]
        role = p.get("role_hint") or (name_lines[0] if name_lines else "Unknown role")
        company = p.get("company_hint") or (
            name_lines[1] if len(name_lines) > 1 and len(name_lines[1]) < 40 and ":" not in name_lines[1] else "Unknown company")

        bullets = [ln.strip()[2:].strip() for ln in posting.splitlines() if ln.strip().startswith("- ") and len(ln.strip()) > 60]
        if not bullets:
            bullets = [s.strip() for s in re.split(r"(?<=[.!?])\s+", " ".join(posting.split())) if len(s.strip()) > 50]
        step = max(1, len(bullets) // 6)
        quotes = [_cut(b, 200) for b in bullets[::step][:6]]
        comps = [{"id": f"c{i}", "name": " ".join(re.findall(r"[\w'+-]+", q)[:5]), "posting_quote": q} for i, q in enumerate(quotes, 1)]

        evidence = []
        for tag in ("cv", "note"):
            for ln in _block(sources, tag).splitlines():
                m = _NUMBERED.match(ln)
                if not m:
                    continue
                t = m[2].strip()
                t = t[2:].strip() if t.startswith("- ") else ""
                if len(t) >= 40 and len(evidence) < 6:
                    q = _cut(t, 160)
                    evidence.append({"id": f"e{len(evidence) + 1}", "kind": "project", "text": q,
                                     "sources": [{"handle": f"{tag}:L{m[1]}", "quote": q}]})

        cycle = {"screening": ["behavioural", "role"], "manager": ["behavioural", "behavioural", "role"],
                 "technical": ["technical", "technical", "role"], "mixed": ["behavioural", "technical", "role"]}[itype]
        text_for = {"behavioural": "Tell me about a time you worked on this: {}.", "technical": "How would you approach this: {}?",
                    "role": "How does your experience relate to this part of the role: {}?"}
        questions = [{"id": "q1", "kind": "opener", "text": OPENER_TEXT, "competency_ids": [], "evidence_ids": [], "follow_ups": []}]
        for i in range(n - 2):
            c = comps[i % len(comps)]
            kind = cycle[i % len(cycle)]
            questions.append({
                "id": f"q{i + 2}", "kind": kind, "text": text_for[kind].format(c["name"]), "competency_ids": [c["id"]],
                "evidence_ids": [evidence[i % len(evidence)]["id"]] if evidence else [],
                "follow_ups": ["Can you put a number on that?", "What would you do differently?"],
            })
        questions.append({"id": f"q{n}", "kind": "motivation", "text": f"What draws you to the {role} role at {company}?",
                          "competency_ids": [], "evidence_ids": [], "follow_ups": []})
        rubric = {c["id"]: {"1": f"Vague or generic about {c['name']}.", "3": f"Concrete example of {c['name']}, few details.",
                            "5": f"Specific example of {c['name']} with measured results."} for c in comps}
        out = {"company": company, "role": role, "competencies": comps, "evidence": evidence, "questions": questions, "rubric": rubric}
        return ModelOutput(json.dumps(out, ensure_ascii=False), Usage(), "end_turn")


    def _session_plan(self, sources: str, params: str) -> ModelOutput:
        """The fake for a session-source build: quotes only lines of the pack and profile it was given."""
        p = {m[1]: m[2] for ln in params.splitlines() if (m := _PARAM.match(ln))}
        asked = [(m[1], m[2]) for ln in params.splitlines() if (m := _FAKE_Q.match(ln))]
        extra = int(p.get("extra_questions", "0"))
        itype = p.get("interview_type", "mixed")
        pack = [(int(m[1]), m[2]) for ln in _block(sources, "pack").splitlines() if (m := _NUMBERED.match(ln))]

        def body(text: str) -> str:
            t = text.strip()
            if t.startswith("[") and "]" in t:                 # "[f001] number | <sentence> | 2 | prep:L14"
                parts = [x.strip() for x in t.split("]", 1)[1].split(" | ")]
                t = max(parts, key=len) if parts else t
            return t.lstrip("-* ").strip()

        usable = [(n, body(t)) for n, t in pack if not t.startswith("#") and len(body(t)) >= 40]
        step = max(1, len(usable) // 5)
        comps, evidence = [], []
        for n, t in usable[::step][:5]:
            q = _cut(t, 160)
            comps.append({"id": f"c{len(comps) + 1}", "name": " ".join(re.findall(r"[\w'+-]+", q)[:5]), "pack_quote": q})
            if len(evidence) < 4:
                evidence.append({"id": f"e{len(evidence) + 1}", "kind": "project", "text": q,
                                 "sources": [{"handle": f"pack:L{n}", "quote": q}]})
        for ln in _block(sources, "me").splitlines():
            m = _NUMBERED.match(ln)
            t = body(m[2]) if m else ""
            if m and len(t) >= 40 and len(evidence) < 6:
                q = _cut(t, 160)
                evidence.append({"id": f"e{len(evidence) + 1}", "kind": "story", "text": q,
                                 "sources": [{"handle": f"me:L{m[1]}", "quote": q}]})
        cycle = {"screening": ["behavioural", "role"], "manager": ["behavioural", "behavioural", "role"],
                 "technical": ["technical", "technical", "role"], "mixed": ["behavioural", "technical", "role"]}[itype]

        def entry(i: int, bank_id: str | None) -> dict:
            e: dict = {"kind": "opener" if i == 0 else cycle[i % len(cycle)],
                       "competency_ids": [comps[i % len(comps)]["id"]] if comps and i else [],
                       "evidence_ids": [evidence[i % len(evidence)]["id"]] if evidence else [],
                       "follow_ups": ["Can you put a number on that?", "What would you do differently?"] if i else []}
            if bank_id is not None:
                e["bank_id"] = bank_id
            return e

        questions = [entry(i, bid) for i, (bid, _t) in enumerate(asked)]
        for k in range(extra):
            e = entry(len(asked) + k, None)
            e["text"] = f"How would you handle this part of the meeting: {comps[k % len(comps)]['name']}?" if comps else "Why this meeting?"
            questions.append(e)
        company = p.get("company_hint") or "Unknown company"
        role = p.get("role_hint") or "Unknown role"
        rubric = {c["id"]: {"1": f"Vague about {c['name']}.", "3": f"Concrete example of {c['name']}.",
                            "5": f"Specific example of {c['name']} with measured results."} for c in comps}
        out = {"company": company, "role": role, "competencies": comps, "evidence": evidence, "questions": questions,
               "rubric": rubric}
        return ModelOutput(json.dumps(out, ensure_ascii=False), Usage(), "end_turn")


_FAKE_Q = re.compile(r"^Q (\S+) \| (.*)$")


def _block(text: str, tag: str) -> str:
    m = re.search(rf"<{tag}>\n(.*?)\n</{tag}>", text, re.S)
    return m[1] if m else ""


def _cut(s: str, limit: int) -> str:
    return s if len(s) <= limit else s[:limit].rsplit(" ", 1)[0]


# ---------------------------------------------------------------------------------------------- grounding


def _s(x: object) -> str:
    return " ".join(x.split()) if isinstance(x, str) else ""


def _list(x: object) -> list:
    return x if isinstance(x, list) else []


def parse_plan(text: str) -> dict:
    t = text.strip()
    t = re.sub(r"^```(?:json)?\s*|\s*```$", "", t)
    a, b = t.find("{"), t.rfind("}")
    if a < 0 or b <= a:
        raise PrepError("the model's sim plan is not JSON")
    try:
        data = json.loads(t[a : b + 1])
    except json.JSONDecodeError as e:
        raise PrepError(f"the model's sim plan is not valid JSON ({e.msg})") from None
    if not isinstance(data, dict):
        raise PrepError("the model's sim plan is not a JSON object")
    return data


def _pieces(quote: str) -> list[str]:
    return [norm(p) for p in re.split(r"…|\.\.\.", quote) if len(norm(p)) >= 4]


def _find_line(lines: list[str], quote: str) -> int | None:
    """1-based line holding the quote (ellipsis pieces must all be in that line, or in a 3-line window)."""
    pieces = _pieces(quote)
    if not pieces:
        return None
    nl = [norm(x) for x in lines]
    for i, ln in enumerate(nl, start=1):
        if all(p in ln for p in pieces):
            return i
    for i in range(len(nl)):
        window = " ".join(nl[i : i + 3])
        if all(p in window for p in pieces):
            return i + 1
    return None


class _Sources:
    def __init__(self, cv: list[str] | None, note: list[str] | None, vault: dict[str, VaultRecord], commits: dict[str, Commit],
                 extra: dict[str, list[str]] | None = None):
        """`extra`: more numbered documents by handle prefix (a session-source build adds `pack` and `me`)."""
        self.docs = {"cv": cv or [], "note": note or [], **(extra or {})}
        self.book = SourceBook(prep_lines=[], vault=vault, commits=commits)
        self._kinds = "|".join(sorted(self.docs))

    def verify(self, raw: object) -> dict | None:
        if not isinstance(raw, dict):
            return None
        handle, quote = _s(raw.get("handle")).strip("[]()"), _s(raw.get("quote"))
        if len(norm(quote)) < MIN_QUOTE_CHARS:
            return None
        kind = re.match(rf"({self._kinds})\b", handle.lower())
        if kind:
            n = _find_line(self.docs[kind[1]], quote)
            return {"kind": kind[1], "ref": f"{kind[1]}:L{n}", "quote": quote[:MAX_QUOTE_CHARS]} if n else None
        src = self.book.resolve(handle, quote)
        return src.as_dict() if src and src.kind in ("vault", "commit") else None


def _ground_competencies(raw: list, posting: str, warnings: list[str], *, label: str = "the posting",
                         book: SourceBook | None = None) -> list[dict]:
    """Keep the competencies whose quote is really in `posting`. With a `book` (a session-source build) the quote is
    checked against the pack lines through `SourceBook`, which also accepts a quote that spans a line break."""
    npost = norm(posting)
    out: list[dict] = []
    for c in raw:
        if not isinstance(c, dict):
            continue
        name, quote = _s(c.get("name")), _s(c.get("posting_quote")) or _s(c.get("pack_quote"))
        if not name or not quote:
            continue
        found = (book.resolve("prep", quote) is not None) if book is not None else norm(quote) in npost
        if len(norm(quote)) < MIN_QUOTE_CHARS or not found:
            warnings.append(f'competency "{name}" dropped: its posting_quote is not text from {label}')
            continue
        if len(out) >= MAX_COMPETENCIES:
            warnings.append(f'competency "{name}" dropped: more than {MAX_COMPETENCIES} competencies')
            continue
        out.append({"old": _s(c.get("id")), "name": name, "posting_quote": quote})
    return out


def _ground_evidence(raw: list, src: _Sources, warnings: list[str]) -> list[dict]:
    out: list[dict] = []
    for e in raw:
        if not isinstance(e, dict):
            continue
        text = _s(e.get("text"))
        if not text:
            continue
        good, seen = [], set()
        for s in _list(e.get("sources")):
            v = src.verify(s)
            if v and (v["ref"], norm(v["quote"])) not in seen:
                seen.add((v["ref"], norm(v["quote"])))
                good.append(v)
        if not good:
            warnings.append(f'evidence dropped (no source quote found in the sources): "{text[:80]}"')
            continue
        have: set[float] = set()
        for v in good:
            have |= numbers_in(v["quote"])
        if not all(any(abs(n - h) < 1e-9 for h in have) for n in numbers_in(text)):
            warnings.append(f'evidence dropped (a number is not in its source quote): "{text[:80]}"')
            continue
        kind = _s(e.get("kind")).lower()
        out.append({"old": _s(e.get("id")), "kind": kind if kind in EVIDENCE_KINDS else "story", "text": text, "sources": good})
    return out


def _target(x: object, kind: str) -> list[int]:
    if isinstance(x, (list, tuple)) and len(x) == 2 and all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in x):
        lo, hi = int(x[0]), int(x[1])
        if 0 < lo < hi <= 600:
            return [lo, hi]
    return list(DEFAULT_TARGET_S[kind])


def _plan_questions(raw: list, n: int, role: str, company: str, warnings: list[str]) -> list[dict]:
    qs: list[dict] = []
    for q in raw:
        if not isinstance(q, dict) or not _s(q.get("text")):
            continue
        kind = _s(q.get("kind")).lower().replace("behavioral", "behavioural")
        qs.append({
            "kind": kind if kind in QUESTION_KINDS else "role", "text": _s(q["text"]),
            "competency_ids": [_s(x) for x in _list(q.get("competency_ids"))], "evidence_ids": [_s(x) for x in _list(q.get("evidence_ids"))],
            "follow_ups": [t for t in (_s(x) for x in _list(q.get("follow_ups"))) if t][:MAX_FOLLOW_UPS],
            "target_s": _target(q.get("target_s"), kind if kind in QUESTION_KINDS else "role"),
        })
    opener = next((q for q in qs if q["kind"] == "opener"), None)
    motivation = next((q for q in qs if q["kind"] == "motivation"), None)
    middle = [q for q in qs if q["kind"] not in ("opener", "motivation")]
    if opener is None:
        warnings.append("the model planned no opener question; a standard opener was added")
        opener = {"kind": "opener", "text": OPENER_TEXT, "competency_ids": [], "evidence_ids": [], "follow_ups": [],
                  "target_s": list(DEFAULT_TARGET_S["opener"])}
    if motivation is None:
        warnings.append("the model planned no motivation question; a standard one was added")
        motivation = {"kind": "motivation", "text": f"What draws you to the {role} role at {company}?", "competency_ids": [],
                      "evidence_ids": [], "follow_ups": [], "target_s": list(DEFAULT_TARGET_S["motivation"])}
        qs.append(motivation)
    keep = middle[: max(0, n - 2)]
    ordered = [opener] + [q for q in qs if q is not opener and (q is motivation or any(q is k for k in keep))]
    if len(ordered) < n:
        warnings.append(f"the model planned {len(ordered)} of {n} questions")
    return ordered


def ground_plan(plan: dict, *, posting: str, src: _Sources, n_questions: int, company: str | None, role: str | None,
                have_sources: bool) -> tuple[dict, list[str]]:
    """The checked and renumbered parts of sim.json: company, role, competencies, evidence, questions, rubric, warnings."""
    warnings: list[str] = []
    company_s = company or _s(plan.get("company"))
    role_s = role or _s(plan.get("role"))
    if not company_s:
        company_s = "Unknown company"
        warnings.append("the company name could not be read from the posting")
    if not role_s:
        role_s = "Unknown role"
        warnings.append("the role title could not be read from the posting")
    comps = _ground_competencies(_list(plan.get("competencies")), posting, warnings)
    if not comps:
        raise PrepError("no competency could be tied to a sentence of the posting; the plan is unusable")
    evidence = _ground_evidence(_list(plan.get("evidence")), src, warnings)
    if not have_sources:
        warnings.append("No experience source was given: the questions come from the posting alone, and answers cannot be "
                        "checked against the candidate's background.")
    elif not evidence:
        warnings.append("No evidence item could be verified against the experience sources: the questions come from the posting "
                        "alone, and answers cannot be checked against the candidate's background.")
    questions = _plan_questions(_list(plan.get("questions")), n_questions, role_s, company_s, warnings)

    return _assemble(company_s, role_s, comps, evidence, questions, plan, warnings)


def _assemble(company_s: str, role_s: str, comps: list[dict], evidence: list[dict], questions: list[dict], plan: dict,
              warnings: list[str]) -> tuple[dict, list[str]]:
    """Renumber competencies, evidence and questions after the drops, so references never dangle, and build the rubric.
    A question may carry a `bank_id` (a session-source build); it is passed through."""
    cmap = {c["old"]: f"c{i}" for i, c in enumerate(comps, start=1) if c["old"]}
    emap = {e["old"]: f"e{i}" for i, e in enumerate(evidence, start=1) if e["old"]}
    rubric_in = plan.get("rubric") if isinstance(plan.get("rubric"), dict) else {}
    rubric: dict[str, dict] = {}
    for i, c in enumerate(comps, start=1):
        r = rubric_in.get(c["old"]) if isinstance(rubric_in.get(c["old"]), dict) else {}
        levels = {k: _s(r.get(k)) for k in ("1", "3", "5") if _s(r.get(k))}
        if len(levels) < 3:
            warnings.append(f'rubric for competency "{c["name"]}" is incomplete')
        rubric[f"c{i}"] = levels
    out_questions = []
    for i, q in enumerate(questions, start=1):
        item = {
            "id": f"q{i}", "kind": q["kind"], "text": q["text"],
            "competency_ids": [cmap[x] for x in q["competency_ids"] if x in cmap],
            "evidence_ids": [emap[x] for x in q["evidence_ids"] if x in emap],
            "follow_ups": q["follow_ups"], "target_s": q["target_s"],
        }
        if q.get("bank_id"):
            item["bank_id"] = q["bank_id"]
        out_questions.append(item)
    parts = {
        "company": company_s, "role": role_s,
        "competencies": [{"id": f"c{i}", "name": c["name"], "posting_quote": c["posting_quote"]} for i, c in enumerate(comps, start=1)],
        "evidence": [{"id": f"e{i}", "kind": e["kind"], "text": e["text"], "sources": e["sources"]} for i, e in enumerate(evidence, start=1)],
        "questions": out_questions, "rubric": rubric,
    }
    return parts, warnings


# ---------------------------------------------------------------------------------------------- from a prepared session

_BACKGROUND = re.compile(
    r"about yourself|your background|introduce yourself|walk (?:me|us) through (?:your|who)|tell (?:me|us) about you\b|"
    r"parlami di te|parlaci di te|raccontami di te|raccontaci di te|presentati|il tuo percorso|"
    r"kendinizden (?:biraz )?bahse|kendinizi tan[ıi]t|kendinden (?:biraz )?bahse|kendini tan[ıi]t", re.I)


def asks_background(question: str) -> bool:
    """True for a "tell me about yourself" question (English, Italian, Turkish)."""
    return bool(_BACKGROUND.search(" ".join(question.split())))


def read_bank(path: Path, warnings: list[str]) -> list[dict]:
    """The session's `bank.jsonl` entries that have an id and a question, in file order. A bad line is skipped and named."""
    p = Path(path)
    if not p.is_file():
        return []
    out: list[dict] = []
    for i, ln in enumerate(_decode(_read_bytes(p, "bank.jsonl"), "bank.jsonl").splitlines(), start=1):
        if not ln.strip():
            continue
        try:
            rec = json.loads(ln)
        except json.JSONDecodeError:
            warnings.append(f"bank.jsonl line {i} is not JSON and was skipped")
            continue
        if isinstance(rec, dict) and _s(rec.get("id")) and _s(rec.get("question")):
            out.append({"id": _s(rec["id"]), "question": _s(rec["question"])})
    return out


def plan_session_questions(bank: list[dict], n: int, warnings: list[str]) -> tuple[list[dict], int]:
    """The question list, decided by code: the opener (bank entry `b001` when it asks about background, else OPENER_TEXT),
    then the other bank entries in bank order, cut to `n`. Each item: `key` (the bank id, or "opener"), `text`, `bank_id`
    (None for the standard opener). Returns (items, extra): with fewer than 3 bank entries the model plans `extra` more."""
    first = next((b for b in bank if b["id"] == "b001" and asks_background(b["question"])), None)
    if first is not None:
        fixed = [{"key": first["id"], "text": first["question"], "bank_id": first["id"]}]
        rest = [b for b in bank if b is not first]
    else:
        fixed = [{"key": "opener", "text": OPENER_TEXT, "bank_id": None}]
        rest = list(bank)
    fixed += [{"key": b["id"], "text": b["question"], "bank_id": b["id"]} for b in rest[: max(0, n - 1)]]
    seen: set[str] = set()
    for f in fixed:                                    # a duplicated bank id would make the model's reply ambiguous
        if f["key"] in seen:
            raise PrepError(f"bank.jsonl has the id {f['key']} twice")
        seen.add(f["key"])
    extra = max(0, n - len(fixed)) if len(bank) < MIN_BANK_FOR_CODE_QUESTIONS else 0
    if len(bank) < MIN_BANK_FOR_CODE_QUESTIONS:
        warnings.append(f"the prep bank has only {len(bank)} question(s); the model plans the other {extra} from the pack")
    elif len(fixed) < n:
        warnings.append(f"the prep bank has {len(bank)} question(s): the interview has {len(fixed)} of {n}")
    return fixed, extra


def _session_questions(raw: list, fixed: list[dict], extra: int, warnings: list[str]) -> list[dict]:
    """Merge the model's per-question fields into the code-built list. The model's order, text and count are ignored;
    only `kind`, the links, the follow-ups and `target_s` are taken, matched by `bank_id`."""
    keys = {f["key"] for f in fixed}
    by_key: dict[str, dict] = {}
    extras: list[dict] = []
    for q in raw:
        if not isinstance(q, dict):
            continue
        key = _s(q.get("bank_id"))
        if key in keys:
            by_key.setdefault(key, q)
        elif _s(q.get("text")):
            extras.append(q)

    def fields(m: dict, kind: str) -> dict:
        return {"competency_ids": [_s(x) for x in _list(m.get("competency_ids"))],
                "evidence_ids": [_s(x) for x in _list(m.get("evidence_ids"))],
                "follow_ups": [t for t in (_s(x) for x in _list(m.get("follow_ups"))) if t][:MAX_FOLLOW_UPS],
                "target_s": _target(m.get("target_s"), kind)}

    def kind_of(m: dict) -> str:
        k = _s(m.get("kind")).lower().replace("behavioral", "behavioural")
        return k if k in QUESTION_KINDS and k != "opener" else "role"

    out: list[dict] = []
    for i, f in enumerate(fixed):
        m = by_key.get(f["key"], {})
        if not m:
            warnings.append(f"the model returned nothing for question {f['key']}: it has no competency or evidence links")
        if i == 0:
            item = {"kind": "opener", **fields(m, "opener")}
            item["follow_ups"] = []
        else:
            item = {"kind": kind_of(m), **fields(m, kind_of(m))}
        item["text"] = f["text"]
        if f["bank_id"]:
            item["bank_id"] = f["bank_id"]
        out.append(item)
    for m in extras[:extra]:
        k = kind_of(m)
        out.append({"kind": k, "text": _s(m["text"]), **fields(m, k)})
    if extra and len(extras) < extra:
        warnings.append(f"the model planned {min(len(extras), extra)} of {extra} extra questions")
    return out


def ground_session_plan(plan: dict, *, pack_text: str, src: _Sources, fixed: list[dict], extra: int, company: str | None,
                        role: str | None) -> tuple[dict, list[str]]:
    """Like `ground_plan` for a session-source build: competency quotes are checked against the pack lines, evidence
    against the pack and the profile, and the questions come from `fixed` (code) plus the model's `extra`."""
    warnings: list[str] = []
    company_s = company or _s(plan.get("company"))
    role_s = _s(plan.get("role"))
    if not company_s:
        company_s = "Unknown company"
        warnings.append("the company name could not be read from the prep pack")
    if not role_s:
        role_s = "Unknown role"
        warnings.append("the role could not be read from the prep pack")
    book = SourceBook(prep_lines=src.docs["pack"])
    comps = _ground_competencies(_list(plan.get("competencies")), pack_text, warnings, label="the prep pack", book=book)
    if not comps:
        raise PrepError("no competency could be tied to a line of the prep pack; the plan is unusable")
    evidence = _ground_evidence(_list(plan.get("evidence")), src, warnings)
    if not evidence:
        warnings.append("No evidence item could be verified against the prep pack or the profile: answers cannot be checked "
                        "against the candidate's background.")
    questions = _session_questions(_list(plan.get("questions")), fixed, extra, warnings)
    return _assemble(company_s, role_s, comps, evidence, questions, plan, warnings)


# ---------------------------------------------------------------------------------------------- build


def slugify(name: str) -> str:
    s = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    s = re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:40].strip("-")
    return s or "company"


def _collect_vault(vault: Vault | None, queries: list[str], warnings: list[str]) -> dict[str, VaultRecord]:
    records: dict[str, VaultRecord] = {}
    if vault is None:
        return {}
    failures, last = 0, ""
    for q in queries:
        try:
            for rec in vault.search(q, limit=3, budget_chars=2500):
                if len(records) < MAX_VAULT_SEED_RECORDS:
                    records.setdefault(rec.record_id, rec)
        except VaultError as e:
            failures += 1
            last = str(e)
    if failures:
        warnings.append(f"vault retrieval failed for {failures} of {len(queries)} queries (last: {last})")
    return {f"V{i}": rec for i, rec in enumerate(records.values(), start=1)}


async def build_sim_async(
    posting_file: Path, *, out: Path, model: SimPrepModel, posting_url: str | None = None, cv: Path | None = None,
    note: Path | None = None, repos: list[Path] | tuple[Path, ...] = (), vault: Vault | None = None,
    interview_type: str = "mixed", difficulty: str = "standard", length_min: int = 30, lang: str = "en",
    company: str | None = None, role: str | None = None, now: datetime | None = None,
    voice_path: Path | None = None, persona: dict | None = None,
) -> Path:
    if interview_type not in INTERVIEW_TYPES:
        raise PrepError(f"interview type must be one of {', '.join(INTERVIEW_TYPES)}")
    if difficulty not in DIFFICULTIES:
        raise PrepError(f"difficulty must be one of {', '.join(DIFFICULTIES)}")
    if not MIN_LENGTH_MIN <= length_min <= MAX_LENGTH_MIN:
        raise PrepError(f"length must be {MIN_LENGTH_MIN} to {MAX_LENGTH_MIN} minutes")
    lang = lang.strip().lower() or "en"
    raw_posting = _read_bytes(posting_file, "posting file")
    posting = _decode(raw_posting, "posting file")
    if not posting.strip():
        raise PrepError("the posting file is empty: paste the job posting text")
    if len(posting) > MAX_POSTING_CHARS:
        raise PrepError(f"posting is {len(posting)} chars; the limit is {MAX_POSTING_CHARS}")
    cv_text = read_cv(cv) if cv else None
    note_text = _read_note(note) if note else None

    warnings: list[str] = []
    commits: dict[str, Commit] = {}
    for r in repos:
        try:
            for c in read_commits(Path(r).expanduser().resolve()):
                commits[c.hash] = c
        except GitError as e:
            warnings.append(f"git digest unavailable: {e}")
    queries = seed_queries(posting + "\n" + (note_text or ""), [Path(r) for r in repos])
    handles = _collect_vault(vault, queries, warnings)

    cv_lines = cv_text.splitlines() if cv_text else None
    note_lines = note_text.splitlines() if note_text else None
    n = question_count(length_min)
    sources = render_sources(posting, cv_lines, note_lines, handles, commits)
    params = render_params(interview_type, difficulty, length_min, n, lang, company, role, (persona or {}).get("focus"))
    res = await model.generate_sim(SYSTEM, sources, params, MAX_OUTPUT_TOKENS)
    if res.stop_reason == "max_tokens":
        raise PrepError(f"the model's sim plan hit the {MAX_OUTPUT_TOKENS}-token limit and was cut off")
    plan = parse_plan(res.text)

    src = _Sources(cv_lines, note_lines, handles, commits)
    have_sources = bool(cv_text or note_text or handles or commits)
    parts, plan_warnings = ground_plan(plan, posting=posting, src=src, n_questions=n, company=company, role=role,
                                       have_sources=have_sources)
    warnings += plan_warnings

    now = now or datetime.now().astimezone()
    out = Path(out).expanduser()
    sid = f"sim-{now:%Y%m%d-%H%M}-{slugify(parts['company'])}"
    final, k = out / sid, 2
    while final.exists():
        final = out / f"{sid}-{k}"
        k += 1
    sim = {
        "session_id": final.name, "created_at": now.isoformat(timespec="seconds"), "lang": lang,
        "company": parts["company"], "role": parts["role"], "interview_type": interview_type, "difficulty": difficulty,
        "length_min": length_min,
        "posting": {"source_url": posting_url or None, "text_path": "posting.txt", "sha256": hashlib.sha256(raw_posting).hexdigest()},
        "competencies": parts["competencies"], "evidence": parts["evidence"], "questions": parts["questions"],
        "rubric": parts["rubric"], "warnings": warnings, "prep_model": model.model, "prep_usage": res.usage.as_dict(),
    }
    voice = load_voice(voice_path)
    if voice is not None:
        sim["voice_sha256"] = sha256_text(voice)
    if persona:
        apply_persona(persona, sim["questions"])
        sim["persona"] = persona

    out.mkdir(parents=True, exist_ok=True)
    tmp = out / f".{final.name}.tmp"
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir()
    try:
        (tmp / "posting.txt").write_bytes(raw_posting)
        (tmp / "sim.json").write_text(json.dumps(sim, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        (tmp / "sim_pack.md").write_text(render_sim_pack(sim, voice), encoding="utf-8")
        tmp.rename(final)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    return final


def build_sim(posting_file: Path, *, model: SimPrepModel | None = None, **kw) -> Path:
    """Build a sim session folder and return its path. Without `model`, a real Sonnet client is created from the
    Keychain key (service `verse-anthropic`)."""

    async def _run() -> Path:
        own = None
        m = model
        if m is None:
            own = m = AnthropicSimModel(read_api_key(), PREP_MODEL, progress=True)
        try:
            return await build_sim_async(posting_file, model=m, **kw)
        finally:
            if own is not None:
                await own.aclose()

    return asyncio.run(_run())


def _read_me(path: Path) -> str:
    text = _decode(_read_bytes(path, "profile"), "profile")
    if not text.strip():
        raise PrepError("the profile file is empty")
    if len(text) > MAX_ME_CHARS:
        raise PrepError(f"the profile is {len(text)} chars; the limit is {MAX_ME_CHARS}")
    return text


def _session_meta(session: Path, warnings: list[str]) -> dict:
    f = session / "meta.json"
    if not f.is_file():
        return {}
    try:
        meta = json.loads(f.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        warnings.append("meta.json could not be read: the language and the company name come from elsewhere")
        return {}
    return meta if isinstance(meta, dict) else {}


async def build_sim_from_session_async(
    session_dir: Path, *, out: Path, model: SimPrepModel, me: Path | None = None,
    interview_type: str = "mixed", difficulty: str = "standard", length_min: int = 30, lang: str | None = None,
    company: str | None = None, role: str | None = None, now: datetime | None = None, voice_path: Path | None = None,
    persona: dict | None = None,
) -> Path:
    """A mock interview from a prepared MEETING session (`pack.md`, `bank.jsonl`, `meta.json`). Writes
    `<out>/sim-<YYYYMMDD-HHMM>-<source session>/` with `sim.json` (`source: "session"`, `source_session`), `source_pack.md`
    and `sim_pack.md`. Questions are decided by code (see `plan_session_questions`); one model call writes the rest."""
    if interview_type not in INTERVIEW_TYPES:
        raise PrepError(f"interview type must be one of {', '.join(INTERVIEW_TYPES)}")
    if difficulty not in DIFFICULTIES:
        raise PrepError(f"difficulty must be one of {', '.join(DIFFICULTIES)}")
    if not MIN_LENGTH_MIN <= length_min <= MAX_LENGTH_MIN:
        raise PrepError(f"length must be {MIN_LENGTH_MIN} to {MAX_LENGTH_MIN} minutes")
    session = Path(session_dir).expanduser()
    if not session.is_dir():
        raise PrepError(f"the session folder does not exist: {session}")
    raw_pack = _read_bytes(session / "pack.md", "pack.md")
    pack_text = strip_voice(_decode(raw_pack, "pack.md"))     # the style guide is wording, never a source of facts
    if not pack_text.strip():
        raise PrepError("the session's pack.md is empty: prepare the meeting first")
    if len(pack_text) > MAX_PACK_CHARS:
        raise PrepError(f"pack.md is {len(pack_text)} chars; the limit is {MAX_PACK_CHARS}")
    me_text = _read_me(me) if me else None

    warnings: list[str] = []
    meta = _session_meta(session, warnings)
    langs = meta.get("languages")
    meta_lang = langs[0] if isinstance(langs, list) and langs and isinstance(langs[0], str) else ""
    lang = (lang or "").strip().lower() or meta_lang.strip().lower() or "en"
    conv = meta.get("conversation") if isinstance(meta.get("conversation"), dict) else {}
    company = company or (_s(conv.get("company")) or None)

    bank = read_bank(session / "bank.jsonl", warnings)
    n = question_count(length_min)
    fixed, extra = plan_session_questions(bank, n, warnings)

    pack_lines = pack_text.splitlines()
    me_lines = me_text.splitlines() if me_text else None
    sources = render_session_sources(pack_lines, me_lines)
    params = render_session_params(interview_type, difficulty, length_min, n, lang,
                                   [(f["key"], f["text"]) for f in fixed], extra, company, role,
                                   (persona or {}).get("focus"))
    res = await model.generate_sim(SESSION_SYSTEM, sources, params, MAX_OUTPUT_TOKENS)
    if res.stop_reason == "max_tokens":
        raise PrepError(f"the model's sim plan hit the {MAX_OUTPUT_TOKENS}-token limit and was cut off")
    plan = parse_plan(res.text)

    src = _Sources(None, None, {}, {}, extra={"pack": pack_lines, "me": me_lines or []})
    parts, plan_warnings = ground_session_plan(plan, pack_text=pack_text, src=src, fixed=fixed, extra=extra,
                                               company=company, role=role)
    warnings += plan_warnings

    now = now or datetime.now().astimezone()
    out = Path(out).expanduser()
    sid = f"sim-{now:%Y%m%d-%H%M}-{slugify(session.name)}"
    final, k = out / sid, 2
    while final.exists():
        final = out / f"{sid}-{k}"
        k += 1
    source_bytes = pack_text.encode("utf-8")
    sim = {
        "session_id": final.name, "created_at": now.isoformat(timespec="seconds"), "lang": lang,
        "company": parts["company"], "role": parts["role"], "interview_type": interview_type, "difficulty": difficulty,
        "length_min": length_min,
        "source": "session", "source_session": session.name,
        "posting": {"source_url": None, "text_path": "source_pack.md", "sha256": hashlib.sha256(source_bytes).hexdigest()},
        "competencies": parts["competencies"], "evidence": parts["evidence"], "questions": parts["questions"],
        "rubric": parts["rubric"], "warnings": warnings, "prep_model": model.model, "prep_usage": res.usage.as_dict(),
    }
    voice = load_voice(voice_path)
    if voice is not None:
        sim["voice_sha256"] = sha256_text(voice)
    if persona:
        apply_persona(persona, sim["questions"])
        sim["persona"] = persona

    out.mkdir(parents=True, exist_ok=True)
    tmp = out / f".{final.name}.tmp"
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir()
    try:
        (tmp / "source_pack.md").write_bytes(source_bytes)
        (tmp / "sim.json").write_text(json.dumps(sim, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        (tmp / "sim_pack.md").write_text(render_sim_pack(sim, voice), encoding="utf-8")
        tmp.rename(final)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    return final


def build_sim_from_session(session_dir: Path, *, model: SimPrepModel | None = None, **kw) -> Path:
    """Build a sim session folder from a prepared meeting session and return its path. Without `model`, a real Sonnet
    client is created from the Keychain key (service `verse-anthropic`)."""

    async def _run() -> Path:
        own = None
        m = model
        if m is None:
            own = m = AnthropicSimModel(read_api_key(), PREP_MODEL, progress=True)
        try:
            return await build_sim_from_session_async(session_dir, model=m, **kw)
        finally:
            if own is not None:
                await own.aclose()

    return asyncio.run(_run())
