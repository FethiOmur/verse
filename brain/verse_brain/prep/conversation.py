"""Prep from a conversation: a pasted thread (+ optional posting and company URL) -> a ready meeting session.

    python -m verse_brain.prep conversation --thread FILE [--posting-file F] [--posting-url U] [--company-url U]
        [--note F] [--me NAME] [--company C] [--repo PATH]... [--lang en] [--out DIR] [--vault PATH|--no-vault]
        [--max-searches 8] [--voice-profile PATH|--no-voice] [--fake]

Stages (docs/specs/2026-10-15-verse-prep-from-conversation-design.md):
 1. extract   Sonnet reads the thread: people, company, role, what they want, the meeting's purpose, open questions,
              promises, what the owner already said. Quotes must really be in the thread; names must appear in the inputs.
 2. research  Sonnet with the Anthropic web_search tool (at most 8 searches). It sees the public-facing fields only (no
              rates, no thread text). A fact is "sourced" when its URL is a page the search really returned; anything else
              is written "unverified".
 3. prep note rendered by code (no model call), in the shape the meeting prep already reads.
 4. meeting prep (`pipeline.build_async`) with the prep note, repos, vault and the voice profile.

The session folder `conv-<YYYYMMDD-HHMM>-<company>` additionally holds `thread.md` (the pasted thread), `research.md` (facts
with sources, the queries, unverified facts, gaps) and `prep_note.md`; `meta.json` gets a `conversation` block with the
cost of every stage. Stdout is the session folder, one line; the summary goes to stderr (`warning: ...`, `error: ...`).
The thread stays on this Mac except for the model calls. It is never written anywhere but the session folder.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import re
import shutil
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

from .conversation_model import (DEFAULT_MAX_SEARCHES, SEARCH_USD, AnthropicConversationModel, ConversationModel,
                                 FakeConversationModel, ResearchOutput)
from .conversation_prompt import EXTRACT_SYSTEM, RESEARCH_SYSTEM, extract_user, research_user
from .keychain import KeychainError, read_api_key, redact
from .model import PREP_MODEL, PRICES, ModelOutput, PrepError, Usage, spend_usd
from .pipeline import build_async
from .sim import slugify
from .sources import norm
from .vault import DEFAULT_VAULT, BeyinVault, Vault
from .voice import DEFAULT_VOICE_PATH

MAX_THREAD_CHARS = 60_000
MAX_POSTING_CHARS = 30_000
MAX_POSTING_NOTE_CHARS = 12_000
MAX_NOTE_CHARS = 20_000
FACT_TOPICS = ("company", "product", "size", "funding", "news", "stack", "person", "market")
UNVERIFIED_NO_URL = "unverified: no source page"
UNVERIFIED_NOT_RETRIEVED = "unverified: the URL was not among the pages the search returned"


class ConversationError(PrepError):
    pass


# ---------------------------------------------------------------------------------------------- extract


def _s(v) -> str:
    return " ".join(str(v).split()) if isinstance(v, (str, int, float)) and not isinstance(v, bool) else ""


def _list(v) -> list:
    return v if isinstance(v, list) else []


def parse_json_object(text: str) -> dict:
    """The first JSON object in the model's answer (tolerates a preface or a markdown fence)."""
    start = text.find("{")
    if start < 0:
        raise ConversationError("the extraction answer has no JSON object")
    try:
        obj, _ = json.JSONDecoder().raw_decode(text[start:])
    except json.JSONDecodeError as e:
        raise ConversationError(f"the extraction answer is not valid JSON: {e.msg}") from None
    if not isinstance(obj, dict):
        raise ConversationError("the extraction answer is not a JSON object")
    return obj


