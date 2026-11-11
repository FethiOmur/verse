"""Review L3: `start` runs the pre-warm as a task, so the input loop keeps reading while it runs.

Before, `on_start` awaited the pre-warm inside `handle`, and `__main__` awaits `handle` per line: for up to
`prewarm_attempts * prewarm_attempt_s` (36 s) no other line was read, `control stop` included. Now `control stop` ends a
stalled warm-up at once; every other line waits in order and is handled after `ready` (dropped when the start halts).

Fictional fixtures only; the transport is the canned fake (no network)."""

from __future__ import annotations

import asyncio
import os
import queue
import subprocess
import sys
import threading
import time

from test_runtime_helpers import final_calls, make, run, session_copy, settle
from test_runtime_ipc import BRAIN, _collect, _reader, _send
from verse_brain.runtime.fake import FakeTransport

OLD = [
    {"turn_id": "r1", "speaker": "remote", "text": "can you tell me about the Lantern invoice pipeline you built?", "t_audio_end": 4.2,
     "addressee": "me", "kind": "question", "lang": "en"},
    {"turn_id": "m2", "speaker": "me", "text": "sure, it read supplier invoices and cut entry time to two minutes", "t_audio_end": 9.8,
     "addressee": "unknown", "kind": "statement", "lang": "en"},
]


class GatedWarm(FakeTransport):
    """Pre-warm creates (max_tokens 0) and pings wait for `gate`; answers and the final merge go through at once."""

    def __init__(self) -> None:
        super().__init__()
        self.gate = asyncio.Event()

    async def create(self, route, request, lane):
        await self.gate.wait()
        return await super().create(route, request, lane)

    async def ping(self, model, lane):
        await self.gate.wait()
        return await super().ping(model, lane)


def _start_msg(sd) -> dict:
    return {"type": "start", "session_dir": str(sd), "lang": "en"}


def _states(em) -> list[str]:
    return [e["state"] for e in em.of("status")]


def test_start_returns_before_the_prewarm_is_done(tmp_path):
    async def go():
        b, _, em = make()
        b.transport = GatedWarm()
        t0 = time.monotonic()
        await asyncio.wait_for(b.handle(_start_msg(session_copy(tmp_path))), 1.0)
        took = time.monotonic() - t0
        states = _states(em)
        b.transport.gate.set()
        await b.warmed()
        return took, states, _states(em)

    took, during, after = run(go())
    assert took < 1.0
    assert during == ["warming"], during
    assert after[-1] == "ready", after


def test_turns_sent_during_the_prewarm_are_answered_after_ready_in_order(tmp_path):
    async def go():
        b, t, em = make()
        b.transport = gated = GatedWarm()
        await b.handle(_start_msg(session_copy(tmp_path)))
        await b.handle({"type": "partial", "turn_id": "r3", "speaker": "remote", "text": "what did the pilot achieve", "cue": True,
                        "t_audio_end": 3.0})
        await b.handle({"type": "turn", "turn_id": "r3", "speaker": "remote", "text": "what did the pilot achieve",
                        "addressee": "me", "t_audio_end": 3.0})
        await asyncio.sleep(0.05)
        calls_while_warming = len(gated.calls)
        gated.gate.set()
        await b.warmed()
        await settle(b)
        return em, calls_while_warming

    em, calls_while_warming = run(go())
    assert calls_while_warming == 0, "nothing is answered before the pre-warm has ended"
    kinds = [(e["type"], e.get("state"), e.get("turn_id")) for e in em.events if e["type"] in ("status", "delta")]
    ready = kinds.index(("status", "ready", None))
    first_delta = next(i for i, k in enumerate(kinds) if k[0] == "delta" and k[2] == "r3")
    assert ready < first_delta, kinds


