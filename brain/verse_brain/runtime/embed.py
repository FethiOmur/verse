"""Paraphrase bank matcher (plan Phase 1b F3): EmbeddingGemma 2 (text 270M, LiteRT-LM, GPU) over the session bank.

The Swift n-gram matcher catches exact phrasings; this path catches the same question asked in other words. It runs in
the brain because the brain already receives every remote `partial` and holds the session's bank.

- `start`: the bank index (question + paraphrases of every entry, the phrases Swift's `BankEntry.phrases(for:)` uses) is
  embedded once, on the embedding thread, while the pre-warm runs.
- Every remote partial that passes the cheap gates (index ready, question cue, >= `embed_min_words` words, no Swift
  n-gram hit for the turn) is queued. One job runs at a time on a single worker thread; while it runs, newer partials
  replace older queued ones (stale partials are dropped, the newest always runs). The event loop never waits for it.
- A hit needs top-1 >= `embed_threshold`, a margin >= `embed_margin` over the runner-up entry, and the same entry on
  `embed_consecutive` consecutive evaluated partials of the turn (F3: short prefixes lock on the wrong entry).
- If `litert_lm` or the model is missing, or the engine fails, the path logs once and stays off; nothing else changes.

Query and document prefix: the symmetric "sentence similarity" task prompt (`bench/embed`, mode `sym`; the accept rule in
`settings.py` was measured on its vectors and on the stored replay `eval/out/f3-embed`).
"""

from __future__ import annotations

import asyncio
import logging
import math
import os
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from operator import mul
from typing import Callable, Protocol

log = logging.getLogger("verse.runtime.embed")

PREFIX = "task: sentence similarity | text: "   # query and document (bench/embed PREFIX["sym"])

DEFAULT_MODEL = ("~/Library/Application Support/Verse/models/embeddinggemma-2-text-270m-litert/"
                 "embeddinggemma-2-text-270m.litertlm")


class EmbedUnavailable(Exception):
    """The embedding path cannot run (library or model missing, engine failed to load)."""


class Embedder(Protocol):
    def embed(self, text: str) -> list[float]: ...

    def close(self) -> None: ...


class LiteRtEmbedder:
    """`litert_lm.EmbeddingEngine` on one thread. Build, call and close it on the same (embedding) thread."""

    def __init__(self, model_path: str = DEFAULT_MODEL, backend: str = "gpu") -> None:
        path = os.path.expanduser(model_path)
        if not os.path.isfile(path):
            raise EmbedUnavailable(f"model not found: {path}")
        try:
            import litert_lm  # noqa: PLC0415 - optional dependency, loaded only when the path is used
        except ImportError as e:
            raise EmbedUnavailable(f"litert_lm not importable: {e}") from e
        try:
            litert_lm.set_min_log_severity(litert_lm.LogSeverity.ERROR)
            be = litert_lm.Backend.GPU() if backend == "gpu" else litert_lm.Backend.CPU()
            # The engine refuses to start when its cache folder is missing (a freshly installed model has none).
            cache_dir = os.path.join(os.path.dirname(path), "cache")
            os.makedirs(cache_dir, exist_ok=True)
            self._eng = litert_lm.EmbeddingEngine(path, backend=be, cache_dir=cache_dir)
        except Exception as e:  # noqa: BLE001 - any engine failure turns the path off
            raise EmbedUnavailable(f"engine failed to load: {type(e).__name__}: {e}") from e

    def embed(self, text: str) -> list[float]:
        return list(self._eng.compute_embedding(text).embedding)

    def close(self) -> None:
        eng, self._eng = getattr(self, "_eng", None), None
        if eng is not None:
            eng.close()


def accepted(top1: float, second: float, threshold: float, margin: float) -> bool:
    """One evaluation passes the score gates (the consecutive-partials gate is counted by the caller). Shared by the engine
    and eval/rescore_bank.py, which re-decides stored replays with it."""
    return top1 >= threshold and top1 - second >= margin


@dataclass(frozen=True)
class AcceptRule:
    """The accept rule of one language (settings.Config.embed_rule builds it).

    Base lane: top-1 >= `threshold`, margin >= `margin`, the same entry on `consecutive` consecutive evaluated partials; the
    final text of a closed turn needs one evaluation. Fast lane (off when `fast_threshold` is None): the same entry on
    `fast_consecutive` consecutive evaluations that each pass `fast_threshold` / `fast_margin` hits at once, one partial
    earlier than the base lane allows."""
    threshold: float
    margin: float
    consecutive: int
    fast_threshold: float | None = None
    fast_margin: float = 0.0
    fast_consecutive: int = 2


