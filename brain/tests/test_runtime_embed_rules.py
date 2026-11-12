"""The paraphrase matcher's accept rule per language and its fast lane (embed.step, Config.embed_rule), and the restart / close
races of the embedding path (review P4). Fake embedder with exact cosines; one test runs the real model."""

from __future__ import annotations

import asyncio
import json
import math
import os
import time
from pathlib import Path

import pytest
from test_runtime_embed import (ESESSION, SPIKE, SPIKE_PARTIALS, FakeEmbedder, _ask, embed_hits, idle, make, partial, run,
                                start)

from verse_brain.runtime.embed import (DEFAULT_MODEL, PREFIX, AcceptRule, LiteRtEmbedder, MatchState, bank_phrases,
                                       entry_scores, gates_ok, step)
from verse_brain.runtime.protocol import load_session
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
    assert c.embed_rule("en") == AcceptRule(0.90, 0.005, 3, 0.93, 0.03, 1, support=0.855, isolation=0.045, isolation_rank=3)
    assert c.embed_rule("it") == AcceptRule(0.95, 0.005, 3, None, 0.03, 1, support=0.855, isolation=0.045, isolation_rank=3)
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


# ---------------------------------------------------------------- support and isolation gates (near misses, 2026-11-12)

def test_entry_scores_best_second_and_isolation():
    ids = ["b1", "b2", "b3", "b4", "b5"]
    #            b1 phrases        b2          b3     b4     b5 (one phrase)
    phrase = [0.95, 0.80, 0.86, 0.90, 0.70, 0.88, 0.87, 0.60]
    entry = [0, 0, 0, 1, 1, 2, 3, 4]
    sc = entry_scores(phrase, entry, ids)
    assert sc.entries[:4] == [("b1", 0.95), ("b2", 0.90), ("b3", 0.88), ("b4", 0.87)]
    assert sc.support == 0.86, "the top entry's second-best phrase"
    assert sc.isolation(3) == pytest.approx(0.95 - 0.87)
    assert sc.isolation(10) == pytest.approx(0.95 - 0.60), "a bank smaller than the rank: the last entry"
    one = entry_scores([0.93], [0], ["b1"])
    assert one.support == 0.93 and one.isolation(3) == 1.0, "a single phrase / a single entry cannot be rejected by the gates"


def test_gates_need_support_and_isolation_and_reject_a_missing_value():
    r = AcceptRule(0.90, 0.005, 3, support=0.855, isolation=0.045)
    assert gates_ok(r, 0.914, 0.86, support=0.86, isolation=0.05)
    assert not gates_ok(r, 0.914, 0.86, support=0.852, isolation=0.05), "one phrase of the entry only"
    assert not gates_ok(r, 0.914, 0.86, support=0.86, isolation=0.04), "close to several entries at once"
    assert not gates_ok(r, 0.914, 0.86), "a gate the rule has but cannot check rejects"
    assert gates_ok(AcceptRule(0.90, 0.005, 3), 0.914, 0.86), "gates off: cosine and margin only"
    # a support failure resets the consecutive count like a low cosine
    st = MatchState()
    seq = [(0.86, 0.05), (0.86, 0.05), (0.852, 0.05), (0.86, 0.05), (0.86, 0.05), (0.86, 0.05)]
    got = [step(st, r, "b1", 0.914, 0.86, support=s, isolation=i) for s, i in seq]
    assert got == [None, None, None, None, None, "b1"]


