"""Ask across meetings: the chat runtime of an entity's or of every meeting (docs/specs/2026-10-21-verse-memory-package-design.md 2.3, 3.4, 3.7).

A process whose first message is `memory_ask_start` runs this mode (runtime/__main__.py). It is an `AskRuntime` that reuses the
streaming, cancel, cost and error mapping of runtime/ask.py and replaces the grounding and the retrieval:

- Grounding: ONE cached user block, the SESSION CATALOG (every in-scope meeting, newest first, at most MEMORY_CATALOG_MAX lines)
  and, when Swift sends `me`, ABOUT <OWNER>. It is a pure function of the scope and the index, so every question of the panel shares
  its bytes. The uncached tail of a question is EXCERPTS (memory/search.py: the best chunks of the scope for the question plus the
  previous question) then QUESTION.
- History: the last MEMORY_HISTORY_PAIRS Q/A pairs after the last `reset` of the chat file, text only. A pair whose stored citations
  name a session that is no longer in the index is not sent.
- Citations: `[<key> <stamp>|summary|prep|chat]` in the answer, validated against the scope and the index (search.resolve_citations)
  and stored as full objects in the chat `a` line and in `ask_done`.
- Billing: `ask.make_client()` (Keychain key) is the only credential path; this file reads no other credential source. Logs carry
  names, counts and timings, never meeting text, questions, answers or emails.
- The index is opened read-only; `chat.jsonl` of the scope (`memory/chats/all.jsonl`, `memory/chats/<entity-id>.jsonl`) is written
  by this runtime only.
"""

from __future__ import annotations

import asyncio
import dataclasses
import json
import logging
import math
import re
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from .. import extensions
from ..memory.index import IndexUnavailable, MemoryIndex, SessionInfo
from ..memory.search import QueryEmbedder, header_line, render_excerpts, resolve_citations, search
from ..prep.model import PREP_MODEL, PRICES, spend_usd
from .ask import AskRuntime, now_iso, usage_of
from .me import load_me, priorities_first
from .protocol import ASK_MODELS
from .settings import MEMORY_CATALOG_MAX, MEMORY_HISTORY_PAIRS, ask_params

log = logging.getLogger("verse.runtime.memory_ask")

EPHEMERAL = {"type": "ephemeral"}

# Frozen (golden tests). `{owner}` / `{OWNER}` / `{scope}` are the only variables; `{scope}` is SCOPE_ALL or SCOPE_ENTITY.
SCOPE_ALL = "all of {owner}'s past meetings"
SCOPE_ENTITY = "{owner}'s past meetings with {name}"
MEMORY_SYSTEM_TEMPLATE = (
    "You answer {owner}'s questions about {scope}. Use only the material in this conversation: the SESSION "
    "CATALOG (every meeting in scope, with its key, date and who was there), the EXCERPTS (the parts of those "
    "meetings that match the question: transcript lines with timestamps, summaries written after each meeting, "
    "his prep, and his earlier chats about a meeting) and ABOUT {OWNER}. Rules: 1) Ground every statement about "
    "what was said and cite it exactly in one of these forms: [<key> <timestamp>] for a transcript line, like "
    "[sk3f9qa 12:34], or [<key> summary], [<key> prep], [<key> chat]; at most three citations per claim. 2) Say "
    "which meeting and when (\"on 19 Oct\"), and who said it: {owner}, or the other side by name when the catalog "
    "gives one (\"Other\" and \"Room\" lines may be either). 3) If the material does not contain the answer, say so "
    "in one sentence; the excerpts are a selection, so say \"in the parts I can see\" when absence matters. Never "
    "guess names, numbers, dates or commitments. 4) The transcript comes from speech recognition, so words can be "
    "wrong; when a key word looks misheard, say so. 5) Prep and chat are not evidence that something was said: "
    "mark them \"(from your prep)\", \"(from an earlier chat)\"; ABOUT {OWNER} is marked \"(from your profile)\". 6) "
    "When meetings disagree, the newer one wins; say so. 7) Answer in the language of the question. Answer "
    "directly first, then at most five \"- \" bullets. Plain text, no headings, no tables."
)
MEMORY_SYSTEM_TEMPLATE = extensions.with_addenda("memory_ask", MEMORY_SYSTEM_TEMPLATE)


def memory_system_text(owner: str, scope_kind: str = "all", name: str = "") -> str:
    scope = SCOPE_ALL if scope_kind == "all" else SCOPE_ENTITY.replace("{name}", name)
    return (MEMORY_SYSTEM_TEMPLATE.replace("{scope}", scope).replace("{owner}", owner).replace("{OWNER}", owner.upper()))


