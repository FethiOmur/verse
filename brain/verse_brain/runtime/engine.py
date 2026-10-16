"""The brain runtime: speculation (S), fast (F) and deep (D) tiers over one warm transport (plan P1-2).

Output contract towards Swift (in addition to the plan's event list):
- Speculative output is held in the brain. S calls (fired on partials) and an early D call stream into a buffer;
  nothing of theirs reaches Swift until the endpoint (`turn`) confirms them. At `turn` the brain sends
  `select{turn_id,id}` for the S call whose input is closest to the endpoint text, then that call's buffered
  deltas, then the rest live. Every `delta` Swift receives is therefore meant to be shown.
- `BANK:` / `OPENER_*` lines are never sent as text; they become `bank_verdict` / `opener_status` events.
- `metric` events carry wall-clock `t` (time.time(), epoch seconds) plus `id`/`tier` and stage details.
- Turn kind (`turn.kind`, optional; Swift VerseTurns): `fragment` -> nothing is fired or shown for the turn (it stays
  in the transcript). `statement` (addressee me|unknown) -> S output is dropped, no early D; one F "statement probe"
  whose first line is `KIND: question|statement`: `statement` shows at most one `SAY:` line of <= 12 words (or nothing
  on `NONE`), `question` continues as the normal F answer and then D. `question` or no kind: unchanged.
- F2 incremental summary, lowest priority. Tier R (Haiku, the S/F tuple and cached prefix, lane 1, no hedge) runs
  every `summary_every_turns` finalized turns or `summary_every_s` of speech, only when no turn is open and no
  S/F/D call is in flight and the Haiku bucket and the budget have room; its lines are merged (deduped) into a
  running list and sent as `actions{items}` plus `summary{decisions,actions,open}`. Tier A (Sonnet, the D tuple,
  lane 1, no hedge) runs on `control stop|summarize`, merges everything and writes `summary.md` into the session
  folder; its `summary` event adds `final`, `conflicts`, `text`, `path` (and `draft_reason` when the merge failed and
  summary.md holds the rolling notes only). R and A never emit `delta`, and spend counts in the session budget.
- Follow my answer (docs/specs/2026-10-16-verse-follow-my-answer-design.md; runtime/follow.py is the state machine). the owner's
  own `partial`/`turn` (speaker me) feed a detector that compares his words with the card of the latest remote question. When
  he goes off the card, one tier-C call (Haiku, the S/F tuple and cached prefix) writes the card that continues his line:
  `follow{turn_id,reason,card_id}`, then `delta`s with tier C and `card_id`. Points he says (also in other words) are sent as
  `covered{turn_id,card_id,point}`; the original card's id is `orig-<turn_id>`. After a follow card, refreshes come at his
  sentence ends only. `start.follow` turns it on (Swift sends it; its setting defaults to on; absent means off); it is English only until the thresholds are tuned for
  other languages. C never changes the S/F/D flow: a failed or dropped C leaves the original card on screen.
- Anytime calls (docs/specs/2026-10-16-verse-anytime-calls-design.md; runtime/me.py is the me layer). `start.me` names the
  permanent profile: its text goes into the cached ABOUT OWNER system block, its NUMBERS are compared with the pack's FACTS
  (`notice me_conflicts`), and chunks of his files are retrieved for remote turns on the embedding thread into the uncached
  tail (F never waits for them; D waits a few ms for the final-text retrieval). `start.mode:"unprepared"` runs on an empty
  pack: no bank, remote statements of >= 4 words go to the statement probe. `speaker:"room"` is the room route's one mic: it
  is treated like `remote`, the addressee is always unknown, and an automatic card needs a question cue and >= 6 words
  (`start.room_auto:"off"` leaves only card-now), or it is a statement of >= 8 words that a silent room probe (the KIND line,
  no acknowledgements) calls a question for Alex. While a card is on screen, a room text whose content words line up with the
  card in order (runtime/own.py) is relabelled `me`: no card, follow coverage, `[Alex]` in the transcript. `control card_now` answers the latest remote/room turn at once on turn
  id `now-<n>`, past the cue, kind and addressee gates. `control lang` changes the session language from then on.
  `control route` (+ optional `room_auto`, `follow`) does the same for the audio route: Swift swaps its listen pipeline in
  place and the session, transcript, cached prefix and open turns go on; only the room gate and follow mode follow the route.
"""

from __future__ import annotations

import asyncio
import logging
import os
import re
import time
from dataclasses import dataclass, field
from itertools import count
from pathlib import Path
from typing import Callable

from ..prep.model import Usage, spend_usd
from .embed import PREFIX, Embedder, EmbedPath, EmbedUnavailable, Job, Result
from .follow import (Covered, Diverged, Ended, FollowMachine, NeedEmbed, Refresh, clean_line, score_matrix)
from .lines import LineAssembler
from .own import OwnSpeech
from .me import LibraryPath, MeLayer, conflicts as me_conflicts, load_me, pack_snippet_refs, select_hits
from .prompt import (STATEMENT_SAY_WORDS, WARMUP_TAIL, Turn, build_request, card_now_tail, deep_tail, fast_tail,
                     files_block, final_tail, follow_tail, rolling_tail, statement_tail)
from .protocol import LANGS, REMOTE_SPEAKERS, Emitter, Session, load_session, msg_lang, turn_kind
from .ratelimit import ModelLimiter
from .settings import HAIKU, MODEL_ROUTE, SONNET, Config, route_params
from .summary import Running, parse_lines, render_markdown
from .transport import (AuthFailed, BadRequest, CreditExhausted, Offline, Overloaded, RateLimited, Transport,
                        TransportError)

log = logging.getLogger("verse.runtime")

# A bank hit that lands after its turn was closed as statement/fragment still answers the turn when it comes within this
# many seconds of the turn's arrival and no newer turn has started. The paraphrase matcher is the only source of such hits
# (Swift's n-gram hits precede their turn on the pipe): a job takes ~20 ms on the GPU, up to ~0.6 s on a busy CPU
# (bench/embed/results/latency_runs.txt), and the first job of a session waits for the bank index (1.6-2.3 s,
# `index_s` in the same runs). 3 s covers that; an answer later than that comes after Alex has started to talk.
LATE_HIT_WINDOW_S = 3.0

_WORD = re.compile(r"[\w']+", re.UNICODE)


def tokens(text: str) -> list[str]:
    return _WORD.findall(text.lower())


_FACT_LINE = re.compile(r"^\[f\d+\]\s+[^|]*\|\s*([^|]+?)\s*(?:\||$)")
_GLOSS_LINE = re.compile(r"^\[g\d+\]\s+(.*?)\s*(?:\|\s*[^|]*)?$")


def follow_pack_lines(session: Session) -> list[str]:
    """Everything the pack can say, line by line (bank openers and points, facts, glossary): the reference the follow
    detector's margin looks at to see that Alex is on another topic of the pack."""
    out: list[str] = []
    for rec in session.bank.values():
        out.append(str(rec.get("opener", "")))
        out += [str(x) for x in rec.get("points", [])]
    for ln in session.pack.splitlines():
        m = _FACT_LINE.match(ln) or _GLOSS_LINE.match(ln)
        if m:
            out.append(m.group(1))
    seen: set[str] = set()
    res = []
    for x in out:
        x = clean_line(x)
        if x and x not in seen:
            seen.add(x)
            res.append(x)
    return res


def edit_distance(a: list[str], b: list[str]) -> int:
    """Token-level Levenshtein distance."""
    if len(a) < len(b):
        a, b = b, a
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def usage_obj(u: dict) -> Usage:
    return Usage(input=u.get("input_tokens", 0) or 0, output=u.get("output_tokens", 0) or 0,
                 cache_read=u.get("cache_read_input_tokens", 0) or 0,
                 cache_write=u.get("cache_creation_input_tokens", 0) or 0)


_seq = count(1)