@dataclass
class MatchState:
    """Per-turn state of the accept rule: the current candidate, its run lengths, the last id sent."""
    cand: str | None = None
    count: int = 0          # consecutive evaluations of `cand` that pass the base gates
    fast: int = 0           # ... of which the trailing run also passes the fast gates
    sent: str | None = None

    def reset(self) -> None:
        self.cand, self.count, self.fast = None, 0, 0


def step(state: MatchState, rule: AcceptRule, top: str | None, s1: float, s2: float, final: bool = False) -> str | None:
    """Advance the rule by one evaluation. -> the bank id to show now, or None. Shared by the engine and the offline tools
    (eval/rescore_bank.py, bench/embed/ml_calib.py), so a replayed decision is the engine's decision."""
    if top is None or not accepted(s1, s2, rule.threshold, rule.margin):
        state.reset()
        return None
    if top == state.cand:
        state.count += 1
    else:
        state.cand, state.count, state.fast = top, 1, 0
    fast_ok = rule.fast_threshold is not None and accepted(s1, s2, rule.fast_threshold, rule.fast_margin)
    state.fast = state.fast + 1 if fast_ok else 0
    hit = final or state.count >= rule.consecutive or (fast_ok and state.fast >= rule.fast_consecutive)
    if hit and top != state.sent:
        state.sent = top
        return top
    return None


def unit(v: list[float]) -> list[float]:
    n = math.sqrt(sum(x * x for x in v))
    return [x / n for x in v] if n > 0 else list(v)


def bank_phrases(rec: dict, lang: str) -> list[str]:
    """The entry's question plus its paraphrases in `lang` (all languages when `lang` has none), as in Swift's
    `BankEntry.phrases(for:)`."""
    out = [rec.get("question", "")]
    para = rec.get("paraphrases") or {}
    if para.get(lang):
        out += list(para[lang])
    else:
        for k in sorted(para):
            out += list(para[k] or [])
    return [p for p in out if isinstance(p, str) and p.strip()]


class BankIndex:
    """Unit vectors of every bank phrase; scores a query as the best phrase per entry (cosine)."""

    def __init__(self, embedder: Embedder, bank: dict[str, dict], lang: str) -> None:
        self.lang = lang                       # the accept rule is chosen by the language the index was built in
        self.ids: list[str] = sorted(bank)
        self.doc_entry: list[int] = []
        self.vecs: list[list[float]] = []
        for ei, bid in enumerate(self.ids):
            for p in bank_phrases(bank[bid], lang):
                self.vecs.append(unit(embedder.embed(PREFIX + p.strip())))
                self.doc_entry.append(ei)

    def __len__(self) -> int:
        return len(self.vecs)

    def top2(self, qv: list[float]) -> list[tuple[str, float]]:
        best = [-1.0] * len(self.ids)
        for di, dv in enumerate(self.vecs):
            s = sum(map(mul, qv, dv))
            e = self.doc_entry[di]
            if s > best[e]:
                best[e] = s
        order = sorted(range(len(best)), key=lambda i: best[i], reverse=True)[:2]
        return [(self.ids[i], best[i]) for i in order]


@dataclass
class Job:
    turn_id: str
    text: str
    queued: float          # time.perf_counter() when queued
    final: bool = False    # the closed turn's final text (one pass at the endpoint), not a growing partial


@dataclass
class Result:
    top: list[tuple[str, float]]
    ms: float               # embed + match on the worker thread
    wait_ms: float          # queued -> started
    lang: str = ""          # the language of the index that scored it


