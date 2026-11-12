"""The paraphrase matcher's accept rule per language and its fast lane (embed.step, Config.embed_rule), and the restart / close
races of the embedding path (review P4). Fake embedder with exact cosines; one test runs the real model."""

from __future__ import annotations

import asyncio
import json
import os
import time
from pathlib import Path

import pytest
from test_runtime_embed import (ESESSION, SPIKE, SPIKE_PARTIALS, FakeEmbedder, _ask, embed_hits, idle, make, partial, run,
                                start)

from verse_brain.runtime.embed import DEFAULT_MODEL, AcceptRule, LiteRtEmbedder, MatchState, step
from verse_brain.runtime.settings import Config

NO_FAST = {"embed_fast_threshold": None}


# ---------------------------------------------------------------- embed.step (shared by the engine and the offline tools)

def test_step_base_lane_needs_three_in_a_row_and_resets_on_a_rejection():
    r, st = AcceptRule(0.90, 0.005, 3), MatchState()
    seq = [("b1", 0.91, 0.85), ("b1", 0.91, 0.85), ("b1", 0.89, 0.85), ("b1", 0.91, 0.85), ("b1", 0.91, 0.85),
           ("b1", 0.91, 0.85), ("b1", 0.92, 0.85)]
    assert [step(st, r, *e) for e in seq] == [None, None, None, None, None, "b1", None]


def test_step_fast_lane_needs_score_and_margin_on_one_evaluation():
    r = AcceptRule(0.90, 0.005, 3, fast_threshold=0.93, fast_margin=0.03, fast_consecutive=1)
    assert step(MatchState(), r, "b1", 0.935, 0.90) == "b1"
    assert step(MatchState(), r, "b1", 0.935, 0.91) is None, "margin 0.025 < 0.03"
    assert step(MatchState(), r, "b1", 0.925, 0.80) is None, "below the fast threshold"
    assert step(MatchState(), AcceptRule(0.90, 0.005, 3), "b1", 0.99, 0.80) is None, "fast lane off"


def test_step_final_text_needs_one_evaluation_and_an_id_is_sent_once():
    r, st = AcceptRule(0.90, 0.005, 3), MatchState()
    assert step(st, r, "b1", 0.905, 0.85, final=True) == "b1"
    assert step(st, r, "b1", 0.905, 0.85, final=True) is None
    assert step(st, r, "b2", 0.95, 0.85, final=True) == "b2"


def test_config_rule_per_language():
    c = Config(embed_lang_rules={"it": {"threshold": 0.95, "fast_threshold": None}})
    assert c.embed_rule("en") == AcceptRule(0.90, 0.005, 3, 0.93, 0.03, 1)
    assert c.embed_rule("it") == AcceptRule(0.95, 0.005, 3, None, 0.03, 1)
    assert c.embed_rule("tr") == c.embed_rule("en")
    assert Config().embed_langs == ("en",), "it/tr are not calibrated (settings.py): they stay lexical"


# ---------------------------------------------------------------- the fast lane in the engine

HIGH = [("end up where", {"b001": 0.95, "b005": 0.85})]


def test_fast_lane_shows_the_card_on_the_first_partial():
    """One partial far above the threshold: the card shows then, not two partials (about 1.1 s of speech) later. With the
    fast lane off, the same partial shows nothing."""
    async def go(**cfg):
        fe = FakeEmbedder(HIGH)
        b, t, em = make(fe, **cfg)
        await start(b)
        await partial(b, "q1", "How did you end up where")
        await idle(b)
        return em

    hits = embed_hits(run(go()))
    assert [(h["turn_id"], h["bank_id"]) for h in hits] == [("q1", "b001")]
    assert not embed_hits(run(go(**NO_FAST)))


def test_fast_lane_keeps_the_recorded_offbank_spikes_out():
    """The two off-bank prefix spikes of the stored replay f3-embed (0.914 on one entry; the dispatcher-pilot question at 0.920)
    stay without a card: both are below 0.93."""
    dispatch = [("for the dispatcher pilot", {"b013": 0.888, "b009": 0.85}),
                ("success for the dispatcher", {"b013": 0.896, "b009": 0.86}),
                ("measure success for", {"b013": 0.920, "b009": 0.87})]
    dispatch_partials = ("How would you measure success for", "How would you measure success for the dispatcher",
                         "How would you measure success for the dispatcher pilot")

    async def go(rules, partials):
        fe = FakeEmbedder(rules)
        b, t, em = make(fe)
        await start(b)
        await _ask(b, "q1", partials, partials[-1] + "?")
        return em

    assert not embed_hits(run(go(SPIKE, SPIKE_PARTIALS)))
    assert not embed_hits(run(go(dispatch, dispatch_partials)))


def test_fast_lane_needs_its_margin():
    async def go():
        fe = FakeEmbedder([("end up where", {"b001": 0.95, "b005": 0.93})])
        b, t, em = make(fe)
        await start(b)
        await partial(b, "q1", "How did you end up where")
        await idle(b)
        return em

    assert not embed_hits(run(go()))


# ---------------------------------------------------------------- languages

async def _start_lang(b, lang: str) -> None:
    await b.handle({"type": "start", "session_dir": str(ESESSION), "lang": lang})
    await b.warmed()
    end = time.monotonic() + 5
    while b.embed is not None and b.embed.state == "loading" and time.monotonic() < end:
        await asyncio.sleep(0.01)


THREE = ("How did you end up where", "How did you end up where you are", "How did you end up where you are today")


