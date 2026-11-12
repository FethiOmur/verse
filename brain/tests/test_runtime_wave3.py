"""Review wave 3 (REVIEW_2026-11-11.md): regression tests for P3 and P5.

P3  memory_ask.py, memory/search.py   the memory search runs off the event loop, a cancel that arrives meanwhile is read, and a
                                       hung query embedding times out into the full-text branch
P5  ask.py, memory_ask.py             `count_tokens` at session start is bounded; a hung count falls back to the estimate
"""

from __future__ import annotations

import asyncio
import math
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import pytest

from test_runtime_ask import make as make_ask, start_msg as ask_start_msg
from test_runtime_memory_ask import idx, make as make_mem, start_msg as mem_start_msg  # noqa: F401 (idx is a fixture)
from verse_brain.memory.search import QueryEmbedder, search
from verse_brain.runtime import memory_ask as mem_mod
from verse_brain.runtime.ask import FakeAskClient


def run(coro):
    return asyncio.run(coro)


# ------------------------------------------------------------------------------------------------------------------ P3
def _slow_search(started: threading.Event, seen: dict, seconds: float = 0.6):
    def slow(index, query, **kw):
        seen["thread"] = threading.current_thread()
        started.set()
        time.sleep(seconds)
        return []
    return slow


def test_p3_the_search_runs_on_a_worker_thread_and_the_loop_keeps_ticking(idx, monkeypatch):  # noqa: F811
    db, _ = idx
    started, seen = threading.Event(), {}
    monkeypatch.setattr(mem_mod, "search", _slow_search(started, seen))

    async def go(tmp):
        rt, em, c = make_mem()
        await rt.handle(mem_start_msg(db, tmp / "c.jsonl"))
        ticks = 0

        async def ticker():
            nonlocal ticks
            while not em.of("ask_done"):
                await asyncio.sleep(0.02)
                ticks += 1

        tick = asyncio.create_task(ticker())
        await rt.handle({"type": "ask", "id": "q1", "text": "What did Marta say about the pilot?"})
        await asyncio.gather(rt._task)
        await tick
        await rt.shutdown()
        return ticks, em

    import tempfile
    from pathlib import Path
    with tempfile.TemporaryDirectory() as t:
        ticks, em = run(go(Path(t)))
    assert seen["thread"] is not threading.main_thread()
    assert ticks >= 15, f"the loop was blocked while the search ran (only {ticks} ticks in 0.6 s)"
    assert em.of("ask_done")


def test_p3_a_cancel_during_the_search_is_read_at_once_and_ends_with_ask_done(idx, monkeypatch, tmp_path):  # noqa: F811
    db, _ = idx
    started, seen = threading.Event(), {}
    monkeypatch.setattr(mem_mod, "search", _slow_search(started, seen, seconds=0.8))

    async def go():
        rt, em, c = make_mem()
        await rt.handle(mem_start_msg(db, tmp_path / "c.jsonl"))
        await rt.handle({"type": "ask", "id": "q1", "text": "What did Marta say about the pilot?"})
        for _ in range(200):
            await asyncio.sleep(0.005)
            if started.is_set():
                break
        t0 = time.monotonic()
        await rt.handle({"type": "control", "action": "cancel"})
        took = time.monotonic() - t0
        await rt.shutdown()
        return em, c, took

    em, c, took = run(go())
    done = em.of("ask_done")
    assert len(done) == 1 and done[0]["stop_reason"] == "cancelled" and not em.of("ask_error")
    assert not c.requests, "no model call after a cancel during the search"
    assert took < 0.4, f"cancel waited for the search ({took:.2f} s)"


def test_p3_a_hung_query_embedding_times_out_and_the_search_falls_back_to_full_text(idx, monkeypatch):  # noqa: F811
    from verse_brain.memory.index import MemoryIndex

    release = threading.Event()

    class Hung:
        def embed(self, text):
            release.wait(5)
            return [1.0, 0.0]

    monkeypatch.setattr(mem_mod, "EMBED_TIMEOUT_S", 0.2)
    pool = ThreadPoolExecutor(max_workers=1)
    qe = QueryEmbedder(mem_mod._ThreadBound(Hung(), pool), "sha")
    t0 = time.monotonic()
    with pytest.raises(TimeoutError):
        qe.query("pilot")
    db, _ = idx
    ix = MemoryIndex.open(db, readonly=True)
    try:
        hits = search(ix, "pilot review", scope=None, embedder=qe)    # must not raise; the vector branch is off
    finally:
        ix.close()
        release.set()
        pool.shutdown(wait=False)
    assert time.monotonic() - t0 < 2.0
    assert hits, "the full-text branch still found the pilot review"


# ------------------------------------------------------------------------------------------------------------------ P5
class _HungCount(FakeAskClient):
    async def count_tokens(self, model, system, messages):
        await asyncio.sleep(30)
        return 1


def test_p5_a_hung_count_tokens_falls_back_to_the_estimate_in_a_bounded_time(tmp_path):
    async def go():
        rt, em, _, d = make_ask(tmp_path, _HungCount(), count_timeout=0.2)
        t0 = time.monotonic()
        await rt.handle(ask_start_msg(d))
        return rt, em, time.monotonic() - t0

    rt, em, took = run(go())
    ready = em.of("status", state="ready")
    assert ready and took < 3.0, f"ask_start waited {took:.1f} s for count_tokens"
    assert rt.tokens == math.ceil(len(rt.grounding) / 3) and rt.tokens > 1


def test_p5_the_memory_runtime_bounds_its_count_too(idx, tmp_path):  # noqa: F811
    db, _ = idx

    async def go():
        rt, em, _ = make_mem(_HungCount(), count_timeout=0.2)
        t0 = time.monotonic()
        await rt.handle(mem_start_msg(db, tmp_path / "c.jsonl"))
        await rt.shutdown()
        return rt, em, time.monotonic() - t0

    rt, em, took = run(go())
    assert em.of("status", state="ready") and took < 3.0
    assert rt.tokens == math.ceil(len(rt.grounding) / 3)
