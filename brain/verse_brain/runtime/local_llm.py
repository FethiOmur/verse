"""G1: local Gemma 4 E4B (LiteRT-LM, in process) as the degraded-mode brain.

Used only through `fallback.FallbackTransport`, and only while the API is offline, rate-limited or out of credit.
Nothing here is imported or loaded while the API is healthy (unless `Config.local_prewarm` is on).

Runtime and settings are the ones that won the F6 bench (`bench/llm-local`): GPU backend, FLOAT32 activations (the default
GPU activations corrupt digits, "11 minutes" came out as "111"), `max_num_tokens` 8192, compiled-model cache next to the
model, sampler top_k 40 / top_p 0.9 / temperature 0.4 / seed 1, thinking off, 120 output tokens. Measured there with the
KV of the prefix already in the conversation: first token 0.5-0.7 s, first SAY line 1.0-1.3 s; the first message of a
conversation pays the prefill of the whole prompt (2.1k tokens 5 s, 3.6k tokens 9-15 s, 4.9k tokens 12-19 s).

How a stateless Anthropic request becomes a stateful Gemma conversation (the only way LiteRT-LM keeps a KV prefix):
- One long-lived `Conversation` holds system prompt + trimmed pack + the transcript so far. The first message carries
  all of that plus the question; every later request sends only the finalized turns that are new since the last
  message and the question tail. The KV of everything before it is reused. A request whose transcript does not extend
  the conversation's (another session, a retried older turn) builds a fresh conversation (cold prefill).
- After `local_recycle_tokens` of KV the conversation is rebuilt in the background right after an answer (between
  questions), so the cold prefill is not paid on a live question.
- `prime()` does the prefill ahead of time (message ends with "reply READY"), at failure detection or, with
  `local_prewarm`, at session start.

What does not carry over (documented degradation, nothing is faked):
- prompt caching (`cache_control`), thinking/effort settings, betas and server-side fallbacks are ignored; tools are not
  used by the runtime.
- S (speculation on partials): not served, raises `LocalSkipped` (the engine already treats a failed S as absent and
  fires F at the endpoint, which is what Gemma then answers). One GPU, serial: speculation would only delay F.
- F: served, SAY + two points + BANK, also the statement probe (`KIND:` line).
- D (deep detail points, opener verdict): not run locally, an empty successful stream (F's two points stand in).
- R (rolling summary): `LocalSkipped` (silent in the engine). A (final summary at stop): `LocalUnsupported`, the engine
  writes the rolling notes with `draft_reason`.

Trimming (from the bench prompts): pack cut to `local_pack_chars` (9500, the size of the p3k bench pack whose answers
were scored): SNIPPETS dropped first, FACTS, GLOSSARY and the voice section kept whole, ANSWER BANK entries kept in order
until the budget is full. The cut entries are not lost: the 1-2 best matches for the question (word overlap) are added to
that request's message. Transcript at (re)build: newest turns first, at most `local_max_turns` and `local_turn_chars`.
If the prompt still exceeds ctx - 2500 tokens (real tokenizer) the pack budget and the oldest turns shrink further.

Threading: every LiteRT-LM call runs on one dedicated worker thread (build, send, close), the same rule as the
EmbeddingGemma path. Failures inside Gemma (exception, no first token in `local_first_token_s`, over `local_total_s`)
cancel the process and raise `LocalFailed`, a `TransportError`, so the engine reports a normal status error.
"""

from __future__ import annotations

import asyncio
import hashlib
import importlib.util
import logging
import os
import re
import resource
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Any, AsyncIterator, Callable, Iterator, Protocol

from .prompt import NO_PACK_LINE, PACK_HEADER, TRANSCRIPT_HEADER, WARMUP_TAIL
from .settings import Config
from .transport import TransportError

log = logging.getLogger("verse.runtime.local")

PRIME_TAIL = ("Language: English\nPRIMING: the meeting has not started yet. Do not answer anything. "
              "Reply with the single word READY.")