def parse_extract(text: str, grounding: str, warnings: list[str]) -> dict:
    """Normalise the extraction. `grounding` is the text names and quotes must come from (thread + posting + note).
    A quote that is not verbatim in the thread is dropped; a person whose name is nowhere in the inputs is dropped.
    Both are named in `warnings`."""
    raw = parse_json_object(text)
    haystack = norm(grounding)
    meeting = raw.get("meeting") if isinstance(raw.get("meeting"), dict) else {}
    people: list[dict] = []
    for p in _list(raw.get("people")):
        if not isinstance(p, dict) or not _s(p.get("name")):
            continue
        name = _s(p["name"])
        if norm(name) not in haystack:
            warnings.append(f"extraction named {name!r}, who is not in the thread; dropped")
            continue
        people.append({k: _s(p.get(k)) for k in ("name", "role", "company", "notes")})
    quotes: list[dict] = []
    for q in _list(raw.get("quotes")):
        if not isinstance(q, dict):
            continue
        text_q = _s(q.get("text"))
        if len(text_q) >= 10 and norm(text_q) in haystack:
            quotes.append({"who": _s(q.get("who")), "text": text_q})
        elif text_q:
            warnings.append("an extracted quote is not verbatim in the thread; dropped")
    promises = [{"who": _s(x.get("who")), "text": _s(x.get("text"))} for x in _list(raw.get("promises"))
                if isinstance(x, dict) and _s(x.get("text"))]
    return {
        "title": _s(raw.get("title")), "company": _s(raw.get("company")), "role": _s(raw.get("role")),
        "people": people,
        "what_they_want": [_s(x) for x in _list(raw.get("what_they_want")) if _s(x)],
        "meeting": {k: _s(meeting.get(k)) for k in ("purpose", "when", "format")},
        "open_questions": [_s(x) for x in _list(raw.get("open_questions")) if _s(x)],
        "promises": promises,
        "candidate_said": [_s(x) for x in _list(raw.get("candidate_said")) if _s(x)],
        "terms": [_s(x) for x in _list(raw.get("terms")) if _s(x)],
        "quotes": quotes,
    }


# ---------------------------------------------------------------------------------------------- research


@dataclass
class Fact:
    topic: str
    text: str
    url: str = ""
    status: str = "sourced"  # "sourced" | "unverified"
    reason: str = ""
    title: str = ""
    page_age: str = ""
    cited: list[str] = field(default_factory=list)


def norm_url(u: str) -> str:
    """Comparison key for URLs: scheme-less, no `www.`, no fragment, no tracking parameters, no trailing slash."""
    try:
        p = urlsplit(u.strip())
    except ValueError:
        return u.strip().lower()
    host = (p.hostname or "").lower().removeprefix("www.")
    query = urlencode([(k, v) for k, v in parse_qsl(p.query) if not k.lower().startswith("utm_") and k.lower() not in
                       {"fbclid", "gclid", "ref"}])
    return urlunsplit(("", host, p.path.rstrip("/"), query, "")).lstrip("/")


_KEY = re.compile(r"^(topic|text|url)\s*:\s*(.*)$", re.I)


def parse_facts(text: str) -> tuple[list[dict], list[str]]:
    """@FACT / @GAP blocks -> (raw facts {topic,text,url}, gap texts). A block never closed by @END is dropped."""
    facts: list[dict] = []
    gaps: list[str] = []
    kind: str | None = None
    cur: dict | None = None
    last: str | None = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        head = line.split()[0].upper()
        if head in ("@FACT", "@GAP"):
            kind, cur, last = head, {"topic": "", "text": "", "url": ""}, None
            continue
        if head == "@END":
            if cur is not None and cur["text"].strip():
                if kind == "@FACT":
                    facts.append(cur)
                else:
                    gaps.append(cur["text"].strip())
            kind = cur = last = None
            continue
        if cur is None:
            continue
        m = _KEY.match(line)
        if m:
            last = m[1].lower()
            cur[last] = m[2].strip()
        elif last == "text":
            cur["text"] = (cur["text"] + " " + line).strip()
    return facts, gaps


_URL = re.compile(r"https?://[^\s)\]>,;\"']+")


