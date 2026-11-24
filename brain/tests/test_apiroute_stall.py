"""Stall guards of the API route (verse_brain/apiroute.py, docs/api-route.md "Stalls"): a proxy that accepts the request and then
goes quiet must cost about the hedge delay, not the read timeout. Fake streams on a fake clock (the router's injected `sleep`): no
network, no model call, no real sleep beyond a few milliseconds."""

from __future__ import annotations

import asyncio
import gc
from types import SimpleNamespace

import pytest

from verse_brain import apiroute
from verse_brain.apiroute import (EV_FALLBACK, EV_PRIMARY, FALLBACK, PROXY, Credentials, Router, RoutedStream, call_routed,
                                  failover_reason)
from verse_brain.runtime.engine import Brain
from verse_brain.runtime.fake import FakeTransport, lines_script
from verse_brain.runtime.protocol import ListEmitter
from verse_brain.runtime.settings import HAIKU, Config
from verse_brain.runtime.transport import (AnthropicTransport, AuthFailed, BadRequest, Ev, Offline, StreamStalled, StreamTap)

URL = "http://127.0.0.1:8317"
HEDGE, IDLE = 1.5, 6.0
EPS = 1e-6
FOREVER = 1e9


# ---------------------------------------------------------------- fake clock and fake route streams
async def settle(n: int = 60) -> None:
    for _ in range(n):
        await asyncio.sleep(0)


class FakeClock:
    """Time only moves in `advance`; `sleep` waits on this clock (the router's injected sleep)."""

    def __init__(self) -> None:
        self.t = 0.0
        self._waiters: list[list] = []

    def __call__(self) -> float:
        return self.t

    async def sleep(self, d: float) -> None:
        w = [self.t + d, asyncio.get_running_loop().create_future()]
        self._waiters.append(w)
        try:
            await w[1]
        finally:
            self._waiters.remove(w)

    async def advance(self, dt: float) -> None:
        target = self.t + dt
        while True:
            await settle()
            due = [w for w in self._waiters if w[0] <= target and not w[1].done()]
            if not due:
                break
            w = min(due, key=lambda w: w[0])
            self.t = max(self.t, w[0])
            w[1].set_result(None)
        self.t = target
        await settle()


def run_clean(coro):
    """Run `coro` on a fresh loop and fail on any task left running or any exception nobody retrieved."""
    loop = asyncio.new_event_loop()
    errors: list[dict] = []
    loop.set_exception_handler(lambda _l, ctx: errors.append(ctx))
    try:
        result = loop.run_until_complete(coro)
        leftover = [t for t in asyncio.all_tasks(loop) if not t.done()]
        loop.run_until_complete(loop.shutdown_asyncgens())
    finally:
        loop.close()
    gc.collect()
    assert not leftover, leftover
    assert not errors, errors
    return result


def router(clock: FakeClock, fallback: bool = True, base: str | None = URL, **kw):
    events: list[tuple[str, dict]] = []
    guards = dict(hedge_s=HEDGE, idle_s=IDLE, call_hedge_s=4.0, first_byte_s=15.0)
    guards.update(kw)
    r = Router(base, fallback, clock=clock, sleep=clock.sleep, sink=lambda ev, **f: events.append((ev, f)), **guards)
    return r, events


START_P = Ev("start", usage={"input_tokens": 5, "route": 1})
START_F = Ev("start", usage={"input_tokens": 5, "route": 2})
CONTENT = Ev(apiroute.CONTENT)          # a route stream's marker: its first content_block_start / content_block_delta arrived


def stop(n: int = 3) -> Ev:
    return Ev("stop", stop_reason="end_turn", usage={"input_tokens": 5, "output_tokens": n})


def text(s: str) -> Ev:
    return Ev("text", text=s)


def bump(st) -> None:          # the server sent something the SDK does not yield (a ping)
    st.activity += 1


def quiet(on: bool):
    def f(st) -> None:
        st.quiet_ok = on
    return f


class TimedStream:
    """A route's stream: Ev items are yielded, numbers wait that long on the fake clock, exceptions are raised, callables touch
    the stream (activity, quiet_ok)."""

    def __init__(self, clock: FakeClock, script, route: str) -> None:
        self.clock, self.script = clock, list(script)
        self.headers = {"route": route}
        self.new_connection = False
        self.closed = self.cancelled = False
        self.activity = 0
        self.quiet_ok = False

    async def __aiter__(self):
        try:
            for item in self.script:
                if isinstance(item, (int, float)):
                    await self.clock.sleep(item)
                elif isinstance(item, BaseException):
                    raise item
                elif callable(item):
                    item(self)
                else:
                    yield item
        except asyncio.CancelledError:
            self.cancelled = True
            raise

    async def aclose(self) -> None:
        self.closed = True


def timed_opener(clock: FakeClock, routes: dict):
    """routes: route -> (seconds until the response headers, script or exception)."""
    log = SimpleNamespace(opened=[], streams={}, open_cancelled=[])

    async def open_route(route):
        log.opened.append((route, clock.t))
        after, script = routes[route]
        try:
            if after:
                await clock.sleep(after)
        except asyncio.CancelledError:
            log.open_cancelled.append(route)
            raise
        if isinstance(script, BaseException):
            raise script
        st = TimedStream(clock, script, route)
        log.streams[route] = st
        return st

    return open_route, log


async def consume_timed(clock: FakeClock, r: Router, fn, advance: float = 60.0):
    """Consume one RoutedStream while the fake clock runs; returns (stream, [(time, event)], error or None)."""
    got: list[tuple[float, Ev]] = []
    s = RoutedStream(r, fn)

    async def consumer():
        try:
            async for ev in s:
                got.append((clock.t, ev))
        finally:
            await s.aclose()

    task = asyncio.ensure_future(consumer())
    await clock.advance(advance)
    err = None
    try:
        await task
    except Exception as e:  # noqa: BLE001
        err = e
    await settle()
    return s, got, err


