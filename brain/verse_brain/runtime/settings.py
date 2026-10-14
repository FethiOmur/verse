"""Fixed settings tuples per route (plan P1-2, spec 5.8) and the runtime's tunable thresholds.

The tuple of a route (model, thinking, effort and, for D, the fallback opt-in) is sent byte-for-byte on the real
call, the pre-warm and the keep-alive. Only `max_tokens` differs: 0 on pre-warm/keep-alive, by definition.
`route_params()` is the single place that builds it, so the three call kinds cannot drift apart.
"""

from __future__ import annotations

import copy
from dataclasses import dataclass

from ..prep.model import HAIKU, PREP_MODEL

SONNET = PREP_MODEL  # "claude-sonnet-5-5"

# The `fallbacks: "default"` scalar form is gated by this beta header (claude-api skill, model-migration ->
# Migrating to Claude Opus 5 -> New API features). Haiku 5.5 has no server-side fallback: never send it there.
FALLBACK_BETA = "server-side-fallback-2026-07-01"

_ROUTES: dict[str, dict] = {
    # S and F share one tuple (and therefore one cache entry): Haiku, thinking off, effort low.
    "S": {"model": HAIKU, "max_tokens": 120, "thinking": {"type": "disabled"}, "output_config": {"effort": "low"}},
    "F": {"model": HAIKU, "max_tokens": 120, "thinking": {"type": "disabled"}, "output_config": {"effort": "low"}},
    # D: Sonnet, between_tools (the lowest thinking setting; disabled is a 400 on Sonnet 5.5), effort medium,
    # server-side fallback opt-in.
    "D": {"model": SONNET, "max_tokens": 600, "thinking": {"type": "between_tools"},
          "output_config": {"effort": "medium"}, "betas": [FALLBACK_BETA], "fallbacks": "default"},
}

# Which tier's tuple each model uses for pre-warm / keep-alive / summarize.
MODEL_ROUTE = {HAIKU: "S", SONNET: "D"}


def route_params(route: str, *, max_tokens: int | None = None) -> dict:
    """A fresh copy of the route's settings tuple. `max_tokens=0` gives the pre-warm/keep-alive form."""
    p = copy.deepcopy(_ROUTES[route])
    if max_tokens is not None:
        p["max_tokens"] = max_tokens
    return p


def tuple_of(params: dict) -> dict:
    """The settings tuple of a request: everything except max_tokens and the prompt itself."""
    return {k: v for k, v in params.items() if k not in ("max_tokens", "system", "messages")}


def uses_beta(route: str) -> bool:
    return "betas" in _ROUTES[route]


@dataclass
class Config:
    # S: speculation
    s_max_inflight: int = 3
    s_min_new_words: int = 4
    s_min_gap_s: float = 0.300
    s_max_per_turn: int = 6          # cost bound per turn (not in the plan; ~$0.0004 per extra call)
    match_max_edit: int = 3          # token edit distance for "S input fits the endpoint text"
    # D
    d_stable_s: float = 0.700
    d_min_words: int = 4
    bank_skip_score: float = 0.85
    bank_verdict_wait_s: float = 3.0  # how long D waits for Haiku's BANK line before firing anyway
    d_retry_max_wait_s: float = 8.0   # a 429 retry-after longer than this makes the answer stale
    # transport
    hedge_after_s: float = 1.5      # S/F (Haiku)
    hedge_after_s_d: float = 2.0    # D (Sonnet): healthy first bytes reach ~1.5 s (P1-2 live run)
    ping_every_s: float = 30.0
    offline_ping_every_s: float = 5.0
    keepalive_idle_s: float = 240.0
    keepalive_check_s: float = 10.0
    bucket_fraction: float = 0.80
    # spend
    budget_usd: float = 3.0