class PhraseFake:
    """Like test_runtime_embed.FakeEmbedder, but each bank PHRASE has its own direction, so a query can be close to one
    phrasing of an entry and not to the others (what the support gate looks at). Background cosine 0.85. A rule gives, per
    entry, the cosines of its phrases in bank order (missing phrases take the last value); unlisted entries sit at 0.85."""

    B, A = 0.85, 0.5

    def __init__(self, rules: list[tuple[str, dict[str, list[float]]]]) -> None:
        sess = load_session(ESESSION)
        self.ids = sorted(sess.bank)
        self.phr = {bid: bank_phrases(sess.bank[bid], "en") for bid in self.ids}
        self.slot = {p.strip(): (bid, i) for bid in self.ids for i, p in enumerate(self.phr[bid])}
        self.pid = [(bid, i) for bid in self.ids for i in range(len(self.phr[bid]))]
        self.rules = rules
        self.queries: list[str] = []
        self.closed = False
        self.k = math.sqrt(1 - self.B)

    def _dim(self) -> int:
        return 1 + len(self.ids) + len(self.pid) + 1

    def _doc(self, bid: str, i: int) -> list[float]:
        v = [0.0] * self._dim()
        v[0] = math.sqrt(self.B)
        v[1 + self.ids.index(bid)] = self.k * math.sqrt(1 - self.A)
        v[1 + len(self.ids) + self.pid.index((bid, i))] = self.k * math.sqrt(self.A)
        return v

    def _query(self, scores: dict[str, list[float]]) -> list[float]:
        v = [0.0] * self._dim()
        v[0] = math.sqrt(self.B)
        for bid, ls in scores.items():
            full = [ls[i] if i < len(ls) else ls[-1] for i in range(len(self.phr[bid]))]
            lo = min(full)
            v[1 + self.ids.index(bid)] = (lo - self.B) / (self.k * math.sqrt(1 - self.A))
            for i, s in enumerate(full):
                v[1 + len(self.ids) + self.pid.index((bid, i))] = (s - lo) / (self.k * math.sqrt(self.A))
        rest = 1 - sum(x * x for x in v)
        assert rest >= 0, f"impossible scores {scores}"
        v[-1] = math.sqrt(rest)
        return v

    def embed(self, text: str) -> list[float]:
        body = text[len(PREFIX):] if text.startswith(PREFIX) else text
        if body.strip() in self.slot:
            return self._doc(*self.slot[body.strip()])
        self.queries.append(body)
        for sub, scores in self.rules:
            if sub in body.lower():
                return self._query(scores)
        return self._query({})

    def close(self) -> None:
        self.closed = True


# The recorded scores of "When is a bigger LLM worth paying for?" (a paraphrase of b019, how to choose between small and
# large models) against b012 (cost, was it worth it) in bench/embed (real model): one b012 phrase at 0.914, the entry's
# second-best phrase at 0.852. Placed on the fixture bank's b015. The 0.90 rule without the support gate shows it.
ONE_PHRASE = [("bigger llm worth", {"b015": [0.852, 0.914, 0.852, 0.852]})]
ONE_PHRASE_PARTIALS = ("When is a bigger LLM worth", "When is a bigger LLM worth paying", "When is a bigger LLM worth paying for")
# A near miss close to several entries at once: top 0.912 (two phrases agree, support 0.905), then 0.89 / 0.885 / 0.875, so
# top-1 minus the 4th-best entry is 0.037 (< 0.045); the margin over the runner-up (0.022) passes.
CROWDED = [("hardest bug you hit", {"b009": [0.912, 0.905], "b005": [0.89], "b001": [0.885], "b015": [0.875]})]
CROWDED_PARTIALS = ("What was the hardest bug you hit", "What was the hardest bug you hit in the",
                    "What was the hardest bug you hit in the route optimiser")
# A paraphrase: three phrases of b001 agree (support 0.90) and it stands out (isolation 0.065).
AGREE = [("end up where", {"b001": [0.915, 0.90, 0.90, 0.88]})]


def _run_phrase_fake(rules, partials, **cfg):
    async def go():
        fe = PhraseFake(rules)
        b, t, em = make(fe, **cfg)
        await start(b)
        await _ask(b, "q1", partials, partials[-1] + "?")
        return em, fe
    return run(go())