def texts(got) -> str:
    return "".join(ev.text for _t, ev in got if ev.kind == "text")


def reasons(events) -> list[str]:
    return [f["reason"] for ev, f in events if ev == EV_FALLBACK]


# ---------------------------------------------------------------- configuration
def test_guards_default_to_the_constants_and_follow_the_environment(monkeypatch, caplog):
    for env in (apiroute.HEDGE_ENV, apiroute.IDLE_ENV, apiroute.CALL_HEDGE_ENV, apiroute.PREP_FIRST_BYTE_ENV):
        monkeypatch.delenv(env, raising=False)
    r = Router(URL, True)
    assert (r.hedge_s, r.idle_s, r.call_hedge_s, r.first_byte_s) == (1.5, 6.0, 4.0, 15.0)
    monkeypatch.setenv(apiroute.HEDGE_ENV, "0.8")
    monkeypatch.setenv(apiroute.IDLE_ENV, "0")
    monkeypatch.setenv(apiroute.CALL_HEDGE_ENV, "soon")
    monkeypatch.setenv(apiroute.PREP_FIRST_BYTE_ENV, "inf")
    r = Router(URL, True)
    assert (r.hedge_s, r.idle_s, r.call_hedge_s, r.first_byte_s) == (0.8, None, 4.0, 15.0)
    assert "VERSE_API_CALL_HEDGE_S ignored" in caplog.text


def test_stalled_is_a_failover_reason():
    assert failover_reason(StreamStalled("quiet")) == "stalled"
    assert isinstance(StreamStalled(), Offline)              # to a caller it is a lost connection, as before


# ---------------------------------------------------------------- hedged start
@pytest.mark.parametrize("proxy", [(FOREVER, []), (0.0, [FOREVER, START_P, stop()])], ids=["before_headers", "after_headers"])
def test_a_stalled_proxy_costs_the_hedge_delay_not_the_read_timeout(proxy):
    async def go():
        clock = FakeClock()
        r, events = router(clock)
        fn, log = timed_opener(clock, {PROXY: proxy, FALLBACK: (0.3, [START_F, text("direct"), stop()])})
        s, got, err = await consume_timed(clock, r, fn)
        assert err is None and texts(got) == "direct"
        assert got[0][0] <= HEDGE + 0.3 + EPS                # the fallback's own latency after the hedge delay, no more
        assert [route for route, _t in log.opened] == [PROXY, FALLBACK] and log.opened[1][1] == pytest.approx(HEDGE)
        assert reasons(events) == ["stalled"] and r.on_fallback and s.hedged and s.route == FALLBACK
        if PROXY in log.streams:
            assert log.streams[PROXY].closed and log.streams[PROXY].cancelled
        else:
            assert log.open_cancelled == [PROXY]
        assert r.fallback_calls == 1

    run_clean(go())


def test_a_proxy_that_answers_just_before_the_hedge_gets_no_duplicate():
    async def go():
        clock = FakeClock()
        r, events = router(clock)
        fn, log = timed_opener(clock, {PROXY: (0.0, [1.4, START_P, text("proxy"), stop()]),
                                       FALLBACK: (0.0, [START_F, stop()])})
        s, got, err = await consume_timed(clock, r, fn)
        assert err is None and texts(got) == "proxy" and got[0][0] == pytest.approx(1.4)
        assert [route for route, _t in log.opened] == [PROXY] and not s.hedged and events == [] and not r.on_fallback

    run_clean(go())


def test_a_proxy_that_answers_just_after_the_hedge_wins_and_records_nothing():
    async def go():
        clock = FakeClock()
        r, events = router(clock)
        fn, log = timed_opener(clock, {PROXY: (0.0, [1.6, START_P, text("proxy"), stop(7)]),
                                       FALLBACK: (0.5, [START_F, text("direct"), stop(9)])})
        s, got, err = await consume_timed(clock, r, fn)
        assert err is None and texts(got) == "proxy" and got[0][0] == pytest.approx(1.6)
        assert [route for route, _t in log.opened] == [PROXY, FALLBACK] and s.hedged
        assert log.open_cancelled == [FALLBACK]              # the duplicate was cancelled before its headers
        assert events == [] and not r.on_fallback and r.fallback_calls == 0
        # spend: the consumer saw the winner's usage only (the loser never produced an event)
        assert [ev.usage for _t, ev in got if ev.kind in ("start", "stop")] == [START_P.usage, stop(7).usage]

    run_clean(go())


def test_a_fallback_that_already_has_headers_when_the_proxy_wins_is_closed():
    async def go():
        clock = FakeClock()
        r, events = router(clock)
        fn, log = timed_opener(clock, {PROXY: (0.0, [1.9, START_P, stop()]),
                                       FALLBACK: (0.1, [FOREVER, START_F, stop()])})
        _s, got, err = await consume_timed(clock, r, fn)
        assert err is None and got[0][1] is START_P and events == []
        assert log.streams[FALLBACK].closed and log.streams[FALLBACK].cancelled

    run_clean(go())


def test_both_routes_stalled_wait_and_clean_up_when_the_caller_gives_up():
    async def go():
        clock = FakeClock()
        r, events = router(clock)
        fn, log = timed_opener(clock, {PROXY: (FOREVER, []), FALLBACK: (0.0, [FOREVER, START_F, stop()])})
        s = RoutedStream(r, fn)
        task = asyncio.ensure_future(s.open())
        await clock.advance(100)
        assert not task.done() and s.racing and s.hedged
        task.cancel()                                        # the caller's own timeout or a newer turn
        with pytest.raises(asyncio.CancelledError):
            await task
        await settle()
        assert not s.racing and log.open_cancelled == [PROXY] and log.streams[FALLBACK].closed
        assert events == []                                  # nobody won: no route change

    run_clean(go())