FOLLOWUP_HEADER = "NEW TURNS SINCE YOUR LAST ANSWER (finalized):"
EXTRA_HEADER = "OTHER ANSWER-BANK ENTRIES THAT MAY FIT THIS QUESTION (not in the pack above):"
MIN_BANK_CHARS = 1500       # room kept for the bank when FACTS + GLOSSARY + voice alone are over budget
CTX_HEADROOM_TOKENS = 2500  # reply + follow-ups must fit after the first message


class LocalUnavailable(Exception):
    """Gemma cannot be used on this machine (model or library missing, engine failed to load)."""


class LocalFailed(TransportError):
    kind = "local_error"


class LocalSkipped(TransportError):
    kind = "local_skipped"


class LocalUnsupported(TransportError):
    kind = "local_unsupported"


# ---------------------------------------------------------------------------------------------------- request parts
def classify(route: str, request: dict) -> str:
    """answer (F) | speculation (S on a partial) | deep (D) | rolling (R) | final (A) | warm (pre-warm/keep-alive)."""
    tail = tail_text(request)
    if tail.startswith("SUMMARIZE-INCREMENTAL"):
        return "rolling"
    if tail.startswith("SUMMARIZE-FINAL"):
        return "final"
    if tail == WARMUP_TAIL:
        return "warm"
    if route == "D":
        return "deep"
    if route == "S":
        return "speculation"
    return "answer"


def tail_text(request: dict) -> str:
    try:
        return request["messages"][-1]["content"][-1]["text"]
    except (KeyError, IndexError, TypeError):
        return ""


@dataclass
class Parts:
    system: str
    pack: str
    turns: list[str]
    tail: str
    me: str = ""      # the ABOUT OWNER block (the second system block of a session with the me layer), "" without


def split_request(request: dict) -> Parts:
    """The Anthropic request of runtime/prompt.py back into system, ABOUT OWNER, pack, turn blocks and tail."""
    sys_blocks = [b.get("text", "") for b in request.get("system", [])]
    system, me = ("".join(sys_blocks), "") if len(sys_blocks) < 2 else (sys_blocks[0], "".join(sys_blocks[1:]))
    blocks = [b.get("text", "") for b in request["messages"][0]["content"]]
    head, turns, tail = blocks[0], blocks[1:-1], blocks[-1]
    if head.startswith(PACK_HEADER):
        head = head[len(PACK_HEADER):]
    if head.endswith(TRANSCRIPT_HEADER):
        head = head[:-len(TRANSCRIPT_HEADER)]
    return Parts(system, head, turns, tail, me)


# ---------------------------------------------------------------------------------------------------- pack trimming
_STOP = frozenset("""about above after again also another because been before being between could does doing during each
from have having here into just more most much only other over really same should some such than that their them then
there these they this those through under very what when where which while will with would your you tell please give
can did how why who whom was were are the and for not but our out any""".split())
_WORD = re.compile(r"[a-z0-9']+")


@dataclass
class BankEntry:
    id: str
    text: str
    words: frozenset = field(default_factory=frozenset)


def _content_words(s: str) -> set[str]:
    return {w for w in _WORD.findall(s.lower()) if len(w) > 3 and w not in _STOP}


def split_sections(pack: str) -> list[tuple[str, str]]:
    """[(heading line, section text incl. heading)] in order; text before the first heading gets an empty heading."""
    out: list[tuple[str, list[str]]] = []
    for line in pack.split("\n"):
        if line.startswith("## ") or not out:
            out.append((line if line.startswith("## ") else "", [line]))
        else:
            out[-1][1].append(line)
    return [(h, "\n".join(ls)) for h, ls in out]


_ENTRY = re.compile(r"(?m)^(?=\[b\d+\])")


def split_bank(section: str) -> tuple[str, list[str]]:
    """(heading, entries) of the ANSWER BANK section; each entry keeps its trailing newline-free text."""
    head, _, body = section.partition("\n")
    return head, [e.rstrip("\n") for e in _ENTRY.split(body) if e.strip()]


