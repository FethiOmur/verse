"""Re-anchoring the reading cursor anywhere on the card (own.py, rule "anchor"; Swift twin: RoomReadingGate in CardReading.swift).

The old rules follow one in-order path from the cursor. When he jumps on the card (skips a sentence, re-reads a line, starts from a
point), a text with 4+ content words on a near-consecutive path (share 0.85) is still his reading and the cursor moves there, forward
or back. A question from the other side that shares two or three card words, or one matching word, changes nothing.

Fictional card (a data engineer called Dana): a SAY line of three sentences and two points."""

from __future__ import annotations

from test_runtime_room_reading import FRAGMENTS, Clock, first_card, italian_session, n_model_calls, rturn, shown
from test_runtime_helpers import run, settle

from verse_brain.runtime.own import OwnParams, OwnSpeech, anchor_path, tokenize

S1 = "I built the invoice pipeline at Lantern."
S2 = "Bad invoices never blocked the pipeline, they went to a review queue."
S3 = "Then I moved to the route optimiser project."
P1 = "The first pilot shipped in six weeks."
P2 = "Routing costs dropped by eleven percent."


def card() -> OwnSpeech:
    o = OwnSpeech(OwnParams(), clock=Clock())
    o.add("t0", "orig", "say", f"{S1} {S2} {S3}", new_say=True)
    o.add("t0", "orig", "point", P1)
    o.add("t0", "orig", "point", P2)
    return o


def end_of(o: OwnSpeech, text: str) -> int:
    """Card position (token index) right after the last token of `text`, which must be a run of tokens of the card."""
    stems = [t.stem for t in o._card("orig", "en")[0]]
    want = [t.stem for t in tokenize(text)]
    for i in range(len(stems) - len(want) + 1):
        if stems[i:i + len(want)] == want:
            return i + len(want)
    raise AssertionError(f"{text!r} is not on the card")


def read(o: OwnSpeech, *texts: str) -> None:
    for k, text in enumerate(texts):
        assert o.judge(text, turn_id=f"read{k}{text[:6]}").label == "me", text
        o.clock.advance(0.8)


def test_skipping_one_sentence_ahead_anchors_there():
    o = card()
    read(o, S1)
    assert o.cursor["orig"] == end_of(o, S1)
    # the next thing he says is the third sentence: 4 content words (moved, route, optimiser, project), under the strict rule's 5
    v = o.judge(S3, turn_id="s3")
    assert v.label == "me" and v.rule == "anchor" and v.matched == 4
    assert o.cursor["orig"] == end_of(o, S3)
    assert o.reading_active()                       # a re-anchored match is his own speech: a held card keeps waiting, no new card


def test_re_reading_the_first_line_after_finishing_the_second_anchors_back():
    o = card()
    read(o, S1, S2)
    after_two = o.cursor["orig"]
    assert after_two == end_of(o, S2)
    v = o.judge(S1, turn_id="again")
    assert v.label == "me"
    assert o.cursor["orig"] == end_of(o, S1) < after_two
    # and he goes on from there: the second sentence is a continuation of the moved cursor
    assert o.judge(S2, turn_id="again2").label == "me" and o.cursor["orig"] == end_of(o, S2)


def test_re_reading_a_line_from_the_middle_of_the_card_moves_the_cursor_back_without_a_line_start():
    o = card()
    read(o, S1, S2, S3)
    # not the start of any line, 4 content words: only the anchor rule can take it, and it moves the cursor back
    again = "never blocked the pipeline they went to a review queue"
    v = o.judge(again, turn_id="mid")
    assert v.label == "me" and o.cursor["orig"] == end_of(o, S2) < end_of(o, S3)


def test_starting_from_the_second_point_anchors_to_it():
    o = card()
    read(o, S1)
    v = o.judge(P2, turn_id="p2")
    assert v.label == "me" and o.cursor["orig"] == end_of(o, P2)
    # then back to the first point
    assert o.judge(P1, turn_id="p1").label == "me" and o.cursor["orig"] == end_of(o, P1)