def test_both_routes_failing_after_the_hedge_raise_the_fallbacks_error():
    async def go():
        clock = FakeClock()
        r, events = router(clock)
        fn, _log = timed_opener(clock, {PROXY: (3.0, Offline("ReadTimeout")), FALLBACK: (2.5, AuthFailed("401", status=401))})
        _s, got, err = await consume_timed(clock, r, fn)
        assert isinstance(err, AuthFailed) and got == []
        assert reasons(events) == ["timeout"]                # the proxy's own failure, recorded when it happened

    run_clean(go())


def test_a_proxy_request_error_before_the_hedge_stays_on_the_proxy():
    async def go():
        clock = FakeClock()
        r, events = router(clock)
        fn, log = timed_opener(clock, {PROXY: (0.2, BadRequest("400 invalid_request_error", status=400)),
                                       FALLBACK: (0.0, [START_F, stop()])})
        _s, _got, err = await consume_timed(clock, r, fn)
        assert isinstance(err, BadRequest) and [route for route, _t in log.opened] == [PROXY] and events == []

    run_clean(go())


def test_the_race_enters_the_cool_off_and_the_next_requests_go_direct():
    async def go():
        clock = FakeClock()
        r, events = router(clock)
        fn, log = timed_opener(clock, {PROXY: (FOREVER, []), FALLBACK: (0.2, [START_F, text("d"), stop()])})
        await consume_timed(clock, r, fn, advance=10)
        assert r.order() == (FALLBACK,)
        log.opened.clear()
        s, got, _err = await consume_timed(clock, r, fn, advance=1)
        assert [route for route, _t in log.opened] == [FALLBACK] and got[0][0] == pytest.approx(clock.t - 1 + 0.2)
        assert not s.hedged
        clock.t += apiroute.COOL_OFF_S                       # the single probe races too; a proxy still stalled renews the cool-off
        log.opened.clear()
        _s, got, _err = await consume_timed(clock, r, fn, advance=10)
        assert [route for route, _t in log.opened] == [PROXY, FALLBACK] and texts(got) == "d"
        assert [e for e, _ in events] == [EV_FALLBACK] and r.on_fallback

    run_clean(go())


def test_a_probe_that_wins_the_race_returns_to_the_proxy():
    async def go():
        clock = FakeClock()
        r, events = router(clock)
        r.failed_over("offline")
        clock.t += apiroute.COOL_OFF_S + 1
        fn, _log = timed_opener(clock, {PROXY: (0.0, [1.7, START_P, stop()]), FALLBACK: (0.0, [FOREVER, START_F, stop()])})
        await consume_timed(clock, r, fn)
        assert [e for e, _ in events] == [EV_FALLBACK, EV_PRIMARY] and not r.on_fallback

    run_clean(go())


def test_no_hedging_without_a_fallback_or_without_a_base_url():
    async def go():
        clock = FakeClock()
        r, events = router(clock, fallback=False)
        fn, log = timed_opener(clock, {PROXY: (0.0, [5.0, START_P, text("slow"), 20.0, stop()])})
        s, got, err = await consume_timed(clock, r, fn)
        assert err is None and texts(got) == "slow" and got[0][0] == pytest.approx(5.0)
        assert [route for route, _t in log.opened] == [PROXY] and not s.hedged and events == []   # no idle limit either

        r, events = router(clock, base=None)
        fn, log = timed_opener(clock, {apiroute.DIRECT: (0.0, [5.0, START_P, 20.0, stop()])})
        s, got, err = await consume_timed(clock, r, fn)
        assert err is None and [route for route, _t in log.opened] == [apiroute.DIRECT] and not s.hedged

    run_clean(go())


def test_the_hedge_and_idle_limit_can_be_turned_off():
    async def go():
        clock = FakeClock()
        r, events = router(clock, hedge_s=None, idle_s=None)
        fn, log = timed_opener(clock, {PROXY: (0.0, [5.0, START_P, 20.0, stop()]), FALLBACK: (0.0, [START_F, stop()])})
        _s, got, err = await consume_timed(clock, r, fn)
        assert err is None and [route for route, _t in log.opened] == [PROXY] and events == []

    run_clean(go())


# ---------------------------------------------------------------- idle limit
def test_an_idle_proxy_before_text_restarts_on_the_fallback():
    async def go():
        clock = FakeClock()
        r, events = router(clock)
        fn, log = timed_opener(clock, {PROXY: (0.0, [0.1, START_P, CONTENT, FOREVER, text("never"), stop()]),
                                       FALLBACK: (0.2, [START_F, text("direct"), stop()])})
        _s, got, err = await consume_timed(clock, r, fn)
        assert err is None and texts(got) == "direct" and [e.kind for _t, e in got].count("stop") == 1
        assert log.opened[1] == (FALLBACK, pytest.approx(0.1 + IDLE))
        assert reasons(events) == ["stalled"] and log.streams[PROXY].closed and log.streams[PROXY].cancelled

    run_clean(go())


def test_an_idle_proxy_after_text_ends_with_an_error_and_the_retry_goes_direct():
    async def go():
        clock = FakeClock()
        r, events = router(clock)
        fn, log = timed_opener(clock, {PROXY: (0.0, [START_P, text("half"), FOREVER, stop()]),
                                       FALLBACK: (0.0, [START_F, text("whole"), stop()])})
        _s, got, err = await consume_timed(clock, r, fn)
        assert isinstance(err, StreamStalled) and isinstance(err, Offline) and texts(got) == "half"
        assert [route for route, _t in log.opened] == [PROXY] and reasons(events) == ["stalled"]
        _s, got, err = await consume_timed(clock, r, fn)     # the caller's retry
        assert err is None and texts(got) == "whole" and log.opened[-1][0] == FALLBACK

    run_clean(go())