class EmbedPath:
    """Owns the worker thread, the index and the coalescing queue. `on_result(job, result)` runs on the event loop."""

    def __init__(self, factory: Callable[[], Embedder], on_result: Callable[[Job, Result], None],
                 spawn: Callable, emit_metric: Callable[..., None]) -> None:
        self._factory = factory
        self._on_result = on_result
        self._spawn = spawn
        self._metric = emit_metric
        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="verse-embed")
        self._embedder: Embedder | None = None
        self._index: BankIndex | None = None
        self.state = "off"          # off | loading | ready | unavailable
        self._pending: Job | None = None
        self._busy = False
        self._warned = False
        self._gen = 0               # bumps on every (re)start and on close: results of an older index are dropped
        self._closed = False

    @property
    def ready(self) -> bool:
        return self.state == "ready"

    # ---- start: load the engine and embed the bank, off the event loop
    def start(self, bank: dict[str, dict], lang: str) -> None:
        if self.state == "unavailable" or self._closed:
            return
        self._gen += 1
        self.state = "loading"
        self._index = None
        self._pending = None
        self._spawn(self._load(bank, lang, self._gen))

    def _load_sync(self, bank: dict[str, dict], lang: str) -> tuple[BankIndex, float, float]:
        t0 = time.perf_counter()
        if self._embedder is None:
            emb = self._factory()
            if self._closed:            # closed while the engine loaded: nobody else will close it (review P4)
                emb.close()
                raise EmbedUnavailable("closed while loading")
            self._embedder = emb
        t1 = time.perf_counter()
        idx = BankIndex(self._embedder, bank, lang)
        return idx, (t1 - t0) * 1000, (time.perf_counter() - t1) * 1000

    async def _load(self, bank: dict[str, dict], lang: str, gen: int) -> None:
        loop = asyncio.get_running_loop()
        try:
            idx, load_ms, index_ms = await loop.run_in_executor(self._pool, self._load_sync, bank, lang)
        except Exception as e:  # noqa: BLE001 - EmbedUnavailable or anything the engine throws: the path stays off
            if not self._closed:
                self._unavailable(e)
            return
        if gen != self._gen or self._closed:
            return
        self._index = idx
        self.state = "ready"
        self._metric("", "embed_ready", docs=len(idx), entries=len(idx.ids), load_ms=round(load_ms, 1),
                     index_ms=round(index_ms, 1))
        self._kick()

    def _unavailable(self, e: BaseException) -> None:
        self.state = "unavailable"
        self._pending = None
        if not self._warned:
            self._warned = True
            reason = str(e) if isinstance(e, EmbedUnavailable) else f"{type(e).__name__}: {e}"
            log.warning("embedding matcher off: %s", reason)
            self._metric("", "embed_unavailable", reason=reason[:200])

    # ---- partials
    def submit(self, turn_id: str, text: str, final: bool = False) -> None:
        """Queue a partial (or, with `final`, the text of a closed turn); a queued, not yet started job is replaced
        (only the newest runs)."""
        if self.state not in ("ready", "loading"):
            return
        self._pending = Job(turn_id, text, time.perf_counter(), final)
        self._kick()

    def drop(self, turn_id: str) -> None:
        if self._pending is not None and self._pending.turn_id == turn_id:
            self._pending = None

    def _kick(self) -> None:
        if self._busy or self._pending is None or not self.ready:
            return
        self._busy = True
        self._spawn(self._drain())

    def _match_sync(self, job: Job, index: BankIndex, embedder: Embedder) -> Result:
        # The index and the engine are captured on the event loop when the job is dispatched: a restart (language change)
        # replaces self._index while this runs, and the result is then dropped by the generation check (review P4).
        t0 = time.perf_counter()
        qv = unit(embedder.embed(PREFIX + job.text.strip()))
        top = index.top2(qv)
        return Result(top, (time.perf_counter() - t0) * 1000, (t0 - job.queued) * 1000, index.lang)

    async def _drain(self) -> None:
        loop = asyncio.get_running_loop()
        try:
            while self._pending is not None and self.ready and self._index is not None and self._embedder is not None:
                job, self._pending = self._pending, None
                gen, index, embedder = self._gen, self._index, self._embedder
                try:
                    res = await loop.run_in_executor(self._pool, self._match_sync, job, index, embedder)
                except Exception as e:  # noqa: BLE001
                    if gen == self._gen:     # a failure of an index that has been replaced or closed is not the path failing
                        self._unavailable(e)
                    return
                if gen == self._gen:
                    self._on_result(job, res)
        finally:
            self._busy = False

    # ---- other jobs on the same thread (follow my answer: card lines, pack lines, his words)
    async def run_job(self, fn: Callable[[Embedder], object]):
        """Run `fn(embedder)` on the embedding worker thread (serialised with the bank jobs; the engine and the GPU are
        shared) once the model is loaded. Raises EmbedUnavailable when the path is off or failed."""
        while self.state == "loading":
            await asyncio.sleep(0.02)
        if self.state != "ready" or self._embedder is None:
            raise EmbedUnavailable(f"embedding path {self.state}")
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(self._pool, fn, self._embedder)

    # ---- shutdown
    def close(self) -> None:
        self.state = "off" if self.state != "unavailable" else self.state
        self._closed = True
        self._gen += 1              # a load or a match still on the worker thread is dropped when it returns
        self._pending = None
        emb, self._embedder = self._embedder, None
        if emb is not None:
            try:
                self._pool.submit(emb.close)
            except RuntimeError:
                pass
        self._pool.shutdown(wait=False)
