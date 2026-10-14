"""F3 paraphrase matcher in the brain: EmbeddingGemma over the bank, gated, off the event loop.

Logic tests use a fake embedder whose cosine scores are set exactly; one test runs the real model and is skipped
when the model file or `litert_lm` is missing."""

from __future__ import annotations

import asyncio
import logging
import math
import os
import sys
import threading
import time
from pathlib import Path

import pytest
from test_runtime_helpers import FIX, lines_script, settle

from verse_brain.runtime.embed import DEFAULT_MODEL, PREFIX, EmbedUnavailable, LiteRtEmbedder, bank_phrases
from verse_brain.runtime.engine import Brain
from verse_brain.runtime.fake import FakeTransport, default_responder
from verse_brain.runtime.protocol import ListEmitter, load_session
from verse_brain.runtime.settings import Config

ESESSION = FIX.parent / "embed_session"
FAST_B001 = "SAY: Sure, here is the short version.\n- I led Lantern.\n- It cut entry to 2 minutes.\nBANK: b001"
FAST_B005 = FAST_B001.replace("BANK: b001", "BANK: b005")


class FakeEmbedder:
    """Every vector shares a common axis (cosine 0.80 between unrelated texts, like the real model's background); a
    bank phrase adds its entry's own axis. A query matching a rule (substring, lower-cased) gets exactly the given
    cosine with each listed entry and 0.80 with the others. `delay` blocks the calling thread per query."""

    BASE = 0.8

    def __init__(self, rules: list[tuple[str, dict[str, float]]], delay: float = 0.0) -> None:
        sess = load_session(ESESSION)
        self.ids = sorted(sess.bank)
        self.docs = {p.strip(): bid for bid, rec in sess.bank.items() for p in bank_phrases(rec, "en")}
        self.rules = rules
        self.delay = delay
        self.queries: list[str] = []
        self.threads: set[str] = set()
        self.closed = False
        self._c = math.sqrt(self.BASE)
        self._own = math.sqrt(1 - self.BASE)

    def _doc(self, bid: str) -> list[float]:
        return [self._c] + [self._own if i == bid else 0.0 for i in self.ids] + [0.0]

    def _query(self, scores: dict[str, float]) -> list[float]:
        b = [(scores.get(i, self.BASE) - self.BASE) / self._own for i in self.ids]
        rest = 1 - self.BASE - sum(x * x for x in b)
        assert rest >= 0, f"impossible scores {scores}"
        return [self._c] + b + [math.sqrt(rest)]

    def embed(self, text: str) -> list[float]:
        self.threads.add(threading.current_thread().name)
        body = text[len(PREFIX):] if text.startswith(PREFIX) else text
        if body in self.docs:
            return self._doc(self.docs[body])
        self.queries.append(body)
        if self.delay:
            time.sleep(self.delay)
        low = body.lower()
        for sub, scores in self.rules:
            if sub in low:
                return self._query(scores)
        return self._query({})

    def close(self) -> None:
        self.closed = True


PARA = [("end up where", {"b001": 0.90, "b005": 0.85})]


def fast_responder(fast: str):
    def responder(info):
        if info.route in ("S", "F") and not info.tail.startswith("SUMMARIZE") and "STATEMENT CHECK" not in info.tail:
            return lines_script(fast)
        return default_responder(info)
    return responder


def make(embedder=None, responder=None, factory=None, **cfg):
    t = FakeTransport(responder or default_responder)
    em = ListEmitter()
    fac = factory if factory is not None else ((lambda: embedder) if embedder is not None else None)
    b = Brain(t, em, Config(**cfg), embedder_factory=fac)
    b.start_background = False
    return b, t, em


async def start(b: Brain) -> None:
    await b.handle({"type": "start", "session_dir": str(ESESSION), "lang": "en"})
    end = time.monotonic() + 5
    while b.embed is not None and b.embed.state == "loading" and time.monotonic() < end:
        await asyncio.sleep(0.01)


async def idle(b: Brain, timeout: float = 3.0, allow_off: bool = False) -> None:
    """Wait until the embedding queue is empty and no job is running (and the path did not turn itself off)."""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if b.embed is None or (b.embed._pending is None and not b.embed._busy):
            assert allow_off or b.embed is None or b.embed.state == "ready", b.embed.state
            return
        await asyncio.sleep(0.01)
    raise AssertionError("embedding queue did not drain")