def _shrink_lines(section: str, to_chars: int) -> str:
    lines = section.split("\n")
    while len(lines) > 2 and len("\n".join(lines)) > to_chars:
        lines.pop()
    return "\n".join(lines)


def trim_pack(pack: str, max_chars: int) -> tuple[str, list[BankEntry]]:
    """Pack cut to `max_chars` (the bench's p2k/p3k rule, section aware). Returns the text and the bank entries cut."""
    if len(pack) <= max_chars:
        return pack, []
    secs = [(h, t) for h, t in split_sections(pack) if not h.upper().startswith("## SNIPPETS")]
    bank_i = next((i for i, (h, _) in enumerate(secs) if h.upper().startswith("## ANSWER BANK")), None)
    fixed = sum(len(t) + 1 for i, (_, t) in enumerate(secs) if i != bank_i)
    if fixed > max_chars - MIN_BANK_CHARS:   # facts + glossary + voice alone fill the budget: shorten the long ones
        over = fixed - (max_chars - MIN_BANK_CHARS)
        for h_prefix in ("## GLOSSARY", "## FACTS"):
            for i, (h, t) in enumerate(secs):
                if i != bank_i and h.upper().startswith(h_prefix) and over > 0:
                    new = _shrink_lines(t, max(len(t) - over, 200))
                    over -= len(t) - len(new)
                    secs[i] = (h, new)
        fixed = sum(len(t) + 1 for i, (_, t) in enumerate(secs) if i != bank_i)
    dropped: list[BankEntry] = []
    if bank_i is not None:
        head, entries = split_bank(secs[bank_i][1])
        room = max(max_chars - fixed - len(head) - 1, 0)
        kept, used = [], 0
        for e in entries:
            if used + len(e) + 1 <= room:
                kept.append(e)
                used += len(e) + 1
            else:
                m = re.match(r"\[(b\d+)\]", e)
                dropped.append(BankEntry(m.group(1) if m else "", e, frozenset(_content_words(e))))
        secs[bank_i] = (head, head + ("\n" + "\n".join(kept) if kept else ""))
    return "\n".join(t for _, t in secs), dropped


_QUESTION = re.compile(r"CURRENT (?:QUESTION|TURN) \([^)]*\):\s*(.*)\Z", re.S)


def question_of(tail: str) -> str:
    m = _QUESTION.search(tail)
    return m.group(1) if m else tail


def retrieve(entries: list[BankEntry], question: str, k: int) -> list[BankEntry]:
    """The `k` cut bank entries that share the most content words with the question (at least 2 shared words)."""
    if k <= 0 or not entries:
        return []
    qw = _content_words(question)
    scored = []
    for e in entries:
        first = e.text.split("\n", 1)[0]
        s = len(qw & e.words) + len(qw & _content_words(first))   # words of the entry's question count double
        if s >= 2:
            scored.append((s, e))
    scored.sort(key=lambda x: -x[0])
    return [e for _, e in scored[:k]]


ME_WITH_PACK = ("WHO I AM", "NUMBERS", "PROJECTS")                 # what stays of the me layer next to a pack
ME_TRIM_ORDER = ("STORIES", "SKILLS", "PROJECTS", "EXPERIENCE")    # unprepared: the build's trim order (tail first)


def _sec_name(heading: str) -> str:
    return heading[3:].split(" (")[0].strip().upper() if heading.startswith("## ") else ""


