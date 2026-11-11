"""Fixed settings tuples per route (plan P1-2, spec 5.8) and the runtime's tunable thresholds.

The tuple of a route (model, thinking, effort and, for D, the fallback opt-in) is sent byte-for-byte on the real
call, the pre-warm and the keep-alive. Only `max_tokens` differs: 0 on pre-warm/keep-alive, by definition.
`route_params()` is the single place that builds it, so the three call kinds cannot drift apart.
"""

from __future__ import annotations

import copy
from dataclasses import dataclass, field

from .follow import FollowParams
from .repeat import RepeatParams
from .own import OwnParams

from ..prep.model import HAIKU, OPUS, PREP_MODEL

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

# Ask this meeting (spec 2.2, runtime/ask.py): one tuple per picker choice, sent as is on every question. Haiku 5.5 allows
# `thinking: disabled` at effort high or below and has no server-side fallback. Sonnet 5.5 leaves thinking to the default
# (adaptive; `disabled` is a 400 there). Opus 5.5 rejects `disabled` too and defaults to effort medium, set explicitly here.
# Sonnet and Opus opt into the server-side fallback like route D.
ASK_ROUTES: dict[str, dict] = {
    "haiku": {"model": HAIKU, "max_tokens": 1500, "thinking": {"type": "disabled"}, "output_config": {"effort": "medium"}},
    "sonnet": {"model": SONNET, "max_tokens": 4000, "output_config": {"effort": "medium"},
               "betas": [FALLBACK_BETA], "fallbacks": "default"},
    "opus": {"model": OPUS, "max_tokens": 4000, "output_config": {"effort": "medium"},
             "betas": [FALLBACK_BETA], "fallbacks": "default"},
}
ASK_CONTEXT_MAX_TOKENS = 180_000    # at or below: the whole transcript is cached (full mode); above: chunked mode
ASK_EXCERPT_TOKENS = 60_000         # chunked mode: the excerpts of one question
ASK_HISTORY_PAIRS = 12              # the last Q/A pairs after the last reset that are sent again