def verify_facts(raw: list[dict], research: ResearchOutput) -> list[Fact]:
    """A fact is sourced only when it carries a URL that the search tool returned (or cited). No URL, `none`, or a URL the
    search never returned (a guessed address) makes it "unverified"; the text is kept so Alex can still read it."""
    retrieved = {norm_url(u): p for u, p in research.pages.items()}
    out: list[Fact] = []
    for r in raw:
        topic = _s(r.get("topic")).lower()
        topic = topic if topic in FACT_TOPICS else "company"
        text = _s(r.get("text"))
        m = _URL.search(r.get("url") or "")
        if not text:
            continue
        if m is None:
            out.append(Fact(topic, text, "", "unverified", UNVERIFIED_NO_URL))
            continue
        url = m.group().rstrip(".")
        page = retrieved.get(norm_url(url))
        if page is None:
            out.append(Fact(topic, text, url, "unverified", UNVERIFIED_NOT_RETRIEVED))
        else:
            out.append(Fact(topic, text, page.url, "sourced", "", page.title, page.page_age, list(page.cited)))
    return out


# ---------------------------------------------------------------------------------------------- files


def _one(s: str) -> str:
    return " ".join(s.split())


def render_thread_md(thread: str, posting: str | None, posting_url: str | None, now: datetime) -> str:
    out = [f"# Thread (pasted {now:%Y-%m-%d %H:%M})", "", thread.strip(), ""]
    if posting:
        out += ["", f"# Posting{f' ({posting_url})' if posting_url else ''}", "", posting.strip(), ""]
    return "\n".join(out)


def _fact_line(f: Fact) -> str:
    return f"- {f.text} (source: {f.url})" if f.status == "sourced" else (
        f"- {f.text} ({f.reason}{f': {f.url}' if f.url else ''})")


def render_prep_note(ex: dict, facts: list[Fact], gaps: list[str], *, owner: str, now: datetime,
                     posting: str | None, posting_url: str | None, company_url: str | None, note: str | None) -> str:
    title = ex["title"] or (f"Call with {ex['company']}" if ex["company"] else "Call")
    L = [f"# Prep note: {title}", ""]
    L.append(f"Built {now:%Y-%m-%d} from a pasted conversation and web research.")
    L.append("Rule for the answers: a research line marked unverified has no source page, so say it only with hedging "
             "(\"I read that...\"); a line with a source can be stated plainly.")
    L += ["", "## The conversation"]
    if ex["company"]:
        L.append(f"- Company: {ex['company']}" + (f" ({company_url})" if company_url else ""))
    elif company_url:
        L.append(f"- Company website given: {company_url}")
    if ex["role"]:
        L.append(f"- Role or engagement under discussion: {ex['role']}")
    m = ex["meeting"]
    if m["purpose"]:
        L.append(f"- Meeting purpose: {m['purpose']}")
    if m["when"]:
        L.append(f"- When: {m['when']}")
    if m["format"]:
        L.append(f"- Format: {m['format']}")
    for w in ex["what_they_want"]:
        L.append(f"- They want: {w}")
    for q in ex["quotes"]:
        L.append(f"- {q['who'] or 'They'} said: \"{q['text']}\"")
    if ex["people"]:
        L += ["", "## The people"]
        for p in ex["people"]:
            bits = ", ".join(x for x in (p["role"], p["company"]) if x)
            L.append(f"- {p['name']}" + (f", {bits}" if bits else "") + (f". {p['notes']}" if p["notes"] else ""))
    if ex["candidate_said"]:
        L += ["", f"## What {owner} already told them (stay consistent)"]
        L += [f"- {x}" for x in ex["candidate_said"]]
    if ex["promises"] or ex["open_questions"]:
        L += ["", "## Promises and open questions"]
        L += [f"- {p['who'] or 'They'} promised: {p['text']}" for p in ex["promises"]]
        L += [f"- Open: {q}" for q in ex["open_questions"]]
    if posting:
        L += ["", f"## The role (posting{f', {posting_url}' if posting_url else ''})"]
        used = 0
        for ln in posting.splitlines():
            ln = _one(ln)
            if not ln:
                continue
            used += len(ln)
            if used > MAX_POSTING_NOTE_CHARS:
                L.append("- (posting cut here; the full text is in thread.md)")
                break
            L.append(f"- {ln}")
    if facts:
        L += ["", "## Research (web, one source per line)"]
        for topic in FACT_TOPICS:
            rows = [f for f in facts if f.topic == topic]
            if rows:
                L += ["", f"### {topic}"] + [_fact_line(f) for f in rows]
    if gaps:
        L += ["", "## Not found"] + [f"- {g}" for g in gaps]
    if ex["terms"]:
        L += ["", "## Terms discussed (keep private)"] + [f"- {t}" for t in ex["terms"]]
    if note and note.strip():
        L += ["", f"## {owner}'s note"] + [f"- {_one(x)}" for x in note.splitlines() if x.strip()]
    return "\n".join(L).rstrip() + "\n"