def trim_me(block: str, max_chars: int, with_pack: bool) -> str:
    """The ABOUT OWNER block cut for Gemma (spec 2.2, local fallback). Next to a pack: only WHO I AM + NUMBERS + PROJECTS, in
    `max_chars`. Unprepared: the whole core in `max_chars` by the build's trim order (STORIES, SKILLS, PROJECTS, EXPERIENCE
    tails); the STYLE GUIDE section, when there is one, stays whole and does not count."""
    secs = split_sections(block)
    style = [i for i, (h, _) in enumerate(secs) if _sec_name(h) == "STYLE GUIDE"]
    if with_pack:
        keep = [i for i, (h, _) in enumerate(secs) if h == "" or _sec_name(h) in ME_WITH_PACK]
        order = ("PROJECTS", "NUMBERS", "WHO I AM")
    else:
        keep = list(range(len(secs)))
        order = ME_TRIM_ORDER
    texts = {i: secs[i][1] for i in keep}
    counted = [i for i in keep if i not in style]
    total = sum(len(texts[i]) + 1 for i in counted)
    for name in order:
        for i in counted:
            over = total - max_chars
            if over <= 0:
                break
            if _sec_name(secs[i][0]) == name:
                new = _shrink_lines(texts[i], max(len(texts[i]) - over, 80))
                total -= len(texts[i]) - len(new)
                texts[i] = new
    return "\n".join(texts[i] for i in keep)


# ---------------------------------------------------------------------------------------------------- backend glue
class Conv(Protocol):
    def send(self, text: str) -> Iterator[str]: ...

    def token_count(self) -> int: ...

    def cancel(self) -> None: ...

    def close(self) -> None: ...


class Backend(Protocol):
    def load(self) -> None: ...

    def count_tokens(self, text: str) -> int: ...

    def new_conv(self, system: str) -> Conv: ...

    def close(self) -> None: ...


def _piece(chunk: Any) -> str:
    c = chunk.get("content", []) if hasattr(chunk, "get") else []
    if isinstance(c, str):
        return c
    return "".join(i.get("text", "") for i in c if isinstance(i, dict) and i.get("type") == "text")


class _LiteConv:
    def __init__(self, conv, token_count_fn) -> None:
        self._c = conv
        self._tc = token_count_fn

    def send(self, text: str) -> Iterator[str]:
        for chunk in self._c.send_message_async(text):
            p = _piece(chunk)
            if p:
                yield p

    def token_count(self) -> int:
        return int(self._c.token_count)

    def cancel(self) -> None:
        self._c.cancel_process()

    def close(self) -> None:
        try:
            self._c.__exit__(None, None, None)
        except Exception:  # noqa: BLE001
            pass


class LiteRtBackend:
    """litert_lm.Engine with the F6 settings. Build, use and close on the same thread."""

    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self.path = os.path.expanduser(cfg.local_model)
        self._lm = None
        self._eng = None

    def load(self) -> None:
        if not os.path.isfile(self.path):
            raise LocalUnavailable(f"model not found: {self.path}")
        try:
            import litert_lm  # noqa: PLC0415 - optional, loaded only when the fallback is used
        except ImportError as e:
            raise LocalUnavailable(f"litert_lm not importable: {e}") from e
        try:
            litert_lm.set_min_log_severity(litert_lm.LogSeverity.ERROR)
            be = litert_lm.Backend.GPU() if self.cfg.local_backend == "gpu" else litert_lm.Backend.CPU()
            cache = os.path.join(os.path.dirname(self.path), "cache")
            os.makedirs(cache, exist_ok=True)
            kw = {}
            if self.cfg.local_activation:
                kw["activation_data_type"] = getattr(litert_lm.ActivationDataType, self.cfg.local_activation)
            self._eng = litert_lm.Engine(self.path, backend=be, max_num_tokens=self.cfg.local_ctx, cache_dir=cache, **kw)
            self._eng.__enter__()
            self._lm = litert_lm
        except Exception as e:  # noqa: BLE001 - any engine failure turns the fallback off
            raise LocalUnavailable(f"engine failed to load: {type(e).__name__}: {e}") from e

    def count_tokens(self, text: str) -> int:
        return len(self._eng.tokenize(text))

    def new_conv(self, system: str) -> Conv:
        lm = self._lm
        conv = self._eng.create_conversation(
            system_message=system, thinking_config=lm.ThinkingConfig(enable_thinking=False),
            sampler_config=lm.SamplerConfig(top_k=40, top_p=0.9, temperature=0.4, seed=1),
            max_output_tokens=self.cfg.local_max_new)
        conv.__enter__()
        return _LiteConv(conv, None)

    def close(self) -> None:
        eng, self._eng = self._eng, None
        if eng is not None:
            eng.__exit__(None, None, None)


