"""Scorer tests on a hand-made run (tests/fixtures/mini): exact precision/recall, latency and no-SAY numbers."""

import json
from pathlib import Path

import pytest

import score

FIX = Path(__file__).parent / "fixtures" / "mini"


@pytest.fixture(scope="module")
def result():
    label = json.loads((FIX / "dmini.json").read_text())
    meta = json.loads((FIX / "meta.json").read_text())
    d = score.score_dialogue(label, score.load_events(FIX / "events.jsonl"), meta)
    return d, score.aggregate([d], {"dmini": meta})


def test_percentiles():
    assert score.pct([3, 1, 2], 0.5) == 2
    assert score.pct([1, 2, 3, 4], 0.5) == 2.5
    assert score.pct([1, 2, 3], 0.9) == 3                       # nearest rank
    assert score.pct(list(range(1, 11)), 0.9) == 9
    assert score.pct([], 0.5) is None


def test_matching(result):
    d, _ = result
    rows = {r["index"]: r for r in d["rows"]}
    assert rows[0]["turn_ids"] == ["r1"] and rows[2]["turn_ids"] == ["r2"] and rows[4]["turn_ids"] == ["r3"]
    assert rows[9]["turn_ids"] == ["r7"]
    assert rows[10]["turn_ids"] == []                             # never detected
    assert [t["turn_id"] for t in d["spurious_turns"]] == ["r8"]  # belongs to no utterance


def test_detection_precision_recall(result):
    _, ag = result
    det = ag["detection"]
    assert det["positives"] == 4 and det["covered"] == 3
    assert det["recall"] == 0.75
    # answerable turns: r1, r2, r5, r7 and the spurious r8 (r3 was recognised as being for someone else)
    assert det["predicted_turns"] == 5 and det["true_positive_turns"] == 3
    assert det["precision"] == 0.6
    assert [m["text"] for m in det["missed"]] == ["Where do you live at the moment?"]
    # a question for Tomas that the runner treated as a question for the user is a false positive too
    assert any(f["category"] == "other" for f in det["false_positives"])


def test_addressee_other_no_say(result):
    _, ag = result
    a = ag["addressee"]
    assert a["questions_to_other"] == 2 and a["no_say"] == 1 and a["no_say_rate"] == 0.5
    assert a["three_speaker_n"] == 2 and a["three_speaker_no_say"] == 1
    assert a["classified_other"] == 1
    assert [f["text"] for f in a["failures"]] == ["Tomas, are you still there?"]


def test_latency_from_true_acoustic_end(result):
    _, ag = result
    lat = ag["latency"]
    assert lat["acoustic_end_to_turn_sent"] == {"n": 3, "p50": 0.4, "p90": 0.6, "max": 0.6}
    assert lat["first_visible_text_any_SF"] == {"n": 3, "p50": 1.2, "p90": 1.5, "max": 1.5}
    assert lat["speculation_hit_opener_visible"]["n"] == 1 and lat["speculation_hit_opener_visible"]["p50"] == 0.6
    assert lat["fresh_haiku_first_word"] == {"n": 2, "p50": 1.35, "p90": 1.5, "max": 1.5}
    assert lat["sonnet_deep_first_words"] == {"n": 1, "p50": 1.5, "p90": 1.5, "max": 1.5}
    assert lat["bank_hit_visible"]["p50"] == -0.2                 # shown before the question ended
    assert lat["fact_chip_visible"]["p50"] == -0.1
    assert lat["n_speculation_path"] == 1 and lat["n_fresh_path"] == 2


def test_bank_hit_and_wrong_hit(result):
    _, ag = result
    b = ag["bank"]
    assert b["banked_questions"] == 2 and b["hits"] == 1 and b["hit_rate"] == 0.5     # the final hit counts, not the first
    # utterance 0 had an early wrong hit that the matcher corrected: only a transient wrong hit; utterance 2 ended on a wrong hit
    assert b["utterances_probed"] == 8 and b["wrong_hits"] == 1 and b["wrong_hit_rate"] == 0.125
    assert b["wrong_hits_transient"] == 2 and b["wrong_hit_rate_transient"] == 0.25
    assert b["confirmed_by_haiku"] == 1 and b["wrong_after_haiku"] == 0
    assert {(w["bank_ids"][-1], w["expected"]) for w in b["wrong_detail"]} == {("b001", "b001"), ("b003", "b002")}


def test_statements_and_cost(result):
    _, ag = result
    assert ag["other"]["statements"] == 1 and ag["other"]["statements_with_say"] == 0
    assert ag["cost"]["total_usd"] == 0.02
    assert ag["cost"]["replay_minutes"] == pytest.approx(44.0 / 60, abs=0.01)
    assert ag["cost"]["usd_per_30_min"] == pytest.approx(0.02 / (44.0 / 60) * 30, abs=1e-3)


def test_warmup_utterances_are_excluded():
    label = json.loads((FIX / "dmini.json").read_text())
    meta = {"engine": [{"state": "engine_switch", "switchAtSec": 20.0}], "duration_s": 45.0, "lead_in_s": 1.0}
    d = score.score_dialogue(label, score.load_events(FIX / "events.jsonl"), meta)
    ag = score.aggregate([d], {"dmini": meta})
    # utterances that start before the switch (session time 20.5 s) are not steady state
    assert ag["excluded_warmup_utterances"] == sum(1 for r in d["rows"] if r["warmup"]) > 0
    assert ag["questions_to_user"] == 2   # only the questions at 22.5 + 0.5 and later remain: utts 6 and 10


def test_no_session_clock_is_reported():
    label = json.loads((FIX / "dmini.json").read_text())
    assert "error" in score.score_dialogue(label, [], None)


def test_suites_are_aggregated_apart(result):
    d, _ = result
    short = dict(d, suite="short")
    meta = json.loads((FIX / "meta.json").read_text())
    assert score.aggregate([d, short], {"dmini": meta})["questions_to_user"] == 4
    assert score.aggregate([d, short], {"dmini": meta}, "short")["questions_to_user"] == 4
    assert score.aggregate([short], {"dmini": meta})["questions_to_user"] == 0