def render_research_md(ex: dict, facts: list[Fact], gaps: list[str], research: ResearchOutput, *, now: datetime,
                       cost: dict) -> str:
    L = [f"# Research: {ex['company'] or ex['title'] or 'conversation'}", "",
         f"Run {now:%Y-%m-%d %H:%M}. {research.searches} web searches, {len(research.pages)} pages returned, "
         f"{sum(f.status == 'sourced' for f in facts)} sourced facts, {sum(f.status != 'sourced' for f in facts)} unverified. "
         f"Cost ${cost['total']:.4f}.", "", "## Queries"]
    L += [f"- {q}" for q in research.queries] or ["- (none)"]
    for status, head in (("sourced", "## Sourced facts"), ("unverified", "## Unverified")):
        rows = [f for f in facts if f.status == status]
        L += ["", head]
        for f in rows:
            L.append(f"- [{f.topic}] {f.text}")
            if f.status == "sourced":
                L.append(f"  - source: {f.url}" + (f" ({f.title})" if f.title else "") + (f", page age {f.page_age}" if f.page_age else ""))
                for c in f.cited[:2]:
                    L.append(f"  - page says: \"{_one(c)[:200]}\"")
            else:
                L.append(f"  - {f.reason}" + (f" ({f.url})" if f.url else ""))
        if not rows:
            L.append("- (none)")
    if gaps:
        L += ["", "## Not found"] + [f"- {g}" for g in gaps]
    L += ["", "## Pages the search returned"]
    L += [f"- {p.url}" + (f" ({p.title})" if p.title else "") for p in research.pages.values()] or ["- (none)"]
    if research.errors:
        L += ["", "## Search errors"] + [f"- {e}" for e in research.errors]
    return "\n".join(L).rstrip() + "\n"


# ---------------------------------------------------------------------------------------------- offline prep model


class FakeConversationPrepModel:
    """Offline stand-in for the meeting-prep call (`--fake`): quotes lines of the prep note, so every block grounds."""

    model = PREP_MODEL

    async def generate(self, system: str, user: str, max_tokens: int) -> ModelOutput:
        lang = (re.search(r"\((\w{2,3})\)", user) or [None, "en"])[1]
        by_line = {int(m[1]): m[2] for ln in user.splitlines() if (m := re.match(r"^L(\d+): (.*)$", ln))}
        sections: dict[str, list[tuple[int, str]]] = {}
        cur = ""
        for n, t in sorted(by_line.items()):
            if t.startswith("#"):
                cur = t.lstrip("#").strip().lower()
            elif t.startswith("- "):
                sections.setdefault(cur, []).append((n, t[2:].strip()))
        out: list[str] = []

        def block(question: str, opener: str, points: list[tuple[int, str]]) -> None:
            points = [p for p in points if len(p[1]) >= 10][:3]
            if not points:
                return
            out.extend(["@BANK", f"lang: {lang}", f"question: {question}"])
            out.extend(f"para.{lang}: {question.rstrip('?')} {w}?" for w in ("exactly", "for us", "in short"))
            out.append(f"opener: {opener}")
            for n, text in points:
                out.extend([f"point: {text}", f"src: prep:L{n} | {text}"])
            out.append("@END")

        block("What is this call about?", "Here is what the conversation says.", sections.get("the conversation", []))
        block("Who is on the other side?", "These are the people from the thread.", sections.get("the people", []))
        research = [p for k, v in sections.items() if k in FACT_TOPICS for p in v if "(source: " in p[1]]
        block("What do we know about their company?", "From the public web.", research)
        return ModelOutput("\n".join(out) + "\n", Usage(), "end_turn")

    async def count_tokens(self, text: str) -> int:
        return len(text) // 4

    async def count_request_tokens(self, system: str, user: str) -> int:
        return (len(system) + len(user)) // 4