def test_pings_and_thinking_keep_a_quiet_proxy_stream_alive():
    async def go():
        clock = FakeClock()
        r, events = router(clock)
        pings = [x for _ in range(10) for x in (2.0, bump)]  # 20 s with a ping every 2 s
        fn, _log = timed_opener(clock, {PROXY: (0.0, [START_P, CONTENT, *pings, text("after pings"), stop()]),
                                        FALLBACK: (0.0, [START_F, stop()])})
        _s, got, err = await consume_timed(clock, r, fn)
        assert err is None and texts(got) == "after pings" and events == []

        fn, _log = timed_opener(clock, {PROXY: (0.0, [START_P, CONTENT, quiet(True), 30.0, quiet(False), text("thought"),
                                                      stop()]),
                                        FALLBACK: (0.0, [START_F, stop()])})
        _s, got, err = await consume_timed(clock, r, fn)
        assert err is None and texts(got) == "thought" and events == []

        fn, _log = timed_opener(clock, {PROXY: (0.0, [START_P, text("a"), 5.0, text("b"), 5.0, stop()]),
                                        FALLBACK: (0.0, [START_F, stop()])})
        _s, got, err = await consume_timed(clock, r, fn)  # gaps under the limit are fine
        assert err is None and texts(got) == "ab" and events == []

    run_clean(go())


def test_the_fallback_has_no_idle_limit():
    async def go():
        clock = FakeClock()
        r, events = router(clock)
        r.failed_over("offline")
        fn, _log = timed_opener(clock, {FALLBACK: (0.0, [START_F, 20.0, text("slow but fine"), stop()])})
        _s, got, err = await consume_timed(clock, r, fn)
        assert err is None and texts(got) == "slow but fine"

    run_clean(go())


# ---------------------------------------------------------------- non-streaming calls
def timed_calls(clock: FakeClock, plan: dict):
    """plan: route -> (seconds, result or exception)."""
    seen: list[tuple[str, float]] = []
    cancelled: list[str] = []

    async def fn(route):
        seen.append((route, clock.t))
        after, result = plan[route]
        try:
            await clock.sleep(after)
        except asyncio.CancelledError:
            cancelled.append(route)
            raise
        if isinstance(result, BaseException):
            raise result
        return result

    return fn, seen, cancelled


def test_call_routed_with_a_hedge_races_a_stalled_proxy():
    async def go():
        clock = FakeClock()
        r, events = router(clock)
        fn, seen, cancelled = timed_calls(clock, {PROXY: (FOREVER, "proxy"), FALLBACK: (0.4, "direct")})
        task = asyncio.ensure_future(call_routed(r, fn, hedge_s=4.0))
        await clock.advance(10)
        assert await task == "direct" and seen == [(PROXY, 0.0), (FALLBACK, 4.0)] and cancelled == [PROXY]
        assert reasons(events) == ["stalled"] and r.fallback_calls == 1

        r, events = router(clock)
        fn, seen, cancelled = timed_calls(clock, {PROXY: (4.2, "proxy"), FALLBACK: (0.4, "direct")})
        task = asyncio.ensure_future(call_routed(r, fn, hedge_s=4.0))
        await clock.advance(10)
        assert await task == "proxy" and cancelled == [FALLBACK] and events == []

    run_clean(go())


# ---------------------------------------------------------------- prep: first-byte deadline
class StallingManager:
    async def __aenter__(self):
        await asyncio.Event().wait()                         # the proxy never sends its headers

    async def __aexit__(self, *a):
        return False


class DoneStream:
    async def __aenter__(self):
        return self

    async def __aexit__(self, *a):
        return False

    @property
    def text_stream(self):
        async def gen():
            yield "from the fallback"
        return gen()

    async def get_final_message(self):
        u = SimpleNamespace(input_tokens=10, output_tokens=4, cache_read_input_tokens=0, cache_creation_input_tokens=0)
        return SimpleNamespace(usage=u, stop_reason="end_turn")


class FakeSdk:
    def __init__(self, make):
        self.make, self.calls = make, 0
        self.messages = self

    def stream(self, **kw):
        self.calls += 1
        return self.make()

    async def close(self):
        pass


def test_prep_restarts_on_the_fallback_after_the_first_byte_deadline():
    from verse_brain.prep.model import AnthropicPrepModel

    async def go():
        clock = FakeClock()
        m = AnthropicPrepModel(Credentials("sk-direct-test-1111111111", URL, "sk-proxy-test-0000000000"))
        r, events = router(clock)
        m._router = r
        m._client = FakeSdk(StallingManager)
        m._clients[FALLBACK] = FakeSdk(DoneStream)
        task = asyncio.ensure_future(m.generate("sys", "user", 100))
        await clock.advance(14.9)
        assert not task.done()
        await clock.advance(0.2)
        out = await task
        assert out.text == "from the fallback" and reasons(events) == ["stalled"]

    run_clean(go())


# ---------------------------------------------------------------- the SDK tap
def test_stream_tap_counts_pings_and_tracks_thinking():
    class RawStream:                                         # the shape of the SDK's AsyncStream: pings never reach __aiter__
        def __init__(self, sses):
            self.sses = sses

        async def _iter_events(self):
            for s in self.sses:
                yield s

        async def __aiter__(self):
            async for sse in self._iter_events():
                if sse != "ping":
                    yield sse

    async def go():
        raw = RawStream(["message_start", "ping", "ping", "content_block_start"])
        tap = StreamTap()
        tap.attach(raw)
        seen = [x async for x in raw]
        assert seen == ["message_start", "content_block_start"] and tap.activity == 4

    run_clean(go())
    tap = StreamTap()
    tap.saw(SimpleNamespace(type="content_block_start", content_block=SimpleNamespace(type="thinking")))
    assert tap.quiet_ok and tap.activity == 1
    tap.saw(SimpleNamespace(type="content_block_stop"))
    tap.saw(SimpleNamespace(type="content_block_start", content_block=SimpleNamespace(type="text")))
    assert not tap.quiet_ok and tap.activity == 3


