"""Review M4: the fast tier (F) gets one immediate second attempt on a 5xx / `overloaded_error` that came before any text,
on the other lane when hedging keeps one warm. Nothing is shown twice and the call's spend is counted once. S, and a 429
on F, are unchanged. Fake transport only (no network, no key)."""

from __future__ import annotations

from test_runtime_helpers import FAST_OK, make, run, settle, start, turn

from verse_brain.runtime.fake import FakeTransport, Script, default_responder, lines_script
from verse_brain.runtime.transport import Ev, Overloaded, RateLimited

Q = "how did you build the invoice pipeline?"


def _fail_first_f(fault, n=1):
    """F's first `n` calls fail before the first byte with `fault`; everything else answers as usual."""
    seen = {"F": 0}

    def responder(info):
        if info.route == "F":
            seen["F"] += 1
            if seen["F"] <= n:
                return Script(error=fault)
            return lines_script(FAST_OK)
        return default_responder(info)
    return responder


def _ask(responder, **cfg):
    async def go():
        b, t, em = make(responder, **cfg)
        await start(b)
        await turn(b, "r1", Q)
        await settle(b)
        return b, t, em
    return run(go())


def _done(em, tier):
    return [e for e in em.of("metric", stage="done") if e.get("tier") == tier]


def test_an_overloaded_fast_call_is_retried_once_on_the_other_lane():
    b, t, em = _ask(_fail_first_f(Overloaded("529 overloaded_error", status=529)))
    f = t.by_route("F")
    assert len(f) == 2, "one immediate second attempt"
    assert [c.lane for c in f] == [0, 1], "the retry goes to the warm second lane"
    say_text = "".join(e["text"] for e in em.of("delta", tier="F"))
    assert say_text.count("SAY:") == 1, "the card is shown once"
    assert not [e for e in em.of("status") if e.get("state") == "error"], "a recovered F call shows no error"
    retry = [e for e in em.of("metric") if e.get("stage") == "retry_fast"]
    assert len(retry) == 1 and retry[0]["lane"] == 1 and retry[0]["kind"] == "overloaded"
    done = _done(em, "F")
    assert len(done) == 1 and done[0]["error"] is None
    assert done[0]["cost_usd"] > 0, "the answered attempt's usage is what is billed, once"


def test_a_second_overload_is_not_retried_again_and_surfaces_as_before():
    b, t, em = _ask(_fail_first_f(Overloaded("529 overloaded_error", status=529), n=5))
    assert len(t.by_route("F")) == 2, "one retry only"
    done = _done(em, "F")
    assert len(done) == 1 and done[0]["error"] == "overloaded" and done[0]["cost_usd"] == 0.0
    assert len(t.by_route("D")) == 1, "D still answers the question"


def test_without_hedging_the_retry_stays_on_the_same_lane():
    b, t, em = _ask(_fail_first_f(Overloaded("529 overloaded_error", status=529)), hedge_after_s=None)
    assert [c.lane for c in t.by_route("F")] == [0, 0]


def test_a_rate_limited_fast_call_is_still_not_retried():
    b, t, em = _ask(_fail_first_f(RateLimited("429 rate_limit_error", status=429, retry_after=None)))
    assert len(t.by_route("F")) == 1
    assert not [e for e in em.of("metric") if e.get("stage") == "retry_fast"]


class _TextThenOverload:
    """A stream that shows a SAY line, then fails with `overloaded_error` (mid-stream)."""

    def __init__(self, t, info):
        self.headers, self.new_connection, self._t, self._info = {}, False, t, info

    async def __aiter__(self):
        yield Ev("start", usage={"input_tokens": 50, "cache_read_input_tokens": 4000, "cache_creation_input_tokens": 0})
        yield Ev("text", text="SAY: Sure, here")
        yield Ev("text", text=" is the short version.\n")
        raise Overloaded("overloaded_error mid-stream", status=529)

    async def aclose(self):
        self._t._end(self._info)


def test_no_retry_once_text_was_streamed():
    class MidStream(FakeTransport):
        async def open_stream(self, route, request, lane):
            if route != "F":
                return await super().open_stream(route, request, lane)
            st = await super().open_stream(route, request, lane)
            return _TextThenOverload(self, st.info)

    async def go():
        b, _, em = make()
        b.transport = MidStream(default_responder)
        await start(b)
        await turn(b, "r1", Q)
        await settle(b)
        return b.transport, em

    t, em = run(go())
    assert len(t.by_route("F")) == 1, "text already on screen is never replayed"
    assert "".join(e["text"] for e in em.of("delta", tier="F")).count("SAY:") == 1


def test_only_the_fast_tier_gets_the_immediate_retry():
    from verse_brain.runtime.engine import Call

    b, _, _ = make()
    req = {"model": "claude-haiku-4-5", "messages": []}
    tiers = {tier: Call(b, tier, "r1", "q", req, buffered=False, route=tier) for tier in ("S", "F", "D")}
    assert {k: c.fast_retries_left for k, c in tiers.items()} == {"S": 0, "F": 1, "D": 0}
