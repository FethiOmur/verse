"""The pre-meeting brief (docs/specs/2026-10-21-verse-memory-package-design.md 2.4, 3.5): who promised what, what is still open and
how the other side likes to work, from the entity's past meetings, every point with citations.

A process whose first message is `brief_start` runs this mode (runtime/__main__.py): ONE Sonnet request, then the process ends.

- Inputs: the entity's past sessions that have a transcript or a summary, newest first, at most BRIEF_MAX_SESSIONS. Per session: the
  header (key, date, title, who), the whole summary, the first 4 and last 8 transcript rows, and the top chunks of three fixed probe
  queries scoped to that session; BRIEF_EXCERPT_TOKENS in all, split evenly. Prep and chat chunks are never inputs. Attendee emails
  never reach this module's request: the UPCOMING line carries names, and anything that looks like an address is cut.
- Output: the model writes five headed sections of "- " lines with citations. `parse_brief` keeps a point only when it has a valid
  citation (a transcript line or a summary of one of the request's sessions) and counts the others in `dropped_uncited`; at most five
  points per section. `brief.json` goes to `out` (and, with `session_out`, next to `brief.md`, the citation-free text the live model
  reads: runtime/protocol.py load_session).
- Billing: `ask.make_client()` (Keychain key) is the only credential path. Logs carry counts and timings, never meeting text.
"""

from __future__ import annotations

import dataclasses
import json
import logging
import os
import re
import time
from datetime import datetime
from pathlib import Path

from .. import extensions
from ..prep.model import PRICES, spend_usd
from ..runtime.ask import Row, error_kind, est_tokens, now_iso, usage_of
from ..runtime.memory_ask import EmbedHost, redact_emails
from ..runtime.prompt import LANG_NAME
from ..runtime.protocol import BRIEF_ERROR_KINDS, LANGS, Emitter
from ..runtime.settings import BRIEF_EXCERPT_TOKENS, BRIEF_MAX_SESSIONS, BRIEF_PACK_CHARS, brief_params
from ..runtime.transport import TransportError
from .index import IndexUnavailable, MemoryIndex, SessionInfo
from .search import CITE_RE, QueryEmbedder, header_line, resolve_citations, search

log = logging.getLogger("verse.memory.brief")

# Frozen (golden test). `{owner}`, `{OWNER}`, `{name}` and `{lang}` are the only variables; `{lang}` is the language's name.
BRIEF_SYSTEM_TEMPLATE = (
    "You write {owner}'s short brief before he meets {name} again. Use only PAST MEETINGS: summaries written "
    "after each meeting and transcript excerpts with timestamps, newest meeting first. Write exactly these five "
    "headings, each on its own line, in this order: DISCUSSED, PROMISED BY {OWNER}, PROMISED BY THEM, STILL OPEN, "
    "TONE AND PREFERENCES. Under each, at most five lines starting with \"- \", each at most 25 words, each ending "
    "with one to three citations exactly as given, like [sk3f9qa 12:34] for a transcript line or [sk3f9qa "
    "summary] for a summary. A line without a citation is discarded. Rules: 1) A promise is something a person "
    "said they would do; say who, and by when if it was said. A plan, a wish or a maybe is not a promise. 2) "
    "STILL OPEN: questions asked and not answered, decisions left for later. 3) TONE AND PREFERENCES: how {name} "
    "likes to work and talk (pace, detail, language, format, what to avoid), only when said or clearly shown; "
    "otherwise \"- (nothing clear yet)\". 4) The transcript comes from speech recognition; when a key word looks "
    "misheard, say so. 5) When meetings disagree, the newer one wins; write \"changed on <date>\" when it matters. "
    "6) A section with nothing: \"- (none)\". 7) Write in {lang}. No other text."
)
BRIEF_SYSTEM_TEMPLATE = extensions.with_addenda("brief", BRIEF_SYSTEM_TEMPLATE)


def brief_system_text(owner: str, name: str, lang: str = "en") -> str:
    return (BRIEF_SYSTEM_TEMPLATE.replace("{name}", name).replace("{lang}", LANG_NAME.get(lang, "English"))
            .replace("{owner}", owner).replace("{OWNER}", owner.upper()))


# Three fixed probe queries, each written in English, Italian and Turkish (the search folds accents and ORs the words).
PROBES: dict[str, str] = {
    "commitments": ("promised will send deliver by deadline Friday agreed committed follow up next step | "
                    "promesso invierò consegnerò entro scadenza venerdì concordato impegno prossimo passo | "
                    "söz verdi göndereceğim teslim edeceğim son tarih cuma kabul taahhüt sonraki adım"),
    "open": ("open question unanswered undecided later unclear still waiting not sure whether | "
             "domanda aperta senza risposta da decidere più avanti poco chiaro in attesa non so se | "
             "açık soru cevapsız karar verilmedi sonra belirsiz bekliyor emin değil"),
    "preferences": ("prefer likes dislikes please avoid format pace detail short long written call email language | "
                    "preferisce piace evitare formato ritmo dettaglio breve lungo scritto chiamata lingua | "
                    "tercih eder sever kaçın biçim hız ayrıntı kısa uzun yazılı arama dil"),
}

