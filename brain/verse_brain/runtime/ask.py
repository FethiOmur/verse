"""Ask this meeting: the chat runtime of one past session (docs/specs/2026-10-20-verse-five-features-design.md 2.2, 3.2, 3.3).

A process whose first message is `ask_start` runs this mode (runtime/__main__.py). It is never a command inside a live meeting's
brain: that process is latency-critical. One process serves one session's panel.

- Grounding: ONE cached user block, in this order: MEETING line, ABOUT <OWNER> (me.md, <OWNER>'S NOTES first; only when Swift sends
  `me`), MEETING PREP (pack.md without its STYLE GUIDE), SUMMARY, TRANSCRIPT. Rows come from Swift (`TranscriptDocument`); this module
  never recomputes stamps. The block is a pure function of its inputs, so every request of the chat shares its bytes.
- Prompt layout: frozen `system` -> messages[0] user = [grounding (cache_control)] + [question 1] -> answer 1 -> question 2 ... plus the
  top-level automatic `cache_control` (two breakpoints). History = the last `ASK_HISTORY_PAIRS` Q/A pairs after the last `reset` of
  `chat.jsonl`; older pairs drop from the front, which only invalidates the history after the grounding block.
- Long meetings: the grounding block is counted once at `ask_start` (free `count_tokens`). Up to `ASK_CONTEXT_MAX_TOKENS`: full
  mode. Above: chunked mode. The cached block then holds a TRANSCRIPT INDEX and each question carries TRANSCRIPT EXCERPTS, chunks of
  about 6k tokens cut on turn boundaries and ranked by BM25 over accent-folded words of the question plus the previous question. No
  extra model call.
- Billing: the key is read by `make_client()` through `prep.keychain.read_api_key()` (the Keychain item) and
  nowhere else; no other credential source is read in this file (a test greps it). The key is never put in an event, a log or the
  chat file.
- `chat.jsonl` is written by this runtime only: the question when received, the answer (or the error) when it ends, a `reset` line on
  `control reset`. Nothing is ever deleted.
"""

from __future__ import annotations

import asyncio
import json
import logging
import math
import re
import time
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from typing import AsyncIterator, Callable, Protocol

from ..owner import OWNER
from ..prep.keychain import read_api_key
from ..prep.model import PRICES, PREP_MODEL, Usage, spend_usd
from ..prep.voice import strip_voice
from .me import load_me, priorities_first
from .protocol import ASK_MODELS, Emitter
from .settings import ASK_CONTEXT_MAX_TOKENS, ASK_EXCERPT_TOKENS, ASK_HISTORY_PAIRS, ask_params
from .transport import TransportError, map_sdk_error

log = logging.getLogger("verse.runtime.ask")

EPHEMERAL = {"type": "ephemeral"}
DEFAULT_MODEL = "sonnet"
CHUNK_TOKENS = 6_000          # one excerpt chunk
INDEX_WINDOW_S = 600          # the transcript index: one entry per 10 minutes
INDEX_TURNS = 3               # ...with the first sentence of its first turns
TOKEN_CHARS = 3.5             # chars per token for budgets that must not call the API (chunk sizes, excerpt budget)
NO_PREP = "(none: unprepared call)"
NO_SUMMARY = "(none yet)"

# Frozen (golden test). `{owner}` / `{OWNER}` are the only variables.
SYSTEM_TEMPLATE = (
    "You answer {owner}'s questions about one past meeting or call. Use only the material in this conversation: the "
    "TRANSCRIPT (what was said, with timestamps), the SUMMARY written after the call, the MEETING PREP he made before it, "
    "and ABOUT {OWNER}. Rules: 1) Ground every statement about what was said in the transcript and cite the line's "
    "timestamp exactly as written, in square brackets, like [12:34]; at most three per claim. 2) Say who said it: {owner}, "
    "or the other side (\"Other\"; \"Room\" lines may be either). 3) If the material does not contain the answer, say so in "
    "one sentence. Never guess names, numbers, dates or commitments. 4) The transcript comes from speech recognition, so "
    "words can be wrong; when a key word looks misheard, say so. 5) The prep and profile tell you what {owner} knew and "
    "planned; they are not evidence that something was said. Mark what comes from them \"(from your prep)\" or \"(from your "
    "profile)\". 6) Answer in the language of the question. Answer directly first, then at most five \"- \" bullets. Plain "
    "text, no headings, no tables."
)