# ---------------------------------------------------------------- the live transport and the engine's lane hedge
class StalledProxy(FakeTransport):
    """Accepts and never answers; records its lanes."""

    def __init__(self):
        super().__init__()
        self.lanes: list[int] = []
        self.cancelled_lanes: list[int] = []

    async def open_stream(self, route, request, lane):
        self.lanes.append(lane)
        try:
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            self.cancelled_lanes.append(lane)
            raise


def lane_transport(proxy, fallback, hedge_s: float) -> AnthropicTransport:
    t = AnthropicTransport(Credentials("sk-direct-test-1111111111", URL, "sk-proxy-test-0000000000"))
    t.router = Router(URL, True, hedge_s=hedge_s, idle_s=IDLE, call_hedge_s=None)
    inners = {PROXY: proxy, FALLBACK: fallback}

    async def _open(target, route, request, lane):
        return await inners[target].open_stream(route, request, lane)

    t._open = _open
    return t


def fake_call(brain: Brain) -> SimpleNamespace:
    out = SimpleNamespace(events=[], stages=[])
    call = SimpleNamespace(tier="F", route="F", lane=0, model=HAIKU, request={"model": HAIKU, "messages": []},
                           hedged=False, winner_lane=None, new_connection=None)
    call._stage = lambda stage, **kw: out.stages.append(stage)
    call._on_event = out.events.append
    return call, out


def test_the_lane_hedge_stands_down_while_the_transport_races_the_proxy():
    """The engine's lane-1 duplicate would go to the same stalled proxy; the route race already sends one to the direct API."""
    proxy, fallback = StalledProxy(), FakeTransport(lambda info: lines_script("SAY: direct"))
    t = lane_transport(proxy, fallback, hedge_s=0.004)       # real time: the engine's hedge runs on the loop clock
    b = Brain(t, ListEmitter(), Config(hedge_after_s=0.001))
    call, out = fake_call(b)

    async def go():
        await b.hedged_stream(call)
        await settle()

    run_clean(go())
    assert "".join(e.text for e in out.events if e.kind == "text") == "SAY: direct"
    assert proxy.lanes == [0] and proxy.cancelled_lanes == [0] and [c.lane for c in fallback.calls] == [0]
    assert "hedge_route" in out.stages and "hedge" not in out.stages and not call.hedged
    assert t.router.on_fallback and t._racing == {}


def test_on_the_fallback_the_lane_hedge_works_as_before():
    """During the cool-off there is no route race: a stalled lane 0 gets the engine's duplicate on lane 1, both direct."""

    class SlowLane0(FakeTransport):
        async def open_stream(self, route, request, lane):
            if lane == 0:
                await asyncio.Event().wait()
            return await super().open_stream(route, request, lane)

    fallback = SlowLane0(lambda info: lines_script("SAY: lane one"))
    t = lane_transport(StalledProxy(), fallback, hedge_s=0.004)
    t.router.failed_over("offline")
    b = Brain(t, ListEmitter(), Config(hedge_after_s=0.001))
    call, out = fake_call(b)
    run_clean(b.hedged_stream(call))
    assert "".join(e.text for e in out.events if e.kind == "text") == "SAY: lane one"
    assert call.hedged and call.winner_lane == 1 and "hedge" in out.stages


# ---------------------------------------------------------------- review fixes
class RefusingProxy(FakeTransport):
    """A proxy port that refuses at once (the proxy is not running); records its lanes."""

    def __init__(self):
        super().__init__()
        self.lanes: list[int] = []

    async def open_stream(self, route, request, lane):
        self.lanes.append(lane)
        raise Offline("APIConnectionError")


class StalledLane0(FakeTransport):
    """The direct API: lane 0's fresh connection stalls, lane 1 answers."""

    async def open_stream(self, route, request, lane):
        if lane == 0:
            await asyncio.Event().wait()
        return await super().open_stream(route, request, lane)


def test_a_refused_proxy_leaves_the_lane_hedge_to_the_direct_request():
    """The proxy fails before the route hedge: the request is a single direct one, so the engine's lane hedge must cover it."""
    proxy, fallback = RefusingProxy(), StalledLane0(lambda info: lines_script("SAY: lane one"))
    t = lane_transport(proxy, fallback, hedge_s=0.004)
    b = Brain(t, ListEmitter(), Config(hedge_after_s=0.001))
    call, out = fake_call(b)

    async def go():
        await asyncio.wait_for(b.hedged_stream(call), 2.0)
        await settle()

    run_clean(go())
    assert "".join(e.text for e in out.events if e.kind == "text") == "SAY: lane one"
    assert "hedge" in out.stages and "hedge_route" not in out.stages and call.hedged and call.winner_lane == 1
    assert proxy.lanes == [0] and [c.lane for c in fallback.calls] == [1] and t.router.on_fallback   # lane 0 stalled unrecorded


def test_racing_is_true_only_while_the_proxy_attempt_is_pending():
    async def go():
        clock = FakeClock()
        r, _events = router(clock)
        fn, log = timed_opener(clock, {PROXY: (0.0, Offline("APIConnectionError")), FALLBACK: (FOREVER, [START_F, stop()])})
        s = RoutedStream(r, fn)
        task = asyncio.ensure_future(s.open())
        await clock.advance(0.1)
        assert [route for route, _t in log.opened] == [PROXY, FALLBACK] and not s.racing and not task.done()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task

        r, _events = router(clock)
        fn, log = timed_opener(clock, {PROXY: (3.0, Offline("ReadTimeout")), FALLBACK: (FOREVER, [START_F, stop()])})
        s = RoutedStream(r, fn)
        task = asyncio.ensure_future(s.open())
        await clock.advance(2.0)
        assert s.racing and s.hedged                         # raced, the proxy still pending
        await clock.advance(1.5)
        assert not s.racing and not task.done()              # the proxy failed: one direct request left
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        await settle()

    run_clean(go())


