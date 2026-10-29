"""A follow card never restates what is already on his screen or in his own answer (runtime/repeat.py, engine `_follow_gate`).

The evidence: four follow cards in 25 seconds of one live answer, each saying the same idea again with the same two points in
other words. Here with fictional text: a refresh card that restates an earlier card is not shown (the card on screen stays), a
card with a genuinely new continuation goes through, a point that repeats is dropped alone, and a machine that hears only the same
idea again does not ask for a new card."""

from __future__ import annotations

import asyncio

from test_follow_rules import following, idle, refreshes, speak as speak_machine
from test_runtime_follow import C_CANNED, FAST_PARAMS, OFF_CARD, c_calls, make, question, me, responder, run, start

from verse_brain.runtime.follow import FollowParams
from verse_brain.runtime.follow_drive import Clock
from verse_brain.runtime.prompt import follow_tail
from verse_brain.runtime.repeat import RepeatParams, filter_card, find_repeat, his_chunks, lex_overlap

# the same idea as C_CANNED's lines, in other words (the concept fake sees "safety" in both)
C_RESTATED = ("SAY: Anything it is unsure about goes to a person first.\n"
              "- Low confidence fields escalate to a human operator.")
# a new step in his line
C_NEW = ("SAY: Next on the list are group challenges for friends.\n"
         "- Members chase a common target every month.\n- Every Sunday the team compares totals.")
# a new SAY with one point that repeats the first card and one that is new
C_HALF = ("SAY: Next on the list are group challenges for friends.\n"
          "- Fields below 0.8 confidence go to a human operator.\n- Every Sunday the team compares totals.")
NEXT_SENTENCE = "and last month we passed fifty thousand runs with a new training plan feature for beginners".split()


async def _second_card(second: str, c_script_first: str = C_CANNED):
    b, t, em, sess, fol = make(responder([c_script_first, second]))
    await start(b, sess, fol)
    await question(b)
    await me(b, OFF_CARD)
    await asyncio.sleep(0.1)
    await settle_(b)
    assert len(c_calls(t)) == 1
    mark = len(em.events)
    for i in range(1, len(NEXT_SENTENCE) + 1):
        await b.handle({"type": "partial", "turn_id": "m2", "speaker": "me", "text": " ".join(NEXT_SENTENCE[:i]), "cue": False,
                        "t_audio_end": 0.0})
        await asyncio.sleep(0.03)
    await asyncio.sleep(0.5)
    await settle_(b)
    return b, t, em, mark


async def settle_(b):
    from test_runtime_helpers import settle
    await settle(b)


def _shown_lines(em, mark):
    out, cur = [], ""
    for e in em.events[mark:]:
        if e["type"] == "delta" and e["tier"] == "C":
            cur += e["text"]
            if e["line_done"]:
                out.append(cur.strip())
                cur = ""
    return out


# ------------------------------------------------------------------------------------------------------------- the engine
def test_a_refresh_card_that_restates_an_earlier_card_is_not_shown():
    b, t, em, mark = run(_second_card(C_RESTATED))
    assert len(c_calls(t)) == 2, "the refresh asked the model"
    assert not [e for e in em.events[mark:] if e["type"] == "follow"], "the card on screen stays"
    assert not _shown_lines(em, mark)
    stages = [e["stage"] for e in em.events[mark:] if e["type"] == "metric"]
    assert "follow_repeat" in stages and "follow_empty" in stages
    assert b.follow.nothing_new == 1, "the next refresh waits longer"


def test_a_genuinely_new_continuation_still_goes_through():
    b, t, em, mark = run(_second_card(C_NEW))
    f2 = [e for e in em.events[mark:] if e["type"] == "follow"]
    assert len(f2) == 1 and f2[0]["reason"] == "refresh"
    assert _shown_lines(em, mark) == ["SAY: Next on the list are group challenges for friends.",
                                      "- Members chase a common target every month.", "- Every Sunday the team compares totals."]
    assert b.follow.nothing_new == 0


def test_a_point_that_repeats_is_dropped_and_the_new_lines_stay():
    b, t, em, mark = run(_second_card(C_HALF))
    assert _shown_lines(em, mark) == ["SAY: Next on the list are group challenges for friends.",
                                      "- Every Sunday the team compares totals."]
    assert b.follow.card_lines(b.follow.visible_id)[-1].text == "Every Sunday the team compares totals."


def test_the_model_writing_none_shows_nothing_and_backs_off():
    b, t, em, mark = run(_second_card("NONE"))
    assert not [e for e in em.events[mark:] if e["type"] == "follow"]
    assert any(e["type"] == "metric" and e["stage"] == "follow_empty" for e in em.events[mark:])
    assert b.follow.nothing_new == 1


def test_the_follow_prompt_lists_what_was_shown_and_allows_none():
    b, t, em, mark = run(_second_card(C_NEW))
    second = c_calls(t)[1].tail
    assert "write the single word NONE" in second
    assert "THE FOLLOW CARD ON HIS SCREEN NOW" in second and "And that is where I keep the model" in second
    # a third card: the first follow card is no longer on screen, so it is listed as shown
    text = follow_tail("q?", "en", "his words", ["SAY: orig"], [], ["SAY: now"], "refresh", shown=["Old follow line.", "Detail line."])
    assert "ALREADY SHOWN TO HIM THIS TURN" in text and "- Old follow line." in text and "- Detail line." in text
    assert "ALREADY SHOWN" not in follow_tail("q?", "en", "his words", ["SAY: orig"], [], None, "diverged")


