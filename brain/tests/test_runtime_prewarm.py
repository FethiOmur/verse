"""Pre-warm survives a stalled first connection: bounded attempts, retried on the other lane."""

from __future__ import annotations

import asyncio

from test_runtime_helpers import make, run, start

from verse_brain.runtime.fake import FakeTransport


class StallFirstLane0(FakeTransport):
    """The first pre-warm on lane 0 hangs (a stalled fresh connection); every other call is instant."""

    def __init__(self) -> None:
        super().__init__()
        self.stalled = False

    async def create(self, route, request, lane):
        if lane == 0 and not self.stalled:
            self.stalled = True
            await asyncio.sleep(30)
        return await super().create(route, request, lane)


def _statuses(em):
    return [(e["state"], e.get("message", "")) for e in em.of("status")]


def test_prewarm_retries_on_other_lane():
    b, t, em = make(prewarm_attempt_s=0.3)
    stall = StallFirstLane0()
    b.transport = stall

    async def go():
        await start(b)

    run(go())
    states = _statuses(em)
    assert any(s == "warming" and "retrying on lane 1" in m for s, m in states), states
    assert states[-1][0] == "ready", states
    assert any(c["lane"] == 1 for c in stall.creates), stall.creates


def test_prewarm_gives_up_offline_after_attempts():
    b, t, em = make(prewarm_attempt_s=0.2, prewarm_attempts=2)

    class AlwaysStall(FakeTransport):
        async def create(self, route, request, lane):
            await asyncio.sleep(30)

    b.transport = AlwaysStall()
    run(start(b))
    states = _statuses(em)
    assert states[-1][0] == "offline" and "after 2 attempts" in states[-1][1], states


# --- review H1: a transient API error (5xx / overloaded / 429) during pre-warm must not end the session -------------------

class FailFirst(FakeTransport):
    """The first `n` pre-warm creates fail with `fault`; everything after works."""

    def __init__(self, fault, n: int) -> None:
        super().__init__()
        self.fault, self.left = fault, n

    async def create(self, route, request, lane):
        if self.left > 0:
            self.left -= 1
            raise type(self.fault)(str(self.fault), retry_after=self.fault.retry_after, status=self.fault.status)
        return await super().create(route, request, lane)


def test_prewarm_retries_overloaded_then_ready():
    from verse_brain.runtime.transport import Overloaded

    b, t, em = make(prewarm_backoff_s=0.01)
    b.transport = FailFirst(Overloaded("529 overloaded_error", status=529), 1)
    run(start(b))
    states = _statuses(em)
    assert not [s for s, _ in states if s == "error"], states
    assert any(s == "warming" and "retrying" in m for s, m in states), states
    last = em.of("status")[-1]
    assert last["state"] == "ready" and not last.get("degraded"), states


def test_prewarm_overloaded_every_attempt_starts_degraded_not_error():
    from verse_brain.runtime.fake import FaultTransport
    from verse_brain.runtime.transport import Overloaded

    b, t, em = make(prewarm_backoff_s=0.01)
    b.transport = FaultTransport(None, Overloaded("simulated overloaded", status=529))
    run(start(b))
    states = _statuses(em)
    assert not [s for s, _ in states if s == "error"], states
    last = em.of("status")[-1]
    assert last["state"] == "ready" and last.get("degraded") is True, states
    assert b.transport.calls >= 3 * 2, "every attempt should have tried again"
    # the keep-alive loop warms again soon instead of after keepalive_idle_s
    assert b.last_call_mono and all(v == 0.0 for v in b.last_call_mono.values())


def test_prewarm_rate_limited_honours_retry_after_capped():
    from verse_brain.runtime.transport import RateLimited

    b, t, em = make(prewarm_backoff_s=0.01, prewarm_retry_max_wait_s=0.05)
    b.transport = FailFirst(RateLimited("429 rate_limit", retry_after=30.0, status=429), 1)

    async def go():
        loop = asyncio.get_running_loop()
        t0 = loop.time()
        await start(b)
        return loop.time() - t0

    took = run(go())
    assert took < 2.0, f"retry-after must be capped, took {took:.2f} s"
    assert em.of("status")[-1]["state"] == "ready", _statuses(em)


def test_prewarm_bad_request_starts_anyway():
    from verse_brain.runtime.fake import FaultTransport
    from verse_brain.runtime.transport import BadRequest

    b, t, em = make(prewarm_backoff_s=0.01)
    b.transport = FaultTransport(None, BadRequest("400 invalid_request_error: x", status=400))
    run(start(b))
    last = em.of("status")[-1]
    assert last["state"] == "ready" and last.get("degraded") is True, _statuses(em)


def test_unreadable_session_folder_is_a_named_fatal_error(tmp_path):
    b, t, em = make()
    run(start(b, tmp_path / "missing"))
    st = em.of("status")[-1]
    assert st["state"] == "error" and st.get("reason") == "bad_session", em.of("status")