def test_a_slow_but_healthy_proxy_pays_for_one_duplicate_not_one_per_request():
    async def go():
        clock = FakeClock()
        r, events = router(clock)
        fn, log = timed_opener(clock, {PROXY: (0.0, [1.8, START_P, text("p"), stop()]),
                                       FALLBACK: (1.0, [START_F, text("d"), stop()])})
        for _ in range(20):
            _s, got, err = await consume_timed(clock, r, fn, advance=10)
            assert err is None and texts(got) == "p"
        assert [route for route, _t in log.opened].count(FALLBACK) == 1 and r.late_wins == 1
        assert r.failovers == 0 and events == []

    run_clean(go())


def test_the_adaptive_hedge_delay_is_capped_keyed_and_decays():
    r = Router(URL, True, hedge_s=HEDGE, idle_s=IDLE, call_hedge_s=4.0, first_byte_s=15.0)
    key = ("stream", HAIKU)
    assert r.hedge_delay(HEDGE, key) == HEDGE and r.hedge_delay(None, key) is None
    r.proxy_answered(key, 1.8, late=True)
    assert r.hedge_delay(HEDGE, key) == pytest.approx(1.8 * apiroute.HEDGE_WIDEN)
    assert r.hedge_delay(HEDGE, ("stream", "other")) == HEDGE and r.hedge_delay(4.0, ("call", HAIKU)) == 4.0
    r.proxy_answered(key, 30.0, late=True)                   # one very slow answer: still a bounded wait for a stall
    assert r.hedge_delay(HEDGE, key) == pytest.approx(HEDGE * apiroute.HEDGE_MAX_FACTOR)
    for _ in range(apiroute.HEDGE_WINDOW):
        r.proxy_answered(key, 0.4, late=False)               # fast again: back to the base delay
    assert r.hedge_delay(HEDGE, key) == HEDGE


def test_a_proxy_attempt_cancelled_from_inside_fails_over_instead_of_leaking_a_cancel():
    async def go():
        clock = FakeClock()
        r, events = router(clock)
        fn, _log = timed_opener(clock, {PROXY: (0.0, asyncio.CancelledError()), FALLBACK: (0.2, [START_F, text("d"), stop()])})
        _s, got, err = await consume_timed(clock, r, fn)
        assert err is None and texts(got) == "d" and reasons(events) == ["stream_broken"]

    run_clean(go())


def test_within_closes_a_result_that_arrived_as_the_deadline_cancelled_it():
    async def go():
        clock = FakeClock()
        closed: list = []

        async def headers_at_the_last_moment():
            try:
                await asyncio.Event().wait()
            except asyncio.CancelledError:
                return "opened"                              # finished anyway

        async def discard(x):
            closed.append(x)

        task = asyncio.ensure_future(apiroute.within(headers_at_the_last_moment(), 1.0, clock.sleep, discard=discard))
        await clock.advance(1.5)
        with pytest.raises(StreamStalled):
            await task
        assert closed == ["opened"]

    run_clean(go())


def test_reap_waits_for_its_tasks_even_when_cancelled_again():
    """A cancelled gather waits for its children: the reaper never returns while a task still runs in the stream."""

    async def go():
        release = asyncio.Event()

        async def slow_cleanup():
            try:
                await asyncio.Event().wait()
            finally:
                try:
                    await release.wait()
                except asyncio.CancelledError:
                    await release.wait()                     # cleanup that outlives a second cancel

        inner = asyncio.ensure_future(slow_cleanup())
        await settle()
        reaper = asyncio.ensure_future(apiroute._reap([inner]))
        await settle()
        reaper.cancel()
        await settle()
        assert not reaper.done() and not inner.done()        # still reaping: nobody may close the stream under it yet
        release.set()
        await settle()
        assert reaper.cancelled() and inner.done()

    run_clean(go())


# ---------------------------------------------------------------- the race's milestone: first content, not message_start
def one_route(got) -> set:
    """The routes whose events the consumer saw (START_P / START_F carry it; text says it too)."""
    seen = {ev.usage.get("route") for _t, ev in got if ev.kind == "start"}
    seen |= {{"proxy": 1, "direct": 2}[ev.text] for _t, ev in got if ev.kind == "text"}
    return seen


DIRECT_AT_24 = (0.0, [0.4, START_F, 0.5, CONTENT, text("direct"), stop()])   # opened at 1.5: message_start 1.9, content 2.4


def test_a_buffering_proxy_beats_a_direct_message_start_that_has_no_content_yet():
    """The real proxy buffers: its message_start comes with its first content. The direct API's early message_start must not win."""
    async def go():
        clock = FakeClock()
        r, events = router(clock)
        fn, log = timed_opener(clock, {PROXY: (0.0, [2.0, START_P, CONTENT, text("proxy"), stop(7)]), FALLBACK: DIRECT_AT_24})
        s, got, err = await consume_timed(clock, r, fn)
        assert err is None and texts(got) == "proxy" and s.route == PROXY and s.hedged
        assert [ev.kind for _t, ev in got] == ["start", "text", "stop"]          # held start once, in order; no marker
        assert got[0] == (pytest.approx(2.0), START_P) and one_route(got) == {1}
        assert [ev.usage for _t, ev in got if ev.kind in ("start", "stop")] == [START_P.usage, stop(7).usage]
        assert log.opened[1] == (FALLBACK, pytest.approx(HEDGE))
        assert log.streams[FALLBACK].closed and log.streams[FALLBACK].cancelled
        assert events == [] and not r.on_fallback and r.failovers == 0 and r.fallback_calls == 0
        assert r.late_wins == 1 and r.hedge_delay(HEDGE, ("stream", None)) == pytest.approx(2.0 * apiroute.HEDGE_WIDEN)

    run_clean(go())