# ---------------------------------------------------------------------------------------------- pipeline


def _usd(model: str, u: Usage) -> float:
    return spend_usd(model, u) if model in PRICES else 0.0


async def run_async(
    thread: str, *, out: Path, model: ConversationModel, prep_model, posting: str | None = None,
    posting_url: str | None = None, company_url: str | None = None, note: str | None = None, owner: str = "Alex",
    company: str | None = None, repos: list[Path] | None = None, langs: list[str] | None = None, max_questions: int = 80,
    vault: Vault | None = None, voice_path: Path | None = None, budget_usd: float = 1.0,
    max_searches: int = DEFAULT_MAX_SEARCHES, now: datetime | None = None, log=None,
) -> tuple[Path, dict]:
    """Returns (session folder, summary). `log(line)` gets progress lines (stderr in the CLI)."""
    log = log or (lambda s: None)
    now = now or datetime.now().astimezone()
    out = Path(out).expanduser()
    if not thread.strip():
        raise ConversationError("the conversation is empty")
    if len(thread) > MAX_THREAD_CHARS:
        raise ConversationError(f"the conversation is {len(thread)} chars; the limit is {MAX_THREAD_CHARS}. Cut it instead of truncating.")
    if posting is not None and len(posting) > MAX_POSTING_CHARS:
        raise ConversationError(f"the posting is {len(posting)} chars; the limit is {MAX_POSTING_CHARS}")
    if note is not None and len(note) > MAX_NOTE_CHARS:
        raise ConversationError(f"the note is {len(note)} chars; the limit is {MAX_NOTE_CHARS}")
    warnings: list[str] = []

    log("extract: reading the conversation")
    ex_out = await model.extract(EXTRACT_SYSTEM, extract_user(owner, thread, posting, posting_url, company_url, note), 8000)
    if ex_out.stop_reason == "max_tokens":
        raise ConversationError("the extraction was cut off (max_tokens)")
    ex = parse_extract(ex_out.text, "\n".join(x for x in (thread, posting, note) if x), warnings)
    if company and company.strip():
        ex["company"] = company.strip()
    log(f"extract: {ex['company'] or '(no company)'} | {len(ex['people'])} people | {len(ex['promises'])} promises | "
        f"{len(ex['open_questions'])} open questions")

    log(f"research: web search, at most {max_searches} searches")
    rs = await model.research(RESEARCH_SYSTEM.format(max_uses=max_searches),
                              research_user(ex, company_url, (posting or "")[:3000] or None), max_searches, 16000)
    raw_facts, gaps = parse_facts(rs.text)
    facts = verify_facts(raw_facts, rs)
    sourced = sum(f.status == "sourced" for f in facts)
    log(f"research: {rs.searches} searches | {len(rs.pages)} pages | {sourced} sourced facts | {len(facts) - sourced} unverified")
    if rs.stop_reason == "max_tokens":
        warnings.append("the research answer hit the token limit; the last fact block was cut off and dropped")
    if not facts:
        warnings.append("research produced no facts; the session is built from the conversation alone")
    elif sourced == 0:
        warnings.append("no research fact has a verified source")
    for e in rs.errors:
        warnings.append(f"web search error: {e}")
    if len(facts) - sourced:
        warnings.append(f"{len(facts) - sourced} research fact(s) are unverified (no source page)")

    sid = f"conv-{now:%Y%m%d-%H%M}-{slugify(ex['company'] or ex['title'] or 'conversation')}"
    work = out / f".{sid}.work"
    work.mkdir(parents=True, exist_ok=True)
    note_text = render_prep_note(ex, facts, gaps, owner=owner, now=now, posting=posting, posting_url=posting_url,
                                 company_url=company_url, note=note)
    (work / "prep_note.md").write_text(note_text, encoding="utf-8")
    (work / "thread.md").write_text(render_thread_md(thread, posting, posting_url, now), encoding="utf-8")

    log("prep: building the meeting session")
    try:
        session = await build_async(work / "prep_note.md", repos or [], langs or ["en"], out, max_questions, model=prep_model,
                                    vault=vault, budget_usd=budget_usd, now=now, session_id=sid, voice_path=voice_path)
    except Exception as e:
        raise ConversationError(f"{e} (the research is kept in {work})") from e
    meta = json.loads((session / "meta.json").read_text(encoding="utf-8"))

    cost = {
        "extract": round(_usd(model.model, ex_out.usage), 6),
        "research_tokens": round(_usd(model.model, rs.usage), 6),
        "searches": 0.0 if getattr(model, "free", False) else round(rs.searches * SEARCH_USD, 6),
        "prep": meta["prep_spend_usd"],
    }
    cost["total"] = round(sum(cost.values()), 6)
    (session / "thread.md").write_text((work / "thread.md").read_text(encoding="utf-8"), encoding="utf-8")
    (session / "prep_note.md").write_text(note_text, encoding="utf-8")
    (session / "research.md").write_text(render_research_md(ex, facts, gaps, rs, now=now, cost=cost), encoding="utf-8")
    for f in (session / "thread.md", session / "prep_note.md"):
        f.chmod(0o600)

    meta["prep_note"] = str(session / "prep_note.md")
    meta["warnings"] = warnings + meta["warnings"]
    meta["conversation"] = {
        "kind": "conversation", "company": ex["company"], "people": [p["name"] for p in ex["people"]],
        "company_url": company_url, "posting_url": posting_url, "thread_chars": len(thread),
        "searches": rs.searches, "queries": rs.queries, "pages": len(rs.pages),
        "facts_sourced": sourced, "facts_unverified": len(facts) - sourced, "gaps": len(gaps),
        "extract_usage": ex_out.usage.as_dict(), "research_usage": rs.usage.as_dict(), "cost_usd": cost,
    }
    (session / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    shutil.rmtree(work, ignore_errors=True)  # our own staging folder; kept on failure for inspection
    summary = {"company": ex["company"], "people": len(ex["people"]), "searches": rs.searches, "pages": len(rs.pages),
               "sourced": sourced, "unverified": len(facts) - sourced, "cost": cost, "meta": meta, "warnings": meta["warnings"]}
    return session, summary


# ---------------------------------------------------------------------------------------------- CLI


def _read_text(path: Path, what: str) -> str:
    try:
        return Path(path).expanduser().read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as e:
        raise ConversationError(f"cannot read {what}: {getattr(e, 'strerror', None) or e}") from e


def conversation_main(argv: list[str], default_out: Path) -> int:
    ap = argparse.ArgumentParser(prog="python -m verse_brain.prep conversation", description=(
        "Prepare a meeting session from a pasted conversation (thread), with web research."))
    ap.add_argument("--thread", type=Path, required=True, help="the pasted conversation as a text/markdown file")
    ap.add_argument("--posting-file", type=Path, help="the job posting text the user confirmed")
    ap.add_argument("--posting-url", help="where the posting came from")
    ap.add_argument("--company-url", help="the company's website")
    ap.add_argument("--note", type=Path, help="a free note from the user (.txt/.md)")
    ap.add_argument("--me", default="Alex", help="the name of the thread's owner (default Alex)")
    ap.add_argument("--company", help="override the company read from the thread")
    ap.add_argument("--repo", type=Path, action="append", default=[])
    ap.add_argument("--lang", default="en")
    ap.add_argument("--out", type=Path, default=default_out, help="sessions root")
    ap.add_argument("--vault", type=Path, default=DEFAULT_VAULT)
    ap.add_argument("--no-vault", action="store_true")
    ap.add_argument("--vault-audience", choices=["internal", "public"], default="internal")
    ap.add_argument("--max-questions", type=int, default=80)
    ap.add_argument("--max-searches", type=int, default=DEFAULT_MAX_SEARCHES)
    ap.add_argument("--budget-usd", type=float, default=1.0, help="sizes max_tokens of the meeting-prep call; no spend cap")
    ap.add_argument("--voice-profile", type=Path, default=DEFAULT_VOICE_PATH)
    ap.add_argument("--no-voice", action="store_true")
    ap.add_argument("--fake", action="store_true", help="offline: canned extraction, research and prep; no key, no network")
    a = ap.parse_args(argv)
    if not 1 <= a.max_searches <= 20:
        ap.error("--max-searches must be between 1 and 20")
    err = lambda s: print(s, file=sys.stderr, flush=True)  # noqa: E731
    key = None
    model = None
    try:
        thread = _read_text(a.thread, "the thread")
        posting = _read_text(a.posting_file, "the posting") if a.posting_file else None
        note = _read_text(a.note, "the note") if a.note else None
        voice_path = None
        if not a.no_voice:
            p = a.voice_profile.expanduser()
            if p.is_file():
                voice_path = p
            elif p != DEFAULT_VOICE_PATH.expanduser():
                raise PrepError(f"voice profile not found: {p}")
        langs = [c.strip() for c in a.lang.split(",") if c.strip()]
        if a.fake:
            model, prep_model, vault = FakeConversationModel(), FakeConversationPrepModel(), None
        else:
            key = read_api_key()  # only to scrub error text; the model client reads its own copy
            model = prep_model = AnthropicConversationModel(key, PREP_MODEL, progress=True)
            vault = None if a.no_vault else BeyinVault(a.vault, audience=a.vault_audience)

        async def go():
            try:
                return await run_async(
                    thread, out=a.out, model=model, prep_model=prep_model, posting=posting, posting_url=a.posting_url,
                    company_url=a.company_url, note=note, owner=a.me, company=a.company, repos=a.repo, langs=langs,
                    max_questions=a.max_questions, vault=vault, voice_path=voice_path, budget_usd=a.budget_usd,
                    max_searches=a.max_searches, log=err)
            finally:
                close = getattr(model, "aclose", None)
                if close is not None:
                    await close()

        session, s = asyncio.run(go())
    except (KeychainError, PrepError, OSError) as e:
        err(f"error: {redact(str(e), key)}")
        return 1
    except Exception as e:  # noqa: BLE001
        err(f"error: {type(e).__name__}: {redact(str(e), key)[:300]}")
        return 1
    c = s["cost"]
    meta = s["meta"]
    st = meta["stats"]
    if "voice_sha256" in st:
        err(f"voice profile: {voice_path}")
    err(f"{s['company'] or 'conversation'} | {s['people']} people | bank entries {st['bank_entries']} | facts {st['facts']}")
    err(f"research: {s['searches']} searches | {s['pages']} pages | {s['sourced']} sourced, {s['unverified']} unverified")
    err(f"cost: ${c['total']:.4f} (extract ${c['extract']:.4f} | research ${c['research_tokens']:.4f} tokens + "
        f"${c['searches']:.4f} for {s['searches']} searches | prep ${c['prep']:.4f})")
    for w in s["warnings"]:
        err(f"warning: {w}")
    print(session)
    return 0
