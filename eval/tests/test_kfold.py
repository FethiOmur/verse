"""E7: held-out scoring of the follow-detector thresholds (eval/kfold.py). Synthetic outcomes, no model."""

import pytest
from kfold import kfold, make_folds, upper_bound


def _loss(oc):
    return oc.count("false"), oc.count("miss")


def test_folds_are_a_partition_and_every_fold_sees_every_kind():
    ids = [f"a{i}" for i in range(10)] + [f"b{i}" for i in range(10)] + [f"c{i}" for i in range(5)]
    kinds = {i: i[0] for i in ids}
    folds = make_folds(ids, kinds, 5)
    assert sorted(i for f in folds for i in f) == sorted(ids)
    assert all({kinds[i] for i in f} == {"a", "b", "c"} for f in folds)
    assert make_folds(ids, kinds, 5) == folds, "deterministic"


def test_k_must_fit_the_cases():
    with pytest.raises(ValueError):
        make_folds(["x", "y"], {"x": "k", "y": "k"}, 1)
    with pytest.raises(ValueError):
        make_folds(["x", "y"], {"x": "k", "y": "k"}, 3)


def test_a_threshold_that_is_right_in_sample_but_idiosyncratic_scores_worse_held_out():
    ids = [f"c{i}" for i in range(6)]
    kinds = {i: "stay" for i in ids}
    folds = make_folds(ids, kinds, 3)
    # parameter P_f flags (a false divergence) exactly the cases of fold f: tuned on the others it looks perfect
    outcomes = {f"P{f}": {i: ("false" if i in folds[f] else "ok") for i in ids} for f in range(3)}
    in_sample = min(_loss(list(o.values()))[0] for o in outcomes.values())
    r = kfold(ids, kinds, outcomes, 3, _loss)
    assert r["chosen"] == ["P0", "P1", "P2"], "each fold is scored with the parameter picked without it"
    assert in_sample == 2 and r["held_out"].count("false") == 6


def test_the_held_out_fold_never_decides_the_choice():
    ids = [f"c{i}" for i in range(6)]
    kinds = {i: "stay" for i in ids}
    folds = make_folds(ids, kinds, 3)
    base = {i: "ok" for i in ids}
    flipped = {i: ("false" if i in folds[0] else "ok") for i in ids}
    r = kfold(ids, kinds, {"flat": base, "flip": flipped}, 3, _loss)
    # on fold 0 both look the same in training (flat 0 false, flip 0 false): the first listed wins, then is scored on fold 0
    assert r["chosen"][0] == "flat" and r["held_out"][:2] == ["ok", "ok"]


def test_upper_bound_matches_the_rule_of_three_and_the_review_figure():
    assert upper_bound(0, 46) == pytest.approx(0.0630, abs=5e-4)       # review E7: "about 6.3 %"
    assert upper_bound(0, 100) == pytest.approx(1 - 0.05 ** (1 / 100), abs=1e-6)
    assert 0.0 < upper_bound(1, 46) < 0.11 and upper_bound(46, 46) == 1.0
    assert upper_bound(2, 46) > upper_bound(1, 46) > upper_bound(0, 46)