def ask_params(model: str) -> dict:
    """A fresh copy of the tuple of an Ask model ("haiku" | "sonnet" | "opus")."""
    return copy.deepcopy(ASK_ROUTES[model])


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
    prewarm_backoff_s: float = 1.0    # wait before retrying a pre-warm that got 5xx/overloaded/429 (doubles per attempt)
    prewarm_retry_max_wait_s: float = 8.0   # a 429 retry-after is honoured up to this; pre-warm never decides whether the call runs
    offline_ping_every_s: float = 5.0
    keepalive_idle_s: float = 240.0
    keepalive_check_s: float = 10.0
    bucket_fraction: float = 0.80
    # follow my answer (docs/specs/2026-10-16-verse-follow-my-answer-design.md); thresholds and their evidence: docs/follow-tuning.md
    follow_default: bool = False       # `start.follow` absent = off (Swift always sends it; its setting defaults to on)
    follow_langs: tuple[str, ...] = ("en",)   # tuned on English only; other languages keep the card as it is
    follow: FollowParams = field(default_factory=FollowParams)
    own: OwnParams = field(default_factory=OwnParams)     # room route: the owner's own voice told by text (runtime/own.py)
    follow_tick_s: float = 0.1         # timer resolution of the machine (pauses, embed timeouts, the 4 s end)
    follow_repeat: RepeatParams = field(default_factory=RepeatParams)   # a follow line that restates a shown line or his words is dropped
    follow_repeat_wait_s: float = 0.6  # the embedding check of a follow card waits this long, then the lexical rule alone decides
    card_size: bool = True             # the card follows the question: short / normal / deep (runtime/size.py); False = every card as before
    # F2 incremental summary (lowest priority: never competes with S/F/D)
    summary_every_turns: int = 6        # finalized turns (both speakers) between rolling passes
    summary_every_s: float = 180.0      # ...or this much speech (audio clock), whichever comes first
    summary_max_tokens: int = 400       # rolling pass output cap (not part of the settings tuple)
    summary_bucket_min: float = 0.5     # skip the rolling pass while the Haiku bucket is below this fraction
    summary_budget_frac: float = 0.9    # ...or the session spend is above this fraction of the budget
    summary_partial_stale_s: float = 5.0   # a remote partial untouched this long no longer counts as "a turn is open"
    final_max_tokens: int = 1500        # the Sonnet merge writes a whole summary; 600 (D) would truncate it
    final_timeout_s: float = 45.0       # `control stop` waits this long for the merge, then closes with the draft
    stop_warm_wait_s: float = 10.0      # `control stop` during the pre-warm with live lines queued (turns, partials) waits this long
                                        # for the pre-warm so they are answered in order, then takes them into the transcript only.
                                        # With nothing live queued (Swift sends only `history` before `ready`) it does not wait.
    # spend
    budget_usd: float | None = None    # None = no cap (the owner: the Max credit pays, no limits)
    # F3 paraphrase matcher (EmbeddingGemma 2 text 270M, LiteRT-LM) next to Swift's n-gram matcher. Every gate is
    # required: the F3 bench showed 10-12 % wrong ids and premature locks on short prefixes without them.
    embed_enabled: bool = True
    embed_model: str = ("~/Library/Application Support/Verse/models/embeddinggemma-2-text-270m-litert/"
                        "embeddinggemma-2-text-270m.litertlm")
    embed_backend: str = "gpu"
    # Accept rule (2026-11-11 retune, criterion 2 of the eval gates on wrong hits among SHOWN hits <= 5 %). Cosine with the
    # sentence-similarity prefix, EmbeddingGemma 2 text 270M (GPU):
    # - bench/embed/results/emb_gpu_sym.npz, full text: right-entry paraphrases top-1 p10/p50/p90 0.875/0.906/0.941 (n=49);
    #   paraphrases whose top-1 is the WRONG entry 0.867/0.881/0.914 (n=11); the 40 off-bank distractors 0.800/0.841/0.869,
    #   max 0.880. Margins over the runner-up overlap (wrong-entry p90 0.024 vs right-entry p50 0.034): the margin cannot
    #   separate them, the threshold and the consecutive rule have to.
    # - eval/out/f3-embed (stored live replay, 193 evaluated partials): off-bank questions spike on 5-6 word prefixes and
    #   decay with more words ("What would you change about Compass if you joined?" 0.914 -> 0.901 -> 0.890 on one entry;
    #   "How would you measure success for the dispatcher pilot?" 0.920 -> 0.896 -> 0.888). The old rule (0.865, margin 0.02,
    #   2 in a row) shows those as wrong cards: 12/24 paraphrase hits, 4 wrong final hits = 11.4 % of 35 shown (with the
    #   final-text pass 15/24, 6 wrong = 14.3 %). This rule: 13/24 paraphrase hits, 0 wrong (0 of 34 shown), with the
    #   final-text pass carrying most of the hits (4/24 from partials alone), so a paraphrase card shows about 0.57 s (p50) /
    #   0.74 s (p90) after the question's acoustic end instead of during it. On the bench's 60 paraphrases + 40 distractors:
    #   32/60 hits, 2 wrong ids, 0 distractor hits. Neighbours: 0.895 gives 14/24 with 1 wrong (2.8 %); 2 in a row instead of
    #   3 gives 13/24, cards at 0.32 / 0.60 s, but shows the Compass spike as a wrong card. it/tr are not calibrated
    #   (embed_langs below). Replay numbers from the stored partial scores re-decided offline; the final-text pass did not
    #   exist when f3-embed was recorded and is approximated by the turn's last evaluated partial.
    embed_threshold: float = 0.90      # top-1 cosine: above every bench distractor (max 0.880) and the wrong-entry median (0.881)
    embed_margin: float = 0.005        # over the runner-up entry; 0.0-0.01 give the same replay result, 0.01 loses 2 bench hits
    embed_min_words: int = 5           # words in the partial
    embed_consecutive: int = 3         # the same entry on this many consecutive evaluated partials (2 lets prefix spikes through)
    embed_langs: tuple[str, ...] = ("en",)   # thresholds were tuned on English only
    # One more match on the final text when a remote turn closes with no bank hit yet (partials that never matched, or a
    # statement/fragment whose cue never showed). A single evaluation is enough there (the consecutive-partials gate
    # exists against premature locks on short prefixes; a closed turn has no prefix). The hit goes through `_late_hit`.
    embed_final_pass: bool = True
    # The me layer (docs/specs/2026-10-16-verse-anytime-calls-design.md 2.2): retrieval of chunks of his files for a remote turn
    # (same partials as the bank matcher, on the same embedding thread), and the unprepared / room / card-now rules.
    # cosine floor of a chunk. The real model's background similarity is high: on the Dana fixtures (13 chunks, 9 questions
    # the files answer, 7 they do not) unrelated questions top out at 0.797 and answerable ones sit at 0.76-0.88, so 0.81 keeps
    # all 7 unrelated ones out and 6 of the 9 answerable ones in (the band is narrow: a miss only means no extra chunk). test_runtime_me.py::test_real_model_floor records it.
    me_retrieval_floor: float = 0.81
    me_retrieval_k: int = 3            # chunks per turn in an unprepared call
    me_retrieval_k_prepared: int = 2   # ...and in a prepared one (the pack carries most of it)
    me_retrieval_min_words: int = 5    # words in the partial (the bank matcher's gate)
    me_retrieval_final_wait_s: float = 0.150   # D waits this long for the final-text retrieval; F never waits
    me_files_max_chars: int = 4800     # FROM <OWNER>'S FILES in the tail: about 1,200 tokens
    room_min_words: int = 6            # room route: an automatic card needs a question cue and this many words
    room_probe_min_words: int = 5      # room route: a statement of at least this many words gets the (silent unless it is a question) statement probe (was 8: Italian yes/no questions without a wh-word, "ha avuto esperienza con ...", are 5-7 words and went unanswered)
    room_hold_s: float = 1.2           # room route: a card held back while he reads the one on screen fires after this long without reading
    room_hold_score: float = 0.35      # ... a new card replaces the one he is reading at once only when its text's own-voice share is below this (and a strong cue or the probe says question for him)
    unprepared_statement_min_words: int = 4   # unprepared: a statement shorter than this gets no probe
    card_now_match_edit: int = 6       # the real turn that follows a card-now answer within this edit distance gets no second card