def test_support_gate_keeps_a_one_phrase_match_out():
    em, fe = _run_phrase_fake(ONE_PHRASE, ONE_PHRASE_PARTIALS)
    assert len(fe.queries) == 4, fe.queries                       # three partials and the final text were evaluated
    assert not embed_hits(em), embed_hits(em)
    m = em.of("metric", stage="embed", turn_id="q1")
    assert m[-1]["support"] == pytest.approx(0.852, abs=1e-3) and m[-1]["accepted"] is False
    assert m[-1]["isolation"] == pytest.approx(0.914 - 0.85, abs=1e-3)
    # with the gate off (the rule before 2026-11-12) the same scores show a card
    em_off, _ = _run_phrase_fake(ONE_PHRASE, ONE_PHRASE_PARTIALS, embed_support=None)
    assert [h["bank_id"] for h in embed_hits(em_off)] == ["b015"]


def test_isolation_gate_keeps_a_crowded_match_out():
    em, _ = _run_phrase_fake(CROWDED, CROWDED_PARTIALS)
    assert not embed_hits(em), embed_hits(em)
    assert em.of("metric", stage="embed", turn_id="q1")[-1]["isolation"] == pytest.approx(0.037, abs=1e-3)
    em_off, _ = _run_phrase_fake(CROWDED, CROWDED_PARTIALS, embed_isolation=None)
    assert [h["bank_id"] for h in embed_hits(em_off)] == ["b009"]


def test_a_paraphrase_that_several_phrases_support_still_hits():
    em, _ = _run_phrase_fake(AGREE, THREE)
    assert [(h["turn_id"], h["bank_id"]) for h in embed_hits(em)] == [("q1", "b001")]


EN_BANK = Path(__file__).resolve().parents[2] / "bench" / "embed" / "ml" / "en_bank.json"


@pytest.mark.skipif(not (_HAVE_MODEL and _HAVE_LITERT), reason="EmbeddingGemma model or litert_lm missing")
def test_real_model_gates_drop_other_entry_paraphrases_and_keep_a_paraphrase():
    """The sample-interview bank (22 entries, bench/embed/ml/en_bank.json), every word prefix from 5 words and the final text
    through embed.step, as the engine runs them. Two paraphrases the 0.90 rule shows on the WRONG entry are kept out by the
    support gate; a paraphrase of b019 still hits."""
    from verse_brain.runtime.embed import BankIndex, unit
    from verse_brain.runtime.engine import tokens
    bank = json.loads(EN_BANK.read_text(encoding="utf-8"))["bank"]
    now = Config().embed_rule("en")
    before = AcceptRule(0.90, 0.005, 3, 0.93, 0.03, 1)
    emb = LiteRtEmbedder()
    try:
        idx = BankIndex(emb, bank, "en")

        def card(sentence: str, rule: AcceptRule) -> str | None:
            st, w = MatchState(), sentence.split()
            texts = [" ".join(w[:n]) for n in range(1, len(w) + 1) if len(tokens(" ".join(w[:n]))) >= 5]
            for i, t in enumerate(texts + [sentence]):
                sc = idx.score(unit(emb.embed(PREFIX + t)))
                hit = step(st, rule, sc.entries[0][0], sc.entries[0][1], sc.entries[1][1], final=i == len(texts),
                           support=sc.support, isolation=sc.isolation(rule.isolation_rank))
                if hit:
                    return hit
            return None

        got = {s: (card(s, before), card(s, now)) for s in (
            "When is a bigger LLM worth paying for?",                   # b019's question, shown as b012 (cost) before
            "What exactly did you build with the Lantern pipeline?",    # b003's question, shown as b008 (our product) before
            "What drove the choice of model size?")}                    # b019
    finally:
        emb.close()
    assert got["When is a bigger LLM worth paying for?"] == ("b012", None), got
    assert got["What exactly did you build with the Lantern pipeline?"] == ("b008", None), got
    assert got["What drove the choice of model size?"] == ("b019", "b019"), got
