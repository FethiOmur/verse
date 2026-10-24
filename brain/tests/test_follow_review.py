"""Regression tests for the review of the follow-my-answer branch (GPT-6 Astra A1-A4, Opus N1 and the minors).

Each test was written against the code as reviewed and failed there; the fix is in follow.py / engine.py."""

from __future__ import annotations

import asyncio
from dataclasses import replace

from follow_helpers import CARD, PACK_FOR_DETECTOR, ConceptEmbedder
from test_runtime_follow import FAST_PARAMS, OFF_CARD, c_calls, make, me, question, responder, settle, start
from test_runtime_helpers import lines_script, turn

from verse_brain.runtime.follow import Covered, Diverged, FollowMachine, FollowParams, NeedEmbed, Refresh
from verse_brain.runtime.follow_drive import Clock, SyncDriver

PARAPHRASE = "I did all of the engineering work completely by myself over several long evenings"


def kinds(fx):
    return [type(e).__name__ for e in fx]


# --------------------------------------------------------------------------------------------------------------- A1
def test_a1_a_stale_embedding_does_not_decide_a_corrected_paraphrase():
    """The scores belong to the words of the request. If he (or the recognizer) revised those words meanwhile, the old
    scores must not flip the card for the new words; a fresh embedding of the current text is asked for instead."""
    clk = Clock(0.0)
    m = FollowMachine(FollowParams(), clk, embed_ok=True)
    m.new_turn("q1")
    m.add_line("orig-q1", "F", "say", "I built it mostly solo.")
    m.drain()
    clk.t = 1.0
    m.on_me("m1", "marathon training runners racing endurance")
    old = [e for e in m.drain() if isinstance(e, NeedEmbed)][-1]
    clk.t = 1.5
    m.on_me("m1", PARAPHRASE)
    m.drain()
    clk.t = 1.6
    m.on_embed(old.seq, {k: [0.70] * len(old.lines) for k in old.texts})
    fx = m.drain()
    assert not any(isinstance(e, Diverged) for e in fx), kinds(fx)
    fresh = [e for e in fx if isinstance(e, NeedEmbed)]
    assert fresh and "evenings" in fresh[-1].texts["stretch"], "the current text is embedded again"
    assert m._pend_div is not None and m._pend_div["seq"] == fresh[-1].seq
    # the answer for the current text decides: a paraphrase stays...
    clk.t = 1.7
    m.on_embed(fresh[-1].seq, {k: [0.92] * len(fresh[-1].lines) for k in fresh[-1].texts}, {k: 0.80 for k in fresh[-1].texts})
    assert not any(isinstance(e, Diverged) for e in m.drain())


def test_a1_words_added_to_the_end_do_not_invalidate_the_answer():
    """Only a revision of the words the request was about makes its scores stale; he simply talking on does not."""
    clk = Clock(0.0)
    m = FollowMachine(FollowParams(), clk, embed_ok=True)
    m.new_turn("q1")
    m.add_line("orig-q1", "F", "say", "I built it mostly solo.")
    clk.t = 1.0
    m.on_me("m1", "marathon training runners racing endurance")
    req = [e for e in m.drain() if isinstance(e, NeedEmbed)][-1]
    clk.t = 1.5
    m.on_me("m1", "marathon training runners racing endurance every single morning before work")
    clk.t = 1.6
    m.on_embed(req.seq, {k: [0.70] * len(req.lines) for k in req.texts}, {k: 0.72 for k in req.texts})
    assert any(isinstance(e, Diverged) for e in m.drain())


# --------------------------------------------------------------------------------------------------------------- A2
def feed(m, text, per=0.56, t0=0.0, tick=True):
    ws = text.split()
    out = []
    for i in range(1, len(ws) + 1):
        m.clock.t = round(t0 + per * i, 3)
        m.on_me("m1", " ".join(ws[:i]))
        if tick:
            m.tick()
        out += m.drain()
    return out


def test_a2_without_the_embedder_nothing_diverges():
    m = FollowMachine(FollowParams(), Clock(0.0), embed_ok=False)
    m.new_turn("q1")
    m.add_line("orig-q1", "F", "say", "I built it mostly solo.")
    fx = feed(m, PARAPHRASE)
    fx += feed(m, "Actually the thing I am most proud of is a running app for the marathon called TrailHead on the App Store "
                  "with thousands of weekly users and a long list of new features", t0=20.0)
    assert not any(isinstance(e, Diverged) for e in fx)
    for i in range(1, 100):                       # and no timer path either
        m.clock.t = 40.0 + 0.1 * i
        m.tick()
    assert not any(isinstance(e, Diverged) for e in m.drain())


def test_a2_without_the_embedder_coverage_still_works():
    m = FollowMachine(FollowParams(), Clock(0.0), embed_ok=False)
    m.new_turn("q1")
    m.add_line("orig-q1", "F", "say", CARD["say"])
    for p in CARD["points"]:
        m.add_line("orig-q1", "F", "point", p)
    fx = feed(m, "I also built a small route optimiser for a courier pilot that reduced empty runs by fourteen percent")
    assert [e.point for e in fx if isinstance(e, Covered)] == [2]