def system_text(owner: str) -> str:
    return SYSTEM_TEMPLATE.replace("{owner}", owner).replace("{OWNER}", owner.upper())


# ---------------------------------------------------------------- text helpers
def fold(s: str) -> str:
    """Case- and accent-insensitive with Turkish folding (the Swift `TextFold.fold`): lowercase, `İ`/`ı` -> i, diacritics out."""
    s = s.replace("İ", "i").replace("I", "i").replace("ı", "i").lower()
    return "".join(c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c))


_WORD = re.compile(r"\w+", re.UNICODE)


def fold_words(s: str) -> list[str]:
    return [w for w in _WORD.findall(fold(s)) if len(w) > 1 or w.isdigit()]


def est_tokens(text: str) -> int:
    return max(1, math.ceil(len(text) / TOKEN_CHARS))


_STAMP = re.compile(r"\[(\d{1,2}:\d{2}(?::\d{2})?)\]")


def stamp_seconds(stamp: str) -> int:
    parts = [int(p) for p in stamp.split(":")]
    sec = 0
    for p in parts:
        sec = sec * 60 + p
    return sec


def extract_citations(text: str, valid: set[str] | frozenset[str]) -> list[str]:
    """The `[m:ss]` / `[h:mm:ss]` stamps of an answer that exist in the transcript, in order of first appearance."""
    out: list[str] = []
    for m in _STAMP.finditer(text):
        s = m.group(1)
        if s in valid and s not in out:
            out.append(s)
    return out


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# ---------------------------------------------------------------- grounding
@dataclass(frozen=True)
class Row:
    stamp: str
    speaker: str
    text: str

    @property
    def line(self) -> str:
        return f"[{self.stamp}] {self.speaker}: {self.text}"


def parse_rows(raw: object) -> list[Row]:
    rows: list[Row] = []
    if not isinstance(raw, list):
        return rows
    for r in raw:
        if not isinstance(r, dict):
            continue
        stamp, speaker, text = r.get("stamp"), r.get("speaker"), r.get("text")
        if not (isinstance(stamp, str) and isinstance(speaker, str) and isinstance(text, str)):
            continue
        text = " ".join(text.split())          # one line per row
        if stamp and text:
            rows.append(Row(stamp, " ".join(speaker.split()) or "Other", text))
    return rows


def first_sentence(text: str, cap: int = 160) -> str:
    m = re.search(r"[.!?…](?:\s|$)", text)
    s = text[: m.end()].strip() if m else text.strip()
    return s if len(s) <= cap else s[: cap - 1].rstrip() + "…"


