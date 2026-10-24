"""Two-track scorer and bleed simulation on hand-made events (no verse-run, no audio, no network)."""

import array
import math

import pytest
import score_twotrack as ST
import twotrack

LABEL = {"id": "tx", "owner": "the owner", "utterances": [
    {"speaker": "Ingrid", "text": "Can you tell me about yourself?", "expect": "answer"},
    {"speaker": "the owner", "text": "Sure, I build pipelines.", "expect": "me_turn"},
    {"speaker": "Ingrid", "text": "Thanks, that is helpful.", "expect": "no_answer"},
]}
META = {"timeline": [
    {"index": 0, "speaker": "Ingrid", "channel": "remote", "t_start": 10.0, "t_end": 12.0},
    {"index": 1, "speaker": "the owner", "channel": "me", "t_start": 13.0, "t_end": 16.0},
    {"index": 2, "speaker": "Ingrid", "channel": "remote", "t_start": 17.0, "t_end": 18.0}]}


def ev(**o):
    return (0.0, o)


def t0():
    return ev(type="metric", stage="session_t0", t=1000.0, origin_remote=0)


def turn(tid, speaker, text, end, kind="question"):
    return ev(type="turn", dir="to_brain", turn_id=tid, speaker=speaker, text=text, t_audio_end=end, kind=kind, addressee="me")


def delta(cid, tid, text, tier="F"):
    return ev(type="delta", id=cid, turn_id=tid, tier=tier, text=text, line_done=True)


ANSWER = "SAY: Sure, here is the short answer."
ACK = "SAY: Thanks, noted."


def test_clean_run_has_no_wrong_triggers():
    events = [t0(), turn("r1", "remote", "Can you tell me about yourself", 12.1), delta("f1", "r1", ANSWER),
              turn("m1", "me", "Sure I build pipelines", 16.0, "statement"),
              turn("r2", "remote", "Thanks that is helpful", 18.2, "statement"), delta("f2", "r2", ACK)]
    r = ST.score(LABEL, events, META)
    assert r["questions"] == {"n": 1, "answered_once": 1, "missed": 0, "double": 0}
    assert r["no_answer_labels"] == {"n": 1, "wrongly_answered": 0}
    assert r["me_labels"]["landed_as_me_turn"] == 1 and r["me_turns"] == 1 and r["false_me_turns"] == 0
    assert r["wrong_triggers"] == [] and r["answered_remote_turns"] == 1


def test_answer_on_a_me_turn_is_a_wrong_trigger():
    events = [t0(), turn("r1", "remote", "Can you tell me about yourself", 12.1), delta("f1", "r1", ANSWER),
              turn("m1", "me", "Sure I build pipelines", 16.0, "statement"), delta("f9", "m1", ANSWER)]
    r = ST.score(LABEL, events, META)
    assert [w["kind"] for w in r["wrong_triggers"]] == ["answer_on_me_turn"] and r["answers_on_me_turns"] == 1


def test_split_question_double_answer_missed_answer_and_answered_statement():
    split = [t0(), turn("r1", "remote", "Can you tell me", 11.0), delta("f1", "r1", ANSWER),
             turn("r2", "remote", "about yourself", 12.2), delta("f2", "r2", ANSWER)]
    r = ST.score(LABEL, split, META)
    assert r["questions"]["double"] == 1 and any(w["kind"] == "double_answer" for w in r["wrong_triggers"])
    missed = ST.score(LABEL, [t0(), turn("r1", "remote", "Can you tell me about yourself", 12.1)], META)
    assert missed["questions"]["missed"] == 1 and missed["wrong_trigger_count"] == 0     # suppressed, not a wrong trigger
    stmt = ST.score(LABEL, [t0(), turn("r3", "remote", "Thanks that is helpful", 18.2, "statement"), delta("f3", "r3", ANSWER)], META)
    assert stmt["no_answer_labels"]["wrongly_answered"] == 1


def test_acknowledgement_is_not_an_answer():
    r = ST.score(LABEL, [t0(), turn("r3", "remote", "Thanks that is helpful", 18.2, "statement"), delta("f3", "r3", ACK)], META)
    assert r["no_answer_labels"]["wrongly_answered"] == 0 and r["answered_remote_turns"] == 0


