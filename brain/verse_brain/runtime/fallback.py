"""G1: the thin wrapper that makes local Gemma the degraded-mode brain, below the engine (the engine is unaware).

`FallbackTransport(primary, local, emitter, cfg)` is a `Transport`. While the API works it only delegates. It switches to
Gemma for exactly three failure classes:
  offline      connection error, or an F answer with no first text after `fallback_first_text_s` (timeout), any tier
  rate_limited 429 / overloaded on S/F traffic (Haiku). S/F have no engine retry (max_retries 0, the engine drops a
               failed S silently), so there is nothing to wait for. A D/A 429 is NOT taken over: the engine's own retry
               (retry-after, one retry) and its `rate_limited` status stay in charge, and Gemma cannot do D/A anyway.
               A speculative S that gets a 429 is left to the engine (dropped) and does not flip the mode.
  credit       billing error / 402, any tier (the engine would halt on it; here it never sees it)
Auth failures and 400s are never taken over: they propagate exactly as before.

Degraded mode: requests go straight to Gemma (no API attempt, no connect timeout in the live path). A background probe
(`create` with max_tokens 0 and a one-word prompt on the S tuple: the same path as the engine's pre-warm, a few tokens
of spend) re-tests the API after `fallback_cooldown_s` (30 s; 60 s afterwards and for credit; a longer retry-after
wins, capped). 30 s because a connection blip is shorter than that and a probe every 30 s costs nothing, while flapping
back and forth would cost answers; 60 s cap because a meeting is short and recovery should not lag. Live questions never
test the API: only the probe does, so a returning-but-flaky API cannot eat a question. On success the prompt cache is
re-written if the outage outlived it, then the mode flips back.

Status messages reuse the existing `status` type and states (`offline` / `rate_limited` / `credit_exhausted` for the
cause, `ready` when recovered) with additive keys `degraded`, `fallback`, `cause`, and `recovered`. The engine's own
`ready` after the pre-warm is rewritten while degraded (`FallbackEmitter`), so the app never shows "ready" over a dead API.
Gemma local metrics (`local_loaded`, `local_primed`, `local_call`, ...) go out as `metric` events with turn_id "".

If Gemma itself cannot load (model or library missing, GPU error) the wrapper switches itself off, says so once, and
every request behaves exactly as without it.
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import AsyncIterator, Callable

from .local_llm import (LocalFailed, LocalGemma, LocalSkipped, LocalUnavailable, LocalUnsupported, available,
                        classify)
from .protocol import Emitter
from .ratelimit import ModelLimiter
from .settings import HAIKU, Config, route_params
from .transport import (CallStream, CreditExhausted, Ev, Offline, Overloaded, RateLimited, Transport,
                        TransportError)

log = logging.getLogger("verse.runtime.fallback")

CAUSE_STATE = {"offline": "offline", "rate_limited": "rate_limited", "overloaded": "rate_limited",
               "credit_exhausted": "credit_exhausted"}
CAUSE_TEXT = {
    "offline": "API unreachable",
    "rate_limited": "API rate-limited (429)",
    "overloaded": "API overloaded",
    "credit_exhausted": "API credit used up",
}
DEGRADED_TAIL = "answering with local Gemma 4 (degraded: slower and shorter, no deep tier, no live summaries)"
PROBE_TIMEOUT_S = 10.0


class FaultTransport:
    """A transport that fails every call with `fault` (until `fault_for_s` has passed), else delegates to `inner`.
    Tests and `VERSE_SIMULATE_API` (live check of the fallback without touching the network or the key)."""

    def __init__(self, inner: Transport | None = None, fault: TransportError | None = None,
                 fault_for_s: float | None = None) -> None:
        self.inner = inner
        self.fault = fault
        self._until = None if fault_for_s is None else time.monotonic() + fault_for_s
        self.calls = 0

    def _check(self) -> None:
        self.calls += 1
        if self.fault is not None and (self._until is None or time.monotonic() < self._until):
            raise type(self.fault)(str(self.fault), retry_after=self.fault.retry_after, status=self.fault.status)
        if self.inner is None:
            raise Offline("no transport")

    async def open_stream(self, route, request, lane):
        self._check()
        return await self.inner.open_stream(route, request, lane)

    async def create(self, route, request, lane):
        self._check()
        return await self.inner.create(route, request, lane)

    async def ping(self, model, lane):
        self._check()
        return await self.inner.ping(model, lane)

    async def aclose(self) -> None:
        if self.inner is not None:
            await self.inner.aclose()


def simulated_fault(name: str) -> TransportError | None:
    name = (name or "").strip().lower()
    return {"offline": Offline("simulated offline"),
            "rate_limited": RateLimited("simulated 429", retry_after=5.0, status=429),
            "overloaded": Overloaded("simulated overloaded", status=529),
            "credit": CreditExhausted("simulated billing error", status=402),
            "credit_exhausted": CreditExhausted("simulated billing error", status=402)}.get(name)


class _EmptyStream:
    headers: dict = {}
    new_connection = None

    async def __aiter__(self):
        yield Ev("start")
        yield Ev("stop", stop_reason="end_turn")

    async def aclose(self) -> None:
        pass


class _LocalStream:
    """Gemma's pieces as the transport's normalised events. Usage stays empty: local tokens cost nothing."""

    headers: dict = {}
    new_connection = None

    def __init__(self, parent: "FallbackTransport", gen: AsyncIterator[str], key: int, cause: str | None,
                 orig: BaseException | None) -> None:
        self._p, self._gen, self._key, self._cause, self._orig = parent, gen, key, cause, orig
        self._closed = False

    async def __aiter__(self):
        started = False
        try:
            async for piece in self._gen:
                if not started:
                    started = True
                    yield Ev("start")
                yield Ev("text", text=piece)
        except LocalUnavailable as e:
            self._p._disable_local(str(e), self._cause)
            if isinstance(self._orig, TransportError):
                raise self._orig from None
            raise Offline(f"local fallback unavailable: {e}") from None
        finally:
            self._release()
        if not started:
            yield Ev("start")
        yield Ev("stop", stop_reason="end_turn")

    def _release(self) -> None:
        self._p._inflight.pop(self._key, None)

    async def aclose(self) -> None:
        if not self._closed:
            self._closed = True
            self._release()
            try:
                await self._gen.aclose()
            except Exception:  # noqa: BLE001
                pass


class _FallbackStream:
    """The API's stream; if it fails before any text (and the failure is one of the three classes), the rest of the
    request is answered by Gemma. After text was streamed nothing is replayed (the engine's rule too)."""

    def __init__(self, parent: "FallbackTransport", inner: CallStream, route: str, kind: str, request: dict, lane: int,
                 t0: float) -> None:
        self._p, self._inner, self.route, self.kind, self.request, self.lane, self.t0 = parent, inner, route, kind, request, lane, t0
        self.headers = getattr(inner, "headers", {}) or {}
        self.new_connection = getattr(inner, "new_connection", None)
        self._local: CallStream | None = None

    async def __aiter__(self):
        p = self._p
        started = seen_text = False
        budget = p.cfg.fallback_first_text_s if self.kind == "answer" else None
        it = self._inner.__aiter__()
        try:
            while True:
                try:
                    if budget is not None and not seen_text:
                        left = budget - (p.clock() - self.t0)
                        if left <= 0:
                            raise asyncio.TimeoutError
                        ev = await asyncio.wait_for(it.__anext__(), left)
                    else:
                        ev = await it.__anext__()
                except StopAsyncIteration:
                    return
                started = started or ev.kind == "start"
                seen_text = seen_text or ev.kind == "text"
                yield ev
        except (TransportError, asyncio.TimeoutError) as e:
            exc = e if isinstance(e, TransportError) else Offline("timeout: no first text from the API")
            cause = None if seen_text else p._cause(self.kind, self.route, exc)
            if cause is None or not p._enter(cause, exc):
                raise exc from None
            await self._inner.aclose()
            self._local = await p._local_stream(self.route, self.kind, self.request, self.lane, cause, exc)
            async for ev in self._local:
                if ev.kind == "start" and started:
                    continue
                yield ev

    async def aclose(self) -> None:
        await self._inner.aclose()
        if self._local is not None:
            await self._local.aclose()


class FallbackTransport:
    def __init__(self, primary: Transport, local: LocalGemma, emitter: Emitter, config: Config | None = None, *,
                 clock: Callable[[], float] = time.monotonic) -> None:
        self.primary = primary
        self.local = local
        self.emitter = emitter
        self.cfg = config or Config()
        self.clock = clock
        self.degraded = False
        self.cause: str | None = None
        self.degraded_since: float | None = None
        self.local_disabled = False
        self._cooldown = self.cfg.fallback_cooldown_s
        self._probes = 0
        self._probe_task: asyncio.Task | None = None
        self._tasks: set[asyncio.Task] = set()
        self._warm_req: dict[str, dict] = {}       # last pre-warm/keep-alive request per route
        self._inflight: dict[int, int] = {}        # id(request) -> lane running on Gemma (hedge duplicates)
        self._bypass = lambda: self.degraded
        ModelLimiter.bypass = self._bypass

    # ------------------------------------------------------------------ classification and mode
    def _cause(self, kind: str, route: str, exc: BaseException) -> str | None:
        if self.local_disabled or not self.cfg.fallback_enabled:
            return None
        if isinstance(exc, (Offline, asyncio.TimeoutError)):
            return "offline"
        if isinstance(exc, CreditExhausted):
            return "credit_exhausted"
        if isinstance(exc, (RateLimited, Overloaded)) and kind in ("answer", "warm") and route != "D":
            return "rate_limited" if isinstance(exc, RateLimited) else "overloaded"
        return None

    def _announce(self, cause: str) -> None:
        self.emitter.status(CAUSE_STATE[cause], f"{CAUSE_TEXT[cause]}: {DEGRADED_TAIL}", degraded=True,
                            fallback="local-gemma", cause=cause)

    def _enter(self, cause: str, exc: BaseException | None = None) -> bool:
        """Switch (or stay) to degraded mode. False when Gemma cannot be used here (the caller re-raises)."""
        if self.local_disabled:
            return False
        if not self.degraded:
            ok, why = available(self.cfg)
            if not ok:
                self._disable_local(why, cause)
                return False
            self.degraded, self.cause, self.degraded_since = True, cause, self.clock()
            self._probes = 0
            self._announce(cause)
        elif cause != self.cause:
            self.cause = cause
            self._announce(cause)
        base = self.cfg.fallback_credit_cooldown_s if cause == "credit_exhausted" else self.cfg.fallback_cooldown_s
        ra = getattr(exc, "retry_after", None)
        if ra:
            base = max(base, min(ra, self.cfg.fallback_cooldown_max_s * 2))
        self._cooldown = base
        if self._probe_task is None or self._probe_task.done():
            self._probe_task = self._spawn(self._probe_loop())
        return True

    def _disable_local(self, reason: str, cause: str | None) -> None:
        if self.local_disabled:
            return
        self.local_disabled = True
        was = self.degraded
        self.degraded = False
        log.warning("local fallback unavailable: %s", reason)
        state = CAUSE_STATE.get(cause or self.cause or "offline", "offline")
        self.emitter.status(state, f"{CAUSE_TEXT.get(cause or self.cause or 'offline', 'API problem')}; local Gemma "
                            f"fallback unavailable ({reason[:160]})", degraded=False, fallback="unavailable")
        if was and self._probe_task is not None:
            self._probe_task.cancel()

    def _spawn(self, coro) -> asyncio.Task:
        t = asyncio.get_running_loop().create_task(coro)
        self._tasks.add(t)
        t.add_done_callback(self._tasks.discard)
        return t

    # ------------------------------------------------------------------ recovery
    def _probe_request(self) -> dict:
        req = route_params("S", max_tokens=0)
        req["messages"] = [{"role": "user", "content": "ping"}]
        return req

    async def _probe_loop(self) -> None:
        while self.degraded:
            await asyncio.sleep(self._cooldown)
            if not self.degraded:
                return
            self._probes += 1
            try:
                await asyncio.wait_for(self.primary.create("S", self._probe_request(), 0), PROBE_TIMEOUT_S)
            except (TransportError, asyncio.TimeoutError) as e:
                exc = e if isinstance(e, TransportError) else Offline("probe timeout")
                cause = self._cause("warm", "S", exc) or self.cause or "offline"
                ra = getattr(exc, "retry_after", None)
                self._cooldown = (self.cfg.fallback_credit_cooldown_s if cause == "credit_exhausted"
                                  else self.cfg.fallback_cooldown_max_s)
                if ra:
                    self._cooldown = max(self._cooldown, min(ra, self.cfg.fallback_cooldown_max_s * 2))
                if cause != self.cause:
                    self.cause = cause
                    self._announce(cause)
                self.emitter.metric("", "fallback_probe", ok=False, kind=exc.kind if isinstance(exc, TransportError) else "timeout",
                                    n=self._probes)
                continue
            except Exception as e:  # noqa: BLE001 - a probe bug must not leave the mode stuck without a retry
                log.warning("fallback probe error: %s: %s", type(e).__name__, e)
                self._cooldown = self.cfg.fallback_cooldown_max_s
                continue
            await self._rewarm()
            self._recover()
            return

    async def _rewarm(self) -> None:
        """Re-write the prompt cache with the last warm-up requests when the outage outlived it (best effort)."""
        if self.degraded_since is None or self.clock() - self.degraded_since < self.cfg.fallback_rewarm_after_s:
            return
        for route, req in list(self._warm_req.items()):
            try:
                usage, _, _ = await asyncio.wait_for(self.primary.create(route, req, 0), PROBE_TIMEOUT_S)
                self.emitter.metric("", "fallback_rewarm", route=route, usage=usage)
            except Exception as e:  # noqa: BLE001
                log.info("rewarm %s failed: %s", route, type(e).__name__)

    def _recover(self) -> None:
        secs = 0.0 if self.degraded_since is None else self.clock() - self.degraded_since
        self.degraded, self.cause, self.degraded_since = False, None, None
        self.emitter.status("ready", f"API recovered after {secs:.0f} s: back on Haiku and Sonnet, local Gemma on standby",
                            degraded=False, recovered=True, fallback="local-gemma")

    # ------------------------------------------------------------------ Gemma side
    async def _local_stream(self, route: str, kind: str, request: dict, lane: int, cause: str | None,
                            orig: BaseException | None) -> CallStream:
        if kind in ("speculation", "rolling"):
            raise LocalSkipped("not run locally while the API is down")
        if kind == "final":
            raise LocalUnsupported("final summary needs the API")
        if kind == "deep":
            return _EmptyStream()
        key = id(request)
        if key in self._inflight and self._inflight[key] != lane:
            raise LocalSkipped("hedge duplicate: already running locally")
        self._inflight[key] = lane
        return _LocalStream(self, self.local.stream(request), key, cause, orig)

    def _prime_from_warm(self) -> None:
        req = self._warm_req.get("S") or self._warm_req.get("F")
        if req is not None and not self.local_disabled:
            self.local.spawn_prime(req)

    # ------------------------------------------------------------------ Transport
    async def open_stream(self, route: str, request: dict, lane: int) -> CallStream:
        kind = classify(route, request)
        if self.degraded:
            return await self._local_stream(route, kind, request, lane, self.cause, None)
        t0 = self.clock()
        try:
            if kind == "answer" and self.cfg.fallback_enabled:
                inner = await asyncio.wait_for(self.primary.open_stream(route, request, lane), self.cfg.fallback_first_text_s)
            else:
                inner = await self.primary.open_stream(route, request, lane)
        except (TransportError, asyncio.TimeoutError) as e:
            exc = e if isinstance(e, TransportError) else Offline("timeout: no response from the API")
            cause = self._cause(kind, route, exc)
            if cause is None or not self._enter(cause, exc):
                raise exc from None
            return await self._local_stream(route, kind, request, lane, cause, exc)
        return _FallbackStream(self, inner, route, kind, request, lane, t0)

    async def create(self, route: str, request: dict, lane: int):
        self._warm_req[route] = request
        if self.degraded:
            self._prime_from_warm()
            return self._synthetic_create()
        try:
            r = await self.primary.create(route, request, lane)
        except (TransportError, asyncio.TimeoutError) as e:
            exc = e if isinstance(e, TransportError) else Offline("timeout")
            cause = self._cause("warm", route, exc)
            if cause is None or not self._enter(cause, exc):
                raise exc from None
            self._prime_from_warm()
            return self._synthetic_create()
        if self.cfg.local_prewarm and route != "D" and not self.local_disabled:
            self.local.spawn_prime(request)
        return r

    @staticmethod
    def _synthetic_create():
        return ({"input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 0,
                 "cache_creation_input_tokens": 0}, {}, "max_tokens")

    async def ping(self, model: str, lane: int) -> dict:
        if self.degraded:
            return {"ms": 0.0, "headers": {}}
        try:
            return await self.primary.ping(model, lane)
        except (Offline, CreditExhausted) as e:
            cause = self._cause("warm", "S" if model == HAIKU else "D", e)
            if cause is None or not self._enter(cause, e):
                raise
            self._prime_from_warm()
            return {"ms": 0.0, "headers": {}}

    async def aclose(self) -> None:
        for t in list(self._tasks):
            t.cancel()
        if self._tasks:
            await asyncio.gather(*self._tasks, return_exceptions=True)
        if ModelLimiter.bypass is self._bypass:
            ModelLimiter.bypass = None
        try:
            await self.local.aclose()
        finally:
            await self.primary.aclose()


class FallbackEmitter(Emitter):
    """Wraps the process emitter for the meeting runtime: forwards everything, but the engine's own `ready` (sent after
    a pre-warm that the wrapper answered locally) must not hide a degraded mode."""

    def __init__(self, inner: Emitter, transport_ref: Callable[[], FallbackTransport | None]) -> None:
        self._inner = inner
        self._ref = transport_ref

    def emit(self, ev: dict) -> None:
        self._inner.emit(ev)

    def status(self, state: str, message: str = "", **extra) -> None:
        ft = self._ref()
        if state == "ready" and ft is not None and ft.degraded and not extra.get("recovered") and ft.cause:
            cause = ft.cause
            self._inner.status(CAUSE_STATE[cause], f"{CAUSE_TEXT[cause]}: {DEGRADED_TAIL}", degraded=True,
                               fallback="local-gemma", cause=cause)
            return
        self._inner.status(state, message, **extra)


def wrap(primary: Transport, emitter: Emitter, cfg: Config) -> tuple[FallbackTransport, FallbackEmitter]:
    """FallbackTransport + the emitter to give the engine. Gemma is not loaded here."""
    box: dict[str, FallbackTransport] = {}
    fe = FallbackEmitter(emitter, lambda: box.get("t"))
    local = LocalGemma(cfg, on_metric=lambda stage, **kw: fe.metric("", stage, **kw))
    ft = FallbackTransport(primary, local, fe, cfg)
    box["t"] = ft
    return ft, fe
