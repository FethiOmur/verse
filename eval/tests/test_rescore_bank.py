"""rescore_bank.py: re-deciding recorded embedding evaluations under an accept rule (synthetic metric lines, no run data)."""

import rescore_bank as rb


def ev(top, s1, s2):
    return {"type": "metric", "stage": "embed", "turn_id": "r1", "top": top, "score": s1, "second": s2}


SPIKE = [ev("b008", 0.914, 0.852), ev("b008", 0.9007, 0.8427), ev("b008", 0.8903, 0.862)]   # f3-embed d09, off-bank
RISING = [ev("b005", 0.88, 0.85), ev("b005", 0.905, 0.86), ev("b005", 0.91, 0.86), ev("b005", 0.93, 0.86)]


def test_old_rule_shows_the_prefix_spike_and_the_new_rule_does_not():
    assert [h[1] for h in rb.decide(SPIKE, *rb.OLD_RULE, final=True)] == ["b008"]
    assert rb.decide(SPIKE, 0.90, 0.005, 3, final=True) == []


def test_consecutive_count_resets_on_a_rejected_evaluation_and_the_hit_is_sent_once():
    hits = rb.decide(RISING, 0.90, 0.005, 3, final=True)
    assert [(j, bid, fin) for j, bid, _, fin in hits] == [(3, "b005", False)]


def test_final_pass_completes_a_turn_one_evaluation_short():
    two = RISING[:3]
    assert rb.decide(two, 0.90, 0.005, 3, final=False) == []
    assert [(bid, fin) for _, bid, _, fin in rb.decide(two, 0.90, 0.005, 3, final=True)] == [("b005", True)]


def test_redecide_replaces_recorded_embed_hits_and_keeps_ngram_hits():
    events = [(1.0, {"type": "bank_hit", "turn_id": "r0", "bank_id": "b001", "score": 0.6, "dir": "to_brain"}),
              (2.0, SPIKE[0]), (2.1, SPIKE[1]),
              (2.2, {"type": "bank_hit", "turn_id": "r1", "bank_id": "b008", "score": 0.9007, "via": "embed"}),
              (2.3, SPIKE[2]),
              (3.0, {"type": "turn", "turn_id": "r1", "dir": "to_brain", "text": "x"})]
    out = rb.redecide(events, 0.90, 0.005, 3, final=True)
    assert [o for _, o in out if o.get("type") == "bank_hit"] == [events[0][1]]
    old = rb.redecide(events, *rb.OLD_RULE, final=True)
    assert [(w, o["bank_id"]) for w, o in old if o.get("via") == "embed"] == [(2.1, "b008")]


def test_fast_lane_hits_on_one_high_partial_and_matches_the_engine_rule():
    high = [ev("b005", 0.95, 0.86), ev("b005", 0.96, 0.86)]
    assert rb.decide(high, 0.90, 0.005, 3, final=False) == []
    assert [(j, bid) for j, bid, _, _ in rb.decide(high, 0.90, 0.005, 3, final=False, fast=(0.93, 0.03, 1))] == [(0, "b005")]
    # the recorded off-bank spike (0.914) stays out of the fast lane
    assert rb.decide(SPIKE, 0.90, 0.005, 3, final=True, fast=(0.93, 0.03, 1)) == []


def test_a_recorded_final_pass_is_used_instead_of_the_approximation():
    fin = dict(ev("b005", 0.905, 0.86), final=True)
    two = RISING[1:3] + [fin]                      # two partials short, then the engine's own final-text evaluation
    assert [(j, bid, f) for j, bid, _, f in rb.decide(two, 0.90, 0.005, 3, final=True)] == [(2, "b005", True)]
    # nothing is shown from the final evaluation when the partials already showed a card (the engine would not queue it)
    three = RISING + [fin]
    assert [(j, f) for j, _, _, f in rb.decide(three, 0.90, 0.005, 3, final=True)] == [(3, False)]
    events = [(1.0, two[0]), (1.5, two[1]), (2.0, {"type": "turn", "turn_id": "r1", "dir": "to_brain", "text": "x"}), (2.07, two[2])]
    hits = [(w, o["bank_id"]) for w, o in rb.redecide(events, 0.90, 0.005, 3, final=True) if o.get("type") == "bank_hit"]
    assert hits == [(2.07, "b005")], "the recorded wall time, not turn + 60 ms"