def test_a_question_from_the_other_side_that_shares_two_or_three_card_words_is_not_his_and_moves_nothing():
    o = card()
    read(o, S1)
    at = dict(o.cursor)
    questions = [
        "Can you tell me more about how bad invoices ended up in the review process",   # bad invoices ... review
        "What was the hardest part of the route you chose for the optimiser",             # route, optimiser
        "And how long did the pilot take, six weeks or more",                              # pilot, six, weeks (3, not consecutive in text order with its gap)
    ]
    for k, q in enumerate(questions):
        v = o.judge(q, turn_id=f"q{k}")
        assert v.label == "room", (q, v)
        assert o.cursor == at, q
        assert o.own_score(q) < o.p.own_drop, q


def test_one_matching_word_never_moves_the_cursor_even_inside_a_reading_session():
    o = card()
    read(o, S1, S2)
    at = dict(o.cursor)
    assert o.reading_active()
    for k, text in enumerate(["pipeline", "queue", "we talked about the pipeline yesterday during lunch", "Lantern", "sure, six"]):
        assert o.judge(text, turn_id=f"j{k}").label == "room", text
        assert o.cursor == at, text


def test_function_words_do_not_count_toward_the_threshold():
    # eight words, all on the card in order, but only "pipeline" and "queue" are content words: 2 < 4
    o = card()
    assert o.judge("the pipeline they went to a review queue", turn_id="f").label == "room" and not o.cursor
    # function words alone, in order on the card
    assert o.judge("then i to the at a the", turn_id="stop").label == "room" and not o.cursor


def test_a_jump_is_stricter_than_continuing():
    # two content words that continue from the cursor keep him reading (the continue rule); the same two words elsewhere do not jump
    o = card()
    read(o, S1)
    start = o.cursor["orig"]
    assert o.judge("bad invoices", turn_id="c1").label == "me" and o.cursor["orig"] > start      # continues where he is
    far = card()
    read(far, S1)
    assert far.judge("eleven percent", turn_id="c2").label == "room" and far.cursor["orig"] == end_of(far, S1)


def test_a_line_said_twice_anchors_at_the_occurrence_nearest_to_the_cursor():
    near = anchor_path(list("abcd"), list("abcdxxabcd"), 1, near=7)
    assert [j for _, j in near] == [6, 7, 8, 9]
    first = anchor_path(list("abcd"), list("abcdxxabcd"), 1, near=1)
    assert [j for _, j in first] == [0, 1, 2, 3]


def test_a_long_reading_with_a_gap_does_not_regress_the_cursor():
    o = card()
    # the whole SAY line in one turn, he drops three content words in the middle: the longest near-consecutive stretch is the first
    # half, but the cursor must end where the text ends
    text = "I built the invoice pipeline at Lantern bad invoices never blocked the pipeline they went to a review queue then I moved to the route optimiser project"
    v = o.judge(text, turn_id="whole")
    assert v.label == "me" and o.cursor["orig"] == end_of(o, S3)


# ---------------------------------------------------------------- through the engine: a re-read line starts no new card
def test_re_reading_a_line_of_the_card_after_a_pause_fires_no_new_card(tmp_path, monkeypatch):
    again = "la chiarezza degli obiettivi e il feedback frequente"     # 4 content words, mid-card: the strict rule needs 5

    async def go():
        b, t, em, clock, sdir, coro = italian_session(tmp_path, monkeypatch)
        await coro
        await first_card(b, em, clock)
        for i, frag in enumerate(FRAGMENTS[:2]):
            await rturn(b, f"f{i}", frag)
            clock.advance(0.8)
        clock.advance(6.0)                                              # the reading session is over
        n_calls, shown_before, at = n_model_calls(t), shown(em), b._own.cursor["orig"]
        await rturn(b, "again", again, kind="question", cue=True, cue_why="come", cue_strong=True)
        await settle(b)
        return b, t, em, n_calls, shown_before, at

    b, t, em, n_calls, shown_before, at = run(go())
    assert b.turns[-1].speaker == "me"
    assert n_model_calls(t) == n_calls and shown(em) == shown_before
    assert b._own.cursor["orig"] > at + 8                                # and the cursor jumped ahead to that line