def test_uncalibrated_language_stays_lexical():
    """An Italian or Turkish session (default config) never embeds a partial: Swift's n-gram matcher is the only bank matcher."""
    async def go(lang):
        fe = FakeEmbedder(HIGH)
        b, t, em = make(fe)
        await _start_lang(b, lang)
        assert b.embed.state == "off", b.embed.state          # never started: no index for an uncalibrated language
        for text in THREE:
            await partial(b, "q1", text)
            await idle(b, allow_off=True)
        await b.handle({"type": "turn", "turn_id": "q1", "speaker": "remote", "text": THREE[-1], "addressee": "me",
                        "kind": "question", "t_audio_end": 0.0})
        await idle(b, allow_off=True)
        return em, fe

    for lang in ("it", "tr"):
        em, fe = run(go(lang))
        assert not embed_hits(em) and fe.queries == [], (lang, fe.queries)


def test_rule_follows_the_language_of_the_index():
    """With a stricter Italian rule, an Italian session's index uses it (and says so in the metric); English keeps its own."""
    cfg = {"embed_langs": ("en", "it"), "embed_lang_rules": {"it": {"threshold": 0.95, "fast_threshold": None}}}

    async def go(lang):
        fe = FakeEmbedder([("end up where", {"b001": 0.925, "b005": 0.85})])
        b, t, em = make(fe, **cfg)
        await _start_lang(b, lang)
        for text in THREE:
            await partial(b, "q1", text)
            await idle(b)
        return em

    em_it = run(go("it"))
    assert not embed_hits(em_it)
    assert {m["lang"] for m in em_it.of("metric", stage="embed")} == {"it"}
    assert [h["bank_id"] for h in embed_hits(run(go("en")))] == ["b001"]


# ---------------------------------------------------------------- review P4: restart and close races

def test_restart_during_a_running_match_does_not_turn_the_path_off():
    """A language change restarts the index while a match runs on the worker thread: the old result is dropped, the path stays
    on (no `embed_unavailable`, no warning latch) and the next partial is matched on the new index."""
    async def go():
        fe = FakeEmbedder(HIGH, delay=0.25)
        b, t, em = make(fe, embed_langs=("en", "it"))
        await start(b)
        await partial(b, "q1", "How did you end up where")
        await asyncio.sleep(0.08)                       # the match is running
        await b.handle({"type": "control", "action": "lang", "lang": "it"})
        end = time.monotonic() + 5
        while b.embed.state != "ready" and time.monotonic() < end:
            await asyncio.sleep(0.01)
        await asyncio.sleep(0.3)
        state_after_restart = b.embed.state
        await partial(b, "q2", "How did you end up where you are")
        await idle(b)
        return b, em, state_after_restart

    b, em, state = run(go())
    assert not em.of("metric", stage="embed_unavailable"), em.of("metric", stage="embed_unavailable")
    assert state == "ready" and not b.embed._warned
    assert [h["turn_id"] for h in embed_hits(em)] == ["q2"], "q1's result belonged to the replaced index"


def test_close_during_load_closes_the_engine():
    """close() while the engine is still loading: the engine built afterwards is closed, not leaked."""
    built: list[FakeEmbedder] = []

    def factory():
        time.sleep(0.3)
        fe = FakeEmbedder(HIGH)
        built.append(fe)
        return fe

    async def go():
        b, t, em = make(factory=factory)
        await b.handle({"type": "start", "session_dir": str(ESESSION), "lang": "en"})
        await asyncio.sleep(0.05)
        b.embed.close()
        await asyncio.sleep(0.6)
        return b, em

    b, em = run(go())
    assert len(built) == 1 and built[0].closed
    assert b.embed._embedder is None
    assert not em.of("metric", stage="embed_ready")


# ---------------------------------------------------------------- the real model

_HAVE_MODEL = os.path.isfile(os.path.expanduser(DEFAULT_MODEL))
try:
    import litert_lm  # noqa: F401
    _HAVE_LITERT = True
except ImportError:
    _HAVE_LITERT = False

ML = Path(__file__).resolve().parents[2] / "bench" / "embed" / "ml"


@pytest.mark.skipif(not (_HAVE_MODEL and _HAVE_LITERT), reason="EmbeddingGemma model or litert_lm missing")
def test_real_model_italian_paraphrases_reach_the_wrong_entry_high():
    """Why it/tr stay lexical, on the real model: in the Italian bank (bench/embed/ml/it.json) blind paraphrases of one entry
    score above 0.92 on ANOTHER entry (b003 "what did you build with Lantern" -> b011 Lantern's accuracy, 0.943; b018 "what
    do you bring to route optimisation" -> b007 the route optimiser, 0.926), where English right-entry hits sit (p50 0.906):
    any threshold that keeps such cards out drops nearly every hit (settings.py, embed_langs)."""
    from verse_brain.runtime.embed import BankIndex
    data = json.loads((ML / "it.json").read_text(encoding="utf-8"))
    bank = {k: {"question": v["question"], "paraphrases": {"it": v["paraphrases"]}} for k, v in data["bank"].items()}
    emb = LiteRtEmbedder()
    try:
        idx = BankIndex(emb, bank, "it")
        from verse_brain.runtime.embed import PREFIX, unit
        got = {t: idx.top2(unit(emb.embed(PREFIX + data["blind"][t][j])))[0] for t, j in (("b003", 2), ("b018", 1))}
    finally:
        emb.close()
    assert got["b003"][0] == "b011" and got["b003"][1] >= 0.92, got
    assert got["b018"][0] == "b007" and got["b018"][1] >= 0.92, got
