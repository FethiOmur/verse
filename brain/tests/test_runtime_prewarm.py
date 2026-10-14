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