# ---------------------------------------------------------------- the embedder, on its own thread
class _ThreadBound:
    """An `embed(text)` object whose engine is built, called and closed on one worker thread (LiteRT-LM requires it); callers
    block on the result."""

    def __init__(self, raw, pool: ThreadPoolExecutor) -> None:
        self._raw, self._pool = raw, pool

    def embed(self, text: str) -> list[float]:
        return self._pool.submit(self._raw.embed, text).result()


class EmbedHost:
    """Loads the query embedder (EmbeddingGemma on LiteRT-LM, or the hash stand-in with `fake`) off the event loop. A failure to
    load leaves `embedder` None: the search is then FTS only."""

    def __init__(self, *, fake: bool = False, no_embed: bool = False, model: str | None = None, backend: str = "gpu") -> None:
        self.fake, self.no_embed, self.model, self.backend = fake, no_embed, model, backend
        self.embedder: QueryEmbedder | None = None
        self._raw = None
        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="memory-query-embed")

    async def start(self) -> QueryEmbedder | None:
        if not self.no_embed:
            await asyncio.get_running_loop().run_in_executor(self._pool, self._load)
        return self.embedder

    def _load(self) -> None:
        from .embed import EmbedUnavailable
        from .me import model_sha

        try:
            if self.fake:
                from ..prep.me import HashEmbedder

                raw, sha = HashEmbedder(), "fake"
            else:
                from .embed import LiteRtEmbedder

                raw = LiteRtEmbedder(self.model or "", self.backend)
                sha = model_sha(self.model or "")
                if sha is None:
                    raise EmbedUnavailable("model file has no sha")
        except EmbedUnavailable as e:
            log.warning("query embeddings off: %s", e)
            return
        except Exception as e:  # noqa: BLE001
            log.warning("query embeddings off: %s", type(e).__name__)
            return
        self._raw = raw
        self.embedder = QueryEmbedder(_ThreadBound(raw, self._pool), sha)

    async def close(self) -> None:
        raw, self._raw, self.embedder = self._raw, None, None
        if raw is not None and hasattr(raw, "close"):
            try:
                await asyncio.get_running_loop().run_in_executor(self._pool, raw.close)
            except Exception as e:  # noqa: BLE001
                log.warning("embedder close failed: %s", type(e).__name__)
        self._pool.shutdown(wait=False)


# ---------------------------------------------------------------- emails never reach the model
_EMAIL = re.compile(r"[^\s@]*@[^\s@]*")


def redact_emails(text: str) -> str:
    """Cut anything that looks like an email address out of text bound for the model (a prep file or a note can carry one)."""
    return _EMAIL.sub("[email removed]", text)


# ---------------------------------------------------------------- grounding
def catalog_line(info: SessionInfo) -> str:
    """`sk3f9qa · Mon 19 Oct 2026 · meeting · Halden kickoff · with Marta Velin (Halden Works)` (the excerpt header without "== ";
    a label that looks like an email address is never sent)."""
    clean = dataclasses.replace(info, labels=[x for x in info.labels if "@" not in x])
    return header_line(clean)[len("== "):]


def render_catalog(*, owner: str, infos: list[SessionInfo], about: str | None, limit: int = MEMORY_CATALOG_MAX) -> str:
    """The one cached user block: SESSION CATALOG (newest first, at most `limit` lines, then a count of the older meetings) and
    ABOUT <OWNER> when the profile is on. A pure function of its arguments."""
    shown = infos[:limit]
    head = f"SESSION CATALOG ({len(infos)} meeting{'s' if len(infos) != 1 else ''}, newest first)"
    lines = [head, *(catalog_line(i) for i in shown)]
    if len(infos) > len(shown):
        lines.append(f"(and {len(infos) - len(shown)} older meetings, searched but not listed)")
    if not infos:
        lines.append("(no meetings)")
    parts = ["\n".join(lines)]
    if about is not None:
        parts.append(f"ABOUT {owner.upper()}\n{about.strip()}")
    return "\n\n".join(parts) + "\n"