async def partial(b: Brain, tid: str, text: str, cue: bool = True) -> None:
    await b.handle({"type": "partial", "turn_id": tid, "speaker": "remote", "text": text, "cue": cue, "t_audio_end": 0.0})


async def turn(b: Brain, tid: str, text: str) -> None:
    await b.handle({"type": "turn", "turn_id": tid, "speaker": "remote", "text": text, "addressee": "me",
                    "kind": "question", "t_audio_end": 0.0})


def embed_hits(em: ListEmitter) -> list[dict]:
    return [e for e in em.of("bank_hit") if e.get("via") == "embed"]


def run(coro):
    return asyncio.run(coro)


# ---------------------------------------------------------------- hits and gates

def test_paraphrase_hits_after_two_consecutive_partials():
    async def go():
        fe = FakeEmbedder(PARA)
        b, t, em = make(fe, fast_responder(FAST_B001))
        await start(b)
        await partial(b, "q1", "How did you end up where")
        await idle(b)
        after_one = len(embed_hits(em))
        await partial(b, "q1", "How did you end up where you are")
        await idle(b)
        after_two = list(embed_hits(em))
        await partial(b, "q1", "How did you end up where you are today")
        await idle(b)
        await turn(b, "q1", "How did you end up where you are today")
        await settle(b)
        return b, t, em, fe, after_one, after_two

    b, t, em, fe, after_one, after_two = run(go())
    assert after_one == 0, "one partial is not enough"
    assert len(after_two) == 1
    hit = after_two[0]
    assert (hit["turn_id"], hit["bank_id"], hit["via"]) == ("q1", "b001", "embed")
    assert hit["score"] == pytest.approx(0.90, abs=1e-3)
    assert len(embed_hits(em)) == 1, "the same hit is not repeated"
    assert all(n.startswith("verse-embed") for n in fe.threads), fe.threads
    # Haiku's BANK line is checked against the embed hit
    assert em.of("bank_verdict", turn_id="q1", bank_id="b001", agree=True)
    # D-skip never applies to an embed hit, even at a score >= 0.85 with Haiku agreeing
    assert len(t.by_route("D")) == 1
    assert not em.of("metric", stage="d_skipped")


def test_short_prefix_gives_no_hit():
    async def go():
        fe = FakeEmbedder([("where do", {"b005": 0.95})])
        b, t, em = make(fe)
        await start(b)
        for text in ("Where do", "Where do you", "Where do you feel", "Where do you feel"):
            await partial(b, "q1", text)
            await idle(b)
        return em, fe

    em, fe = run(go())
    assert not embed_hits(em)
    assert fe.queries == [], "partials under 5 words are never embedded"


def test_distractor_gives_no_hit():
    async def go(rules):
        fe = FakeEmbedder(rules)
        b, t, em = make(fe)
        await start(b)
        words = "Do you have experience with Kubernetes and container orchestration".split()
        for n in range(5, len(words) + 1):
            await partial(b, "q1", " ".join(words[:n]))
            await idle(b)
        return em, fe

    # below the threshold
    em, fe = run(go([("kubernetes", {"b009": 0.86}), ("do you have", {"b009": 0.85})]))
    assert fe.queries, "the partials were evaluated"
    assert not embed_hits(em)
    # above the threshold but too close to the runner-up
    em, fe = run(go([("do you have", {"b009": 0.90, "b015": 0.897})]))
    assert not embed_hits(em)


def test_no_hit_without_question_cue():
    async def go():
        fe = FakeEmbedder(PARA)
        b, t, em = make(fe)
        await start(b)
        for text in ("How did you end up where", "How did you end up where you are", "How did you end up where you are today"):
            await partial(b, "q1", text, cue=False)
            await idle(b)
        return em, fe

    em, fe = run(go())
    assert not embed_hits(em)
    assert fe.queries == []


def test_ngram_hit_already_present_blocks_embed():
    async def go():
        fe = FakeEmbedder(PARA)
        b, t, em = make(fe)
        await start(b)
        await b.handle({"type": "bank_hit", "turn_id": "q1", "bank_id": "b002", "score": 0.7})
        for text in ("How did you end up where", "How did you end up where you are", "How did you end up where you are today"):
            await partial(b, "q1", text)
            await idle(b)
        return b, em, fe

    b, em, fe = run(go())
    assert not embed_hits(em)
    assert fe.queries == []
    assert b.ts["q1"].bank_hit.bank_id == "b002"


