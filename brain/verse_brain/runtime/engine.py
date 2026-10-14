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
from .embed import Embedder, EmbedPath, Job, Result
from .lines import LineAssembler
from .prompt import (STATEMENT_SAY_WORDS, WARMUP_TAIL, Turn, build_request, deep_tail, fast_tail, final_tail,
                     rolling_tail, statement_tail)
from .protocol import Emitter, Session, load_session, turn_kind
from .ratelimit import ModelLimiter
from .settings import HAIKU, MODEL_ROUTE, SONNET, Config, route_params
from .summary import Running, parse_lines, render_markdown
from .transport import (AuthFailed, BadRequest, CreditExhausted, Offline, Overloaded, RateLimited, Transport,
                        TransportError)

log = logging.getLogger("verse.runtime")

_WORD = re.compile(r"[\w']+", re.UNICODE)


def tokens(text: str) -> list[str]:
    return _WORD.findall(text.lower())


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
                 buffered: bool, route: str, probe: bool = False) -> None:
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
        self.kind: str | None = None          # None until the KIND line (or, without one, the first text line)
        self.kind_known = asyncio.Event()
        self.points: list[str] = []
        self.stop_reason: str | None = None
        self.usage: dict = {}
        self.error: TransportError | None = None
        self.hedged = False
        self.winner_lane: int | None = None
        self.new_connection: bool | None = None
        self.retries_left = 1 if tier in ("D", "A") else 0  # S/F/R: max_retries 0; D, A: one retry
        self.lane = 1 if tier in ("R", "A") else 0   # summaries keep off the S/F/D connection (lane 0)
        self.summary_lines: list[str] = []
        self.t: dict[str, float] = {}
        self.done = asyncio.Event()
        self.bank_known = asyncio.Event()
        self.first_text_seen = False
        self.lines = LineAssembler(self._on_text, self._on_control, hold_first_line=(tier == "D" or probe))
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

    def discard(self) -> None:
        if self.discarded:
            return
        self.discarded = True
        self.buffer.clear()
        if self.task is not None and not self.task.done():
            self.task.cancel()

    # ---- line handling
    def _on_text(self, chunk: str, line_done: bool, line: str) -> None:
        if self.tier in ("R", "A"):  # summary output becomes `summary`/`actions` events, never deltas
            if line_done:
                self.summary_lines.append(line.strip())
            return
        if self.probe and self.kind != "question":
            self._on_statement_text(line_done, line)
            return
        self._out(self.brain.emitter.delta(self.id, self.turn_id, self.tier, chunk, line_done))
        if line_done:
            s = line.strip()
            if s.startswith("SAY:") and self.say_line is None:
                self.say_line = s[4:].strip()
                self._stage("say_line")
            elif s.startswith("- "):
                self.points.append(s[2:].strip())
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
        if self.say_line is not None or not s.startswith("SAY:"):
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

    def _on_control(self, line: str) -> None:
        if line.startswith("KIND:"):
            if self.probe and self.kind is None:
                self.kind = "question" if line[5:].strip().lower().startswith("question") else "statement"
                self.kind_known.set()
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
    # F3 paraphrase matcher: the candidate entry of the last evaluated partials, how many in a row, the id sent
    embed_cand: str | None = None
    embed_count: int = 0
    embed_sent: str | None = None


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

    # ------------------------------------------------------------------ start / warm transport
    def _prefix_request(self, route: str, max_tokens: int | None, tail: str, turns: list[Turn] | None = None) -> dict:
        assert self.session is not None
        return build_request(route, route_params(route, max_tokens=max_tokens), self.session.pack,
                             list(self.turns if turns is None else turns), tail)

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
        if self.embed is not None and self.lang in self.config.embed_langs:
            self.embed.start(self.session.bank, self.lang)   # on the embedding thread, while the pre-warm runs
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
            self._status("ready", f"warm; spend so far ${self.spend:.4f}")
        if self.start_background:
            self.bg.append(self._spawn(self._ping_loop()))
            self.bg.append(self._spawn(self._keepalive_loop()))

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
                self._status("ready", "back online")
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
                probe: bool = False) -> Call | None:
        if self.halted or self.session is None:
            return None
        if self.config.budget_usd is not None and self.spend >= self.config.budget_usd:
            self._halt("error", f"budget cap ${self.config.budget_usd:.2f} reached")
            return None
        route = {"R": "S", "A": "D"}.get(tier, tier)   # summaries ride the S/F and D tuples (and their caches)
        max_tokens = {"R": self.config.summary_max_tokens, "A": self.config.final_max_tokens}.get(tier)
        req = build_request(route, route_params(route, max_tokens=max_tokens), self.session.pack, turns, tail)
        model = req["model"]
        est_in = sum(len(b.get("text", "")) for b in req["messages"][0]["content"]) // 4
        if not self.limiters[model].try_acquire(est_in, req["max_tokens"]):
            self.emitter.metric(turn_id, "dropped_rate_bucket", tier=tier)
            if tier in ("D", "A"):
                self._status("rate_limited", "client-side token bucket empty", turn_id=turn_id)
            return None
        call = Call(self, tier, turn_id, text, req, buffered=buffered, route=route, probe=probe)
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
        elif call.tier == "R":
            pass   # a failed rolling pass is silent (the metric records it); the next window retries
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
        if self.config.budget_usd is not None and self.spend >= self.config.budget_usd and not self.halted:
            self._halt("error", f"budget cap ${self.config.budget_usd:.2f} reached")
        self._maybe_roll()

    # ------------------------------------------------------------------ partials: S and early D
    def on_partial(self, msg: dict) -> None:
        if msg.get("speaker") != "remote" or self.session is None:
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
        text = msg.get("text", "")
        now = time.monotonic()
        st.cue = bool(msg.get("cue"))
        if text != st.partial:
            st.partial = text
            st.partial_changed = now
            if st.d_timer is not None and not st.d_timer.done():
                st.d_timer.cancel()
            st.d_timer = self._spawn(self._d_stable_check(tid, now))
        self._maybe_fire_s(st, now)
        self._embed_partial(st)

    def _maybe_fire_s(self, st: TurnState, now: float) -> None:
        cfg = self.config
        words = tokens(st.partial)
        if not st.cue or len(words) < cfg.s_min_new_words:
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
        call = self._launch("S", st.turn_id, st.partial, fast_tail(st.partial, self.lang, final=False),
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
        st.d_call = self._fire_d(st, st.partial, final=False, buffered=True)

    def _fire_d(self, st: TurnState, text: str, *, final: bool, buffered: bool, opener: str | None = None) -> Call | None:
        shown = opener if opener is not None else self._shown_opener_guess(st)
        tail = deep_tail(text, self.lang, final, shown, self._bank_rec(st))
        turns = st.turns_before if st.finished else list(self.turns)
        return self._launch("D", st.turn_id, text, tail, turns, buffered=buffered)

    # ------------------------------------------------------------------ F3: paraphrase matcher (embedding)
    def _embed_partial(self, st: TurnState) -> None:
        """Queue the partial for the embedding thread when the cheap gates pass. Never blocks the loop."""
        e = self.embed
        if e is None or e.state not in ("ready", "loading"):
            return
        if st.bank_hit is not None and st.bank_hit.via != "embed":   # Swift's n-gram already hit this turn
            return
        if not st.cue or len(tokens(st.partial)) < self.config.embed_min_words:
            st.embed_cand, st.embed_count = None, 0
            e.drop(st.turn_id)
            return
        e.submit(st.turn_id, st.partial)

    def _on_embed_result(self, job: Job, res: Result) -> None:
        cfg = self.config
        top = res.top
        s1 = top[0][1] if top else -1.0
        s2 = top[1][1] if len(top) > 1 else -1.0
        ok = bool(top) and s1 >= cfg.embed_threshold and s1 - s2 >= cfg.embed_margin
        self.emitter.metric(job.turn_id, "embed", ms=round(res.ms, 2), wait_ms=round(res.wait_ms, 2),
                            top=top[0][0] if top else None, score=round(s1, 4), second=round(s2, 4),
                            words=len(tokens(job.text)), accepted=ok)
        st = self.ts.get(job.turn_id)
        if st is None:
            return
        if st.bank_hit is not None and st.bank_hit.via != "embed":   # a Swift hit landed while this ran
            return
        if job.turn_id not in (self.active_remote, self.latest_remote_turn):   # a newer turn has started
            return
        if st.finished and (st.addressee == "other" or st.kind == "fragment"):
            return
        if not ok:
            st.embed_cand, st.embed_count = None, 0
            return
        cand = top[0][0]
        if cand == st.embed_cand:
            st.embed_count += 1
        else:
            st.embed_cand, st.embed_count = cand, 1
        if st.embed_count >= cfg.embed_consecutive and cand != st.embed_sent:
            self._embed_hit(st, cand, s1)

    def _embed_hit(self, st: TurnState, bank_id: str, score: float) -> None:
        prev = st.bank_hit
        st.bank_hit = BankHit(bank_id, score, via="embed")
        st.embed_sent = bank_id
        if prev is not None and prev.bank_id != bank_id:
            st.verdict_sent = False          # Haiku's BANK line is checked against the new id
        self.emitter.emit({"type": "bank_hit", "turn_id": st.turn_id, "bank_id": bank_id, "score": round(score, 4),
                           "via": "embed"})
        self._maybe_verdict(st)

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
        self._maybe_verdict(st)

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
        if speaker != "remote":
            self.turns.append(Turn(tid, speaker, text))
            return
        st = self._ts(tid)
        if st.finished:
            return
        st.finished = True
        st.final_text = text
        st.addressee = msg.get("addressee", "unknown")
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
            st.fast = self._launch("F", st.turn_id, st.final_text, fast_tail(st.final_text, self.lang, final=True),
                                   st.turns_before, buffered=False)
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
        st.fast = self._launch("F", st.turn_id, st.final_text, statement_tail(st.final_text, self.lang),
                               st.turns_before, buffered=False, probe=True)
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
        st.d_call = self._fire_d(st, st.final_text, final=True, buffered=False, opener=opener)

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
        return any(c.tier in ("S", "F", "D") and not c.done.is_set() for c in self.calls)

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
                                                   "model": SONNET if note is None else HAIKU}, note=note)
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