def render_index(rows: list[Row]) -> str:
    """TRANSCRIPT INDEX: per 10-minute window the stamp range and the first sentence of its first turns."""
    windows: dict[int, list[Row]] = {}
    for r in rows:
        windows.setdefault(stamp_seconds(r.stamp) // INDEX_WINDOW_S, []).append(r)
    out = ["TRANSCRIPT INDEX (the transcript is too long to include; the excerpts that match each question follow it)"]
    for w in sorted(windows):
        rs = windows[w]
        out.append(f"[{rs[0].stamp}-{rs[-1].stamp}]")
        out.extend(f"- {r.speaker}: {first_sentence(r.text)}" for r in rs[:INDEX_TURNS])
    return "\n".join(out)


def render_grounding(*, owner: str, title: str, date: str, about: str | None, pack: str, summary: str,
                     rows: list[Row], chunked: bool = False) -> str:
    """The one cached user block. A pure function of its arguments."""
    head = f"MEETING: {title.strip() or '(untitled)'}" + (f" ({date.strip()})" if date.strip() else "")
    parts = [head]
    if about is not None:
        parts.append(f"ABOUT {owner.upper()}\n{about.strip()}")
    parts.append("MEETING PREP\n" + (pack.strip() or NO_PREP))
    parts.append("SUMMARY\n" + (summary.strip() or NO_SUMMARY))
    if chunked:
        parts.append(render_index(rows))
    else:
        parts.append("TRANSCRIPT\n" + "\n".join(r.line for r in rows))
    return "\n\n".join(parts) + "\n"


# ---------------------------------------------------------------- chunks and BM25
@dataclass
class Chunk:
    index: int
    rows: list[Row]
    text: str
    tokens: int
    tf: dict[str, int] = field(default_factory=dict)
    length: int = 0


def make_chunks(rows: list[Row], chunk_tokens: int = CHUNK_TOKENS) -> list[Chunk]:
    """Chunks of about `chunk_tokens` (estimated), cut on turn boundaries. A row longer than a chunk is a chunk of its own."""
    groups: list[list[Row]] = []
    cur: list[Row] = []
    cur_tokens = 0
    for r in rows:
        t = est_tokens(r.line)
        if cur and cur_tokens + t > chunk_tokens:
            groups.append(cur)
            cur, cur_tokens = [], 0
        cur.append(r)
        cur_tokens += t
    if cur:
        groups.append(cur)
    out: list[Chunk] = []
    for i, g in enumerate(groups):
        text = "\n".join(r.line for r in g)
        words = fold_words(text)
        tf: dict[str, int] = {}
        for w in words:
            tf[w] = tf.get(w, 0) + 1
        out.append(Chunk(i, g, text, est_tokens(text), tf, len(words)))
    return out


def bm25_scores(chunks: list[Chunk], query: str, k1: float = 1.5, b: float = 0.75) -> list[float]:
    q = sorted(set(fold_words(query)))
    n = len(chunks)
    if not chunks or not q:
        return [0.0] * n
    avg = (sum(c.length for c in chunks) / n) or 1.0
    scores = [0.0] * n
    for w in q:
        df = sum(1 for c in chunks if w in c.tf)
        if not df:
            continue
        idf = math.log(1 + (n - df + 0.5) / (df + 0.5))
        for i, c in enumerate(chunks):
            f = c.tf.get(w, 0)
            if f:
                scores[i] += idf * f * (k1 + 1) / (f + k1 * (1 - b + b * c.length / avg))
    return scores


def select_chunks(chunks: list[Chunk], query: str, budget_tokens: int) -> list[Chunk]:
    """The best chunks for the query up to the budget, returned in time order. A query that shares no word with any chunk gets the
    leading chunks (the budget still applies)."""
    scores = bm25_scores(chunks, query)
    order = sorted((i for i in range(len(chunks)) if scores[i] > 0), key=lambda i: (-scores[i], i))
    if not order:
        order = list(range(len(chunks)))
    picked: list[int] = []
    used = 0
    for i in order:
        if used + chunks[i].tokens <= budget_tokens:
            picked.append(i)
            used += chunks[i].tokens
    return [chunks[i] for i in sorted(picked)]


def render_excerpts(selected: list[Chunk]) -> str:
    out = ["TRANSCRIPT EXCERPTS (the parts of the transcript that match this question, in time order; stamps as in the transcript)"]
    prev = None
    for c in selected:
        if prev is not None and c.index != prev + 1:
            out.append("[...]")
        out.append(c.text)
        prev = c.index
    return "\n".join(out)


# ---------------------------------------------------------------- chat.jsonl
def load_history(path: Path, limit: int = ASK_HISTORY_PAIRS) -> list[tuple[str, str]]:
    """The Q/A pairs after the last `reset`, oldest first, capped at the last `limit`. An `a_error` and its question, a question
    without an answer and an answer without text are skipped."""
    if not path.is_file():
        return []
    qs: dict[str, str] = {}
    pairs: list[tuple[str, str]] = []
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
                pairs.append((qs[rec["q"]], rec["text"]))
    return pairs[-limit:] if limit > 0 else []


# ---------------------------------------------------------------- model client
@dataclass
class AskEv:
    kind: str                     # start | text | stop
    text: str = ""
    stop_reason: str | None = None
    usage: dict = field(default_factory=dict)
    model: str | None = None


class AskClient(Protocol):
    def stream(self, request: dict) -> AsyncIterator[AskEv]: ...

    async def count_tokens(self, model: str, system: list[dict], messages: list[dict]) -> int: ...

    async def aclose(self) -> None: ...


def _int_usage(obj) -> dict:
    if obj is None:
        return {}
    d = obj.model_dump() if hasattr(obj, "model_dump") else dict(obj)
    return {k: v for k, v in d.items() if isinstance(v, int)}


class AnthropicAskClient:
    """The real client (Anthropic SDK). `beta.messages.stream` when the request carries `betas` (Sonnet and Opus: the server-side
    fallback), `messages.stream` otherwise (Haiku). Errors are mapped with `transport.map_sdk_error`."""

    def __init__(self, api_key: str) -> None:
        import anthropic
        import httpx2

        http = anthropic.DefaultAsyncHttpxClient(
            http2=True, limits=httpx2.Limits(max_connections=4, max_keepalive_connections=4, keepalive_expiry=300))
        self._client = anthropic.AsyncAnthropic(api_key=api_key, http_client=http,
                                                timeout=anthropic.Timeout(120.0, connect=10.0))

    async def stream(self, request: dict) -> AsyncIterator[AskEv]:
        ns = self._client.beta.messages if request.get("betas") else self._client.messages
        usage: dict = {}
        stop_reason = None
        try:
            async with ns.stream(**request) as s:
                async for ev in s:
                    et = ev.type
                    if et == "message_start":
                        usage = _int_usage(ev.message.usage)
                        yield AskEv("start", usage=dict(usage), model=getattr(ev.message, "model", None))
                    elif et == "content_block_delta":
                        d = ev.delta
                        if getattr(d, "type", None) == "text_delta":
                            yield AskEv("text", text=d.text)
                    elif et == "message_delta":
                        usage.update(_int_usage(ev.usage))
                        stop_reason = getattr(ev.delta, "stop_reason", None)
        except TransportError:
            raise
        except Exception as e:  # noqa: BLE001
            raise map_sdk_error(e) from None
        yield AskEv("stop", stop_reason=stop_reason, usage=usage)

    async def count_tokens(self, model: str, system: list[dict], messages: list[dict]) -> int:
        try:
            r = await self._client.messages.count_tokens(model=model, system=system, messages=messages)
        except Exception as e:  # noqa: BLE001
            raise map_sdk_error(e) from None
        return int(r.input_tokens)

    async def aclose(self) -> None:
        try:
            await self._client.close()
        except Exception:  # noqa: BLE001
            pass


def make_client(fake: bool = False) -> AskClient:
    """The Keychain key (prep/keychain.py, service verse-anthropic) is the only credential. Raises KeychainError when it is missing."""
    if fake:
        return FakeAskClient()
    return AnthropicAskClient(read_api_key())


# ---------------------------------------------------------------- fake client (tests, --fake)
@dataclass
class AskScript:
    chunks: list[tuple[float, str]] = field(default_factory=list)     # (delay before chunk, text)
    first_byte_delay: float = 0.0
    stop_reason: str = "end_turn"
    error: TransportError | None = None
    model: str | None = None
    usage: dict = field(default_factory=lambda: {"input_tokens": 412, "output_tokens": 388,
                                                 "cache_read_input_tokens": 31240, "cache_creation_input_tokens": 0})


def words_script(text: str, **kw) -> AskScript:
    return AskScript(chunks=[(0.0, p) for p in re.findall(r" ?[^ \n]+|\n", text)], **kw)


def default_ask_responder(request: dict, n: int) -> AskScript:
    """Canned answer: cites the first stamp of the grounding block so the citation path is exercised."""
    try:
        first = request["messages"][0]["content"][0]["text"]
        m = re.search(r"^\[(\d{1,2}:\d{2}(?::\d{2})?)\] ", first, re.M)
        stamp = m.group(1) if m else None
    except (KeyError, IndexError, TypeError):
        stamp = None
    cite = f" [{stamp}]" if stamp else ""
    return words_script(f"Fake answer {n}: it was said near the start{cite}.\n- First point.\n- Second point.",
                        model=request.get("model"))


class FakeAskClient:
    """Scriptable fake: `responder(request, n) -> AskScript`. Records every request. `token_counter(model, system, messages)`
    answers `count_tokens` (default: characters / 4)."""

    def __init__(self, responder: Callable[[dict, int], AskScript] | None = None,
                 token_counter: Callable[[str, list[dict], list[dict]], int] | None = None) -> None:
        self.responder = responder or default_ask_responder
        self.token_counter = token_counter
        self.requests: list[dict] = []
        self.counts: list[tuple[str, list[dict], list[dict]]] = []
        self.closed = False

    async def stream(self, request: dict) -> AsyncIterator[AskEv]:
        import copy

        self.requests.append(copy.deepcopy(request))
        script = self.responder(request, len(self.requests))
        if script.first_byte_delay:
            await asyncio.sleep(script.first_byte_delay)
        if script.error is not None:
            raise script.error
        yield AskEv("start", usage={k: v for k, v in script.usage.items() if k != "output_tokens"},
                    model=script.model or request.get("model"))
        for delay, text in script.chunks:
            if delay:
                await asyncio.sleep(delay)
            yield AskEv("text", text=text)
        yield AskEv("stop", stop_reason=script.stop_reason, usage=dict(script.usage))

    async def count_tokens(self, model: str, system: list[dict], messages: list[dict]) -> int:
        self.counts.append((model, system, messages))
        if self.token_counter is not None:
            return self.token_counter(model, system, messages)
        return len(json.dumps(messages, ensure_ascii=False)) // 4

    async def aclose(self) -> None:
        self.closed = True


# ---------------------------------------------------------------- runtime
def usage_of(u: dict) -> Usage:
    return Usage(input=u.get("input_tokens", 0) or 0, output=u.get("output_tokens", 0) or 0,
                 cache_read=u.get("cache_read_input_tokens", 0) or 0,
                 cache_write=u.get("cache_creation_input_tokens", 0) or 0)


def error_kind(e: BaseException) -> str:
    if isinstance(e, TransportError) and e.kind in {"credit_exhausted", "offline", "rate_limited", "overloaded", "auth",
                                                    "bad_request"}:
        return e.kind
    return "error"


class AskRuntime:
    def __init__(self, client: AskClient, emitter: Emitter, *, context_max: int = ASK_CONTEXT_MAX_TOKENS,
                 excerpt_tokens: int = ASK_EXCERPT_TOKENS, history_pairs: int = ASK_HISTORY_PAIRS,
                 chunk_tokens: int = CHUNK_TOKENS) -> None:
        self.client = client
        self.emitter = emitter
        self.context_max = context_max
        self.excerpt_tokens = excerpt_tokens
        self.history_pairs = history_pairs
        self.chunk_tokens = chunk_tokens
        self.stopped = asyncio.Event()
        self.started = False
        self.session_dir: Path | None = None
        self.owner = OWNER.display_name
        self.rows: list[Row] = []
        self.stamps: frozenset[str] = frozenset()
        self.grounding = ""
        self.mode = "full"
        self.tokens = 0
        self.chunks: list[Chunk] = []
        self.model_key = DEFAULT_MODEL
        self.history: list[tuple[str, str]] = []
        self._task: asyncio.Task | None = None
        self._cancelled = False
        self._busy_q: str | None = None

    # ------------------------------------------------------------------ files
    @property
    def chat_path(self) -> Path:
        assert self.session_dir is not None
        return self.session_dir / "chat.jsonl"

    def _append_chat(self, rec: dict) -> None:
        try:
            with open(self.chat_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
        except OSError as e:
            log.warning("chat.jsonl not written: %s", type(e).__name__)

    # ------------------------------------------------------------------ dispatch
    async def handle(self, msg: dict) -> None:
        t = msg.get("type")
        if t == "ask_start":
            await self._start(msg)
        elif t == "ask":
            self._on_ask(msg)
        elif t == "control":
            a = msg.get("action")
            if a == "cancel":
                await self._cancel()
            elif a == "reset":
                await self._cancel()
                if self.started:
                    self._append_chat({"type": "reset", "t": now_iso()})
                    self.history = []
            elif a == "stop":
                await self._cancel()
                self.stopped.set()

    async def shutdown(self) -> None:
        await self._cancel(quiet=True)
        await self.client.aclose()

    # ------------------------------------------------------------------ ask_start
    async def _start(self, msg: dict) -> None:
        await self._cancel()
        self.started = False
        sd = msg.get("session_dir")
        if not isinstance(sd, str) or not Path(sd).expanduser().is_dir():
            self.emitter.status("error", "cannot read the session folder")
            return
        self.session_dir = Path(sd).expanduser()
        self.owner = " ".join(str(msg.get("owner_name") or OWNER.display_name).split()) or OWNER.display_name
        self.model_key = msg.get("model") if msg.get("model") in ASK_MODELS else DEFAULT_MODEL
        self.rows = parse_rows(msg.get("transcript"))
        self.stamps = frozenset(r.stamp for r in self.rows)
        self.emitter.status("warming", "building the meeting context")
        pack = strip_voice(self._read("pack.md"))
        summary = self._read("summary.md")
        about = None
        me = load_me(msg.get("me")) if msg.get("me") else None
        if me is not None:
            about = priorities_first(me.core)
        meta = dict(owner=self.owner, title=str(msg.get("title") or ""), date=str(msg.get("date") or ""),
                    about=about, pack=pack, summary=summary, rows=self.rows)
        full = render_grounding(**meta)
        self.tokens = await self._count(full)
        if self.tokens <= self.context_max:
            self.mode, self.grounding, self.chunks = "full", full, []
        else:
            self.mode = "chunked"
            self.grounding = render_grounding(**meta, chunked=True)
            self.chunks = make_chunks(self.rows, self.chunk_tokens)
        self.history = load_history(self.chat_path, self.history_pairs)
        self.started = True
        self.emitter.status("ready", "", context={"tokens": self.tokens, "mode": self.mode, "rows": len(self.rows),
                                                  "history": len(self.history)})

    def _read(self, name: str) -> str:
        try:
            return (self.session_dir / name).read_text(encoding="utf-8")   # type: ignore[operator]
        except (OSError, UnicodeDecodeError):
            return ""

    async def _count(self, grounding: str) -> int:
        """Tokens of the full grounding block, counted once on Sonnet (free). If the count fails, a conservative estimate."""
        system = [{"type": "text", "text": system_text(self.owner)}]
        messages = [{"role": "user", "content": [{"type": "text", "text": grounding}]}]
        try:
            return await self.client.count_tokens(PREP_MODEL, system, messages)
        except Exception as e:  # noqa: BLE001
            log.warning("count_tokens failed (%s); estimating", type(e).__name__)
            return math.ceil(len(grounding) / 3)

    # ------------------------------------------------------------------ request
    def build_request(self, model_key: str, question: str, history: list[tuple[str, str]] | None = None,
                      previous_question: str = "") -> dict:
        hist = self.history if history is None else history
        hist = hist[-self.history_pairs:] if self.history_pairs > 0 else []
        req = ask_params(model_key)
        req["system"] = [{"type": "text", "text": system_text(self.owner)}]
        tail = question
        if self.mode == "chunked":
            query = question + " " + (previous_question or (hist[-1][0] if hist else ""))
            sel = select_chunks(self.chunks, query, self.excerpt_tokens)
            tail = render_excerpts(sel) + "\n\nQUESTION\n" + question
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

    # ------------------------------------------------------------------ ask
    def _on_ask(self, msg: dict) -> None:
        q_id = str(msg.get("id") or "")
        text = msg.get("text")
        a_id = ("a" + q_id[1:]) if q_id.startswith("q") else ("a" + q_id)
        if not self.started:
            self.emitter.emit({"type": "ask_error", "id": a_id, "q": q_id, "kind": "bad_request",
                               "message": "ask_start has not completed"})
            return
        if not q_id or not isinstance(text, str) or not text.strip():
            self.emitter.emit({"type": "ask_error", "id": a_id, "q": q_id, "kind": "bad_request", "message": "empty question"})
            return
        if self._task is not None and not self._task.done():
            self.emitter.emit({"type": "ask_error", "id": a_id, "q": q_id, "kind": "bad_request",
                               "message": "an answer is already streaming"})
            return
        if msg.get("model") in ASK_MODELS:
            self.model_key = msg["model"]
        params = ask_params(self.model_key)
        self._append_chat({"type": "q", "id": q_id, "t": now_iso(), "text": text, "model": params["model"]})
        self._cancelled = False
        self._task = asyncio.get_running_loop().create_task(self._answer(q_id, a_id, text.strip(), self.model_key))

    async def _cancel(self, quiet: bool = False) -> None:
        t = self._task
        if t is not None and not t.done():
            self._cancelled = not quiet
            t.cancel()
            await asyncio.gather(t, return_exceptions=True)

    async def _answer(self, q_id: str, a_id: str, text: str, model_key: str) -> None:
        req = self.build_request(model_key, text)
        asked_model = req["model"]
        t0 = time.monotonic()
        parts: list[str] = []
        usage: dict = {}
        model_used = asked_model
        first_ms: int | None = None
        stop_reason: str | None = None
        agen = self.client.stream(req)
        try:
            async for ev in agen:
                if ev.kind == "start":
                    usage = dict(ev.usage)
                    model_used = ev.model or asked_model
                elif ev.kind == "text":
                    if first_ms is None:
                        first_ms = round((time.monotonic() - t0) * 1000)
                    parts.append(ev.text)
                    self.emitter.emit({"type": "ask_delta", "id": a_id, "q": q_id, "text": ev.text})
                elif ev.kind == "stop":
                    stop_reason = ev.stop_reason
                    usage = dict(ev.usage) or usage
        except asyncio.CancelledError:
            if not self._cancelled:
                raise
            self._finish(q_id, a_id, text, model_used, asked_model, "".join(parts), usage, first_ms, t0, "cancelled")
            return
        except TransportError as e:
            self._error(q_id, a_id, error_kind(e), str(e)[:200] or type(e).__name__, getattr(e, "retry_after", None))
            return
        except Exception as e:  # noqa: BLE001
            log.warning("ask failed: %s", type(e).__name__)
            self._error(q_id, a_id, "error", type(e).__name__)
            return
        finally:
            try:
                await agen.aclose()      # type: ignore[attr-defined]
            except Exception:  # noqa: BLE001
                pass
        if stop_reason == "refusal":
            self._error(q_id, a_id, "refusal", "the model declined to answer this question")
            return
        self._finish(q_id, a_id, text, model_used, asked_model, "".join(parts), usage, first_ms, t0, stop_reason or "end_turn")

    def _error(self, q_id: str, a_id: str, kind: str, message: str, retry_after: float | None = None) -> None:
        self._append_chat({"type": "a_error", "id": a_id, "q": q_id, "t": now_iso(), "kind": kind, "message": message})
        ev = {"type": "ask_error", "id": a_id, "q": q_id, "kind": kind, "message": message}
        if retry_after is not None:
            ev["retry_after"] = retry_after
        self.emitter.emit(ev)

    def _finish(self, q_id: str, a_id: str, question: str, model_used: str, asked_model: str, answer: str, usage: dict,
                first_ms: int | None, t0: float, stop_reason: str) -> None:
        estimated = stop_reason == "cancelled"
        u = usage_of(usage)
        if estimated:
            u.output = math.ceil(len(answer) / 4)       # characters / 4: the stream did not report its final usage
        price_model = model_used if model_used in PRICES else asked_model
        cost = round(spend_usd(price_model, u), 6)
        ms_total = round((time.monotonic() - t0) * 1000)
        cites = extract_citations(answer, self.stamps)
        self._append_chat({"type": "a", "id": a_id, "q": q_id, "t": now_iso(), "text": answer, "model": model_used,
                           "usage": u.as_dict(), "cost_usd": cost, "cost_estimated": estimated, "ms_first_token": first_ms,
                           "ms_total": ms_total, "citations": cites, "stop_reason": stop_reason, "context": self.mode})
        self.emitter.emit({"type": "ask_done", "id": a_id, "q": q_id, "model": model_used, "usage": u.as_dict(),
                           "cost_usd": cost, "ms_first_token": first_ms, "ms_total": ms_total, "citations": cites,
                           "stop_reason": stop_reason, "cost_estimated": estimated})
        if answer.strip():
            self.history.append((question, answer))
            del self.history[:-self.history_pairs]