# Memory index and search (docs/specs/2026-10-21-verse-memory-package-design.md 2.1-2.2; memory/index.py, memory/search.py).
MEMORY_CHUNK_ROWS = 8               # a turn chunk: at most this many consecutive transcript rows...
MEMORY_CHUNK_CHARS = 1_200          # ...and this many characters (a longer row is a chunk of its own); prep chunks share the cap
MEMORY_CANDIDATES = 60              # top-N of the BM25 list and of the cosine list that go into the rank fusion
MEMORY_RRF_K = 60                   # reciprocal rank fusion: score = sum of 1 / (K + rank)
MEMORY_SOURCE_WEIGHTS = {"turn": 1.0, "summary": 1.2, "prep": 0.6, "chat": 0.5}
MEMORY_EXCERPT_TOKENS = 16_000      # the excerpts of one question, estimated with ask.est_tokens
MEMORY_SESSION_EXCERPT_TOKENS = 6_000   # ...of which one session may take this much
MEMORY_EMBED_BATCH = 32             # chunks embedded per batch in phase 2 of the index run


# Memory Ask and the pre-meeting brief (spec 2.3, 2.4; runtime/memory_ask.py, memory/brief.py).
MEMORY_HISTORY_PAIRS = 6            # Q/A pairs of a memory chat that are sent again (text only)
MEMORY_CATALOG_MAX = 400            # SESSION CATALOG lines (newest first); older meetings are searched but not listed
BRIEF_MAX_SESSIONS = 8              # past sessions a brief reads
BRIEF_EXCERPT_TOKENS = 18_000       # ...of excerpts in all, split evenly between them
BRIEF_MAX_TOKENS = 1_500            # the brief's output cap
BRIEF_PACK_CHARS = 2_400            # brief.md as the live model sees it (about 600 tokens)


def brief_params() -> dict:
    """The brief's request tuple: Sonnet's Ask tuple with the brief's output cap."""
    p = ask_params("sonnet")
    p["max_tokens"] = BRIEF_MAX_TOKENS
    p["output_config"] = {"effort": "low"}       # the default (adaptive) thinking at medium used the whole cap before the text (live check)
    return p