def _key(parts: Parts) -> str:
    """Identity of a conversation's frozen part: the same system, ABOUT OWNER and pack mean the same KV prefix."""
    return hashlib.sha1((parts.system + "\x00" + parts.pack + (("\x00" + parts.me) if parts.me else "")).encode()).hexdigest()


def available(cfg: Config) -> tuple[bool, str]:
    """Cheap check (no load): is there a chance Gemma can run here?"""
    path = os.path.expanduser(cfg.local_model)
    if not os.path.isfile(path):
        return False, f"model not found: {path}"
    if importlib.util.find_spec("litert_lm") is None:
        return False, "litert_lm not installed"
    return True, ""


def rss_mb() -> float:
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6   # macOS reports bytes


# ---------------------------------------------------------------------------------------------------- the client
@dataclass
class _Ctx:
    key: str
    conv: Conv
    base: int                      # index in the engine's turn list where this conversation's transcript starts
    sent: list[str]                # turn blocks already in the conversation (full[base:base+len(sent)])
    extra: list[BankEntry]         # bank entries cut from the prefix
    tokens: int = 0
    alive: bool = True


class LocalGemma:
    def __init__(self, cfg: Config, backend: Backend | None = None,
                 on_metric: Callable[..., None] | None = None) -> None:
        self.cfg = cfg
        self.backend: Backend = backend if backend is not None else LiteRtBackend(cfg)
        self._on_metric = on_metric or (lambda stage, **kw: None)
        self._pool = ThreadPoolExecutor(1, thread_name_prefix="verse-gemma")
        self._lock: asyncio.Lock | None = None
        self._load_task: asyncio.Task | None = None
        self._loaded = False
        self._failed: str | None = None
        self._ctx: _Ctx | None = None
        self._stuck = False
        self._bg: set[asyncio.Task] = set()
        self._closed = False
        self.load_s: float | None = None

    # -- state
    @property
    def loaded(self) -> bool:
        return self._loaded

    def metric(self, stage: str, **kw) -> None:
        try:
            self._on_metric(stage, **kw)
        except Exception:  # noqa: BLE001
            pass

    def _lk(self) -> asyncio.Lock:
        if self._lock is None:
            self._lock = asyncio.Lock()
        return self._lock

    async def _run(self, fn, *a):
        return await asyncio.get_running_loop().run_in_executor(self._pool, fn, *a)

    async def ensure_loaded(self) -> None:
        if self._failed:
            raise LocalUnavailable(self._failed)
        if self._loaded:
            return
        if self._load_task is None:
            self._load_task = asyncio.ensure_future(self._load())
        await asyncio.shield(self._load_task)

    async def _load(self) -> None:
        t0 = time.perf_counter()
        try:
            await self._run(self.backend.load)
        except LocalUnavailable as e:
            self._failed = str(e)
            raise
        except Exception as e:  # noqa: BLE001
            self._failed = f"{type(e).__name__}: {e}"
            raise LocalUnavailable(self._failed) from e
        self._loaded = True
        self.load_s = time.perf_counter() - t0
        self.metric("local_loaded", load_s=round(self.load_s, 2), rss_mb=round(rss_mb(), 1))

    # -- prompt building
    async def _build(self, parts: Parts) -> tuple[_Ctx, str, str]:
        """A fresh conversation for `parts`: (ctx, first message without the tail, tail-independent extras source)."""
        cfg = self.cfg
        pack_chars = cfg.local_pack_chars
        me_chars, with_pack = 0, True
        if parts.me:       # the me layer: next to a pack it gets a small share, in an unprepared call it is the prefix
            with_pack = parts.pack.strip() != NO_PACK_LINE
            me_chars = cfg.local_me_chars if with_pack else cfg.local_pack_chars
            if with_pack:
                pack_chars = cfg.local_pack_chars_with_me
        full = parts.turns
        n_keep = min(len(full), cfg.local_max_turns)
        for _ in range(8):
            kept: list[str] = []
            chars = 0
            for b in reversed(full):
                if len(kept) >= n_keep or (len(kept) >= 2 and chars + len(b) > cfg.local_turn_chars):
                    break
                kept.append(b)
                chars += len(b)
            kept.reverse()
            pack, dropped = trim_pack(parts.pack, pack_chars)
            me_text = trim_me(parts.me, me_chars, with_pack) if parts.me else ""
            head = (me_text + "\n\n" if me_text else "") + PACK_HEADER + pack + TRANSCRIPT_HEADER
            body = "\n".join([head, *kept])
            n = await self._run(self.backend.count_tokens, parts.system + body)
            if n <= cfg.local_ctx - CTX_HEADROOM_TOKENS or (pack_chars <= 3000 and n_keep <= 2 and (with_pack or me_chars <= 3000)):
                break
            pack_chars = max(pack_chars - 1500, 3000)
            if parts.me and not with_pack:
                me_chars = max(me_chars - 1500, 3000)
            n_keep = max(n_keep - 2, 2)
        conv = await self._run(self.backend.new_conv, parts.system)
        key = _key(parts)
        ctx = _Ctx(key, conv, len(full) - len(kept), list(kept), dropped)
        self.metric("local_build", prompt_tokens=n, pack_chars=len(pack), me_chars=len(me_text), dropped_bank=len(dropped),
                    turns=len(kept))
        return ctx, body, key

    def _extras(self, ctx: _Ctx, tail: str) -> str:
        if tail == PRIME_TAIL:
            return ""
        hits = retrieve(ctx.extra, question_of(tail), self.cfg.local_bank_extra)
        if not hits:
            return ""
        return EXTRA_HEADER + "\n" + "\n".join(h.text[:700] for h in hits)

    def _usable(self, parts: Parts) -> bool:
        c = self._ctx
        if c is None or not c.alive or c.tokens > self.cfg.local_recycle_tokens:
            return False
        key = _key(parts)
        end = c.base + len(c.sent)
        return c.key == key and len(parts.turns) >= end and parts.turns[c.base:end] == c.sent

    async def _prepare(self, parts: Parts, tail: str, *, force_new: bool = False) -> tuple[_Ctx, str, bool]:
        """-> (ctx, message text, cold). Advances the ctx's bookkeeping to include the message."""
        if not force_new and self._usable(parts):
            ctx = self._ctx
            assert ctx is not None
            end = ctx.base + len(ctx.sent)
            delta = parts.turns[end:]
            lines = ([FOLLOWUP_HEADER, *delta] if delta else [])
            extras = self._extras(ctx, tail)
            if extras:
                lines.append(extras)
            lines.append(tail)
            ctx.sent = ctx.sent + delta
            return ctx, "\n".join(lines), False
        ctx, body, _ = await self._build(parts)
        extras = self._extras(ctx, tail)
        text = "\n".join([body, *([extras] if extras else []), tail])
        old, self._ctx = self._ctx, ctx
        if old is not None:
            await self._run(old.conv.close)
        return ctx, text, True

    # -- running a message
    async def _send(self, ctx: _Ctx, text: str, *, cold: bool, route: str = "") -> AsyncIterator[str]:
        if self._stuck:
            raise LocalFailed("local worker is stuck")
        loop = asyncio.get_running_loop()
        q: asyncio.Queue = asyncio.Queue()

        def post(item) -> None:
            try:
                loop.call_soon_threadsafe(q.put_nowait, item)
            except RuntimeError:   # loop already closed
                pass

        def work() -> None:
            try:
                for piece in ctx.conv.send(text):
                    post(("t", piece))
                post(("end", None))
            except BaseException as e:  # noqa: BLE001 - reported to the consumer
                post(("err", e))

        t0 = time.perf_counter()
        fut = loop.run_in_executor(self._pool, work)
        first = True
        t_first = None
        n_out = 0
        ok = False
        try:
            while True:
                left = self.cfg.local_total_s - (time.perf_counter() - t0)
                timeout = min(self.cfg.local_first_token_s, left) if first else left
                try:
                    kind, val = await asyncio.wait_for(q.get(), max(timeout, 0.001))
                except asyncio.TimeoutError:
                    ctx.alive = False
                    raise LocalFailed("no first token in %.0f s" % self.cfg.local_first_token_s
                                      if first else "answer exceeded %.0f s" % self.cfg.local_total_s) from None
                if kind == "t":
                    if first:
                        first, t_first = False, time.perf_counter() - t0
                    n_out += 1
                    yield val
                elif kind == "end":
                    ok = True
                    break
                else:
                    ctx.alive = False
                    raise LocalFailed(f"{type(val).__name__}: {str(val)[:200]}") from None
            try:
                ctx.tokens = await self._run(ctx.conv.token_count)
            except Exception:  # noqa: BLE001
                ctx.alive = False
            self.metric("local_call", route=route, cold=cold, first_token_s=round(t_first or 0.0, 3),
                        total_s=round(time.perf_counter() - t0, 3), chunks=n_out, kv_tokens=ctx.tokens)
        finally:
            if not ok:
                try:
                    ctx.conv.cancel()
                except Exception:  # noqa: BLE001
                    pass
                try:
                    await asyncio.wait_for(asyncio.shield(fut), 5.0)
                except asyncio.TimeoutError:
                    self._stuck = True
                    log.error("local worker did not stop after cancel; local fallback disabled for this process")
                except Exception:  # noqa: BLE001
                    pass

    async def stream(self, request: dict) -> AsyncIterator[str]:
        """The answer to an F request, piece by piece. Serialised: one message at a time on the GPU."""
        parts = split_request(request)
        async with self._lk():
            await self.ensure_loaded()
            ctx, text, cold = await self._prepare(parts, parts.tail)
            async for piece in self._send(ctx, text, cold=cold, route="F"):
                yield piece
            if ctx.tokens > self.cfg.local_recycle_tokens and not self._closed:
                self._spawn(self.prime(request, force=True))

    async def prime(self, request: dict, *, force: bool = False) -> None:
        """Load the engine and prefill the pack + transcript, so the next question only pays the follow-up."""
        parts = split_request(request)
        async with self._lk():
            await self.ensure_loaded()
            if not force and self._usable(parts):
                return
            t0 = time.perf_counter()
            ctx, text, cold = await self._prepare(parts, PRIME_TAIL, force_new=True)
            async for _ in self._send(ctx, text, cold=True, route="prime"):
                pass
            self.metric("local_primed", prime_s=round(time.perf_counter() - t0, 2), kv_tokens=ctx.tokens,
                        rss_mb=round(rss_mb(), 1))

    def _spawn(self, coro) -> None:
        t = asyncio.get_running_loop().create_task(self._guard(coro))
        self._bg.add(t)
        t.add_done_callback(self._bg.discard)

    async def _guard(self, coro) -> None:
        try:
            await coro
        except asyncio.CancelledError:
            raise
        except Exception as e:  # noqa: BLE001 - background priming must never take the process down
            log.warning("local background task failed: %s: %s", type(e).__name__, e)

    def spawn_prime(self, request: dict) -> None:
        self._spawn(self.prime(request))

    async def aclose(self) -> None:
        self._closed = True
        for t in list(self._bg):
            t.cancel()
        if self._bg:
            await asyncio.gather(*self._bg, return_exceptions=True)
        ctx, self._ctx = self._ctx, None
        if ctx is not None and not self._stuck:
            try:
                await asyncio.wait_for(self._run(ctx.conv.close), 5.0)
            except Exception:  # noqa: BLE001
                pass
        if self._loaded and not self._stuck:
            try:
                await asyncio.wait_for(self._run(self.backend.close), 10.0)
            except Exception:  # noqa: BLE001
                pass
        self._pool.shutdown(wait=False, cancel_futures=True)
