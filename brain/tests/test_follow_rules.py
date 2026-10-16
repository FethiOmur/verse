"""Follow my answer: coverage of card points, the refresh schedule and the end conditions (runtime/follow.py)."""

from __future__ import annotations

from follow_helpers import CARD, PACK_FOR_DETECTOR, ConceptEmbedder

from verse_brain.runtime.follow import Covered, Diverged, Ended, FollowMachine, FollowParams, Refresh
from verse_brain.runtime.follow_drive import Clock, make_machine, simulate

WORD = dict(wps=2.5, chunk_s=0.4)
SENTENCE = "the running app coaches marathon training for complete beginners"      # 8 words, 6 content words


def covered(text, **kw):
    r = simulate(CARD, text, embedder=ConceptEmbedder(), pack=PACK_FOR_DETECTOR, **{**WORD, **kw})
    return sorted({e.fx.point for e in r.of(Covered)}), r


def test_a_point_said_in_other_words_is_struck():
    pts, r = covered("With Lantern the time people spent typing invoice data went down from eleven minutes to just two")
    assert 1 in pts
    assert r.of(Covered)[0].fx.via in ("lex", "embed")


def test_a_point_said_verbatim_is_struck_lexically():
    r = simulate(CARD, "I also built a small route optimiser for a courier pilot that reduced empty runs by fourteen percent",
                 embedder=None, **WORD)
    assert [e.fx.point for e in r.of(Covered)] == [2]
    assert r.of(Covered)[0].fx.via == "lex"


def test_an_unrelated_sentence_strikes_nothing():
    pts, r = covered("Outside of work I train for the marathon and last spring I ran a trail race near the lake")
    assert pts == []


def test_a_point_with_other_numbers_is_not_struck():
    """Same words, other facts: "twenty minutes to five" says something else than "11 minutes to 2 minutes", and a
    sentence that has not reached its numbers yet has not said the point."""
    pts, _ = covered("With Lantern the time people spent typing invoice data went down from twenty minutes to five")
    assert 1 not in pts
    r = simulate(CARD, "Lantern cut manual data entry from twenty minutes to five minutes per invoice", embedder=None, **WORD)
    assert not r.of(Covered)


def test_a_point_is_struck_once():
    pts, r = covered("I also built a small route optimiser for a courier pilot that reduced empty runs by fourteen percent. "
                     "I also built a small route optimiser for a courier pilot that reduced empty runs by fourteen percent")
    assert len(r.of(Covered)) == 1


# ------------------------------------------------------------------------------------------------------------ refresh
def following(clock: Clock | None = None, params: FollowParams | None = None):
    """A machine that diverged and whose follow call (c0001, two points) is on screen and done at t = clock.t."""
    clock = clock or Clock()
    m, drv = make_machine(CARD, params, ConceptEmbedder(), clock, card_id="orig-q1", pack=PACK_FOR_DETECTOR)
    fx: list = []
    drv.m.c_started("c0001", now=clock.t)
    m.add_line("c0001", "C", "say", "It is a running coach for iOS.")
    m.add_line("c0001", "C", "point", "It is live on the App Store.")
    m.add_line("c0001", "C", "point", "It reached the first thousand users.")
    m.c_done()
    return m, drv, clock, fx


def speak(m, drv, clock, fx, words, t0, per=0.4, turn="m1", prefix=""):
    ws = words.split()
    for i in range(1, len(ws) + 1):
        clock.t = round(t0 + per * i, 3)
        m.on_me(turn, (prefix + " " + " ".join(ws[:i])).strip(), False)
        drv.pump(fx.append, now=clock.t)
        m.tick()
        drv.pump(fx.append, now=clock.t)
    return clock.t


def idle(m, drv, clock, fx, t0, secs, step=0.1):
    t = t0
    while t < t0 + secs:
        t = round(t + step, 3)
        clock.t = t
        m.tick()
        drv.pump(fx.append, now=t)
    return t


def refreshes(fx):
    return [e for e in fx if isinstance(e, Refresh)]


def test_refresh_never_comes_mid_sentence():
    clock = Clock(10.0)
    m, drv, clock, fx = following(clock)
    clock.t = 15.0                                      # more than 4 s after the follow call
    speak(m, drv, clock, fx, SENTENCE, 15.0)
    assert not refreshes(fx), "he is still talking: the card does not change under him"


def test_refresh_comes_at_the_pause_after_four_new_content_words():
    clock = Clock(10.0)
    m, drv, clock, fx = following(clock)
    t = speak(m, drv, clock, fx, SENTENCE, 15.0)
    idle(m, drv, clock, fx, t, 1.0)
    assert len(refreshes(fx)) == 1 and refreshes(fx)[0].new_words >= 4