# ---------------------------------------------------------------- chat file
def load_memory_history(path: Path) -> list[tuple[str, str, tuple[str, ...]]]:
    """The Q/A pairs after the last `reset`, oldest first, each with the session names its stored citations name. An `a_error` and
    its question, a question without an answer and an answer without text are skipped (as ask.load_history)."""
    if not path.is_file():
        return []
    qs: dict[str, str] = {}
    pairs: list[tuple[str, str, tuple[str, ...]]] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return []
    for ln in lines:
        if not ln.strip():
            continue
        try:
            rec = json.loads(ln)
        except json.JSONDecodeError:
            continue
        if not isinstance(rec, dict):
            continue
        t = rec.get("type")
        if t == "reset":
            qs, pairs = {}, []
        elif t == "q" and isinstance(rec.get("id"), str) and isinstance(rec.get("text"), str):
            qs[rec["id"]] = rec["text"]
        elif t == "a" and isinstance(rec.get("q"), str) and rec["q"] in qs and isinstance(rec.get("text"), str):
            if rec["text"].strip() and qs[rec["q"]].strip():
                cites = rec.get("citations")
                names = tuple(c["session"] for c in cites if isinstance(c, dict) and isinstance(c.get("session"), str)) \
                    if isinstance(cites, list) else ()
                pairs.append((qs[rec["q"]], rec["text"], names))
    return pairs