def test_ngram_hit_while_embedding_wins():
    """A Swift hit that lands while the embedding job runs: the job's result is dropped."""
    async def go():
        fe = FakeEmbedder(PARA, delay=0.15)
        b, t, em = make(fe)
        await start(b)
        await partial(b, "q1", "How did you end up where")
        await idle(b)
        await partial(b, "q1", "How did you end up where you are")
        await asyncio.sleep(0.03)            # second job running
        await b.handle({"type": "bank_hit", "turn_id": "q1", "bank_id": "b002", "score": 0.7})
        await idle(b)
        return b, em

    b, em = run(go())
    assert not embed_hits(em)
    assert b.ts["q1"].bank_hit.bank_id == "b002"


def test_haiku_disagrees_retracts_embed_hit():
    async def go():
        fe = FakeEmbedder(PARA)
        b, t, em = make(fe, fast_responder(FAST_B005))
        await start(b)
        for text in ("How did you end up where", "How did you end up where you are"):
            await partial(b, "q1", text)
            await idle(b)
        await turn(b, "q1", "How did you end up where you are")
        await settle(b)
        return b, t, em

    b, t, em = run(go())
    assert len(embed_hits(em)) == 1
    assert em.of("bank_verdict", turn_id="q1", bank_id="b001", agree=False)
    # the brain drops it too: D is not handed the rejected entry's prepared answer
    assert b.ts["q1"].bank_hit is None
    d = t.by_route("D")
    assert len(d) == 1 and "PREPARED DEEP ANSWER" not in d[0].tail


# ---------------------------------------------------------------- availability

def test_missing_model_leaves_brain_running(caplog, tmp_path):
    async def go(factory):
        b, t, em = make(factory=factory, responder=fast_responder(FAST_B001))
        await start(b)
        for text in ("How did you end up where", "How did you end up where you are"):
            await partial(b, "q1", text)
            await idle(b, allow_off=True)
        await turn(b, "q1", "How did you end up where you are")
        await settle(b)
        await partial(b, "q2", "How did you end up where you are")
        await idle(b, allow_off=True)
        return b, t, em

    caplog.set_level(logging.WARNING, logger="verse.runtime.embed")
    cases = [lambda: LiteRtEmbedder(str(tmp_path / "missing.litertlm"))]
    fake_model = tmp_path / "model.litertlm"
    fake_model.write_bytes(b"x")

    def no_litert():
        saved = sys.modules.get("litert_lm")
        sys.modules["litert_lm"] = None          # import fails
        try:
            return LiteRtEmbedder(str(fake_model))
        finally:
            if saved is None:
                sys.modules.pop("litert_lm", None)
            else:
                sys.modules["litert_lm"] = saved

    def crashes():
        raise RuntimeError("GPU delegate failed")

    cases += [no_litert, crashes]
    for factory in cases:
        caplog.clear()
        b, t, em = run(go(factory))
        assert b.embed.state == "unavailable"
        assert not embed_hits(em)
        assert em.of("status", state="ready")
        assert [e for e in em.of("delta") if e["tier"] in ("S", "F")], "the fast tiers still answer"
        assert len(em.of("metric", stage="embed_unavailable")) == 1
        warnings = [r for r in caplog.records if r.name == "verse.runtime.embed" and r.levelno == logging.WARNING]
        assert len(warnings) == 1, [r.getMessage() for r in warnings]


def test_litert_embedder_reasons(tmp_path):
    with pytest.raises(EmbedUnavailable, match="model not found"):
        LiteRtEmbedder(str(tmp_path / "nope.litertlm"))


# ---------------------------------------------------------------- speed: the event loop never waits