class Call:
    """One model call (S, F, D; R = rolling summary, A = final summary) with hedging, line parsing and
    buffered/live output."""

    def __init__(self, brain: "Brain", tier: str, turn_id: str, input_text: str, request: dict, *,
                 buffered: bool, route: str, probe: bool = False, quiet: bool = False) -> None:
        self.brain = brain
        self.tier = tier
        self.route = route
        self.turn_id = turn_id
        self.input_text = input_text
        self.input_tokens = tokens(input_text)
        self.request = request
        self.model = request["model"]
        self.seq = next(_seq)
        self.id = f"{tier.lower()}{self.seq:04d}"
        self.buffered = buffered
        self.discarded = False
        self.buffer: list[dict] = []
        self.say_line: str | None = None
        self.first_point: str | None = None
        self.bank_id: str | None = None
        self.opener_ok: bool | None = None
        # statement probe (an F call for a turn Swift called a statement): its first line is `KIND: ...`
        self.probe = probe
        self.quiet = quiet                    # a probe that shows nothing unless it says KIND: question (the room route: no acknowledgements)
        self.kind: str | None = None          # None until the KIND line (or, without one, the first text line)
        self.kind_known = asyncio.Event()
        self.points: list[str] = []
        self.stop_reason: str | None = None
        self.usage: dict = {}
        self.error: TransportError | None = None
        self.hedged = False
        self.winner_lane: int | None = None
        self.new_connection: bool | None = None
        self.retries_left = 1 if tier in ("D", "A") else 0  # S/F/R/C: max_retries 0; D, A: one retry
        self.follow_reason: str | None = None   # tier C: "diverged" | "refresh"
        self.follow_sent = False                # tier C: the `follow` event went out (just before its first delta)
        self.follow_t0: float = 0.0             # tier C: when the divergence / refresh was decided (time.time())
        self.lane = 1 if tier in ("R", "A") else 0   # summaries keep off the S/F/D connection (lane 0)
        self.summary_lines: list[str] = []
        self.t: dict[str, float] = {}
        self.done = asyncio.Event()
        self.bank_known = asyncio.Event()
        self.first_text_seen = False
        self.lines = LineAssembler(self._on_text, self._on_control, hold_first_line=(tier == "D" or probe),
                                   on_sentinel=self._on_sentinel)
        self.task: asyncio.Task | None = None

    # ---- output
    def _out(self, ev: dict) -> None:
        if self.discarded:
            return
        if self.buffered:
            self.buffer.append(ev)
        else:
            if "visible" not in self.t:
                self._stage("visible")
            self.brain.emitter.emit(ev)

    def _stage(self, stage: str, **extra) -> None:
        now = time.time()
        self.t.setdefault(stage, now)
        self.brain.emitter.metric(self.turn_id, stage, now, id=self.id, tier=self.tier, **extra)

    def release(self) -> None:
        """Make a speculative call visible: flush its buffer, then stream live."""
        if self.discarded or not self.buffered:
            return
        self.buffered = False
        self._stage("release", buffered_events=len(self.buffer))
        buf, self.buffer = self.buffer, []
        for ev in buf:
            self._out(ev)
        self.brain.on_card_released(self)

    def discard(self) -> None:
        if self.discarded:
            return
        self.discarded = True
        self.buffer.clear()
        if self.task is not None and not self.task.done():
            self.task.cancel()
            # A task cancelled before its first step never enters `run()`, so its `finally` never sets these: whoever
            # waits on the call (the statement decider, D's bank wait, `settle`) would wait forever.
            self.task.add_done_callback(self._release_waiters)

    def _release_waiters(self, _task=None) -> None:
        self.bank_known.set()
        self.kind_known.set()
        self.done.set()

    # ---- line handling
    def _on_text(self, chunk: str, line_done: bool, line: str) -> None:
        if self.tier in ("R", "A"):  # summary output becomes `summary`/`actions` events, never deltas
            if line_done:
                self.summary_lines.append(line.strip())
            return
        if self.probe and self.kind != "question":
            self._on_statement_text(line_done, line)
            return
        if self.tier == "C" and not self.follow_sent and not self.discarded:
            self.follow_sent = True      # the card switches when its first text arrives, not when the call is launched
            self.brain.emitter.emit({"type": "follow", "turn_id": self.turn_id, "reason": self.follow_reason,
                                     "card_id": self.id})
        self._out(self.brain.emitter.delta(self.id, self.turn_id, self.tier, chunk, line_done,
                                           card_id=self.id if self.tier == "C" else None))
        if line_done:
            s = line.strip()
            if s.startswith("SAY:") and self.say_line is None:
                self.say_line = s[4:].strip()
                self._stage("say_line")
                self.brain.on_card_line(self, "say", self.say_line)
            elif s.startswith("- "):
                self.points.append(s[2:].strip())
                self.brain.on_card_line(self, "point", s[2:].strip())
                if self.first_point is None:
                    self.first_point = s[2:].strip()
                    self._stage("first_point")

    def _on_statement_text(self, line_done: bool, line: str) -> None:
        """Statement mode: only the first complete `SAY:` line of <= STATEMENT_SAY_WORDS words is shown. Points, a
        BANK line, a second line, `NONE` and an over-long acknowledgement are dropped, whatever the model writes."""
        if not line_done:
            return
        if self.kind is None:              # no KIND line: a statement is the safe reading
            self.kind = "statement"
            self.kind_known.set()
        s = line.strip()
        if self.quiet or self.say_line is not None or not s.startswith("SAY:"):
            return
        body = s[4:].strip()
        if not body:
            return
        if len(body.split()) > STATEMENT_SAY_WORDS:
            self._stage("statement_overlong", words=len(body.split()))
            return
        self.say_line = body
        self._out(self.brain.emitter.delta(self.id, self.turn_id, self.tier, s, True))
        self._stage("say_line")

    def _on_sentinel(self, line: str) -> None:
        """A "nothing to say" line (NONE, SAY: NONE, N/A, SKIP ...): never shown, whatever tier wrote it."""
        self._stage("sentinel_dropped", line=line[:40])

    def _on_control(self, line: str) -> None:
        if line.startswith("KIND:"):
            if self.probe and self.kind is None:
                self.kind = "question" if line[5:].strip().lower().startswith("question") else "statement"
                self.kind_known.set()
                if self.kind == "question":
                    # the SAY and point lines may follow in the same chunk, before any waiter runs: the follow machine must
                    # already be on this question when they complete
                    self.brain.on_probe_escalated(self)
        elif line.startswith("BANK:"):
            if self.probe and self.kind != "question":
                return
            bid = line[5:].strip().split()[0] if line[5:].strip() else "none"
            self.bank_id = bid.strip("[]").lower() if bid.lower() == "none" else bid.strip("[]")
            self.bank_known.set()
            self.brain.on_bank_line(self)
        elif line.startswith("OPENER_"):
            self.opener_ok = line.startswith("OPENER_OK")
            self._out({"type": "opener_status", "turn_id": self.turn_id, "ok": self.opener_ok})

    def _on_event(self, ev) -> None:
        if ev.kind == "start":
            self.usage.update(ev.usage)
        elif ev.kind == "text":
            if not self.first_text_seen:
                self.first_text_seen = True
                self._stage("first_delta")
                self.brain.on_first_text(self)
            self.lines.feed(ev.text)
        elif ev.kind == "stop":
            self.usage.update(ev.usage)
            self.stop_reason = ev.stop_reason
            self.lines.close()

    # ---- run
    async def run(self) -> None:
        b = self.brain
        try:
            while True:
                try:
                    self._stage("fire", words=len(self.input_tokens), hedge_after_s=b._hedge_after(self))
                    await b.hedged_stream(self)
                    break
                except (RateLimited, Overloaded) as e:
                    if self.retries_left > 0 and b.retry_ok(self, e):
                        self.retries_left -= 1
                        wait = e.retry_after if isinstance(e, RateLimited) and e.retry_after is not None else 0.5
                        self._stage("retry_wait", kind=e.kind, wait_s=wait)
                        await asyncio.sleep(wait)
                        self.t.pop("fire", None)
                        continue
                    raise
        except asyncio.CancelledError:
            self.discarded = True
        except TransportError as e:
            self.error = e
            b.on_call_error(self, e)
        finally:
            self.bank_known.set()  # waiters re-check bank_id; a call without a BANK line must not stall D
            self.kind_known.set()  # ...and a probe that failed or never wrote KIND must not stall its decider
            self.done.set()        # before on_call_done: its follow-ups (next summary pass) must see this call as over
            b.on_call_done(self)
            self._stage("done", stop_reason=self.stop_reason, usage=self.usage, hedged=self.hedged,
                        winner_lane=self.winner_lane, new_connection=self.new_connection,
                        error=self.error.kind if self.error else None, discarded=self.discarded,
                        cost_usd=round(spend_usd(self.model, usage_obj(self.usage)), 6) if self.usage else 0.0)


@dataclass
class BankHit:
    bank_id: str
    score: float
    via: str = "ngram"      # "ngram": Swift's matcher (exact phrasings); "embed": the brain's paraphrase matcher


@dataclass
class TurnState:
    turn_id: str
    partial: str = ""
    partial_changed: float = 0.0
    cue: bool = False
    s_calls: list[Call] = field(default_factory=list)
    last_fire_text: str | None = None
    last_fire_t: float = 0.0
    d_call: Call | None = None
    d_timer: asyncio.Task | None = None
    bank_hit: BankHit | None = None
    finished: bool = False
    final_text: str = ""
    addressee: str = "unknown"
    fast: Call | None = None
    verdict_sent: bool = False
    turns_before: list[Turn] = field(default_factory=list)
    retried_offline: bool = False
    kind: str | None = None        # `turn.kind` as sent by Swift (None = missing or unknown: question behaviour)
    finished_at: float = 0.0       # time.monotonic() when the turn arrived
    rescued: bool = False          # a late bank hit turned a statement/fragment into an answered question
    # F3 paraphrase matcher: the candidate entry of the last evaluated partials, how many in a row, the id sent
    embed_cand: str | None = None
    embed_count: int = 0
    embed_sent: str | None = None
    embed_final_queued: bool = False    # the final-text pass was queued for this turn (at most once)
    # anytime calls
    lang: str | None = None             # `lang` of the turn's messages (None = the session's)
    room: bool = False                  # the room route's mic (speaker "room"): remote pipeline, no addressee
    me_hits: list = field(default_factory=list)           # the newest retrieval of the me library for this turn (Hit)
    me_final: asyncio.Event | None = None                  # set when the final-text retrieval has come back
    card_now: bool = False              # answered on request (control card_now): the cue / kind / addressee gates were skipped
    card_now_t0: float = 0.0            # time.time() of the key press
    card_now_partial: bool = False      # card-now answered a partial that was still being spoken
    answered_by: str | None = None      # id of the card-now turn that already answered this (still open) turn
    answered_text: str = ""


def _follow_safe(fn):
    """Follow my answer is an extra: whatever goes wrong inside it turns it off for the session and never reaches the
    S/F/D path or the process (one `follow_error` metric says what)."""
    import functools  # noqa: PLC0415

    @functools.wraps(fn)
    def wrapper(self, *a, **kw):
        try:
            return fn(self, *a, **kw)
        except Exception as e:  # noqa: BLE001
            log.exception("follow my answer failed in %s", fn.__name__)
            if self.follow is not None:
                self.follow = None
                self.follow_on = False
                self.emitter.metric("", "follow_error", where=fn.__name__, reason=f"{type(e).__name__}: {e}"[:200])
            return None
    return wrapper