def test_a2_an_embedder_that_never_answers_does_not_flip_the_card_either():
    clk = Clock(0.0)
    m = FollowMachine(FollowParams(), clk, embed_ok=True)
    m.new_turn("q1")
    m.add_line("orig-q1", "F", "say", "I built it mostly solo.")
    fx = feed(m, PARAPHRASE)                    # requests go out, no answer ever comes
    for i in range(1, 60):
        clk.t = 10.0 + 0.1 * i
        m.tick()
        fx += m.drain()
    assert not any(isinstance(e, Diverged) for e in fx)
    assert any(isinstance(e, NeedEmbed) for e in fx), "it keeps asking instead"


# --------------------------------------------------------------------------------------------------------------- A3
def following_with_bank(bank_first: bool):
    clk = Clock(0.0)
    m = FollowMachine(FollowParams(), clk, embed_ok=True)
    m.new_turn("q1")
    pt = "Lantern cut manual data entry from eleven minutes to two minutes per invoice"
    if bank_first:
        m.add_line("bank:b1", "bank", "point", pt, source="bank")
    m.add_line("orig-q1", "F", "say", "Sure, here is the short version.")
    m.add_line("orig-q1", "F", "point", pt)
    drv = SyncDriver(m, ConceptEmbedder(), PACK_FOR_DETECTOR)
    clk.t = 1.0
    m.c_started("c0001", now=1.0)
    m.add_line("c0001", "C", "say", "It is a running coach for iOS.")
    m.add_line("c0001", "C", "point", "It is live on the App Store.")
    m.add_line("c0001", "C", "point", "It reached the first thousand users.")
    m.c_done()
    fx: list = []
    drv.pump(fx.append, now=1.0)
    fx.clear()
    clk.t = 6.0
    m.on_me("m1", pt)
    drv.pump(fx.append, now=6.0)
    clk.t = 6.8
    m.tick()
    drv.pump(fx.append, now=6.8)
    return fx


def test_a3_reading_the_original_card_is_no_news_even_when_a_bank_reference_matches_too():
    for bank_first in (False, True):
        fx = following_with_bank(bank_first)
        assert not any(isinstance(e, Refresh) for e in fx), (bank_first, kinds(fx))
        assert any(isinstance(e, Covered) and e.card_id == "orig-q1" for e in fx)


# --------------------------------------------------------------------------------------------------------------- A4
def completed_card():
    clk = Clock(0.0)
    m = FollowMachine(FollowParams(), clk, embed_ok=True)
    m.new_turn("q1")
    m.add_line("orig-q1", "F", "say", "Sure, here is the short version.")
    m.add_line("orig-q1", "F", "point", "I built it mostly solo.")
    drv = SyncDriver(m, ConceptEmbedder(), PACK_FOR_DETECTOR)
    clk.t = 1.0
    m.c_started("c0001", now=1.0)
    m.add_line("c0001", "C", "say", "It is a running coach.")
    m.add_line("c0001", "C", "point", "Marathon training builds endurance")
    m.add_line("c0001", "C", "point", "Running races improves fitness")
    m.c_done()
    fx: list = []
    drv.pump(fx.append, now=1.0)
    fx.clear()
    return m, drv, clk, fx


def test_a4_a_finished_card_gets_no_refresh_with_the_shipped_timers():
    m, drv, clk, fx = completed_card()
    clk.t = 6.0
    m.on_me("m1", "Marathon training builds endurance and running races improves fitness")
    drv.pump(fx.append, now=6.0)
    assert m._all_covered()
    for t in (6.8, 7.2, 8.0, 9.0, 12.0):
        clk.t = t
        m.tick()
        drv.pump(fx.append, now=t)
    assert not any(isinstance(e, Refresh) for e in fx), kinds(fx)
    clk.t = 13.0
    m.on_me("m1", "Marathon training builds endurance and running races improves fitness", True)     # a final result
    drv.pump(fx.append, now=13.0)
    assert not any(isinstance(e, Refresh) for e in fx), "not even a final result"


def test_a4_new_material_after_the_card_is_finished_brings_the_refresh_back():
    m, drv, clk, fx = completed_card()
    clk.t = 6.0
    m.on_me("m1", "Marathon training builds endurance and running races improves fitness")
    drv.pump(fx.append, now=6.0)
    more = "Marathon training builds endurance and running races improves fitness. Then we added sleep tracking and nutrition plans for beginners"
    clk.t = 9.0
    m.on_me("m1", more)
    drv.pump(fx.append, now=9.0)
    for t in (9.5, 10.0):
        clk.t = t
        m.tick()
        drv.pump(fx.append, now=t)
    assert any(isinstance(e, Refresh) for e in fx)