# ---------------------------------------------------------------- runtime
class MemoryAskRuntime(AskRuntime):
    def __init__(self, client, emitter, *, fake: bool = False, no_embed: bool = False, embed_model: str | None = None,
                 embed_backend: str = "gpu", history_pairs: int = MEMORY_HISTORY_PAIRS, **kw) -> None:
        super().__init__(client, emitter, history_pairs=history_pairs, **kw)
        self.mode = "memory"
        self.index: MemoryIndex | None = None
        self.scope: list[str] | None = None
        self.scope_kind = "all"
        self.scope_id = "all"
        self.scope_name = ""
        self.chat_file: Path | None = None
        self.embedder: QueryEmbedder | None = None
        self.host = EmbedHost(fake=fake, no_embed=no_embed, model=embed_model, backend=embed_backend)
        self.pairs: list[tuple[str, str, tuple[str, ...]]] = []     # (question, answer, cited session names)
        self.excerpt_tokens_last = 0

    # ------------------------------------------------------------------ files
    @property
    def chat_path(self) -> Path:
        assert self.chat_file is not None
        return self.chat_file

    def _append_chat(self, rec: dict) -> None:
        if rec.get("type") == "q":
            rec = {**rec, "scope": self.scope_id}
        super()._append_chat(rec)

    # ------------------------------------------------------------------ dispatch
    async def handle(self, msg: dict) -> None:
        t = msg.get("type")
        if t == "memory_ask_start":
            await self._start_memory(msg)
        elif t == "ask_start":
            return                      # a per-session chat is another process
        else:
            await super().handle(msg)
            if t == "control" and msg.get("action") == "reset":
                self.pairs = []

    async def shutdown(self) -> None:
        await super().shutdown()
        await self.host.close()
        if self.index is not None:
            self.index.close()
            self.index = None

    # ------------------------------------------------------------------ memory_ask_start
    async def _start_memory(self, msg: dict) -> None:
        await self._cancel()
        self.started = False
        db, chat = msg.get("db"), msg.get("chat")
        if not isinstance(db, str) or not db or not isinstance(chat, str) or not chat:
            self.emitter.status("error", "memory_ask_start needs db and chat")
            return
        scope = msg.get("scope") if isinstance(msg.get("scope"), dict) else {}
        kind = scope.get("kind")
        if kind not in ("all", "entity"):
            self.emitter.status("error", "unknown scope")
            return
        self.emitter.status("warming", "building the memory context")
        if self.index is not None:
            self.index.close()
            self.index = None
        try:
            self.index = MemoryIndex.open(Path(db).expanduser(), readonly=True)
        except IndexUnavailable as e:
            self.emitter.status("error", f"cannot read the memory index ({e})")
            return
        names = scope.get("sessions")
        self.scope_kind = kind
        self.scope = None if kind == "all" else [n for n in names if isinstance(n, str)] if isinstance(names, list) else []
        self.scope_id = "all" if kind == "all" else str(scope.get("id") or "entity")
        self.scope_name = " ".join(str(scope.get("name") or "").split())
        self.chat_file = Path(chat).expanduser()
        try:
            self.chat_file.parent.mkdir(parents=True, exist_ok=True)
        except OSError:
            self.emitter.status("error", "cannot write the chat folder")
            return
        self.owner = " ".join(str(msg.get("owner_name") or self.owner).split()) or self.owner
        self.model_key = msg.get("model") if msg.get("model") in ASK_MODELS else self.model_key
        about = None
        me = load_me(msg.get("me")) if msg.get("me") else None
        if me is not None:
            about = priorities_first(me.core)
        infos = self.index.sessions(self.scope)
        self.grounding = render_catalog(owner=self.owner, infos=infos, about=about)
        self.tokens = await self._count(self.grounding)
        self.embedder = await self.host.start()
        self.pairs = load_memory_history(self.chat_path)
        self.history = [(q, a) for q, a, _ in self.pairs][-self.history_pairs:]
        self.started = True
        self.emitter.status("ready", "", context={"tokens": self.tokens, "mode": "memory", "sessions": len(infos),
                                                  "history": len(self._usable_pairs())})

    def _system(self) -> str:
        return memory_system_text(self.owner, self.scope_kind, self.scope_name)

    async def _count(self, grounding: str) -> int:
        system = [{"type": "text", "text": self._system()}]
        messages = [{"role": "user", "content": [{"type": "text", "text": grounding}]}]
        try:
            return await self.client.count_tokens(PREP_MODEL, system, messages)
        except Exception as e:  # noqa: BLE001
            log.warning("count_tokens failed (%s); estimating", type(e).__name__)
            return math.ceil(len(grounding) / 3)

    # ------------------------------------------------------------------ request
    def _usable_pairs(self) -> list[tuple[str, str]]:
        """The last `history_pairs` pairs whose cited sessions are all still in the index (checked now: the index may have changed)."""
        live = {s.name for s in self.index.sessions(None)} if self.index is not None else set()
        ok = [(q, a) for q, a, cited in self.pairs if all(c in live for c in cited)]
        return ok[-self.history_pairs:] if self.history_pairs > 0 else []

    def build_request(self, model_key: str, question: str, history: list[tuple[str, str]] | None = None,
                      previous_question: str = "") -> dict:
        assert self.index is not None
        hist = self._usable_pairs() if history is None else history[-self.history_pairs:]
        req = ask_params(model_key)
        req["system"] = [{"type": "text", "text": self._system()}]
        query = question + " " + (previous_question or (hist[-1][0] if hist else ""))
        excerpts = search(self.index, query, scope=self.scope, embedder=self.embedder)
        self.excerpt_tokens_last = sum(ex.tokens for ex in excerpts)
        body = redact_emails(render_excerpts(excerpts)) or "(no matching passages in the meetings in scope)"
        tail = "EXCERPTS (the parts of the meetings above that match this question, newest meeting first)\n" + body \
            + "\n\nQUESTION\n" + question
        grounding_block = {"type": "text", "text": self.grounding, "cache_control": dict(EPHEMERAL)}
        messages: list[dict] = []
        if hist:
            messages.append({"role": "user", "content": [grounding_block, {"type": "text", "text": hist[0][0]}]})
            messages.append({"role": "assistant", "content": hist[0][1]})
            for q, a in hist[1:]:
                messages.append({"role": "user", "content": q})
                messages.append({"role": "assistant", "content": a})
            messages.append({"role": "user", "content": tail})
        else:
            messages.append({"role": "user", "content": [grounding_block, {"type": "text", "text": tail}]})
        req["messages"] = messages
        req["cache_control"] = dict(EPHEMERAL)
        return req

    # ------------------------------------------------------------------ answer
    def _finish(self, q_id: str, a_id: str, question: str, model_used: str, asked_model: str, answer: str, usage: dict,
                first_ms: int | None, t0: float, stop_reason: str) -> None:
        estimated = stop_reason == "cancelled"
        u = usage_of(usage)
        if estimated:
            u.output = math.ceil(len(answer) / 4)       # characters / 4: the stream did not report its final usage
        price_model = model_used if model_used in PRICES else asked_model
        cost = round(spend_usd(price_model, u), 6)
        ms_total = round((time.monotonic() - t0) * 1000)
        cites = resolve_citations(self.index, answer, self.scope) if self.index is not None else []
        self._append_chat({"type": "a", "id": a_id, "q": q_id, "t": now_iso(), "text": answer, "model": model_used,
                           "usage": u.as_dict(), "cost_usd": cost, "cost_estimated": estimated, "ms_first_token": first_ms,
                           "ms_total": ms_total, "citations": cites, "stop_reason": stop_reason, "context": "memory",
                           "excerpt_tokens": self.excerpt_tokens_last})
        self.emitter.emit({"type": "ask_done", "id": a_id, "q": q_id, "model": model_used, "usage": u.as_dict(),
                           "cost_usd": cost, "ms_first_token": first_ms, "ms_total": ms_total, "citations": cites,
                           "stop_reason": stop_reason, "cost_estimated": estimated, "excerpt_tokens": self.excerpt_tokens_last})
        if answer.strip():
            self.pairs.append((question, answer, tuple(c["session"] for c in cites)))
            self.history.append((question, answer))
            del self.history[:-self.history_pairs]