class Brain:
    def __init__(self, transport: Transport, emitter: Emitter, config: Config | None = None,
                 embedder_factory: Callable[[], Embedder] | None = None) -> None:
        self.transport = transport
        self.emitter = emitter
        self.config = config or Config()
        # F3 paraphrase matcher; None (tests, `--fake`, `--no-embed`) leaves only Swift's n-gram hits
        self.embed: EmbedPath | None = None
        if embedder_factory is not None and self.config.embed_enabled:
            self.embed = EmbedPath(embedder_factory, self._on_embed_result, self._spawn,
                                   lambda tid, stage, **kw: self.emitter.metric(tid, stage, **kw))
        self.session: Session | None = None
        self.lang = "en"
        # anytime calls
        self.mode = "prepared"                   # "unprepared": an empty pack, no bank
        self.route_kind = "meeting"              # "meeting" | "phone" | "room"
        self.room_auto = "questions"             # room route: automatic cards for questions only, or "off"
        self.me: MeLayer | None = None
        self.about: str | None = None            # the ABOUT OWNER system block (None: the layer is off)
        self.lib: LibraryPath | None = None
        self._bank_embed = False                 # the bank matcher is on for this session's language
        self._snippet_refs: set[str] = set()
        self._now_seq = count(1)
        self._own = OwnSpeech(self.config.own)   # room route: the card on screen, to tell the owner's own reading of it from the room
        self._own_turns: dict[str, bool] = {}    # room turn id -> relabelled `me` (a turn keeps its label unless its text stops lining up)
        self._follow_want = False
        self.turns: list[Turn] = []
        self.ts: dict[str, TurnState] = {}
        self.active_remote: str | None = None
        self.latest_remote_turn: str | None = None
        self.calls: list[Call] = []
        self.spend = 0.0
        self.halted: str | None = None
        self.offline = False
        self.pending_turn: str | None = None
        self.limiters = {HAIKU: ModelLimiter(self.config.bucket_fraction), SONNET: ModelLimiter(self.config.bucket_fraction)}
        self.last_call_mono = {HAIKU: 0.0, SONNET: 0.0}
        self.bg: list[asyncio.Task] = []
        self.tasks: set[asyncio.Task] = set()
        self.stopped = asyncio.Event()
        self.start_background = True
        self.late_hit_window_s = LATE_HIT_WINDOW_S
        # F2 incremental summary
        self.running = Running()
        self.summary_spend = 0.0
        self.closing = False
        self._rolled_n = 0                       # finalized turns covered by the last rolling pass
        self._roll_t0: float | None = None       # audio clock when that pass started (first turn's end before)
        self._last_audio_end: float | None = None
        self._last_partial_t = 0.0
        self._roll_call: Call | None = None
        self._deciding = 0                       # `_decide_d` tasks pending (D not yet fired or skipped)
        self._defer_reason: str | None = None
        self._final_task: asyncio.Task | None = None
        self._final_n = -1
        self._final_events: list[dict] = []
        # follow my answer
        self.follow: FollowMachine | None = None
        self.follow_on = False
        self._follow_pack: list[str] = []         # every opener, point, fact and glossary line of the pack (the margin's reference)
        self._follow_cache: dict[str, list[float]] = {}   # text -> unit vector (touched on the embedding thread only)
        self._follow_req: NeedEmbed | None = None  # newest embedding request not yet started (older ones are dropped)
        self._follow_busy = False
        self._follow_embed_failed = False
        self._follow_embed_ok: bool | None = None
        self._follow_task: asyncio.Task | None = None   # the ticker: not in `tasks`, so `settle()` does not wait for it
        self._follow_calls: list[Call] = []
        self._follow_detected: dict[str, float] = {}      # turn_id -> time.time() of the last divergence/refresh decision
        self._follow_banks: set[str] = set()
        self.follow_counts = {"diverged": 0, "refresh": 0, "covered": 0, "c_calls": 0, "c_empty": 0}

    # ------------------------------------------------------------------ helpers
    def _spawn(self, coro) -> asyncio.Task:
        t = asyncio.get_running_loop().create_task(coro)
        self.tasks.add(t)
        t.add_done_callback(self.tasks.discard)
        return t

    def _ts(self, turn_id: str) -> TurnState:
        st = self.ts.get(turn_id)
        if st is None:
            st = self.ts[turn_id] = TurnState(turn_id)
        return st

    def _status(self, state: str, message: str = "", **extra) -> None:
        self.emitter.status(state, message, **extra)

    def _halt(self, state: str, message: str) -> None:
        if self.halted is None:
            self.halted = state
            self._status(state, message)
            for c in self.calls:
                if not c.done.is_set():
                    c.discard()

    @property
    def unprepared(self) -> bool:
        return self.mode == "unprepared" or self.session is None or not self.session.pack.strip()

    def _lang(self, st: TurnState) -> str:
        return st.lang or self.lang

    def _ready_extra(self) -> dict:
        return {"me": self.me.info() if self.me is not None else None}

    # ------------------------------------------------------------------ dispatch
    async def handle(self, msg: dict) -> None:
        t = msg.get("type")
        if t == "start":
            await self.on_start(msg)
        elif t == "partial":
            self.on_partial(msg)
        elif t == "turn":
            self.on_turn(msg)
        elif t == "bank_hit":
            self.on_bank_hit(msg)
        elif t == "control":
            a = msg.get("action")
            if a == "stop":
                await self.stop()
            elif a == "summarize":
                self._spawn(self.summarize())
            elif a == "card_now":
                self._card_now()
            elif a == "lang":
                self._set_lang(msg.get("lang"))
            elif a == "route":
                self._set_route(msg)

    # ------------------------------------------------------------------ start / warm transport
    def _prefix_request(self, route: str, max_tokens: int | None, tail: str, turns: list[Turn] | None = None) -> dict:
        assert self.session is not None
        return build_request(route, route_params(route, max_tokens=max_tokens), self.session.pack,
                             list(self.turns if turns is None else turns), tail, self.about)

    async def _warm(self, model: str, kind: str, lane: int = 0) -> None:
        route = MODEL_ROUTE[model]
        req = self._prefix_request(route, 0, WARMUP_TAIL)
        self.last_call_mono[model] = time.monotonic()
        t0 = time.time()
        usage, headers, stop = await self.transport.create(route, req, lane)
        self.limiters[model].update_from_headers(headers)
        cost = spend_usd(model, usage_obj(usage))
        self.spend += cost
        self.emitter.metric("", kind, time.time(), model=model, usage=usage, stop_reason=stop,
                            ms=round((time.time() - t0) * 1000, 1), cost_usd=round(cost, 6))

    async def on_start(self, msg: dict) -> None:
        try:
            self.session = load_session(msg["session_dir"])
        except (OSError, KeyError, ValueError) as e:
            self._status("error", f"cannot read session folder: {type(e).__name__}")
            return
        self.lang = msg.get("lang", "en")
        self.mode = "unprepared" if msg.get("mode") == "unprepared" else "prepared"
        self.route_kind = msg["route"] if msg.get("route") in ("meeting", "phone", "room") else "meeting"
        self.room_auto = "off" if msg.get("room_auto") == "off" else "questions"
        self._snippet_refs = pack_snippet_refs(self.session.pack)
        self._load_me(msg.get("me"))
        self._bank_embed = self.lang in self.config.embed_langs
        if self.embed is not None and (self._bank_embed or self.lib is not None):
            # on the embedding thread, while the pre-warm runs; the library alone starts it with an empty bank
            self.embed.start(self.session.bank if self._bank_embed else {}, self.lang)
        if self.lib is not None:
            self.lib.start()
        self._follow_want = bool(msg.get("follow", self.config.follow_default))
        self._follow_start(msg)
        self._status("warming", f"pre-warming {HAIKU} and {SONNET}")
        try:
            # Open every lane now (pre-warm on one lane, ping on the other) so no connection is opened at t = 0.
            # 5-8 % of fresh connections on the owner's network stall 10-50 s (bench/RESULTS.md): bound each attempt and
            # retry on the other lane instead of giving up on the first stall.
            last: Exception | None = None
            for attempt in range(self.config.prewarm_attempts):
                warm_lane, ping_lane = attempt % 2, (attempt + 1) % 2
                try:
                    await asyncio.wait_for(asyncio.gather(
                        self._warm(HAIKU, "prewarm", warm_lane), self._warm(SONNET, "prewarm", warm_lane),
                        *(self._ping_one(m, ping_lane) for m in (HAIKU, SONNET))),
                        timeout=self.config.prewarm_attempt_s)
                    last = None
                    break
                except (Offline, asyncio.TimeoutError) as e:
                    last = e
                    if attempt + 1 < self.config.prewarm_attempts:
                        self._status("warming", f"pre-warm attempt {attempt + 1} stalled ({type(e).__name__}); retrying on lane {(attempt + 1) % 2}")
            if last is not None:
                raise Offline(f"{type(last).__name__} after {self.config.prewarm_attempts} attempts")
        except Offline as e:
            self.offline = True
            self._status("offline", f"pre-warm failed: {e}")
        except CreditExhausted:
            self._halt("credit_exhausted", "Max API credit used up")
            return
        except AuthFailed as e:
            self._halt("error", f"API key rejected ({e})")
            return
        except TransportError as e:
            self._status("error", f"pre-warm failed: {e}")
        else:
            self._status("ready", f"warm; spend so far ${self.spend:.4f}", **self._ready_extra())
        if self.start_background:
            self.bg.append(self._spawn(self._ping_loop()))
            self.bg.append(self._spawn(self._keepalive_loop()))

    def _load_me(self, spec: object) -> None:
        """`start.me`: the permanent profile. Absent or null: today's behaviour. Named but unreadable: a `me_missing` notice and
        the session runs without it."""
        self.me = self.about = self.lib = None
        if spec is None:
            return
        assert self.session is not None
        layer = load_me(spec)
        if layer is None:
            self.emitter.notice("me_missing")
            return
        self.me = layer
        self.about = layer.about_block(self.session.pack)
        items = me_conflicts(layer.facts, self.session.pack)
        if items:
            self.emitter.notice("me_conflicts", items=items)
        if layer.chunks and self.embed is not None:
            cfg = self.config
            self.lib = LibraryPath(layer, self.embed, self._spawn, cfg.embed_model, self._on_lib_result,
                                   lambda tid, stage, **kw: self.emitter.metric(tid, stage, **kw),
                                   floor=cfg.me_retrieval_floor, k=cfg.me_retrieval_k)

    def _set_lang(self, lang: object) -> None:
        """`control lang`: the session language from now on (Swift restarts its engines). The bank matcher and follow mode
        follow the language: they are on only where their thresholds were tuned."""
        if not isinstance(lang, str) or lang not in LANGS or lang == self.lang:
            return
        self.lang = lang
        self.emitter.metric("", "lang_change", lang=lang)
        want = lang in self.config.embed_langs
        if self.embed is not None and self.session is not None:
            if want:
                self._bank_embed = True
                self.embed.start(self.session.bank, lang)     # the index is built from the phrases of this language
            else:
                self._bank_embed = False
        self._follow_resync()

    def _set_route(self, msg: dict) -> None:
        """`control route`: the audio route changed in the running call (Swift swapped its listen pipeline in place). The session,
        the transcript, the cached prefix and the open turns stay. Only what depends on the route changes: the room route's
        automatic-card gate (`room_auto`, when given) and follow mode, which is off in the room route (no `me` channel) and
        comes back with the meeting. `follow` (when given) is the user's setting, as `start.follow` was, so a call that began
        in the room can still turn follow on when it moves to the meeting."""
        route = msg.get("route")
        if route not in ("meeting", "phone", "room"):
            return
        if "room_auto" in msg:
            self.room_auto = "off" if msg.get("room_auto") == "off" else "questions"
        if "follow" in msg:
            self._follow_want = bool(msg.get("follow"))
        if route != self.route_kind:
            self.route_kind = route
            self.emitter.metric("", "route_change", route=route)
        self._follow_resync()

    def _follow_resync(self) -> None:
        """Follow mode after the language or the route changed: starts, stops or keeps it. A change that leaves it as it was
        (English to English, a lang control that repeats the route) keeps the running machine and the card it follows."""
        if self.session is None:
            return
        on = self._follow_want and self.lang in self.config.follow_langs
        if on == self.follow_on and (self.follow is not None) == on:
            return
        self._follow_start({"follow": self._follow_want})

    def _card_now(self) -> None:
        """`control card_now`: answer the latest remote/room turn now. The open partial if there is one, else the last final.
        The cue, kind and addressee gates are skipped; the card is a normal F (+ D) answer on a turn id `now-<n>`."""
        t0 = time.time()
        if self.session is None or self.halted or self.closing:
            return
        src: TurnState | None = None
        text, final = "", True
        open_st = self.ts.get(self.active_remote) if self.active_remote else None
        if open_st is not None and not open_st.finished and open_st.partial.strip():
            src, text, final = open_st, open_st.partial, False
        else:
            last = next((t for t in reversed(self.turns) if t.speaker in REMOTE_SPEAKERS and t.text.strip()), None)
            if last is not None:
                text = last.text
                src = self.ts.get(last.turn_id)
        if not text.strip():
            self._status("ready", "card now: nothing has been said by the other side yet", **self._ready_extra())
            self.emitter.metric("", "card_now_empty")
            return
        nid = f"now-{next(self._now_seq)}"
        st = self._ts(nid)
        st.finished, st.finished_at, st.final_text = True, time.monotonic(), text
        st.kind, st.addressee, st.card_now, st.card_now_t0 = "question", "me", True, t0
        st.card_now_partial = not final
        st.lang = src.lang if src is not None else None
        st.turns_before = list(self.turns)
        if src is not None:
            st.me_hits = list(src.me_hits)
        if not final and src is not None:
            # the open turn is answered now: drop its speculation; its endpoint will not answer a second time
            for c in src.s_calls:
                c.discard()
            if src.d_call:
                src.d_call.discard()
            if src.d_timer is not None and not src.d_timer.done():
                src.d_timer.cancel()
            src.answered_by, src.answered_text = nid, text
        self.latest_remote_turn = nid
        self.emitter.metric(nid, "card_now_request", partial=not final, words=len(tokens(text)), hits=len(st.me_hits),
                            source=src.turn_id if src is not None else None)
        self._lib_final(st)
        self._endpoint(st)

    def on_first_text(self, call: Call) -> None:
        if call.tier != "F" or not call.turn_id.startswith("now-"):
            return
        st = self.ts.get(call.turn_id)
        if st is not None and st.card_now_t0:
            t0, st.card_now_t0 = st.card_now_t0, 0.0
            self.emitter.metric(call.turn_id, "card_now", ms=round((time.time() - t0) * 1000, 1), id=call.id)

    # ------------------------------------------------------------------ the me library (retrieval for a remote turn)
    def _lib_partial(self, st: TurnState) -> None:
        if self.lib is None or not st.cue or len(tokens(st.partial)) < self.config.me_retrieval_min_words:
            return
        self.lib.submit(st.turn_id, st.partial)

    def _lib_final(self, st: TurnState) -> None:
        """One retrieval on the final text. F does not wait for it (it uses the hits of the partials); D waits briefly."""
        if self.lib is None or st.me_final is not None or len(tokens(st.final_text)) < self.config.me_retrieval_min_words:
            return
        if self.lib.submit(st.turn_id, st.final_text, final=True):
            st.me_final = asyncio.Event()

    def _on_lib_result(self, job, hits: list, ms: float, wait_ms: float) -> None:
        self.emitter.metric(job.turn_id, "me_retrieval", ms=round(ms, 2), wait_ms=round(wait_ms, 2), hits=len(hits),
                            top=round(hits[0].score, 4) if hits else None, ids=[h.chunk.id for h in hits],
                            final=job.final, words=len(tokens(job.text)))
        st = self.ts.get(job.turn_id)
        if st is None:
            return
        if job.final or st.me_final is None or not st.me_final.is_set():
            st.me_hits = hits
        if job.final and st.me_final is not None:
            st.me_final.set()

    async def _lib_wait_final(self, st: TurnState) -> None:
        ev = st.me_final
        if ev is None or ev.is_set() or self.lib is None:
            return
        t0 = time.monotonic()
        try:
            await asyncio.wait_for(ev.wait(), self.config.me_retrieval_final_wait_s)
        except asyncio.TimeoutError:
            pass
        self.emitter.metric(st.turn_id, "me_final_wait", ms=round((time.monotonic() - t0) * 1000, 1), got=ev.is_set())

    def _files(self, st: TurnState) -> str:
        """FROM USER'S FILES for a tail: the turn's hits, without the chunks the pack already carries as a snippet."""
        if self.lib is None or not st.me_hits:
            return ""
        cfg = self.config
        limit = cfg.me_retrieval_k if self.unprepared else cfg.me_retrieval_k_prepared
        sel = select_hits(st.me_hits, self._snippet_refs, limit, cfg.me_files_max_chars)
        return files_block([(h.chunk.id, h.chunk.source, h.chunk.text) for h in sel])

    def _room_ok(self, st: TurnState, n_words: int) -> bool:
        """Room route, before D: an automatic card needs a question cue and enough words."""
        return self.room_auto != "off" and st.cue and n_words >= self.config.room_min_words

    async def _ping_one(self, model: str, lane: int) -> None:
        r = await self.transport.ping(model, lane)
        self.limiters[model].update_from_headers(r.get("headers", {}))

    async def _ping_loop(self) -> None:
        while not self.stopped.is_set():
            await asyncio.sleep(self.config.offline_ping_every_s if self.offline else self.config.ping_every_s)
            if self.halted:
                continue
            try:
                await asyncio.gather(*(self._ping_one(m, lane) for m in (HAIKU, SONNET) for lane in (0, 1)))
            except Offline:
                if not self.offline:
                    self.offline = True
                    self._status("offline", "ping failed")
                continue
            except TransportError as e:
                log.warning("ping error: %s", e)
                continue
            if self.offline:
                self.offline = False
                self._status("ready", "back online", **self._ready_extra())
                self._retry_pending()

    async def _keepalive_loop(self) -> None:
        while not self.stopped.is_set():
            await asyncio.sleep(self.config.keepalive_check_s)
            if self.halted or self.offline or self.session is None:
                continue
            for model in (HAIKU, SONNET):
                if time.monotonic() - self.last_call_mono[model] >= self.config.keepalive_idle_s:
                    try:
                        await self._warm(model, "keepalive")
                    except TransportError as e:
                        log.warning("keep-alive %s failed: %s", model, e)

    # ------------------------------------------------------------------ call plumbing
    def _launch(self, tier: str, turn_id: str, text: str, tail: str, turns: list[Turn], *, buffered: bool,
                probe: bool = False, quiet: bool = False) -> Call | None:
        if self.halted or self.session is None:
            return None
        if self.config.budget_usd is not None and self.spend >= self.config.budget_usd:
            self._halt("error", f"budget cap ${self.config.budget_usd:.2f} reached")
            return None
        route = {"R": "S", "A": "D"}.get(tier, tier)   # summaries ride the S/F and D tuples (and their caches)
        max_tokens = {"R": self.config.summary_max_tokens, "A": self.config.final_max_tokens}.get(tier)
        req = build_request(route, route_params(route, max_tokens=max_tokens), self.session.pack, turns, tail, self.about)
        model = req["model"]
        est_in = (sum(len(b.get("text", "")) for b in req["messages"][0]["content"]) + len(self.about or "")) // 4
        if not self.limiters[model].try_acquire(est_in, req["max_tokens"]):
            self.emitter.metric(turn_id, "dropped_rate_bucket", tier=tier)
            if tier in ("D", "A"):
                self._status("rate_limited", "client-side token bucket empty", turn_id=turn_id)
            return None
        call = Call(self, tier, turn_id, text, req, buffered=buffered, route=route, probe=probe, quiet=quiet)
        self.calls.append(call)
        self.last_call_mono[model] = time.monotonic()
        call.task = self._spawn(call.run())
        return call

    def _hedge_after(self, call: Call) -> float | None:
        if call.tier in ("R", "A"):   # a duplicate summary is pure cost: no hedging
            return None
        return self.config.hedge_after_s_d if call.route == "D" else self.config.hedge_after_s

    async def hedged_stream(self, call: Call) -> None:
        """Run the call on lane 0; if no first byte after `hedge_after_s`, start a duplicate on lane 1.
        The first lane to deliver an event wins; the other is cancelled and its stream closed."""
        winner: list[int] = []
        first = asyncio.Event()
        tasks: dict[int, asyncio.Task] = {}

        async def attempt(lane: int) -> None:
            stream = await self.transport.open_stream(call.route, call.request, lane)
            try:
                async for ev in stream:
                    if not winner:
                        winner.append(lane)
                        call.winner_lane = lane
                        call.new_connection = getattr(stream, "new_connection", None)
                        self.limiters[call.model].update_from_headers(getattr(stream, "headers", {}) or {})
                        call._stage("first_byte", lane=lane, new_connection=call.new_connection)
                        first.set()
                        for other, t in tasks.items():
                            if other != lane and not t.done():
                                t.cancel()
                    elif winner[0] != lane:
                        return
                    call._on_event(ev)
            finally:
                await stream.aclose()

        loop = asyncio.get_running_loop()
        lane0 = call.lane
        hedge_after = self._hedge_after(call)
        tasks[lane0] = loop.create_task(attempt(lane0))
        try:
            waiter = loop.create_task(first.wait())
            try:
                await asyncio.wait({waiter, tasks[lane0]}, timeout=hedge_after, return_when=asyncio.FIRST_COMPLETED)
            finally:
                waiter.cancel()
            if hedge_after is not None and not first.is_set() and not tasks[lane0].done():
                call.hedged = True
                call._stage("hedge", after_s=hedge_after)
                tasks[1 - lane0] = loop.create_task(attempt(1 - lane0))
            results = await asyncio.gather(*tasks.values(), return_exceptions=True)
        finally:
            for t in tasks.values():
                if not t.done():
                    t.cancel()
        by_lane = dict(zip(tasks.keys(), results))
        if winner:
            r = by_lane[winner[0]]
            if isinstance(r, BaseException) and not isinstance(r, asyncio.CancelledError):
                raise r
            return
        errs = [r for r in results if isinstance(r, TransportError)]
        if errs:
            raise errs[0]
        others = [r for r in results if isinstance(r, BaseException) and not isinstance(r, asyncio.CancelledError)]
        if others:
            raise TransportError(type(others[0]).__name__)

    def retry_ok(self, call: Call, e: TransportError) -> bool:
        if call.discarded or self.halted or call.first_text_seen:  # never replay text already streamed
            return False
        if isinstance(e, RateLimited) and e.retry_after is not None and e.retry_after > self.config.d_retry_max_wait_s:
            return False
        if call.tier == "A":   # the final summary belongs to the whole meeting, not to one turn
            return True
        # still relevant: the turn is the newest remote turn (or still being spoken)
        return call.turn_id in (self.latest_remote_turn, self.active_remote)

    def on_call_error(self, call: Call, e: TransportError) -> None:
        log.warning("call %s (%s) failed: %s", call.id, call.tier, e)
        if isinstance(e, CreditExhausted):
            self._halt("credit_exhausted", "Max API credit used up")
        elif isinstance(e, AuthFailed):
            self._halt("error", f"API key rejected ({e})")
        elif isinstance(e, Offline):
            if not self.offline:
                self.offline = True
                self._status("offline", "network error")
            st = self.ts.get(call.turn_id)
            if st is not None and st.finished and call.tier in ("F", "D") and not call.discarded:
                self.pending_turn = call.turn_id
        elif isinstance(e, RateLimited):
            if call.tier in ("D", "A"):
                self._status("rate_limited", "429 from the API", turn_id=call.turn_id, id=call.id)
            # S/F: dropped silently (the metric records it)
        elif call.tier in ("R", "C"):
            pass   # a failed rolling pass or follow card is silent (the metric records it); the original card stays
        elif isinstance(e, BadRequest):
            self._status("error", f"request rejected: {e}", turn_id=call.turn_id, id=call.id)
        else:
            if call.tier in ("D", "A") or not call.buffered:
                self._status("error", f"{e.kind}: {e}", turn_id=call.turn_id, id=call.id)

    def on_call_done(self, call: Call) -> None:
        if call.usage:
            cost = spend_usd(call.model, usage_obj(call.usage))
            self.spend += cost
            if call.tier in ("R", "A"):
                self.summary_spend += cost
        if call.stop_reason == "refusal" and call.tier in ("S", "F", "D") and not call.buffered and not call.discarded:
            self._status("refusal", f"{call.tier} declined this turn", turn_id=call.turn_id, id=call.id)
        if call.tier == "R":
            self._rolling_done(call)
        if call.tier == "C":
            self._follow_c_done(call)
        if self.config.budget_usd is not None and self.spend >= self.config.budget_usd and not self.halted:
            self._halt("error", f"budget cap ${self.config.budget_usd:.2f} reached")
        self._maybe_roll()

    # ------------------------------------------------------------------ partials: S and early D
    def on_partial(self, msg: dict) -> None:
        if msg.get("speaker") == "room":
            msg = self._room_label(msg, final=False)
        if msg.get("speaker") == "me":
            self._follow_me(msg, final=False)
            return
        if msg.get("speaker") not in REMOTE_SPEAKERS or self.session is None:
            return
        tid = msg["turn_id"]
        if self.active_remote and self.active_remote != tid:
            old = self.ts.get(self.active_remote)
            if old is not None and not old.finished:   # abandoned turn (no endpoint arrived)
                for c in old.s_calls:
                    c.discard()
                if old.d_call:
                    old.d_call.discard()
        self.active_remote = tid
        self._last_partial_t = time.monotonic()
        st = self._ts(tid)
        if st.finished:
            return
        self._follow_remote_activity()         # a late partial of a closed turn is not "the remote speaks again"
        text = msg.get("text", "")
        now = time.monotonic()
        st.cue = bool(msg.get("cue"))
        st.room = st.room or msg.get("speaker") == "room"
        st.lang = msg_lang(msg) or st.lang
        if text != st.partial:
            st.partial = text
            st.partial_changed = now
            if st.d_timer is not None and not st.d_timer.done():
                st.d_timer.cancel()
            st.d_timer = self._spawn(self._d_stable_check(tid, now))
        self._maybe_fire_s(st, now)
        self._embed_partial(st)
        self._lib_partial(st)

    def _maybe_fire_s(self, st: TurnState, now: float) -> None:
        cfg = self.config
        words = tokens(st.partial)
        if not st.cue or len(words) < cfg.s_min_new_words:
            return
        if st.room and not self._room_ok(st, len(words)):
            return
        if st.last_fire_text is not None:
            if edit_distance(tokens(st.last_fire_text), words) < cfg.s_min_new_words:
                return
            if now - st.last_fire_t < cfg.s_min_gap_s:
                return
        if sum(1 for c in st.s_calls if not c.done.is_set()) >= cfg.s_max_inflight:
            return
        if len(st.s_calls) >= cfg.s_max_per_turn:
            return
        call = self._launch("S", st.turn_id, st.partial,
                            fast_tail(st.partial, self._lang(st), final=False, files=self._files(st)),
                            list(self.turns), buffered=True)
        if call is not None:
            st.s_calls.append(call)
            st.last_fire_text = st.partial
            st.last_fire_t = now

    def _strong_bank(self, st: TurnState) -> bool:
        # D-skip is for Swift's n-gram hits only: an embedding score is on another scale and paraphrase hits are less
        # certain, so D always runs for them.
        return (st.bank_hit is not None and st.bank_hit.via != "embed"
                and st.bank_hit.score >= self.config.bank_skip_score)

    def _shown_opener_guess(self, st: TurnState) -> str | None:
        for c in sorted(st.s_calls, key=lambda c: c.seq, reverse=True):
            if c.say_line and not c.discarded and c.stop_reason != "refusal":
                return c.say_line
        if st.bank_hit and self.session and st.bank_hit.bank_id in self.session.bank:
            return self.session.bank[st.bank_hit.bank_id].get("opener")
        return None

    def _bank_rec(self, st: TurnState) -> dict | None:
        if st.bank_hit and self.session:
            return self.session.bank.get(st.bank_hit.bank_id)
        return None

    async def _d_stable_check(self, tid: str, changed_at: float) -> None:
        await asyncio.sleep(self.config.d_stable_s)
        st = self.ts.get(tid)
        if st is None or st.finished or st.d_call is not None or st.partial_changed != changed_at:
            return
        if len(tokens(st.partial)) < self.config.d_min_words:
            return
        if not (st.cue or st.bank_hit is not None) or self._strong_bank(st):
            return
        if st.room and not self._room_ok(st, len(tokens(st.partial))):
            return
        st.d_call = self._fire_d(st, st.partial, final=False, buffered=True)

    def _fire_d(self, st: TurnState, text: str, *, final: bool, buffered: bool, opener: str | None = None) -> Call | None:
        shown = opener if opener is not None else self._shown_opener_guess(st)
        tail = deep_tail(text, self._lang(st), final, shown, self._bank_rec(st), self._files(st))
        turns = st.turns_before if st.finished else list(self.turns)
        return self._launch("D", st.turn_id, text, tail, turns, buffered=buffered)

    # ------------------------------------------------------------------ F3: paraphrase matcher (embedding)
    def _embed_partial(self, st: TurnState) -> None:
        """Queue the partial for the embedding thread when the cheap gates pass. Never blocks the loop."""
        e = self.embed
        if e is None or not self._bank_embed or self.session is None or not self.session.bank or e.state not in ("ready", "loading"):
            return                                         # no bank (an unprepared call): the matcher is idle
        if st.bank_hit is not None and st.bank_hit.via != "embed":   # Swift's n-gram already hit this turn
            return
        if not st.cue or len(tokens(st.partial)) < self.config.embed_min_words:
            st.embed_cand, st.embed_count = None, 0
            e.drop(st.turn_id)
            return
        e.submit(st.turn_id, st.partial)

    def _embed_final(self, st: TurnState) -> None:
        """One embedding match on the final text of a remote turn that closed with no bank hit (Swift's n-gram or the
        brain's own). Rescues a paraphrase whose partials never matched (no cue yet, too few words, a recognizer that
        delivered the question in one burst) and a hit the consecutive-partials gate was one evaluation short of. The result
        comes back through `_on_embed_result`, and a statement/fragment turn is then answered through `_late_hit`
        (once; an acknowledgement already on screen or an escalated probe stand, a newer turn or the window ends it)."""
        e = self.embed
        if (e is None or not self._bank_embed or self.session is None or not self.session.bank
                or not self.config.embed_final_pass or e.state not in ("ready", "loading")):
            return
        if st.embed_final_queued or st.bank_hit is not None or st.addressee == "other":
            return
        if self.halted or self.session is None or len(tokens(st.final_text)) < self.config.embed_min_words:
            return
        st.embed_final_queued = True
        self.emitter.metric(st.turn_id, "embed_final_queued", kind=st.kind, words=len(tokens(st.final_text)))
        e.submit(st.turn_id, st.final_text, final=True)

    def _on_embed_result(self, job: Job, res: Result) -> None:
        cfg = self.config
        top = res.top
        s1 = top[0][1] if top else -1.0
        s2 = top[1][1] if len(top) > 1 else -1.0
        ok = bool(top) and s1 >= cfg.embed_threshold and s1 - s2 >= cfg.embed_margin
        self.emitter.metric(job.turn_id, "embed", ms=round(res.ms, 2), wait_ms=round(res.wait_ms, 2),
                            top=top[0][0] if top else None, score=round(s1, 4), second=round(s2, 4),
                            words=len(tokens(job.text)), accepted=ok, final=job.final)
        st = self.ts.get(job.turn_id)
        if st is None:
            return
        if st.bank_hit is not None and st.bank_hit.via != "embed":   # a Swift hit landed while this ran
            return
        why = self._late_reason(st) if st.finished else "open"
        late = why is None                  # a statement/fragment just closed, nothing newer yet
        if why in ("window", "newer_turn") and not st.rescued:
            self.emitter.metric(st.turn_id, "late_hit_ignored", reason=why, kind=st.kind, via="embed")
        if job.turn_id not in (self.active_remote, self.latest_remote_turn) and not late:   # a newer turn has started
            return
        if st.finished and (st.addressee == "other" or (st.kind == "fragment" and not late)):
            return
        if not ok:
            st.embed_cand, st.embed_count = None, 0
            return
        cand = top[0][0]
        if cand == st.embed_cand:
            st.embed_count += 1
        else:
            st.embed_cand, st.embed_count = cand, 1
        # A closed turn's final text needs one evaluation: the consecutive-partials gate guards against locking on a short
        # prefix, and a final text is no prefix.
        if (job.final or st.embed_count >= cfg.embed_consecutive) and cand != st.embed_sent:
            self._embed_hit(st, cand, s1)

    def _embed_hit(self, st: TurnState, bank_id: str, score: float) -> None:
        prev = st.bank_hit
        st.bank_hit = BankHit(bank_id, score, via="embed")
        st.embed_sent = bank_id
        if prev is not None and prev.bank_id != bank_id:
            st.verdict_sent = False          # Haiku's BANK line is checked against the new id
        self.emitter.emit({"type": "bank_hit", "turn_id": st.turn_id, "bank_id": bank_id, "score": round(score, 4),
                           "via": "embed"})
        self._follow_bank(st)
        self._maybe_verdict(st)
        self._late_hit(st)

    # ------------------------------------------------------------------ bank hits and verdicts
    def on_bank_hit(self, msg: dict) -> None:
        st = self._ts(msg["turn_id"])
        prev = st.bank_hit
        try:
            st.bank_hit = BankHit(str(msg["bank_id"]), float(msg.get("score", 0.0)))
        except (KeyError, TypeError, ValueError):
            return
        if prev is not None and prev.bank_id != st.bank_hit.bank_id:
            st.verdict_sent = False          # the overlay rejects per id: the new id gets its own verdict
        if self.embed is not None:
            self.embed.drop(st.turn_id)      # Swift's hit wins; no embedding for this turn from now on
        self._follow_bank(st)
        self._maybe_verdict(st)
        self._late_hit(st)

    def _late_reason(self, st: TurnState) -> str | None:
        """None when a bank hit may still answer this finished statement/fragment turn, else why not."""
        if not st.finished or st.rescued or st.kind not in ("statement", "fragment") or st.addressee == "other":
            return "not_applicable"
        if time.monotonic() - st.finished_at > self.late_hit_window_s:
            return "window"
        if not self.turns or self.turns[-1].turn_id != st.turn_id or self.active_remote not in (None, st.turn_id):
            return "newer_turn"        # another turn (also the owner's own) has been heard or has started since
        return None

    def _late_hit(self, st: TurnState) -> None:
        """A bank hit for a turn that was already closed as statement or fragment ("So, have you built ..." has no
        question cue; the paraphrase matcher still found the prepared question). Answer it as a question, once, when
        the hit comes within `late_hit_window_s` and nothing newer has been heard. A statement probe that is still
        undecided is dropped (nothing of it was shown); one that escalated is already answering; one whose
        acknowledgement is on screen stays (a second card would be a double answer)."""
        if not st.finished or st.rescued or st.kind not in ("statement", "fragment") or st.addressee == "other":
            return
        why = self._late_reason(st)
        probe = st.fast if st.fast is not None and st.fast.probe and not st.fast.discarded and st.fast.error is None else None
        if why is None and probe is not None:
            if probe.kind == "question":
                why = "already_answering"
            elif probe.say_line is not None:
                why = "ack_shown"
        if why is None and (self.halted or self.session is None):
            why = "halted"
        if why is not None:
            self.emitter.metric(st.turn_id, "late_hit_ignored", reason=why, kind=st.kind)
            return
        if probe is not None:
            probe.discard()
        was = st.kind
        st.rescued = True
        st.kind = "question"
        st.fast = None
        st.verdict_sent = False
        self.latest_remote_turn = st.turn_id
        self.emitter.metric(st.turn_id, "late_hit_rescue", was=was, bank_id=st.bank_hit.bank_id if st.bank_hit else None,
                            since_turn_s=round(time.monotonic() - st.finished_at, 3))
        self._endpoint(st)

    def on_bank_line(self, call: Call) -> None:
        st = self.ts.get(call.turn_id)
        if st is not None and st.fast is call:
            self._maybe_verdict(st)

    def _maybe_verdict(self, st: TurnState) -> None:
        c = st.fast
        if st.verdict_sent or c is None or c.bank_id is None or st.bank_hit is None or c.buffered or c.discarded:
            return
        st.verdict_sent = True
        agree = c.bank_id == st.bank_hit.bank_id
        self.emitter.emit({"type": "bank_verdict", "turn_id": st.turn_id, "bank_id": st.bank_hit.bank_id,
                           "agree": agree})
        if not agree and st.bank_hit.via == "embed":
            # Haiku retracts a paraphrase hit: the overlay drops its opener, and D is not handed that entry either
            st.bank_hit = None

    # ------------------------------------------------------------------ endpoint: select S or fire F; decide D
    def on_turn(self, msg: dict) -> None:
        ta = msg.get("t_audio_end")
        if isinstance(ta, (int, float)) and not isinstance(ta, bool):
            self._last_audio_end = float(ta)
            if self._roll_t0 is None:
                self._roll_t0 = float(ta)
        self._on_turn(msg)
        self._maybe_roll()     # after the tiers have been launched: a summary only ever runs in a quiet moment

    def _on_turn(self, msg: dict) -> None:
        tid = msg["turn_id"]
        speaker = msg.get("speaker", "remote")
        text = msg.get("text", "")
        self.emitter.metric(tid, "turn_recv", speaker=speaker, t_audio_end=msg.get("t_audio_end"))
        if speaker == "room":
            msg = self._room_label(msg, final=True)
            speaker = msg.get("speaker", "room")
        if speaker not in REMOTE_SPEAKERS:
            self.turns.append(Turn(tid, speaker, text))
            self._follow_me(msg, final=True)
            return
        st = self._ts(tid)
        if st.finished:
            return
        self._follow_remote_activity()
        st.finished = True
        st.finished_at = time.monotonic()
        st.final_text = text
        st.room = st.room or speaker == "room"
        st.lang = msg_lang(msg) or st.lang
        st.addressee = "unknown" if st.room else msg.get("addressee", "unknown")
        st.kind = turn_kind(msg)
        if st.kind == "fragment" and st.bank_hit is not None:
            st.kind = "question"           # it matched a prepared question: answer it, don't drop it as a fragment
        st.turns_before = list(self.turns)
        self.turns.append(Turn(tid, speaker, text))
        if st.kind != "fragment":      # a stray fragment must not make the pending question's retry look stale
            self.latest_remote_turn = tid
        if self.active_remote == tid:
            self.active_remote = None
        if st.d_timer is not None and not st.d_timer.done():
            st.d_timer.cancel()
        if st.addressee == "other":
            for c in st.s_calls:
                c.discard()
            if st.d_call:
                st.d_call.discard()
            self.emitter.metric(tid, "for_others")
            return
        if st.answered_by is not None and edit_distance(tokens(st.answered_text), tokens(text)) <= self.config.card_now_match_edit:
            # card-now answered this turn while it was still open and nothing new was said since: no second card
            self.latest_remote_turn = st.answered_by
            self.emitter.metric(tid, "card_now_covers_turn", by=st.answered_by)
            return
        if st.room:
            # room route (before diarization): one mic, no addressee; only a question with a cue gets a card by itself
            cue = (st.kind == "question") if st.kind is not None else bool(msg.get("cue", st.cue))
            st.cue = cue
            n_words = len(tokens(text))
            asked = cue and n_words >= self.config.room_min_words
            # An indirect ask has no cue ("one of the big decisions is which school ..."): a statement of enough words gets the
            # statement probe, which shows a card only when it says KIND: question (no acknowledgements in the room).
            probe = (not asked and st.kind == "statement" and n_words >= self.config.room_probe_min_words)
            if self.room_auto == "off" or not (asked or probe):
                for c in st.s_calls:
                    c.discard()
                if st.d_call:
                    st.d_call.discard()
                self.emitter.metric(tid, "room_skipped", cue=cue, words=n_words, room_auto=self.room_auto)
                return
            st.kind = "question" if asked else "statement"
        self._embed_final(st)
        self._lib_final(st)
        if st.kind == "fragment":
            # a cut-off clause: nothing is fired or shown; speculation that started on its partials is closed
            for c in st.s_calls:
                c.discard()
            if st.d_call:
                st.d_call.discard()
            self.emitter.metric(tid, "fragment_skipped")
            return
        if self.halted or self.session is None:
            return
        self._endpoint(st)

    def _endpoint(self, st: TurnState) -> None:
        # A turn that matched a prepared bank question is answered as a question even when Swift's cue check called it
        # a statement ("So, have you built ..." starts with a discourse word and has no question cue).
        if st.kind == "statement" and st.bank_hit is None:
            return self._endpoint_statement(st)
        self._follow_question(st)
        cfg = self.config
        final = tokens(st.final_text)
        best: tuple[int, int] | None = None   # (distance, -seq): closest input wins, the newest on a tie
        chosen: Call | None = None
        for c in st.s_calls:
            if c.discarded or c.error is not None:
                continue
            key = (edit_distance(c.input_tokens, final), -c.seq)
            if key[0] <= cfg.match_max_edit and (best is None or key < best):
                best, chosen = key, c
        for c in st.s_calls:
            if c is not chosen:
                c.discard()
        if chosen is not None and chosen.done.is_set() and chosen.stop_reason == "refusal":
            chosen.discard()
            self._status("refusal", "S declined this turn", turn_id=st.turn_id, id=chosen.id)
            self.emitter.metric(st.turn_id, "s_refused", id=chosen.id)
            st.fast = None
        elif chosen is not None:
            self.emitter.emit({"type": "select", "turn_id": st.turn_id, "id": chosen.id})
            self.emitter.metric(st.turn_id, "select", id=chosen.id, tier="S", distance=best[0])
            st.fast = chosen
            chosen.release()
            self._maybe_verdict(st)
        else:
            tail = (card_now_tail(st.final_text, self._lang(st), not st.card_now_partial, self._files(st)) if st.card_now
                    else fast_tail(st.final_text, self._lang(st), final=True, files=self._files(st)))
            st.fast = self._launch("F", st.turn_id, st.final_text, tail, st.turns_before, buffered=False)
        self._deciding += 1
        self._spawn(self._decide_d_tracked(st))

    def _endpoint_statement(self, st: TurnState) -> None:
        """A statement (addressee me|unknown): speculation is dropped (it answered a question nobody asked) and no D
        is decided up front. One F probe either acknowledges in one short line, stays silent, or says `KIND: question`
        (an implicit request), in which case the normal answer lines stream and D follows."""
        for c in st.s_calls:
            c.discard()
        if st.d_call is not None:
            st.d_call.discard()
            st.d_call = None
        if self.unprepared and len(tokens(st.final_text)) < self.config.unprepared_statement_min_words:
            self.emitter.metric(st.turn_id, "statement_skipped", words=len(tokens(st.final_text)))
            return
        st.fast = self._launch("F", st.turn_id, st.final_text,
                               statement_tail(st.final_text, self._lang(st), self._files(st), room=st.room),
                               st.turns_before, buffered=False, probe=True, quiet=st.room)
        self.emitter.metric(st.turn_id, "statement_probe", launched=st.fast is not None)
        if st.fast is None:
            return
        self._deciding += 1
        self._spawn(self._decide_statement_tracked(st, st.fast))

    async def _decide_statement_tracked(self, st: TurnState, probe: Call) -> None:
        try:
            await probe.kind_known.wait()
            if probe.discarded or probe.error is not None:
                return
            if probe.kind == "question":
                self.emitter.metric(st.turn_id, "statement_escalated", id=probe.id)
                await self._decide_d(st)
                return
            await probe.done.wait()
            if not probe.discarded and probe.error is None and probe.say_line is None:
                self.emitter.metric(st.turn_id, "statement_no_reply", id=probe.id)
        finally:
            self._deciding -= 1
            self._maybe_roll()

    async def _decide_d_tracked(self, st: TurnState) -> None:
        try:
            await self._decide_d(st)
        finally:
            self._deciding -= 1
            self._maybe_roll()

    async def _decide_d(self, st: TurnState) -> None:
        cfg = self.config
        d = st.d_call
        if d is not None and (d.discarded or d.error is not None
                              or edit_distance(d.input_tokens, tokens(st.final_text)) > cfg.match_max_edit):
            d.discard()
            self.emitter.metric(st.turn_id, "d_early_dropped", id=d.id)
            d = st.d_call = None
        if self._strong_bank(st) and st.fast is not None:
            fast = st.fast
            try:
                await asyncio.wait_for(fast.bank_known.wait(), timeout=cfg.bank_verdict_wait_s)
            except asyncio.TimeoutError:
                pass
            if fast.bank_id is not None and st.bank_hit and fast.bank_id == st.bank_hit.bank_id:
                if d is not None:
                    d.discard()
                    st.d_call = None
                self.emitter.metric(st.turn_id, "d_skipped", bank_id=st.bank_hit.bank_id)
                return
        if d is not None:
            self.emitter.metric(st.turn_id, "d_confirmed", id=d.id)
            d.release()
            return
        opener = st.fast.say_line if st.fast is not None else None
        if opener is None and st.fast is not None and st.fast.tier == "S":
            opener = self._shown_opener_guess(st)
        await self._lib_wait_final(st)      # <= me_retrieval_final_wait_s; F never waits
        st.d_call = self._fire_d(st, st.final_text, final=not st.card_now_partial, buffered=False, opener=opener)

    # ------------------------------------------------------------------ follow my answer (tier C)
    @_follow_safe
    def _follow_start(self, msg: dict) -> None:
        cfg = self.config
        want = bool(msg.get("follow", cfg.follow_default))
        self.follow_on = want and self.lang in cfg.follow_langs   # the room route has no `me` channel: its text told as his feeds follow mode (own.py)
        self.emitter.metric("", "follow_state", on=self.follow_on, requested=want, lang=self.lang)
        if not self.follow_on or self.session is None:
            self.follow = None
            return
        self.follow = FollowMachine(cfg.follow, time.monotonic, embed_ok=False)
        self._follow_pack = follow_pack_lines(self.session)
        self._follow_embed_failed = False
        if self.embed is not None and self.lang in cfg.embed_langs:
            self._spawn(self._follow_warm())
        if self._follow_task is None:
            self._follow_task = asyncio.get_running_loop().create_task(self._follow_loop())

    async def _follow_warm(self) -> None:
        """Embed the pack lines once, on the embedding thread, after the bank index (the margin needs them)."""
        pack, cache = list(self._follow_pack), self._follow_cache

        def work(e: Embedder) -> int:
            for t in pack:
                if t not in cache:
                    from .follow import unit   # noqa: PLC0415
                    cache[t] = unit(e.embed(PREFIX + t))
            return len(pack)

        try:
            t0 = time.perf_counter()
            n = await self.embed.run_job(work)       # type: ignore[union-attr]
            self.emitter.metric("", "follow_warm", lines=n, ms=round((time.perf_counter() - t0) * 1000, 1))
        except Exception as e:  # noqa: BLE001 - without it the margin is simply absent
            self.emitter.metric("", "follow_warm_failed", reason=f"{type(e).__name__}: {e}"[:160])

    def _follow_sync(self) -> bool:
        f = self.follow
        if f is None:
            return False
        ok = self.embed is not None and self.embed.ready and not self._follow_embed_failed
        f.embed_ok = ok
        if ok != self._follow_embed_ok:      # without the embedder the card never flips: say so once per change
            self._follow_embed_ok = ok
            self.emitter.metric("", "follow_embed_state", ok=ok, divergence=("on" if ok else "off (coverage only)"),
                                state=self.embed.state if self.embed is not None else "absent")
        return True

    async def _follow_loop(self) -> None:
        while not self.stopped.is_set():
            await asyncio.sleep(self.config.follow_tick_s)
            f = self.follow
            if f is None or f.turn_id is None or f.ended or self.halted:
                continue
            self._follow_tick(f)

    @_follow_safe
    @_follow_safe
    def _follow_tick(self, f: FollowMachine) -> None:
        self._follow_sync()
        f.tick()
        self._follow_apply()

    @_follow_safe
    def _follow_embed_result(self, req: NeedEmbed, scores: dict, others: dict | None) -> None:
        self._follow_sync()
        self.follow.on_embed(req.seq, scores, others)       # type: ignore[union-attr]
        self._follow_apply()

    @_follow_safe
    def _follow_me(self, msg: dict, final: bool) -> None:
        if self.session is None or self.halted or self.closing or not self._follow_sync():
            return
        tid = msg.get("turn_id")
        if not isinstance(tid, str) or not tid:
            return
        self.follow.on_me(tid, str(msg.get("text", "")), final)     # type: ignore[union-attr]
        self._follow_apply()

    def _follow_remote_activity(self) -> None:
        if self.follow is not None:
            self.follow.on_remote_activity()

    @_follow_safe
    def _follow_question(self, st: TurnState) -> None:
        """A question is being answered: follow mode of the previous turn is over, this card is the reference."""
        f = self.follow
        if f is None or self.session is None:
            return
        self._follow_sync()
        if f.turn_id == st.turn_id:
            f.reset_cards()               # the same question answered again (offline retry, late bank hit)
        else:
            if f.turn_id is not None and not f.ended and any(f.stats.values()):
                self.emitter.metric(f.turn_id, "follow_end", reason="new_question", **dict(f.stats))
            f.new_turn(st.turn_id, since=st.partial_changed or st.finished_at)
            for c in self._follow_calls:
                if c.turn_id != st.turn_id and not c.done.is_set():
                    c.discard()           # a follow card of the old answer must not land on the new question
            self._follow_calls = [c for c in self._follow_calls if c.turn_id == st.turn_id]
        self._follow_banks.clear()
        self._follow_bank(st)
        self._follow_apply()

    @_follow_safe
    def _follow_bank(self, st: TurnState) -> None:
        f = self.follow
        if f is None or f.turn_id != st.turn_id or st.bank_hit is None or self.session is None:
            return
        bid = st.bank_hit.bank_id
        rec = self.session.bank.get(bid)
        if rec is None or bid in self._follow_banks:
            return
        self._follow_banks.add(bid)
        orig = f"orig-{st.turn_id}"          # the overlay shows the bank card as the original card until the fast tier answers
        if rec.get("opener"):
            f.add_line(f"bank:{bid}", "bank", "say", str(rec["opener"]), source="bank", report_as=orig)
        for pt in rec.get("points", []):
            f.add_line(f"bank:{bid}", "bank", "point", str(pt), source="bank", report_as=orig)

    @_follow_safe
    def on_probe_escalated(self, call: Call) -> None:
        st = self.ts.get(call.turn_id)
        if st is not None and self.follow is not None:
            self._follow_question(st)

    def on_card_line(self, call: Call, kind: str, text: str) -> None:
        """A complete line of a card the overlay shows (S/F/D/C). Lines of a buffered S call arrive in `on_card_released`."""
        if call.discarded or call.buffered or (call.probe and call.kind != "question"):
            return
        self._own_card_line(call, kind, text)
        if self.follow is None:
            return
        self._follow_feed(call, kind, text)

    @_follow_safe
    def on_card_released(self, call: Call) -> None:
        if call.discarded or (call.probe and call.kind != "question"):
            return
        if call.say_line:
            self._own_card_line(call, "say", call.say_line)
        for pt in call.points:
            self._own_card_line(call, "point", pt)
        if self.follow is None:
            return
        if call.say_line:
            self._follow_feed(call, "say", call.say_line)
        for pt in call.points:
            self._follow_feed(call, "point", pt)

    # ------------------------------------------------------------------ room route: the owner's own voice, told by text
    def _own_card_line(self, call: Call, kind: str, text: str) -> None:
        """Remember the lines of the card on screen: what he would read aloud. S/F (and D's points after them) make one card
        in reading order, a follow card (C) is its own."""
        if call.tier in ("S", "F", "D"):
            self._own.add(call.turn_id, "orig", kind, text, new_say=(kind == "say" and call.tier in ("S", "F")))
        elif call.tier == "C":
            self._own.add(call.turn_id, call.id, kind, text)

    def _room_label(self, msg: dict, final: bool) -> dict:
        """A `room` partial or turn while a card is on screen: when its content words line up with the card in order (runtime/own.py)
        it is Alex reading the card, so it is relabelled `me`. It then goes down the `me` path (follow mode's coverage, the
        transcript as `[Alex]`) and never fires a card; whatever the room route had started for it is dropped. Anything else
        stays `room`. A turn keeps its label unless its text stops lining up (`own.stay`)."""
        tid = msg.get("turn_id")
        if not isinstance(tid, str) or not tid or not self._own.has_card():
            return msg
        was = self._own_turns.get(tid, False)
        own, sc = self._own.is_own(str(msg.get("text", "")), already=was)
        self._own_turns[tid] = own
        if own != was or (final and (own or sc.matched >= self.config.own.min_matched)):
            self.emitter.metric(tid, "room_own", own=own, share=round(sc.share, 3), matched=sc.matched, content=sc.content,
                                final=final, card=sc.card)
        if not own:
            return msg
        st = self.ts.get(tid)
        if st is not None:
            for c in st.s_calls:
                c.discard()
            if st.d_call:
                st.d_call.discard()
            if st.d_timer is not None and not st.d_timer.done():
                st.d_timer.cancel()
            if final:
                st.finished = True
        if self.active_remote == tid:
            self.active_remote = None
        return {**msg, "speaker": "me"}

    @_follow_safe
    def _follow_feed(self, call: Call, kind: str, text: str) -> None:
        f = self.follow
        if f is None or f.turn_id != call.turn_id:
            return
        if call.tier in ("S", "F"):
            f.add_line(f"orig-{call.turn_id}", call.tier, kind, text)
        elif call.tier == "C":
            f.add_line(call.id, "C", kind, text)
            if kind == "say" and "follow_card" not in call.t:
                now = time.time()
                call.t["follow_card"] = now
                self.emitter.metric(call.turn_id, "follow_card", now, id=call.id, reason=call.follow_reason,
                                    first_sentence_ms=round((now - call.t.get("fire", now)) * 1000, 1),
                                    since_decision_ms=round((now - call.follow_t0) * 1000, 1))
        elif call.tier == "D":
            f.add_line(f"d:{call.id}", "D", kind if kind == "point" else "say", text, source="ref")
        else:
            return
        self._follow_sync()
        self._follow_apply()

    @_follow_safe
    def _follow_apply(self) -> None:
        f = self.follow
        if f is None:
            return
        for fx in f.drain():
            if isinstance(fx, Covered):
                self.follow_counts["covered"] += 1
                self.emitter.emit({"type": "covered", "turn_id": f.turn_id, "card_id": fx.card_id, "point": fx.point})
                self.emitter.metric(f.turn_id or "", "follow_covered", card_id=fx.card_id, point=fx.point, via=fx.via,
                                    score=fx.score)
            elif isinstance(fx, Diverged):
                self.follow_counts["diverged"] += 1
                self.emitter.metric(f.turn_id or "", "follow_diverged", reason=fx.reason, lexical=fx.lex_score,
                                    unmatched=fx.words, embed=fx.embed, margin=fx.margin, run_words=fx.run_words,
                                    ms=fx.ms, ms_since_start=fx.start_ms)
                self._follow_launch("diverged")
            elif isinstance(fx, Refresh):
                self.follow_counts["refresh"] += 1
                self.emitter.metric(f.turn_id or "", "follow_refresh", new_words=fx.new_words)
                self._follow_launch("refresh")
            elif isinstance(fx, NeedEmbed):
                self._follow_embed(fx)
            elif isinstance(fx, Ended):
                self.emitter.metric(f.turn_id or "", "follow_end", reason=fx.reason, **{k: v for k, v in f.stats.items()})

    @_follow_safe
    def _follow_launch(self, reason: str) -> None:
        f = self.follow
        st = self.ts.get(f.turn_id or "") if f is not None else None
        if f is None or st is None or self.halted or self.closing or self.session is None:
            if f is not None:
                f.c_failed()
            return
        orig = f.card_lines(f.original_id)
        card = [("SAY: " if ln.kind == "say" else "- ") + ln.text for ln in orig]
        cur = f.card_lines(f.visible_id) if f.visible_id != f.original_id else []
        said = [ln.text for cid in f.order for ln in f.cards[cid].lines if ln.covered and ln.visible]
        now_card = [("SAY: " if ln.kind == "say" else "- ") + ln.text for ln in cur] if reason == "refresh" and cur else None
        words = f.his_text().split()
        his = ("... " if len(words) > 160 else "") + " ".join(words[-160:])
        tail = follow_tail(st.final_text, self.lang, his, card, said, now_card, reason, me_on=self.about is not None)
        call = self._launch("C", st.turn_id, his, tail, st.turns_before, buffered=False)
        if call is None:
            f.c_failed()
            self.emitter.metric(st.turn_id, "follow_dropped", reason=reason)
            return
        call.follow_reason = reason
        call.follow_t0 = time.time()
        self._follow_calls.append(call)
        self.follow_counts["c_calls"] += 1
        f.c_started(call.id)

    @_follow_safe
    def _follow_c_done(self, call: Call) -> None:
        f = self.follow
        if f is None or f.turn_id != call.turn_id:
            return
        f.c_done()
        if not call.discarded and call.error is None and call.say_line is None and not call.points:
            self.follow_counts["c_empty"] += 1
            self.emitter.metric(call.turn_id, "follow_empty", id=call.id, reason=call.follow_reason,
                                stop=call.stop_reason)

    def _follow_embed(self, req: NeedEmbed) -> None:
        self._follow_req = req            # a request that has not started yet is replaced: only the newest runs
        if not self._follow_busy:
            self._follow_busy = True
            self._spawn(self._follow_embed_loop())

    async def _follow_embed_loop(self) -> None:
        try:
            while self._follow_req is not None and self.follow is not None and self.embed is not None:
                req, self._follow_req = self._follow_req, None
                pack, cache = self._follow_pack, self._follow_cache
                t0 = time.perf_counter()
                try:
                    scores, others = await self.embed.run_job(
                        lambda e, req=req: score_matrix(e.embed, req, cache, PREFIX, pack))     # type: ignore[arg-type]
                except Exception as e:  # noqa: BLE001 - the detector falls back to the lexical rule
                    self._follow_embed_failed = True
                    self.emitter.metric("", "follow_embed_failed", reason=f"{type(e).__name__}: {e}"[:160])
                    self._follow_sync()
                    return
                self.emitter.metric(self.follow.turn_id or "", "follow_embed", ms=round((time.perf_counter() - t0) * 1000, 2),
                                    seq=req.seq)
                self._follow_embed_result(req, scores, others if pack else None)
        finally:
            self._follow_busy = False

    # ------------------------------------------------------------------ offline recovery
    def _retry_pending(self) -> None:
        tid, self.pending_turn = self.pending_turn, None
        if not tid or tid != self.latest_remote_turn:
            return
        st = self.ts.get(tid)
        if st is None or st.retried_offline:
            return
        st.retried_offline = True
        st.s_calls = []
        st.d_call = None
        st.fast = None
        st.verdict_sent = False
        self.emitter.metric(tid, "offline_retry")
        self._endpoint(st)

    # ------------------------------------------------------------------ F2: rolling summary (tier R)
    def _roll_due(self) -> bool:
        cfg = self.config
        new = len(self.turns) - self._rolled_n
        if new <= 0:
            return False
        if new >= cfg.summary_every_turns:
            return True
        return (self._roll_t0 is not None and self._last_audio_end is not None
                and self._last_audio_end - self._roll_t0 >= cfg.summary_every_s)

    def _turn_in_flight(self) -> bool:
        """A question is being spoken or answered: S/F/D own the connection, the rate bucket and the moment."""
        if self._deciding > 0:
            return True
        if self.active_remote is not None and time.monotonic() - self._last_partial_t < self.config.summary_partial_stale_s:
            return True
        return any(c.tier in ("S", "F", "D", "C") and not c.done.is_set() for c in self.calls)

    def _defer(self, reason: str) -> None:
        if reason != self._defer_reason:    # one metric per reason, not one per event
            self._defer_reason = reason
            self.emitter.metric("", "summary_deferred", reason=reason)

    def _maybe_roll(self) -> None:
        cfg = self.config
        if self.session is None or self.closing or self.halted or self.offline or self.stopped.is_set():
            return
        if not self._roll_due():
            self._defer_reason = None
            return
        if self._roll_call is not None and not self._roll_call.done.is_set():
            return
        if self._final_task is not None and not self._final_task.done():
            return
        if self._turn_in_flight():
            return self._defer("turn_in_flight")
        if self.limiters[HAIKU].fraction_left() < cfg.summary_bucket_min:
            return self._defer("bucket_low")
        if cfg.budget_usd is not None and self.spend >= cfg.budget_usd * cfg.summary_budget_frac:
            return self._defer("budget")
        self._defer_reason = None
        n = len(self.turns)
        call = self._launch("R", "", "", rolling_tail(self.lang, self.running.as_lines()), list(self.turns),
                            buffered=False)
        if call is not None:
            # this window is used up even if the pass fails: a failing call is not retried in a loop
            self._rolled_n, self._roll_t0, self._roll_call = n, self._last_audio_end, call

    @staticmethod
    def _summary_lines(call: Call) -> list[str]:
        lines = list(call.summary_lines)
        if call.stop_reason == "max_tokens" and lines:
            lines.pop()          # the last line was cut off mid-sentence
        return lines

    def _rolling_done(self, call: Call) -> None:
        if call.discarded or call.error is not None or call.stop_reason == "refusal":
            return
        if self.running.merge_lines(parse_lines(self._summary_lines(call))):
            self.emitter.emit({"type": "actions", "items": list(self.running.actions)})
            self.emitter.emit({"type": "summary", **self.running.lists()})

    # ------------------------------------------------------------------ F2: final summary (tier A) / stop
    def _write_summary(self, r: Running, *, note: str | None, n: int) -> Path | None:
        assert self.session is not None
        md = render_markdown(r, text=r.text, meta={"session": self.session.meta.get("session_id"), "turns": n,
                                                   "model": SONNET if note is None else HAIKU,
                                                   "follow": dict(self.follow_counts) if self.follow_on else None},
                             note=note)
        path = self.session.path / "summary.md"
        tmp = path.with_name(".summary.md.tmp")
        try:
            tmp.write_text(md, encoding="utf-8")
            os.replace(tmp, path)
        except OSError as e:
            self._status("error", f"cannot write summary.md: {type(e).__name__}")
            return None
        return path

    async def summarize(self, timeout: float | None = None) -> None:
        """Final merge (one Sonnet call on the D prefix) into summary.md. Idempotent for an unchanged transcript."""
        if self.session is None or not self.turns:
            return
        task = self._final_task
        if task is None or task.done():
            if self._final_n == len(self.turns) and self._final_events:
                for ev in self._final_events:
                    self.emitter.emit(ev)
                return
            task = self._final_task = self._spawn(self._run_final(len(self.turns)))
        try:
            await asyncio.wait_for(asyncio.shield(task), timeout)
        except asyncio.TimeoutError:
            log.warning("final summary still running after %.0f s; closing with the draft on disk", timeout or 0)

    async def _run_final(self, n: int) -> None:
        draft = self.running.copy()
        self._write_summary(draft, note="final merge pending", n=n)    # on disk even if the merge never finishes
        reason: str | None = None
        final = draft
        call = self._launch("A", "", "", final_tail(self.lang, draft.as_lines()), list(self.turns), buffered=False)
        if call is None:
            reason = "not started (halted, budget or rate limit)"
        else:
            await call.done.wait()
            if call.discarded:
                reason = "cancelled"
            elif call.error is not None:
                reason = call.error.kind
            elif call.stop_reason == "refusal":
                reason = "refusal"
            else:
                got = Running()
                got.merge_lines(parse_lines(self._summary_lines(call)))
                if got.is_empty():
                    reason = "empty answer"
                else:
                    if call.stop_reason == "max_tokens":   # truncated: keep what the rolling pass had as well
                        for kind, items in (("DECISION", draft.decisions), ("ACTION", draft.actions), ("OPEN", draft.open)):
                            for x in items:
                                got.add(kind, x)
                    final = got
        note = None if reason is None else f"final merge unavailable ({reason}); rolling notes only"
        path = self._write_summary(final, note=note, n=n)
        if reason is None:
            self.running = final.copy()
        ev = {"type": "summary", **final.lists(), "final": reason is None, "conflicts": list(final.conflicts),
              "text": final.text, "path": str(path) if path else None}
        if reason is not None:
            ev["draft_reason"] = reason
        events = [{"type": "actions", "items": list(final.actions)}, ev]
        for e in events:
            self.emitter.emit(e)
        self.emitter.metric("", "summary_final", ok=reason is None, reason=reason, turns=n,
                            cost_usd=round(spend_usd(SONNET, usage_obj(call.usage)), 6) if call and call.usage else 0.0)
        if reason is None:
            self._final_n, self._final_events = n, events

    async def stop(self) -> None:
        """`control stop`: drop whatever S/F/D/R is in flight (as before), run the final merge, then shut down."""
        if self.stopped.is_set():
            return
        self.closing = True
        for c in self.calls:
            if not c.done.is_set() and c.tier != "A":
                c.discard()
        try:
            await self.summarize(timeout=self.config.final_timeout_s)
        except Exception:  # noqa: BLE001 - a summary problem must never keep the process from exiting
            log.exception("final summary failed")
        await self.shutdown()

    async def shutdown(self) -> None:
        if self.stopped.is_set():
            return
        self.stopped.set()
        if self._follow_task is not None:
            self._follow_task.cancel()
        if self.embed is not None:
            self.embed.close()
        for c in self.calls:
            if not c.done.is_set():
                c.discard()
        for t in list(self.tasks):
            if not t.done():
                t.cancel()
        await asyncio.gather(*list(self.tasks), return_exceptions=True)
        await self.transport.aclose()