def test_fewer_than_four_new_content_words_do_not_refresh():
    clock = Clock(10.0)
    m, drv, clock, fx = following(clock)
    t = speak(m, drv, clock, fx, "the app plans training", 15.0)
    idle(m, drv, clock, fx, t, 2.0)
    assert not refreshes(fx)


def test_refresh_waits_for_four_seconds_after_the_follow_call_and_fires_once():
    clock = Clock(10.0)
    m, drv, clock, fx = following(clock)
    t = speak(m, drv, clock, fx, SENTENCE, 10.2, per=0.2)
    assert t < 12.5 and not refreshes(fx)
    t = idle(m, drv, clock, fx, t, 1.0)
    assert not refreshes(fx), "he has paused, but it is less than 4 s since the follow call"
    idle(m, drv, clock, fx, t, 5.0)
    assert len(refreshes(fx)) == 1, "it fires at the first pause after the gap, once"
    m.c_started("c0002", now=clock.t)
    m.c_done()
    t = idle(m, drv, clock, fx, clock.t, 6.0)
    assert len(refreshes(fx)) == 1, "no new words, no new refresh"


def test_a_refresh_is_not_started_while_the_follow_call_still_streams():
    clock = Clock(10.0)
    m, drv, clock, fx = following(clock)
    m.c_in_flight = True
    t = speak(m, drv, clock, fx, SENTENCE, 15.0)
    idle(m, drv, clock, fx, t, 2.0)
    assert not refreshes(fx)


def test_all_points_covered_and_stopped_means_quiet():
    clock = Clock(10.0)
    m, drv, clock, fx = following(clock, FollowParams(pause_s=0.7, quiet_s=0.0))
    # He says exactly the two points on the follow card; the card has nothing left to offer and he has stopped.
    t = speak(m, drv, clock, fx, "it is live on the app store and it reached the first thousand users", 15.0)
    idle(m, drv, clock, fx, t, 2.0)
    assert any(isinstance(e, Covered) and e.card_id == "c0001" for e in fx)
    assert not refreshes(fx)


def test_words_that_return_to_the_original_card_are_not_news_for_the_follow_card():
    clock = Clock(10.0)
    m, drv, clock, fx = following(clock)
    t = speak(m, drv, clock, fx, "Lantern cut manual data entry from eleven minutes to two minutes per invoice", 15.0)
    idle(m, drv, clock, fx, t, 2.0)
    assert not refreshes(fx)
    assert any(isinstance(e, Covered) and e.card_id == "orig-q1" and e.point == 1 for e in fx)


def test_a_final_result_is_a_sentence_end():
    clock = Clock(10.0)
    m, drv, clock, fx = following(clock)
    t = speak(m, drv, clock, fx, SENTENCE, 15.0)
    clock.t = t + 0.1
    m.on_me("m1", SENTENCE, True)
    drv.pump(fx.append, now=clock.t)
    assert len(refreshes(fx)) == 1


# --------------------------------------------------------------------------------------------------------------- end
def started():
    clock = Clock(0.0)
    m, drv = make_machine(CARD, None, ConceptEmbedder(), clock, card_id="orig-q1", pack=PACK_FOR_DETECTOR)
    return m, drv, clock, []


def test_a_new_remote_question_ends_the_turn():
    m, drv, clock, fx = started()
    speak(m, drv, clock, fx, "Actually the thing I'm most proud of is a running app for the marathon called Trailhead", 0.0)
    assert any(isinstance(e, Diverged) for e in fx)
    m.new_turn("q2")
    assert m.turn_id == "q2" and not m.cards and m.mode == "watch" and not m.toks()
    fx.clear()
    clock.t += 1.0
    m.on_me("m1", "Actually the thing I'm most proud of is a running app", False)   # the old turn's text keeps coming in
    assert not m.toks(), "his open turn belongs to the old question"
    assert not m.drain()


def test_four_seconds_of_silence_after_the_remote_spoke_again_ends_follow_mode():
    m, drv, clock, fx = started()
    t = speak(m, drv, clock, fx, "so the running app", 0.0)
    m.on_remote_activity(now=t + 0.5)
    for i in range(1, 80):
        clock.t = round(t + 0.5 + i * 0.1, 3)
        m.tick()
    ends = [e for e in m.drain() if isinstance(e, Ended)]
    assert len(ends) == 1 and ends[0].reason == "remote_spoke_again"
    assert m.ended


def test_he_keeps_talking_while_the_remote_speaks_no_end():
    m, drv, clock, fx = started()
    t = speak(m, drv, clock, fx, "so the running app", 0.0)
    m.on_remote_activity(now=t)
    t = speak(m, drv, clock, fx, "is a coach that plans marathon training for beginners and runs offline", t)
    for i in range(1, 30):
        clock.t = round(t + i * 0.1, 3)
        m.tick()
    assert not m.ended