SECTIONS = ("discussed", "promised_owner", "promised_them", "open", "tone")
MAX_POINTS = 5
MAX_CITES = 3
EMPTY_LINES = {"(none)", "(nothing clear yet)"}
_EMAIL = re.compile(r"[^\s@]*@[^\s@]*")


def scrub(text: object) -> str:
    """One line, with anything that looks like an email address cut out."""
    return " ".join(_EMAIL.sub("", str(text or "")).split())


# ---------------------------------------------------------------- inputs
class _Memo:
    """Embeds each probe once for all sessions."""

    def __init__(self, inner: QueryEmbedder) -> None:
        self._inner = inner
        self.model_sha = inner.model_sha
        self._cache: dict[str, list[float]] = {}

    def query(self, text: str) -> list[float]:
        if text not in self._cache:
            self._cache[text] = self._inner.query(text)
        return self._cache[text]


def _clean_info(info: SessionInfo) -> SessionInfo:
    return dataclasses.replace(info, labels=[x for x in info.labels if "@" not in x])


def session_block(index: MemoryIndex, info: SessionInfo, embedder, budget_tokens: int) -> str:
    """The excerpts of one past session (spec 2.4): header, whole summary, first 4 and last 8 rows, probe chunks; transcript lines
    in time order with `[...]` between non-adjacent ones. Never longer than the budget unless the fixed part alone is."""
    summary = [f"SUMMARY ({c.label}): {c.text}" if c.label else f"SUMMARY: {c.text}" for c in index.chunks_of(info.name, "summary")]
    lines: dict[float, str] = {}
    last = max((c.row_last for c in index.chunks_of(info.name, "turn") if c.row_last is not None), default=None)
    if last is not None:
        for k, r in enumerate(index.first_last_rows(info.name, 0, 3)):
            lines[float(k)] = Row(r.stamp, r.speaker, r.text).line
        start = max(0, last - 7)
        for k, r in enumerate(index.first_last_rows(info.name, start, last)):
            lines[float(start + k)] = Row(r.stamp, r.speaker, r.text).line
    head = header_line(_clean_info(info))
    fixed = est_tokens("\n".join([head, *summary, *lines.values()]))
    remaining = budget_tokens - fixed
    if remaining > 0 and last is not None:
        share = max(1, remaining // len(PROBES))
        for probe in PROBES.values():
            for ex in search(index, probe, scope=[info.name], embedder=embedder, budget_tokens=share,
                             per_session_tokens=share, sources=("turn", "summary")):
                for c in ex.chunks:
                    if c.source != "turn" or c.row_first is None:
                        continue
                    texts = c.text.split("\n")
                    aligned = c.row_last is not None and len(texts) == c.row_last - c.row_first + 1
                    for k, t in enumerate(texts):
                        lines.setdefault(float(c.row_first + k) if aligned else c.row_first + k / 1000.0, t)
    out = [head, *summary]
    prev: float | None = None
    for ix in sorted(lines):
        if prev is not None and ix - prev > 1.0001:
            out.append("[...]")
        out.append(lines[ix])
        prev = ix
    return "\n".join(out)


def upcoming_line(up: object) -> str | None:
    """`UPCOMING: <title> · <d Mon yyyy HH:mm> · with <names>`; attendee names only, never an address."""
    if not isinstance(up, dict):
        return None
    parts = [scrub(up.get("title")) or "(untitled)"]
    start = up.get("start")
    if isinstance(start, str) and start:
        try:
            d = datetime.fromisoformat(start)
            parts.append(f"{d.day} {d:%b %Y %H:%M}")
        except ValueError:
            pass
    att = up.get("attendees")
    names = [n for n in (scrub(a) for a in att) if n] if isinstance(att, list) else []
    if names:
        parts.append("with " + ", ".join(names))
    return "UPCOMING: " + " · ".join(parts)


# ---------------------------------------------------------------- parsing
def section_title(sid: str, owner: str) -> str:
    return {"discussed": "DISCUSSED", "promised_owner": f"PROMISED BY {owner.upper()}", "promised_them": "PROMISED BY THEM",
            "open": "STILL OPEN", "tone": "TONE AND PREFERENCES"}[sid]


def _heading_id(line: str, owner: str) -> str | None:
    n = re.sub(r"^[#*_`\s]+|[#*_`:\s]+$", "", line).casefold()
    n = " ".join(n.split())
    if n == "discussed":
        return "discussed"
    if n == "still open":
        return "open"
    if n == "tone and preferences":
        return "tone"
    if n == "promised by them":
        return "promised_them"
    if n == f"promised by {owner}".casefold():
        return "promised_owner"
    return None


_BULLET = re.compile(r"^\s*[-*\u2022]\s+(.*\S)\s*$")


def parse_brief(text: str, index: MemoryIndex, scope: list[str], owner: str) -> tuple[list[dict], int]:
    """(sections in spec order, dropped_uncited). A point needs a valid citation (a transcript line or a summary of a session of
    `scope`); `(none)` / `(nothing clear yet)` stay as an empty section; at most five points per section."""
    points: dict[str, list[dict]] = {s: [] for s in SECTIONS}
    dropped = 0
    cur: str | None = None
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        hid = _heading_id(line, owner)
        if hid is not None:
            cur = hid
            continue
        m = _BULLET.match(line)
        if m is None or cur is None:
            continue
        body = m.group(1)
        plain = " ".join(CITE_RE.sub("", body).split())
        plain = re.sub(r"\s+([,.;:!?])", r"\1", plain).rstrip(" ,;")
        cites = [c for c in resolve_citations(index, body, scope) if c["kind"] in ("turn", "summary")][:MAX_CITES]
        if not cites:
            if plain.casefold().rstrip(".") in EMPTY_LINES:
                continue
            dropped += 1
            continue
        if not plain:
            dropped += 1
            continue
        if len(points[cur]) < MAX_POINTS:
            points[cur].append({"text": plain, "cites": [{k: c[k] for k in ("key", "session", "kind", "stamp")} for c in cites]})
    return [{"id": s, "points": points[s]} for s in SECTIONS], dropped


# ---------------------------------------------------------------- brief.md
def _sentence(t: str) -> str:
    t = t.strip()
    return t if t[-1:] in ".!?" else t + "."


def render_brief_md(brief: dict, owner: str, limit: int = BRIEF_PACK_CHARS) -> str:
    """The text the live model reads (spec 2.4, 3.5): the heading line and one line per section that has points, citations removed,
    cut at whole lines to `limit` characters. Empty when no section has a point."""
    try:
        d = datetime.fromisoformat(str(brief.get("made_at", "")).replace("Z", "+00:00"))
        as_of = f"{d.day} {d:%b %Y}"
    except ValueError:
        as_of = ""
    head = (f"PAST MEETINGS WITH {brief.get('name', '')} (from Verse's memory, as of {as_of}; background only: what was said "
            f"before, not facts of this meeting)")
    titles = {"discussed": "Discussed", "promised_owner": f"Promised by {owner}", "promised_them": "Promised by them",
              "open": "Still open", "tone": "Tone and preferences"}
    body: list[str] = []
    for sec in brief.get("sections", []):
        pts = [CITE_RE.sub("", p["text"]).strip() for p in sec.get("points", []) if p.get("text")]
        if pts:
            body.append(f"{titles[sec['id']]}: " + " ".join(_sentence(p) for p in pts))
    if not body:
        return ""
    out = [head]
    total = len(head) + 1
    for ln in body:
        if total + len(ln) + 1 > limit:
            break
        out.append(ln)
        total += len(ln) + 1
    return "\n".join(out) + "\n" if len(out) > 1 else ""


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


# ---------------------------------------------------------------- runtime
class BriefRuntime:
    """One `brief_start`, one request, then `stopped`."""

    def __init__(self, client, emitter: Emitter, *, fake: bool = False, no_embed: bool = False,
                 embed_model: str | None = None, embed_backend: str = "gpu") -> None:
        import asyncio

        self.client = client
        self.emitter = emitter
        self.stopped = asyncio.Event()
        self.host = EmbedHost(fake=fake, no_embed=no_embed, model=embed_model, backend=embed_backend)
        self._index: MemoryIndex | None = None

    async def handle(self, msg: dict) -> None:
        if msg.get("type") != "brief_start":
            return
        try:
            await self._run(msg)
        finally:
            self.stopped.set()

    async def shutdown(self) -> None:
        await self.host.close()
        if self._index is not None:
            self._index.close()
            self._index = None
        await self.client.aclose()

    def _error(self, kind: str, message: str, retry_after: float | None = None) -> None:
        assert kind in BRIEF_ERROR_KINDS, kind
        ev = {"type": "brief_error", "kind": kind, "message": message}
        if retry_after is not None:
            ev["retry_after"] = retry_after
        self.emitter.emit(ev)

    async def _run(self, msg: dict) -> None:
        from ..owner import OWNER

        t0 = time.monotonic()
        db, out = msg.get("db"), msg.get("out")
        ent = msg.get("entity") if isinstance(msg.get("entity"), dict) else {}
        names = msg.get("sessions")
        if not (isinstance(db, str) and db and isinstance(out, str) and out and isinstance(ent.get("id"), str)
                and isinstance(ent.get("name"), str) and ent["name"].strip() and isinstance(names, list)):
            self._error("bad_request", "brief_start needs db, out, entity{id,name} and sessions")
            return
        owner = " ".join(str(msg.get("owner_name") or OWNER.display_name).split()) or OWNER.display_name
        name = " ".join(ent["name"].split())
        lang = msg.get("lang") if msg.get("lang") in LANGS else "en"
        session_out = Path(msg["session_out"]).expanduser() if isinstance(msg.get("session_out"), str) and msg["session_out"] else None
        self.emitter.status("warming", "reading past meetings")
        try:
            self._index = MemoryIndex.open(Path(db).expanduser(), readonly=True)
        except IndexUnavailable as e:
            self._error("error", f"cannot read the memory index ({e})")
            return
        index = self._index
        skip = session_out.name if session_out is not None else None
        wanted = [n for n in names if isinstance(n, str) and n != skip]
        infos = [i for i in index.sessions(wanted)
                 if index.chunks_of(i.name, "turn") or index.chunks_of(i.name, "summary")][:BRIEF_MAX_SESSIONS]
        if not infos:
            self._error("no_sessions", "no past meeting with a transcript or a summary")
            return
        qe = await self.host.start()
        embedder = _Memo(qe) if qe is not None else None
        per = max(1, BRIEF_EXCERPT_TOKENS // len(infos))
        blocks = [session_block(index, i, embedder, per) for i in infos]
        parts = []
        up = upcoming_line(msg.get("upcoming"))
        if up:
            parts.append(up)
        parts.append("PAST MEETINGS (newest first)\n" + redact_emails("\n\n".join(blocks)))
        req = brief_params()
        req["system"] = [{"type": "text", "text": brief_system_text(owner, name, lang)}]
        req["messages"] = [{"role": "user", "content": "\n\n".join(parts)}]
        self.emitter.status("ready", "", context={"sessions": len(infos)})
        asked_model = req["model"]
        chunks: list[str] = []
        usage: dict = {}
        model_used = asked_model
        stop_reason: str | None = None
        agen = self.client.stream(req)
        try:
            async for ev in agen:
                if ev.kind == "start":
                    usage = dict(ev.usage)
                    model_used = ev.model or asked_model
                elif ev.kind == "text":
                    chunks.append(ev.text)
                elif ev.kind == "stop":
                    stop_reason = ev.stop_reason
                    usage = dict(ev.usage) or usage
        except TransportError as e:
            self._error(error_kind(e), str(e)[:200] or type(e).__name__, getattr(e, "retry_after", None))
            return
        except Exception as e:  # noqa: BLE001
            log.warning("brief failed: %s", type(e).__name__)
            self._error("error", type(e).__name__)
            return
        finally:
            try:
                await agen.aclose()      # type: ignore[attr-defined]
            except Exception:  # noqa: BLE001
                pass
        if stop_reason == "refusal":
            self._error("refusal", "the model declined to write this brief")
            return
        u = usage_of(usage)
        cost = round(spend_usd(model_used if model_used in PRICES else asked_model, u), 6)
        scope = [i.name for i in infos]
        sections, dropped = parse_brief("".join(chunks), index, scope, owner)
        brief = {"version": 1, "entity": ent["id"], "name": name, "made_at": now_iso(), "lang": lang, "model": model_used,
                 "newest_session": infos[0].name, "for_session": skip,
                 "sessions": [{"name": i.name, "key": i.key, "title": i.title, "date": i.date} for i in infos],
                 "sections": sections, "usage": u.as_dict(), "cost_usd": cost, "dropped_uncited": dropped}
        try:
            payload = json.dumps(brief, ensure_ascii=False, indent=1) + "\n"
            write_text(Path(out).expanduser(), payload)
            if session_out is not None:
                write_text(session_out / "brief.json", payload)
                md = render_brief_md(brief, owner)
                if md:
                    write_text(session_out / "brief.md", md)
                else:
                    (session_out / "brief.md").unlink(missing_ok=True)       # a stale brief must not reach the live model
        except OSError as e:
            log.warning("brief not written: %s", type(e).__name__)
            self._error("error", "cannot write the brief")
            return
        points = sum(len(s["points"]) for s in sections)
        log.info("brief done: sessions=%d points=%d dropped=%d", len(infos), points, dropped)
        self.emitter.emit({"type": "brief_done", "path": out, "cost_usd": cost, "usage": u.as_dict(), "points": points,
                           "dropped_uncited": dropped, "ms_total": round((time.monotonic() - t0) * 1000)})