def test_a_short_question_gets_no_follow_card():
    async def go():
        b, t, em, sess, fol = make()
        await start(b, sess, fol)
        await question(b, text="Can you hear me?")
        await me(b, OFF_CARD)
        await asyncio.sleep(0.4)
        await settle_(b)
        return t, em

    t, em = run(go())
    assert not c_calls(t) and not [e for e in em.events if e["type"] == "follow"]


# -------------------------------------------------------------------------------------------------------- the pure guard
def test_lexical_overlap_and_the_threshold():
    a = "I weigh the options, pick one, and accept the tradeoff"
    assert lex_overlap(a, "I pick one option and accept the tradeoff, after I weigh them") >= RepeatParams().lex_dup
    assert lex_overlap(a, "We shipped the beta to forty users in March") < 0.3
    assert lex_overlap("Yes it works", "Yes it works fine") == 0.0, "a line with fewer than three content stems is not matched"


def test_embedding_cosine_decides_a_paraphrase_without_shared_words():
    refs = ["Reviews take a few hours every week."]
    vecs = {"New line": [1.0, 0.0], "Reviews take a few hours every week.": [0.9, 0.436]}
    hit = find_repeat("New line", refs, vecs)
    assert hit is not None and hit[1] == "embed" and hit[2] >= 0.86
    vecs["Reviews take a few hours every week."] = [0.8, 0.6]
    assert find_repeat("New line", refs, vecs) is None, "0.8 is a related line, not the same idea"
    assert find_repeat("New line", refs, None) is None, "no vectors: the lexical rule alone"


def test_filter_card_drops_a_card_whose_say_repeats_and_single_points_otherwise():
    shown = ["The big calls like which database to pick are mine to make."]
    keep, pts, found = filter_card("Choosing which database to pick is mine to make.", ["A point."], shown)
    assert not keep and pts == [] and found[0][0] == "say"
    keep, pts, found = filter_card("Next I plan the migration.", ["Choosing which database to pick is mine to make.",
                                                                   "The cutover runs on a weekend."], shown)
    assert keep and pts == ["The cutover runs on a weekend."] and [f[0] for f in found] == ["point"]
    keep, pts, _ = filter_card("Next I plan the migration.", ["The cutover runs on a weekend.", "The cutover runs on a weekend night."], shown)
    assert pts == ["The cutover runs on a weekend."], "a point that repeats a point of the same card goes too"


def test_his_own_sentences_are_compared_too():
    mine = his_chunks("I decided to rewrite the importer in Rust. It runs ten times faster now. We merged it last week.")
    keep, _, found = filter_card("I rewrote the importer in Rust.", [], mine)
    assert not keep and found


# ------------------------------------------------------------------------------------------------ the cadence (the machine)
def test_the_same_idea_in_other_words_asks_for_no_new_card():
    clock = Clock(10.0)
    m, drv, clock, fx = following(clock)
    t = speak_machine(m, drv, clock, fx, "the running app coaches marathon training for complete beginners", 15.0)
    idle(m, drv, clock, fx, t, 1.0)
    assert len(refreshes(fx)) == 1
    m.c_started("c0002", now=clock.t)
    m.add_line("c0002", "C", "say", "Every plan adapts to the runner.")
    m.c_done()
    t = speak_machine(m, drv, clock, fx, "complete beginners get marathon training from the running app that coaches them",
                      clock.t + 0.5, turn="m2")
    idle(m, drv, clock, fx, t, 8.0)
    assert len(refreshes(fx)) == 1, "nothing he said is news: the stems were said and shown already"


def test_new_material_still_asks_for_a_card():
    clock = Clock(10.0)
    m, drv, clock, fx = following(clock)
    t = speak_machine(m, drv, clock, fx, "the running app coaches marathon training for complete beginners", 15.0)
    idle(m, drv, clock, fx, t, 1.0)
    m.c_started("c0002", now=clock.t)
    m.add_line("c0002", "C", "say", "Every plan adapts to the runner.")
    m.c_done()
    t = speak_machine(m, drv, clock, fx, "injuries and sleep shape every schedule, hydration reminders arrive daily", clock.t + 0.5, turn="m2")
    idle(m, drv, clock, fx, t, 8.0)
    assert len(refreshes(fx)) == 2


def test_a_card_that_showed_nothing_makes_the_next_refresh_wait_longer():
    clock = Clock(10.0)
    m, drv, clock, fx = following(clock, FollowParams(refresh_gap_s=2.0))
    m.c_started("c0002", now=clock.t)
    m.c_done(shown=False)
    first = "injuries and sleep shape every schedule, hydration reminders"
    t = speak_machine(m, drv, clock, fx, first, clock.t + 0.2, turn="m2")
    idle(m, drv, clock, fx, t, 6.0)
    assert not refreshes(fx), "six new content words are fewer than the doubled eight, however long he waits"
    t = speak_machine(m, drv, clock, fx, "pacing adjusts, nutrition advice follows workload", clock.t + 0.2, turn="m2", prefix=first)
    idle(m, drv, clock, fx, t, 1.0)
    assert len(refreshes(fx)) == 1