@pytest.mark.parametrize("proxy", [(FOREVER, []), (0.0, [FOREVER, START_P]), (0.0, [0.1, START_P, FOREVER, CONTENT])],
                         ids=["silent", "headers_only", "message_start_then_nothing"])
def test_a_stalled_proxy_loses_at_the_hedge_plus_the_direct_first_content(proxy):
    async def go():
        clock = FakeClock()
        r, events = router(clock)
        fn, log = timed_opener(clock, {PROXY: proxy, FALLBACK: DIRECT_AT_24})
        s, got, err = await consume_timed(clock, r, fn)
        assert err is None and texts(got) == "direct" and s.route == FALLBACK
        assert got[0] == (pytest.approx(HEDGE + 0.9), START_F) and one_route(got) == {2}   # the proxy's start never shown
        assert [ev.kind for _t, ev in got] == ["start", "text", "stop"]
        assert reasons(events) == ["stalled"] and r.on_fallback and r.fallback_calls == 1 and not s.racing
        if PROXY in log.streams:
            assert log.streams[PROXY].closed and log.streams[PROXY].cancelled

    run_clean(go())


def test_a_proxy_that_started_and_went_quiet_hits_the_idle_limit_inside_the_race():
    """message_start, then nothing, with a direct API that is slow too: the proxy attempt still ends at the idle limit."""
    async def go():
        clock = FakeClock()
        r, events = router(clock)
        fn, log = timed_opener(clock, {PROXY: (0.0, [0.1, START_P, FOREVER]), FALLBACK: (0.0, [FOREVER, START_F, stop()])})
        s = RoutedStream(r, fn)
        task = asyncio.ensure_future(s.open())
        await clock.advance(0.1 + IDLE - 0.01)
        assert s.racing and events == []
        await clock.advance(0.02)
        assert not s.racing and reasons(events) == ["stalled"] and log.streams[PROXY].closed and not task.done()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        await settle()

    run_clean(go())


def test_a_response_without_content_reaches_the_milestone_at_its_stop():
    async def go():
        clock = FakeClock()
        r, events = router(clock)                            # max_tokens 0 / an immediate stop: no content event at all
        fn, log = timed_opener(clock, {PROXY: (0.0, [0.2, START_P, stop(0)]), FALLBACK: DIRECT_AT_24})
        s, got, err = await consume_timed(clock, r, fn)
        assert err is None and [ev.kind for _t, ev in got] == ["start", "stop"] and got[0][0] == pytest.approx(0.2)
        assert [route for route, _t in log.opened] == [PROXY] and not s.hedged and events == []

        r, events = router(clock)                            # the direct API's empty answer wins against a silent proxy
        fn, log = timed_opener(clock, {PROXY: (FOREVER, []), FALLBACK: (0.0, [0.3, START_F, stop(0)])})
        t0 = clock.t
        s, got, err = await consume_timed(clock, r, fn)
        assert err is None and [ev.kind for _t, ev in got] == ["start", "stop"] and one_route(got) == {2}
        assert got[0][0] - t0 == pytest.approx(HEDGE + 0.3) and reasons(events) == ["stalled"]

        r, events = router(clock)                            # a fallback that just ends: the race ends too
        fn, log = timed_opener(clock, {PROXY: (FOREVER, []), FALLBACK: (0.0, [0.3, START_F])})
        s, got, err = await consume_timed(clock, r, fn)
        assert err is None and [ev for _t, ev in got] == [START_F]

    run_clean(go())


def test_a_proxy_stop_without_a_reason_loses_the_race_to_the_running_direct_request():
    async def go():
        clock = FakeClock()
        r, events = router(clock)
        fn, _log = timed_opener(clock, {PROXY: (0.0, [2.0, START_P, Ev("stop")]), FALLBACK: DIRECT_AT_24})
        s, got, err = await consume_timed(clock, r, fn)
        assert err is None and texts(got) == "direct" and one_route(got) == {2} and reasons(events) == ["stream_broken"]

    run_clean(go())


def test_markers_never_reach_the_consumer_without_a_race():
    async def go():
        clock = FakeClock()
        r, events = router(clock, hedge_s=None)
        fn, _log = timed_opener(clock, {PROXY: (0.0, [START_P, CONTENT, text("proxy"), stop()]), FALLBACK: DIRECT_AT_24})
        _s, got, err = await consume_timed(clock, r, fn)
        assert err is None and [ev.kind for _t, ev in got] == ["start", "text", "stop"]

    run_clean(go())


def sdk_events():
    return [SimpleNamespace(type="message_start", message=SimpleNamespace(usage={"input_tokens": 5}, model="m")),
            SimpleNamespace(type="ping"),
            SimpleNamespace(type="content_block_start", content_block=SimpleNamespace(type="thinking")),
            SimpleNamespace(type="content_block_delta", delta=SimpleNamespace(type="thinking_delta")),
            SimpleNamespace(type="content_block_stop"),
            SimpleNamespace(type="content_block_start", content_block=SimpleNamespace(type="text")),
            SimpleNamespace(type="content_block_delta", delta=SimpleNamespace(type="text_delta", text="hi")),
            SimpleNamespace(type="message_delta", usage={"output_tokens": 2}, delta=SimpleNamespace(stop_reason="end_turn"))]


