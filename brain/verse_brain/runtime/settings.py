"""Fixed settings tuples per route (plan P1-2, spec 5.8) and the runtime's tunable thresholds.

The tuple of a route (model, thinking, effort and, for D, the fallback opt-in) is sent byte-for-byte on the real
call, the pre-warm and the keep-alive. Only `max_tokens` differs: 0 on pre-warm/keep-alive, by definition.
`route_params()` is the single place that builds it, so the three call kinds cannot drift apart.
"""

from __future__ import annotations

import copy
from dataclasses import dataclass, field

from .follow import FollowParams

from ..prep.model import HAIKU, PREP_MODEL

SONNET = PREP_MODEL  # "claude-sonnet-5-5"

# The `fallbacks: "default"` scalar form is gated by this beta header (claude-api skill, model-migration ->
# Migrating to Claude Opus 5 -> New API features). Haiku 5.5 has no server-side fallback: never send it there.
FALLBACK_BETA = "server-side-fallback-2026-07-01"

_ROUTES: dict[str, dict] = {
    # S and F share one tuple (and therefore one cache entry): Haiku, thinking off, effort low.
    "S": {"model": HAIKU, "max_tokens": 120, "thinking": {"type": "disabled"}, "output_config": {"effort": "low"}},
    "F": {"model": HAIKU, "max_tokens": 120, "thinking": {"type": "disabled"}, "output_config": {"effort": "low"}},
    # C (follow my answer): the S/F tuple byte for byte, so it rides their prompt cache (and their pre-warm). Only max_tokens
    # is its own: a follow card is a SAY line and two or three points, like F's.
    "C": {"model": HAIKU, "max_tokens": 160, "thinking": {"type": "disabled"}, "output_config": {"effort": "low"}},
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
    prewarm_attempts: int = 3
    prewarm_attempt_s: float = 12.0   # a healthy pre-warm takes ~1-2 s; longer means a stalled connection
    offline_ping_every_s: float = 5.0
    keepalive_idle_s: float = 240.0
    keepalive_check_s: float = 10.0
    bucket_fraction: float = 0.80
    # follow my answer (docs/specs/2026-10-16-verse-follow-my-answer-design.md); thresholds and their evidence: docs/follow-tuning.md
    follow_default: bool = False       # `start.follow` absent = off (Swift always sends it; its setting defaults to on)
    follow_langs: tuple[str, ...] = ("en",)   # tuned on English only; other languages keep the card as it is
    follow: FollowParams = field(default_factory=FollowParams)
    follow_tick_s: float = 0.1         # timer resolution of the machine (pauses, embed timeouts, the 4 s end)
    # F2 incremental summary (lowest priority: never competes with S/F/D)
    summary_every_turns: int = 6        # finalized turns (both speakers) between rolling passes
    summary_every_s: float = 180.0      # ...or this much speech (audio clock), whichever comes first
    summary_max_tokens: int = 400       # rolling pass output cap (not part of the settings tuple)
    summary_bucket_min: float = 0.5     # skip the rolling pass while the Haiku bucket is below this fraction
    summary_budget_frac: float = 0.9    # ...or the session spend is above this fraction of the budget
    summary_partial_stale_s: float = 5.0   # a remote partial untouched this long no longer counts as "a turn is open"
    final_max_tokens: int = 1500        # the Sonnet merge writes a whole summary; 600 (D) would truncate it
    final_timeout_s: float = 45.0       # `control stop` waits this long for the merge, then closes with the draft
    # spend
    budget_usd: float | None = None    # None = no cap (Alex: the Max credit pays, no limits)
    # F3 paraphrase matcher (EmbeddingGemma 2 text 270M, LiteRT-LM) next to Swift's n-gram matcher. Every gate is
    # required: the F3 bench showed 10-12 % wrong ids and premature locks on short prefixes without them.
    embed_enabled: bool = True
    embed_model: str = ("~/Library/Application Support/Verse/models/embeddinggemma-2-text-270m-litert/"
                        "embeddinggemma-2-text-270m.litertlm")
    embed_backend: str = "gpu"
    embed_threshold: float = 0.865     # top-1 cosine (F3 tuning, bench/embed/results/analysis_gpu_sym.txt)
    embed_margin: float = 0.02         # over the runner-up entry; 0.005 (F3) gave 9.7 % wrong hits in replay, 0.02 gives 4.3 % (12/24 paraphrase hits)
    embed_min_words: int = 5           # words in the partial
    embed_consecutive: int = 2         # the same entry on this many consecutive evaluated partials
    embed_langs: tuple[str, ...] = ("en",)   # thresholds were tuned on English only
    # One more match on the final text when a remote turn closes with no bank hit yet (partials that never matched, or a
    # statement/fragment whose cue never showed). A single evaluation is enough there (the consecutive-partials gate
    # exists against premature locks on short prefixes; a closed turn has no prefix). The hit goes through `_late_hit`.
    embed_final_pass: bool = True
    # The me layer (docs/specs/2026-10-16-verse-anytime-calls-design.md 2.2): retrieval of chunks of his files for a remote turn
    # (same partials as the bank matcher, on the same embedding thread), and the unprepared / room / card-now rules.
    me_retrieval_floor: float = 0.80   # cosine floor of a chunk (start value; the evidence is in tests/test_runtime_me.py)
    me_retrieval_k: int = 3            # chunks per turn in an unprepared call
    me_retrieval_k_prepared: int = 2   # ...and in a prepared one (the pack carries most of it)
    me_retrieval_min_words: int = 5    # words in the partial (the bank matcher's gate)
    me_retrieval_final_wait_s: float = 0.150   # D waits this long for the final-text retrieval; F never waits
    me_files_max_chars: int = 4800     # FROM USER'S FILES in the tail: about 1,200 tokens
    room_min_words: int = 6            # room route: an automatic card needs a question cue and this many words
    unprepared_statement_min_words: int = 4   # unprepared: a statement shorter than this gets no probe
    card_now_match_edit: int = 6       # the real turn that follows a card-now answer within this edit distance gets no second card
    local_me_chars: int = 3000         # G1 fallback: WHO I AM + NUMBERS + PROJECTS of the me layer next to a pack...
    local_pack_chars_with_me: int = 6500   # ...and the pack's share of the 9,500 chars then
    # G1 local degraded-mode fallback (Gemma 4 E4B, LiteRT-LM, in process). The API stays primary; Gemma answers only
    # while the API is offline, rate-limited or out of credit. Values and their reasons: docs/licences.md (model terms)
    # and the G1 notes in runtime/local_llm.py.
    fallback_enabled: bool = True
    fallback_cooldown_s: float = 30.0         # first re-probe after a failure; ~2 tiny probes a minute, a blip costs <= 30 s of Gemma
    fallback_cooldown_max_s: float = 60.0     # later probes (and the cap for a long retry-after)
    fallback_credit_cooldown_s: float = 60.0  # a top-up is a human-timescale event: probe once a minute
    fallback_first_text_s: float = 8.0        # F with no first text from the API after this long counts as a timeout
    fallback_rewarm_after_s: float = 240.0    # re-write the prompt cache on recovery when the outage outlived it
    local_prewarm: bool = False               # True: load Gemma and prime the pack at session start even when the API is healthy
    local_model: str = ("~/Library/Application Support/Verse/models/gemma-4-E4B-it-litert-lm/"
                        "gemma-4-E4B-it.litertlm")
    local_backend: str = "gpu"
    local_activation: str = "FLOAT32"         # F6 bench: the default GPU activations corrupt numbers ("11" became "111")
    local_ctx: int = 8192                     # F6 bench: 4096 rejects a 4.9k prompt, 8192 holds p5k with room to grow
    local_max_new: int = 120                  # same cap as the Haiku S/F route
    local_pack_chars: int = 9500              # ~ the p3k bench pack (9.7 KB): the size whose answers were scored
    local_max_turns: int = 12
    local_turn_chars: int = 3200              # transcript budget at (re)build time, newest turns first
    local_bank_extra: int = 2                 # bank entries cut from the prefix that are retrieved into the tail per question
    local_recycle_tokens: int = 6400          # rebuild the conversation (cold prefill, between questions) past this KV size
    local_first_token_s: float = 30.0         # no first token this long after the message is sent = Gemma failed (cold p5k ~20 s)
    local_total_s: float = 60.0
