"""Held-out scoring for the follow-detector tuning (review E7): pick the thresholds on k-1 folds, score the fold left out.

No model and no embedder here: the caller hands in, per candidate parameter set, what each labelled case did with it. The
numbers `tune_follow.py` reports on the 87 cases it swept are in-sample; these are the honest ones."""

from __future__ import annotations

import math
from collections import defaultdict


def make_folds(ids: list[str], kinds: dict[str, str], k: int) -> list[list[str]]:
    """k folds, deterministic and stratified: the cases of each kind are dealt round-robin, so every fold sees every kind."""
    if k < 2 or k > len(ids):
        raise ValueError(f"k must be between 2 and {len(ids)}")
    by_kind: dict[str, list[str]] = defaultdict(list)
    for i in sorted(ids):
        by_kind[kinds[i]].append(i)
    folds: list[list[str]] = [[] for _ in range(k)]
    n = 0
    for kind in sorted(by_kind):
        for i in by_kind[kind]:
            folds[n % k].append(i)
            n += 1
    return folds


def upper_bound(events: int, n: int, conf: float = 0.95) -> float:
    """One-sided exact (Clopper-Pearson) upper bound of a rate seen `events` times in `n` trials. 0 of 46 gives 0.063."""
    if n <= 0:
        return float("nan")
    if events >= n:
        return 1.0
    alpha = 1.0 - conf
    lo, hi = 0.0, 1.0
    for _ in range(60):
        mid = (lo + hi) / 2
        cdf = sum(math.comb(n, j) * mid**j * (1 - mid) ** (n - j) for j in range(events + 1))
        if cdf > alpha:
            lo = mid
        else:
            hi = mid
    return hi


def kfold(ids: list[str], kinds: dict[str, str], outcomes: dict, k: int, loss) -> dict:
    """`outcomes[params][case id]` is whatever the caller scores; `loss(list of outcomes)` returns a tuple, smaller is better
    (compared left to right, so put the failure that matters most first). For each fold the parameters are the grid point with
    the least loss on the other folds (ties: first in `outcomes` order); the fold is then scored with them.
    Returns {"chosen": [params per fold], "held_out": [outcome per case, in fold order], "folds": folds}."""
    folds = make_folds(ids, kinds, k)
    chosen, held = [], []
    for f, fold in enumerate(folds):
        train = [i for g, other in enumerate(folds) if g != f for i in other]
        best = min(outcomes, key=lambda p: loss([outcomes[p][i] for i in train]))   # min keeps the first of equals
        chosen.append(best)
        held.extend(outcomes[best][i] for i in fold)
    return {"chosen": chosen, "held_out": held, "folds": folds}