# --------------------------------------------------------------------------------------------------------------- N1
def test_n1_his_turn_that_started_after_the_question_ended_moves_into_the_new_question():
    clk = Clock(0.0)
    m = FollowMachine(FollowParams(), clk, embed_ok=True)
    m.new_turn("q1")
    m.add_line("orig-q1", "F", "say", CARD["say"])
    clk.t = 10.0
    m.on_me("m1", "Sure here is the answer to the first question", True)          # his answer to q1, long closed
    clk.t = 50.0
    m.on_me("m2", "Actually the")                                                  # starts before the brain hears q2's turn
    m.new_turn("q2", since=49.0)
    m.add_line("orig-q2", "F", "say", "Another card.")
    clk.t = 50.4
    m.on_me("m2", "Actually the thing I am proud of is a running app")
    assert m.his_text() == "Actually the thing I am proud of is a running app", m.his_text()
    clk.t = 51.0
    m.on_me("m1", "Sure here is the answer to the first question and more")        # the old answer keeps arriving: ignored
    assert "first question" not in m.his_text()


def early_partial_scenario(early: bool):
    async def go():
        b, t, em, sess, fol = make()
        await start(b, sess, fol)
        await question(b, "q1", "Can you tell me about yourself?")
        await me(b, "Sure, here is the short version. I led Lantern.", tid="m1", final=True)
        await settle(b)
        await asyncio.sleep(1.3)                      # his answer to q1 is old news by the time q2 is heard
        if early:
            await b.handle({"type": "partial", "turn_id": "m2", "speaker": "me", "text": "Actually the", "cue": False,
                            "t_audio_end": 0.0})
        await question(b, "q2", "And what are you working on outside of work?")
        await me(b, OFF_CARD, tid="m2")
        await asyncio.sleep(0.4)
        await settle(b)
        return t, em
    return asyncio.run(go())


def test_n1_engine_a_partial_that_precedes_the_question_turn_is_not_lost():
    for early in (False, True):
        t, em = early_partial_scenario(early)
        fol = [e for e in em.events if e["type"] == "follow"]
        assert any(e["turn_id"] == "q2" for e in fol), ("early" if early else "control", fol)


PROBE = "KIND: question\nSAY: Outside of work I am building a running app called TrailHead.\n- It is live on the App Store."


def test_n1_escalation_keeps_the_probe_card_when_kind_and_say_arrive_in_one_chunk():
    base = responder()

    def r(info):
        if "STATEMENT CHECK" in info.tail:
            return lines_script(PROBE, per_chunk=0.0)          # a stream that never yields to the event loop
        return base(info)

    async def go():
        b, t, em, sess, fol = make(resp=r)
        await start(b, sess, fol)
        await turn(b, "q2", "Walk me through what you are building outside of work.", kind="statement")
        await settle(b)
        cards = {cid: [(ln.kind, ln.text) for ln in c.lines] for cid, c in b.follow.cards.items()}
        await me(b, OFF_CARD, tid="m1", every=0.02)
        await asyncio.sleep(0.4)
        await settle(b)
        return b, t, em, cards

    b, t, em, cards = asyncio.run(go())
    assert b.follow.turn_id == "q2"
    lines = cards.get("orig-q2", [])
    assert ("say", "Outside of work I am building a running app called TrailHead.") in lines
    assert ("point", "It is live on the App Store.") in lines


# ------------------------------------------------------------------------------------------------------------- minors
def test_the_follow_card_is_visible_only_once_its_say_line_has_arrived():
    m = FollowMachine(FollowParams(), Clock(0.0), embed_ok=True)
    m.new_turn("q1")
    m.add_line("orig-q1", "F", "say", "Sure.")
    m.add_line("orig-q1", "F", "point", "A point on the card.")
    m.c_started("c1", now=0.0)
    m.add_line("c1", "C", "point", "A point that came before the SAY line.")
    assert m.visible_id == "orig-q1"
    m.add_line("c1", "C", "say", "Now the SAY line.")
    assert m.visible_id == "c1"


def test_bank_points_on_screen_before_the_fast_say_can_be_struck_and_then_become_references():
    clk = Clock(0.0)
    m = FollowMachine(FollowParams(), clk, embed_ok=False)
    m.new_turn("q1")
    m.add_line("bank:b1", "bank", "say", "Sure, I'll give you the short version.", source="bank", report_as="orig-q1")
    m.add_line("bank:b1", "bank", "point", CARD["points"][0], source="bank", report_as="orig-q1")
    m.add_line("bank:b1", "bank", "point", CARD["points"][1], source="bank", report_as="orig-q1")
    m.drain()
    clk.t = 1.0
    m.on_me("m1", "Lantern cut manual data entry from eleven minutes to two minutes per invoice")
    cov = [e for e in m.drain() if isinstance(e, Covered)]
    assert [(e.card_id, e.point) for e in cov] == [("orig-q1", 1)]
    m.add_line("orig-q1", "F", "say", "Sure, I'll give you the short version.")
    m.add_line("orig-q1", "F", "point", CARD["points"][2])
    assert not any(ln.visible for ln in m.card_lines("bank:b1")), "the fast tier's card replaced the bank card on screen"