def test_sdk_streams_mark_their_first_content_only_when_routed():
    from verse_brain.runtime.transport import _SdkStream

    class Sdk:
        def __aiter__(self):
            async def gen():
                for e in sdk_events():
                    yield e
            return gen()

        async def close(self):
            pass

    raw = SimpleNamespace(headers={"request-id": "req_1"})

    async def kinds(marks):
        return [ev.kind async for ev in _SdkStream(raw, Sdk(), None, marks=marks)]

    assert run_clean(kinds(True)) == ["start", apiroute.CONTENT, "text", "stop"]   # at the thinking block, not at the text
    assert run_clean(kinds(False)) == ["start", "text", "stop"]                     # no base URL: unwrapped, no marker


def test_the_ask_clients_route_streams_mark_their_first_content():
    from verse_brain.runtime.ask import AnthropicAskClient

    class Manager:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *a):
            return False

        def __aiter__(self):
            async def gen():
                for e in sdk_events():
                    yield e
            return gen()

    client = SimpleNamespace(messages=SimpleNamespace(stream=lambda **kw: Manager()))
    c = AnthropicAskClient(Credentials("sk-direct-test-1111111111", URL, "sk-proxy-test-0000000000"))

    async def kinds(tap):
        return [ev.kind async for ev in c._stream_on(client, {"model": "m"}, tap)]

    assert run_clean(kinds(StreamTap())) == ["start", apiroute.CONTENT, "text", "stop"]
    assert run_clean(kinds(None)) == ["start", "text", "stop"]


# ---------------------------------------------------------------- second review: cancels during the race's cleanup
class SlowCloseStream(TimedStream):
    """A route stream whose `aclose` waits for `release` (an HTTP stream that takes a while to shut down)."""

    def __init__(self, clock, script, route, release: asyncio.Event) -> None:
        super().__init__(clock, script, route)
        self.release, self.closing = release, False

    async def aclose(self) -> None:
        self.closing = True
        await self.release.wait()
        self.closed = True


def test_a_cancel_while_the_loser_closes_still_closes_the_winner_and_the_loser():
    """The caller (a discarded live call, a closed ask panel) is cancelled after the race picked the fallback and while it is
    still closing the proxy: the winner's opened stream is not the caller's yet, so the race must close it, and the loser's own
    close must not be cut short by the second cancel."""

    async def go():
        clock = FakeClock()
        r, _events = router(clock)
        release = asyncio.Event()
        streams: dict = {}

        async def open_route(route):
            if route == PROXY:
                st = SlowCloseStream(clock, [FOREVER], route, release)
            else:
                st = TimedStream(clock, [START_F, CONTENT, text("d"), stop()], route)
            streams[route] = st
            return st

        rs = RoutedStream(r, open_route)
        task = asyncio.ensure_future(rs.open())
        await clock.advance(HEDGE + 0.1)
        assert streams[PROXY].closing and not task.done()     # the fallback won; the race is reaping the proxy
        task.cancel()
        await settle()
        assert not task.done()                                # the loser's close runs to its end first
        release.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        await rs.aclose()
        assert rs.inner is None
        assert streams[FALLBACK].closed and streams[PROXY].closed

    run_clean(go())


def test_within_closes_its_result_when_the_caller_is_cancelled_while_the_timer_is_reaped():
    async def go():
        gate, closed = asyncio.Event(), []
        response = asyncio.get_running_loop().create_future()

        async def sticky_sleep(_d):                           # a timer whose cancel takes a moment to finish
            try:
                await asyncio.Event().wait()
            except asyncio.CancelledError:
                await gate.wait()
                raise

        async def answer():
            return await response

        async def discard(x):
            closed.append(x)

        task = asyncio.ensure_future(apiroute.within(answer(), 1.0, sticky_sleep, discard=discard))
        await settle()
        response.set_result("opened")
        await settle()
        assert not task.done()                                # reaping the timer
        task.cancel()
        await settle()
        gate.set()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert closed == ["opened"]

    run_clean(go())


def test_within_keeps_stream_stalled_when_closing_the_late_result_fails():
    """prep/model.py's close_unused runs the SDK manager's __aexit__; if that raises, call_routed must still see StreamStalled."""

    async def go():
        clock = FakeClock()

        async def headers_at_the_last_moment():
            try:
                await asyncio.Event().wait()
            except asyncio.CancelledError:
                return "opened"

        async def failing_discard(_x):
            raise RuntimeError("close failed")

        task = asyncio.ensure_future(apiroute.within(headers_at_the_last_moment(), 1.0, clock.sleep, discard=failing_discard))
        await clock.advance(1.5)
        with pytest.raises(StreamStalled):
            await task

    run_clean(go())


def test_the_first_byte_metric_says_which_route_answered_and_whether_the_race_hedged():
    proxy, fallback = StalledProxy(), FakeTransport(lambda info: lines_script("SAY: direct"))
    t = lane_transport(proxy, fallback, hedge_s=0.004)
    b = Brain(t, ListEmitter(), Config(hedge_after_s=0.001))
    call, out = fake_call(b)
    stages: dict = {}
    call._stage = lambda stage, **kw: stages.setdefault(stage, kw)

    async def go():
        await b.hedged_stream(call)
        await settle()

    run_clean(go())
    assert stages["first_byte"]["api_route"] == FALLBACK and stages["first_byte"]["route_hedged"] is True


def test_a_direct_stream_adds_no_route_fields_to_the_first_byte_metric():
    b = Brain(FakeTransport(lambda info: lines_script("SAY: x")), ListEmitter(), Config(hedge_after_s=None))
    call, _out = fake_call(b)
    stages: dict = {}
    call._stage = lambda stage, **kw: stages.setdefault(stage, kw)
    run_clean(b.hedged_stream(call))
    assert "api_route" not in stages["first_byte"] and "route_hedged" not in stages["first_byte"]