def test_bleed_run_with_silent_owner_counts_every_me_turn_as_false():
    events = [t0(), turn("r1", "remote", "Can you tell me about yourself", 12.1), delta("f1", "r1", ANSWER),
              turn("m1", "me", "can you tell", 14.0, "fragment"),                       # inside the owner's window, but he is silent
              ev(type="metric", stage="echo_gate_dropped", text="x"), ev(type="metric", stage="echo_guard_dropped", text="y"),
              ev(type="metric", stage="echo_guard_dropped", text="z")]
    r = ST.score(LABEL, events, dict(META, owner_silent=True))
    assert r["false_me_turns"] == 1 and r["echo_gate_dropped"] == 1 and r["echo_guard_dropped"] == 2
    assert r["me_labels"]["landed_as_me_turn"] == 0
    still = ST.score(LABEL, events, META)
    assert still["false_me_turns"] == 0       # with a talking owner the same turn belongs to his utterance


def test_spurious_remote_turn_that_gets_an_answer():
    events = [t0(), turn("r7", "remote", "something nobody said", 40.0), delta("f7", "r7", ANSWER)]
    r = ST.score(LABEL, events, META)
    assert any(w["kind"] == "answer_on_spurious_turn" for w in r["wrong_triggers"]) and r["spurious_remote_turns"] == 1


def test_listen_summary_origins_shift_the_windows():
    events = [t0(), ev(type="metric", stage="listen_summary", origin_remote=5.0, origin_me=5.0),
              turn("r1", "remote", "Can you tell me about yourself", 17.1), delta("f1", "r1", ANSWER)]
    assert ST.score(LABEL, events, META)["questions"]["answered_once"] == 1


def test_fixture_validates_and_bad_ones_do_not():
    f = twotrack.load("t01")
    assert f["owner"] == "the owner" and any(u["expect"] == "answer" for u in f["utterances"])
    bad = {"id": "x", "owner": "the owner", "participants": ["I"], "voices": {"I": "Kathy", "the owner": "Daniel"},
           "utterances": [{"speaker": "the owner", "text": "a", "offset_s": 0, "expect": "answer"}]}
    assert twotrack.validate(bad)


def test_bleed_is_attenuated_delayed_and_noisy():
    imp = array.array("h", [0] * 100)
    imp[10] = 10000
    out = twotrack.bleed(imp, None, attenuation_db=20.0, delay_ms=2.0, noise_dbfs=None)      # 2 ms = 32 samples at 16 kHz
    assert out[42] == pytest.approx(1000, abs=1) and sum(1 for s in out if s) == 1
    own = array.array("h", [0] * 100)
    own[5] = 500
    assert twotrack.bleed(imp, own, 20.0, 2.0, None)[5] == 500
    noisy = twotrack.bleed(array.array("h", [0] * 16000), None, 20.0, 0.0, noise_dbfs=-50.0, seed=3)
    assert twotrack.rms_dbfs(noisy) == pytest.approx(-50.0, abs=0.5)
    assert noisy == twotrack.bleed(array.array("h", [0] * 16000), None, 20.0, 0.0, noise_dbfs=-50.0, seed=3)    # deterministic
    assert math.isclose(twotrack.db_to_gain(-20.0), 0.1)


def test_gate_drop_over_users_own_speech_is_counted_and_deferrals_too():
    # the owner speaks 13.0-16.0 on the me clock (origin 0). The gate dropped one event inside his speech and one in a silent stretch.
    events = [t0(),
              ev(type="metric", stage="echo_gate_dropped", text="sorry", audio_start=13.1, audio_end=13.3),
              ev(type="metric", stage="echo_gate_dropped", text="thanks", audio_start=10.2, audio_end=11.0),
              ev(type="metric", stage="echo_gate_decision", verdict="defer", audio_start=13.1, audio_end=15.0),
              ev(type="metric", stage="echo_gate_decision", verdict="keep", audio_start=13.1, audio_end=15.0)]
    r = ST.score(LABEL, events, META)
    assert r["echo_gate_dropped"] == 2 and r["gate_dropped_over_own_speech"] == 1 and r["gate_dropped_over_own_speech_texts"] == ["sorry"]
    assert r["echo_gate_deferred"] == 1
    # bleed-only run: he says nothing, so nothing of his can be dropped
    assert ST.score(LABEL, events, dict(META, owner_silent=True))["gate_dropped_over_own_speech"] == 0
