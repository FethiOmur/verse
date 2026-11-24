"""Follow my answer: the refresh cap (`max_refreshes_per_answer`, `min_card_show_s`), an extra gate on the refresh rules."""

from __future__ import annotations

from follow_helpers import CARD, PACK_FOR_DETECTOR, ConceptEmbedder
from test_follow_log import Sink
from test_follow_rules import SENTENCE, idle, refreshes, speak

from verse_brain.runtime.follow import FollowParams
from verse_brain.runtime.follow_drive import Clock, make_machine

# six sentences with no word in common (each is four or more new content words)
SENTENCES = [
    "the running app coaches marathon training for complete beginners",
    "weekly challenges reward consistent athletes with colourful badges",
    "friends compare distances through leaderboards every sunday evening",
    "premium subscribers unlock detailed pacing charts after workouts",
    "volunteers translated onboarding screens into seven additional languages",
    "yesterday journalists reviewed everything and published glowing coverage",
]


def following(clock, params=None, sink=None):
    """Diverged and the first follow card (c0001) is on screen, shown at clock.t."""
    m, drv = make_machine(CARD, params, ConceptEmbedder(), clock, card_id="orig-q1", pack=PACK_FOR_DETECTOR, log=sink)
    m.c_started("c0001", now=clock.t)
    m.add_line("c0001", "C", "say", "It is a running coach for iOS.")
    m.add_line("c0001", "C", "point", "It is live on the App Store.")
    m.add_line("c0001", "C", "point", "It reached the first thousand users.")
    m.c_done()
    return m, drv


def launch_card(m, n):
    """What the engine does for a Refresh it accepts: launch the call, show its card."""
    m.c_started(f"c{n:04d}")
    m.add_line(f"c{n:04d}", "C", "say", f"Next idea number {n} about {SENTENCES[n]}.")
    m.add_line(f"c{n:04d}", "C", "point", f"Detail {n} about {SENTENCES[n].split()[1]}.")
    m.c_done()


def test_a_long_answer_with_many_sentence_ends_gets_one_first_card_and_two_refreshes():
    sink, fx = Sink(), []
    clock = Clock(10.0)
    m, drv = following(clock, sink=sink)
    t, cards = clock.t, 1
    for i, sentence in enumerate(SENTENCES):
        t = speak(m, drv, clock, fx, sentence, t + 0.2, turn="m1", prefix=" ".join(SENTENCES[:i]))
        t = idle(m, drv, clock, fx, t, 10.0)               # a pause long enough for the gap and the 8 s floor
        if len(refreshes(fx)) > cards - 1:
            launch_card(m, cards)
            cards += 1
    assert len(refreshes(fx)) == 2 and cards == 3, (len(refreshes(fx)), cards)
    assert m.refresh_count == 2
    capped = [s for s in sink.of("follow_state", state="refresh_blocked") if s["reason"] == "refresh_capped"]
    assert capped and all(s["refreshes"] == 2 and s["max_refreshes"] == 2 for s in capped)
    assert len({(s["refreshes"], s["new_words"], s["card_age_s"]) for s in capped}) == len(capped)


def test_a_refresh_five_seconds_after_the_card_is_blocked_and_one_at_eight_seconds_passes():
    sink, fx = Sink(), []
    clock = Clock(10.0)
    m, drv = following(clock, sink=sink)
    t = speak(m, drv, clock, fx, SENTENCE, 10.2, per=0.2)           # card shown at 10.0, his sentence ends near 12.0
    t = idle(m, drv, clock, fx, t, 15.0 - t)                          # 5 s after the card: gap and pause are fine
    assert not refreshes(fx), "the card has been on screen for 5 s"
    blocked = sink.of("follow_state", state="refresh_blocked")
    assert len(blocked) == 1, "once per sentence end, not once per tick"
    assert blocked[0]["reason"] == "refresh_too_soon" and 4.0 <= blocked[0]["card_age_s"] < 8.0
    assert blocked[0]["min_card_show_s"] == 8.0
    idle(m, drv, clock, fx, t, 3.5)                                   # now 8.5 s
    assert len(refreshes(fx)) == 1


def test_the_floor_counts_from_when_the_card_got_its_say_line():
    """The follow call was launched at 10.0 but its card only reached the screen at 14.0: 8 s run from 14.0."""
    fx = []
    clock = Clock(10.0)
    m, drv = make_machine(CARD, None, ConceptEmbedder(), clock, card_id="orig-q1", pack=PACK_FOR_DETECTOR)
    m.c_started("c0001", now=10.0)
    clock.t = 14.0
    m.add_line("c0001", "C", "say", "It is a running coach for iOS.")
    m.c_done()
    t = speak(m, drv, clock, fx, SENTENCE, 14.2, per=0.2)
    idle(m, drv, clock, fx, t, 20.5 - t)                              # 6.5 s after the card, 10.5 s after the launch
    assert not refreshes(fx)
    idle(m, drv, clock, fx, clock.t, 2.0)
    assert len(refreshes(fx)) == 1


def test_a_new_question_and_the_end_of_follow_mode_reset_the_count():
    clock = Clock(10.0)
    m, _ = following(clock)
    m.c_started("c0002")
    m.c_started("c0003")
    assert m.refresh_count == 2
    m.new_turn("q2")
    assert m.refresh_count == 0 and m.card_shown_t is None
    m.c_started("c0004")
    m.c_started("c0005")
    assert m.refresh_count == 1
    m.end("remote_spoke_again")
    assert m.refresh_count == 0


def test_a_refused_launch_does_not_use_up_a_refresh():
    sink, fx = Sink(), []
    clock = Clock(10.0)
    m, drv = following(clock, FollowParams(max_refreshes_per_answer=1), sink=sink)
    t = speak(m, drv, clock, fx, SENTENCES[0], 10.2, per=0.2)
    t = idle(m, drv, clock, fx, t, 10.0)
    assert len(refreshes(fx)) == 1
    m.c_failed(reason="call_refused:refresh")                        # the engine could not start the call
    assert m.refresh_count == 0
    t = speak(m, drv, clock, fx, SENTENCES[1], t + 0.2, prefix=SENTENCES[0])
    idle(m, drv, clock, fx, t, 2.0)
    assert len(refreshes(fx)) == 2, "the next sentence end may try again"
    m.c_started("c0002")
    assert m.refresh_count == 1
    assert [s["reason"] for s in sink.of("follow_state", state="launch_refused")] == ["call_refused:refresh"]
