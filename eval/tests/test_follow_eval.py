"""Follow-my-answer eval pieces: the t02-t04 fixtures, the direct replay's recognizer model and the follow scoring."""

import pytest
import run_follow as RF
import score_twotrack as ST
import twotrack


@pytest.mark.parametrize("fid", ["t02", "t03", "t04"])
def test_fixtures_are_valid_and_labelled(fid):
    f = twotrack.load(fid)
    labels = [u["follow"] for u in f["utterances"] if u.get("follow")]
    assert labels and set(labels) <= {"none", "diverge"}
    if fid == "t02":
        assert set(labels) == {"none"}
    else:
        assert labels == ["diverge"]
        u = next(u for u in f["utterances"] if u.get("follow") == "diverge")
        assert 0 < u["off_from_word"] < len(u["text"].split())


def test_diverge_label_needs_off_from_word():
    bad = {"id": "x", "owner": "the owner", "participants": ["I"], "voices": {"I": "a", "the owner": "b"},
           "utterances": [{"speaker": "the owner", "text": "hi", "offset_s": 0, "expect": "me_turn", "follow": "diverge"}]}
    assert any("off_from_word" in e for e in twotrack.validate(bad))


def test_partials_are_cumulative_ordered_and_end_with_the_whole_text():
    text = "one two three four five six seven eight nine ten"
    ps = RF.partials_for(text, 10.0, 14.0)
    times = [t for t, _ in ps]
    assert times == sorted(times) and times[0] > 10.0
    assert ps[-1][1] == text and ps[-1][0] <= 14.0 + RF.RECOGNIZER_LAG_S + 1e-9
    for (_, a), (_, b) in zip(ps, ps[1:]):
        assert b.startswith(a) and len(b) > len(a)


def test_schedule_orders_partials_turns_and_the_bank_hit():
    f = twotrack.load("t03")
    tl = [{"index": 0, "speaker": "Ingrid", "channel": "remote", "t_start": 4.0, "t_end": 6.0},
          {"index": 1, "speaker": "the owner", "channel": "me", "t_start": 7.0, "t_end": 17.0}]
    msgs = RF.schedule(f, tl, 3.0)
    assert [t for t, _ in msgs] == sorted(t for t, _ in msgs)
    kinds = [(m["type"], m.get("speaker")) for _, m in msgs]
    assert ("bank_hit", None) in kinds
    turn_r = next(t for t, m in msgs if m["type"] == "turn" and m["speaker"] == "remote")
    turn_m = next(t for t, m in msgs if m["type"] == "turn" and m["speaker"] == "me")
    assert turn_r == pytest.approx(6.0 + RF.REMOTE_END_DELAY_S) and turn_m == pytest.approx(17.0 + RF.ME_END_DELAY_S)
    last_me_partial = max(t for t, m in msgs if m["type"] == "partial" and m["speaker"] == "me")
    assert last_me_partial < turn_m


LABEL = {"id": "tf", "owner": "the owner", "utterances": [
    {"speaker": "Ingrid", "text": "Tell me about yourself.", "expect": "answer"},
    {"speaker": "the owner", "text": "one two three four five six seven eight nine ten", "expect": "me_turn", "follow": "diverge", "off_from_word": 5},
    {"speaker": "Ingrid", "text": "Next?", "expect": "answer"},
    {"speaker": "the owner", "text": "stays on the card", "expect": "me_turn", "follow": "none"}]}
META = {"timeline": [
    {"index": 0, "speaker": "Ingrid", "channel": "remote", "t_start": 1.0, "t_end": 2.0},
    {"index": 1, "speaker": "the owner", "channel": "me", "t_start": 10.0, "t_end": 20.0},
    {"index": 2, "speaker": "Ingrid", "channel": "remote", "t_start": 30.0, "t_end": 31.0},
    {"index": 3, "speaker": "the owner", "channel": "me", "t_start": 40.0, "t_end": 42.0}]}


def ev(w, **o):
    return (w, o)


def base():
    return [ev(0.0, type="metric", stage="session_t0", t=1000.0, origin_remote=0.0, origin_me=0.0)]


def test_follow_scoring_times_run_from_the_first_off_card_word():
    events = base() + [
        ev(1015.0 + 2.5, type="follow", turn_id="r1", reason="diverged", card_id="c1"),
        ev(1015.0 + 3.0, type="delta", id="c1", card_id="c1", turn_id="r1", tier="C", text="SAY: Next", line_done=False),
        ev(1015.0 + 3.1, type="delta", id="c1", card_id="c1", turn_id="r1", tier="C", text=" sentence.", line_done=True),
        ev(1015.0 + 3.2, type="delta", id="c1", card_id="c1", turn_id="r1", tier="C", text="- a point", line_done=True),
        ev(1030.0, type="covered", turn_id="r1", card_id="orig-r1", point=0)]
    f = ST.follow_stats(LABEL, events, META, 0.0, 1000.0)
    row = f["rows"][0]      # off word 5 of 10 = t 15 s
    assert row["ok"] and row["detection_ms"] == 2500 and row["first_sentence_ms"] == 3100 and row["card_points"] == 1
    assert f["rows"][1]["ok"] and f["rows"][1]["follow_events"] == 0
    assert f["covered_events"] == 1 and f["unlabelled_follow_events"] == 0


def test_a_follow_card_while_he_stays_on_the_card_is_bad_and_a_missing_one_too():
    events = base() + [ev(1041.0, type="follow", turn_id="r2", reason="diverged", card_id="c9")]
    f = ST.follow_stats(LABEL, events, META, 0.0, 1000.0)
    assert [r["ok"] for r in f["rows"]] == [False, False]


def test_lines_of_joins_pieces_until_line_done():
    got = ST.lines_of([(1.0, {"text": "SAY:", "line_done": False}), (2.0, {"text": " hi", "line_done": True}),
                       (3.0, {"text": "- x", "line_done": True})])
    assert got == [(2.0, "SAY: hi"), (3.0, "- x")]