def test_s_and_f_launch_timing_unchanged():
    words = "so tell me how exactly did you design the invoice extraction pipeline".split()

    async def go(embedder):
        b, t, em = make(embedder, responder=fast_responder(FAST_B001))
        await start(b)
        # a fixed wall-clock schedule (one partial every 100 ms, then the endpoint): lag is measured against the
        # schedule, so a blocked event loop shows up as lag
        t0 = time.time() + 0.05
        sent: dict[int, float] = {}
        for n in range(1, len(words) + 1):
            sent[n] = t0 + 0.1 * (n - 1)
            await asyncio.sleep(max(0.0, sent[n] - time.time()))
            await partial(b, "q1", " ".join(words[:n]))
        t_turn = t0 + 0.1 * len(words)
        await asyncio.sleep(max(0.0, t_turn - time.time()))
        await turn(b, "q1", "what salary range are you expecting for this position in Milan")
        await asyncio.sleep(0.05)
        s_lag = [c.t["fire"] - sent[len(c.input_tokens)] for c in b.ts["q1"].s_calls]
        f = b.ts["q1"].fast
        f_lag = f.t["fire"] - t_turn
        await settle(b)
        if embedder is not None:
            assert b.embed.state == "ready", b.embed.state
        return s_lag, f_lag, embedder

    base_s, base_f, _ = run(go(None))
    slow = FakeEmbedder([("tell me", {"b009": 0.82})], delay=0.25)   # every embedding blocks its thread 250 ms
    s_lag, f_lag, fe = run(go(slow))
    assert len(fe.queries) >= 3, "the embedding path ran during the timeline"
    assert len(s_lag) == len(base_s)
    # one blocked embedding would add >= 250 ms; 100 ms leaves room for scheduler jitter on a loaded Mac
    assert max(s_lag) < 0.1, s_lag
    assert f_lag < 0.1, f_lag
    assert max(base_s) < 0.1 and base_f < 0.1, (base_s, base_f)


def test_stale_partials_are_dropped():
    async def go():
        fe = FakeEmbedder(PARA, delay=0.2)
        b, t, em = make(fe)
        await start(b)
        words = "How did you end up where you are today in your career".split()
        for n in range(5, len(words) + 1):
            await partial(b, "q1", " ".join(words[:n]))
            await asyncio.sleep(0.02)
        await idle(b)
        return fe, " ".join(words)

    fe, last = run(go())
    assert len(fe.queries) <= 3, fe.queries
    assert fe.queries[-1] == last, "the newest partial always runs"


def test_metrics_and_close():
    async def go():
        fe = FakeEmbedder(PARA)
        b, t, em = make(fe)
        await start(b)
        await partial(b, "q1", "How did you end up where")
        await idle(b)
        await b.shutdown()
        await asyncio.sleep(0.05)
        return em, fe

    em, fe = run(go())
    ready = em.of("metric", stage="embed_ready")
    assert ready and ready[0]["entries"] == 5 and ready[0]["docs"] == 20
    m = em.of("metric", stage="embed")
    assert m and m[0]["top"] == "b001" and "ms" in m[0] and "wait_ms" in m[0]
    assert fe.closed


# ---------------------------------------------------------------- the real model

_HAVE_MODEL = os.path.isfile(os.path.expanduser(DEFAULT_MODEL))
try:
    import litert_lm  # noqa: F401
    _HAVE_LITERT = True
except ImportError:
    _HAVE_LITERT = False


@pytest.mark.skipif(not (_HAVE_MODEL and _HAVE_LITERT), reason="EmbeddingGemma model or litert_lm missing")
def test_real_model_paraphrase_and_distractor():
    async def go():
        b, t, em = make(factory=lambda: LiteRtEmbedder())
        await start(b)
        assert b.embed.state == "ready", b.embed.state

        async def say(tid, sentence):
            w = sentence.split()
            for n in range(1, len(w) + 1):
                await partial(b, tid, " ".join(w[:n]))
                await idle(b, timeout=10)

        await say("q1", "Where do you feel you fall short at work these days?")
        await say("q2", "How long until you could begin if you accepted our offer?")
        await say("q3", "Do you have experience with Kubernetes and container orchestration?")
        await say("q4", "How do you feel about remote work versus coming into the office?")
        ms = [e["ms"] for e in em.of("metric", stage="embed")]
        await b.shutdown()
        return em, ms

    em, ms = run(go())
    hits = {e["turn_id"]: e["bank_id"] for e in embed_hits(em)}
    assert hits.get("q1") == "b005", hits
    assert hits.get("q2") == "b015", hits
    assert "q3" not in hits and "q4" not in hits, hits
    assert sorted(ms)[len(ms) // 2] < 100, ms
