"""Prompt layout and settings tuples: cache-stable prefix, breakpoint 2 cadence, identical pre-warm tuples."""

from __future__ import annotations

import json

from test_runtime_helpers import make, run, settle, start, turn

from verse_brain.runtime.prompt import BP2_EVERY, Turn, bp2_index, build_messages
from verse_brain.runtime.settings import FALLBACK_BETA, HAIKU, SONNET, route_params, tuple_of


def _bp_positions(req: dict) -> list[int]:
    return [i for i, b in enumerate(req["messages"][0]["content"]) if "cache_control" in b]


def _bytes(obj) -> str:
    return json.dumps(obj, sort_keys=True, ensure_ascii=False)


def test_bp2_cadence_unit():
    assert [bp2_index(n) for n in range(10)] == [None, None, None, None, 3, 3, 3, 3, 7, 7]
    turns = [Turn(f"t{i}", "remote" if i % 2 else "me", f"turn number {i}") for i in range(9)]
    prev = None
    for n in range(10):
        msgs = build_messages("PACK", turns[:n], "tail")
        content = msgs[0]["content"]
        marks = [i for i, b in enumerate(content) if "cache_control" in b]
        expected_bp2 = None if n < BP2_EVERY else (n // BP2_EVERY) * BP2_EVERY  # +1 for the pack block, -1 index
        assert marks[0] == 0  # breakpoint 1 on the pack
        assert marks[1:] == ([] if expected_bp2 is None else [expected_bp2])
        assert "cache_control" not in content[-1]  # the tail is never cached
        if prev is not None:
            # append-only: every block of the previous request except its tail reappears unchanged (markers aside)
            strip = lambda bs: [{k: v for k, v in b.items() if k != "cache_control"} for b in bs]  # noqa: E731
            assert strip(content[: len(prev) - 1]) == strip(prev[:-1])
        prev = content


def test_layout_cache_stable():
    """Two successive turns give identical prefix bytes up to breakpoint 1, and breakpoint 2 moves only every
    4 turns (driven through the brain, so the requests are the ones actually sent)."""
    async def go():
        b, t, em = make()
        await start(b)
        for i in range(9):
            await turn(b, f"r{i}", f"question number {i} about the Lantern project?")
            await settle(b)
            await turn(b, f"m{i}", f"my answer {i}", speaker="me")
        return t

    t = run(go())
    fs = [c.request for c in t.by_route("F")]
    ds = [c.request for c in t.by_route("D")]
    assert len(fs) == 9 and len(ds) == 9
    for reqs in (fs, ds):
        for a, b_ in zip(reqs, reqs[1:]):
            assert _bytes(a["system"]) == _bytes(b_["system"])
            assert _bytes(a["messages"][0]["content"][0]) == _bytes(b_["messages"][0]["content"][0])
            assert tuple_of(a) == tuple_of(b_)
    # finalized turns before turn i: 2*i (remote + me); bp2 sits on block index floor(n/4)*4 (pack is block 0)
    for i, req in enumerate(fs):
        n = 2 * i
        want = [0] + ([(n // 4) * 4] if n >= 4 else [])
        assert _bp_positions(req) == want, (i, _bp_positions(req))
    moves = [i for i in range(1, len(fs)) if _bp_positions(fs[i]) != _bp_positions(fs[i - 1])]
    assert moves == [2, 4, 6, 8]  # every 2 remote turns = every 4 finalized turns


def test_settings_tuples_identical_for_prewarm_and_calls():
    async def go():
        b, t, em = make()
        await start(b)
        await turn(b, "r1", "how did you build the invoice pipeline?")
        await settle(b)
        # force a keep-alive now
        await b._warm(HAIKU, "keepalive")
        await b._warm(SONNET, "keepalive")
        return t

    t = run(go())
    creates = t.creates
    assert len(creates) == 4  # two pre-warms + two keep-alives
    for c in creates:
        req = c["request"]
        assert req["max_tokens"] == 0 and "stream" not in req
        real_route = "D" if req["model"] == SONNET else "F"
        real = next(x.request for x in t.calls if x.route == real_route)
        assert tuple_of(req) == tuple_of(real)
        # same system bytes and same pack block bytes (the cached prefix)
        assert _bytes(req["system"]) == _bytes(real["system"])
        assert _bytes(req["messages"][0]["content"][0]) == _bytes(real["messages"][0]["content"][0])
    # the exact tuples from the plan
    assert tuple_of(route_params("S")) == {"model": HAIKU, "thinking": {"type": "disabled"}, "output_config": {"effort": "low"}}
    assert tuple_of(route_params("D")) == {"model": SONNET, "thinking": {"type": "between_tools"},
                                           "output_config": {"effort": "medium"}, "betas": [FALLBACK_BETA],
                                           "fallbacks": "default"}
    assert route_params("S")["max_tokens"] == 120 and route_params("D")["max_tokens"] == 600
    assert "fallbacks" not in route_params("F")
    # no connection opened at t = 0: both lanes of both models were opened at start (pre-warm lane 0, ping lane 1)
    assert {(c["request"]["model"], c["lane"]) for c in creates[:2]} == {(HAIKU, 0), (SONNET, 0)}
    assert set(t.pings) >= {(HAIKU, 1), (SONNET, 1)}