def test_a_halted_start_drops_what_was_queued(tmp_path):
    from verse_brain.runtime.transport import CreditExhausted

    class NoCredit(FakeTransport):
        async def create(self, route, request, lane):
            await asyncio.sleep(0.05)
            raise CreditExhausted("billing", status=402)

    async def go():
        b, _, em = make()
        b.transport = t = NoCredit()
        await b.handle(_start_msg(session_copy(tmp_path)))
        await b.handle({"type": "turn", "turn_id": "r3", "speaker": "remote", "text": "what did the pilot achieve",
                        "addressee": "me", "t_audio_end": 3.0})
        await b.warmed()
        await settle(b)
        return em, t

    em, t = run(go())
    assert _states(em)[-1] == "credit_exhausted"
    assert t.calls == [], "no answer is attempted after a halt"
    assert not em.of("delta")


def test_stop_during_a_stalled_prewarm_ends_at_once_and_the_summary_covers_the_history(tmp_path):
    async def go():
        b, _, em = make(final_timeout_s=5)
        b.transport = gated = GatedWarm()
        sd = session_copy(tmp_path)
        await b.handle(_start_msg(sd))
        await b.handle({"type": "history", "turns": OLD})
        t0 = time.monotonic()
        await asyncio.wait_for(b.handle({"type": "control", "action": "stop"}), 3.0)
        return b, em, gated, time.monotonic() - t0, sd

    b, em, gated, took, sd = run(go())
    assert b.stopped.is_set()
    assert took < 3.0
    assert "ready" not in _states(em), "the cancelled pre-warm says nothing more"
    assert [x.turn_id for x in b.turns] == ["r1", "m2"], "the history queued during the warm-up joined the transcript"
    finals = final_calls(gated)
    assert len(finals) == 1, "the final merge ran"
    assert (sd / "summary.md").is_file()
    m = em.of("metric", stage="warm_queue_at_stop")
    assert m and m[0]["messages"] == 1


def test_stop_with_a_turn_queued_lets_a_short_prewarm_finish_and_answers_it(tmp_path):
    async def go():
        b, _, em = make(stop_warm_wait_s=2.0, final_timeout_s=5)
        b.transport = gated = GatedWarm()
        await b.handle(_start_msg(session_copy(tmp_path)))
        await b.handle({"type": "turn", "turn_id": "r3", "speaker": "remote", "text": "what did the pilot achieve",
                        "addressee": "me", "t_audio_end": 3.0})
        asyncio.get_running_loop().call_later(0.2, gated.gate.set)
        await b.handle({"type": "control", "action": "stop"})
        return b, em

    b, em = run(go())
    assert "ready" in _states(em)
    assert "r3" in [x.turn_id for x in b.turns]


# ---------------------------------------------------------------- over the pipes (the real process, --fake)
def _spawn_stalled(stall_s: float) -> subprocess.Popen:
    env = dict(os.environ, VERSE_EVENTS="0", VERSE_SIMULATE_STALL_S=str(stall_s))
    return subprocess.Popen([sys.executable, "-u", "-m", "verse_brain.runtime", "--fake"], cwd=BRAIN, env=env,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)


def test_control_stop_is_read_while_the_prewarm_stalls_over_the_pipes(tmp_path):
    """Every API call stalls for 60 s (VERSE_SIMULATE_STALL_S): before the fix the process read nothing more until its pre-warm
    gave up (36 s); now `control stop` ends it within seconds."""
    sd = session_copy(tmp_path)
    p = _spawn_stalled(60)
    try:
        q: queue.Queue = queue.Queue()
        threading.Thread(target=_reader, args=(p, q), daemon=True).start()
        _send(p, _start_msg(sd))
        got = []
        end = time.time() + 15
        while time.time() < end and not any(e.get("state") == "warming" for _, e in got):
            got += _collect(q, time.time() + 0.5)
        assert any(e.get("state") == "warming" for _, e in got), got
        t0 = time.time()
        _send(p, {"type": "control", "action": "stop"})
        code = p.wait(timeout=8)
        assert code == 0
        assert time.time() - t0 < 8
        got += _collect(q, time.time() + 0.5)
        assert not any(e.get("state") in ("ready", "offline") for _, e in got), "the stop came before any readiness"
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=5)
