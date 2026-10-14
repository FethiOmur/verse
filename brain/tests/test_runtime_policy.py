"""Tier policies with the fake streaming transport: S speculation, F fallback, early D and skip, hedging,
opener verdict, addressee, refusal and 429 handling."""

from __future__ import annotations

import asyncio

from test_runtime_helpers import DEEP_OK, FAST_OK, Script, lines_script, make, partial, run, settle, speak, start, turn

from verse_brain.runtime.transport import RateLimited

WORDS = "so tell me how exactly did you design the invoice extraction pipeline at your last company".split()


def _slow_fast(per_chunk: float = 0.12):
    def responder(info):
        if info.route == "D":
            return lines_script(DEEP_OK)
        return lines_script(FAST_OK, first_byte_delay=0.05, per_chunk=per_chunk)
    return responder


def _ids(em, type_, **kw):
    return [e["id"] for e in em.of(type_, **kw)]


def test_speculation_policy():
    async def go():
        b, t, em = make(_slow_fast(0.12))  # ~16 chunks x 0.12 s: each S call stays in flight ~2 s
        await start(b)
        await speak(b, "q1", WORDS[:16], every=0.1)
        s_calls = list(b.ts["q1"].s_calls)
        max_inflight = t.max_inflight.get("S", 0)
        final = " ".join(WORDS[:13])
        await turn(b, "q1", final)
        await settle(b)
        return b, t, em, s_calls, max_inflight

    b, t, em, s_calls, max_inflight = run(go())
    # fires at 4, 8, 12 words (>= 4 new words, >= 300 ms apart); the 16-word partial finds 3 in flight
    assert [len(c.input_tokens) for c in s_calls] == [4, 8, 12]
    assert max_inflight == 3
    gaps = [b_.t["fire"] - a.t["fire"] for a, b_ in zip(s_calls, s_calls[1:])]
    assert all(g >= 0.3 for g in gaps), gaps
    # select picks the closest input (12 words vs 13-word endpoint text); no F call
    sel = em.of("select", turn_id="q1")
    assert [e["id"] for e in sel] == [s_calls[2].id]
    assert not t.by_route("F")
    # only the selected call's text reaches Swift, and only after the select event
    delta_ids = {e["id"] for e in em.of("delta") if e["tier"] == "S"}
    assert delta_ids == {s_calls[2].id}
    first_s_delta = next(i for i, e in enumerate(em.events) if e["type"] == "delta" and e["tier"] == "S")
    assert em.events.index(sel[0]) < first_s_delta
    assert all(c.discarded for c in s_calls[:2])


def test_speculation_min_gap_and_cue():
    async def go():
        b, t, em = make(_slow_fast(0.0))
        await start(b)
        # 4 words per partial, every 100 ms: fires at 4 words, then not before 300 ms have passed
        await speak(b, "q1", WORDS[:16], every=0.05, step=4)
        calls = list(b.ts["q1"].s_calls)
        # no cue -> no speculation at all
        await speak(b, "q2", WORDS[:12], every=0.1, cue=False)
        return calls, len(b.ts["q2"].s_calls)

    calls, q2_calls = run(go())
    # every partial carries >= 4 new words, so only the 300 ms gap can hold a fire back
    assert len(calls[0].input_tokens) == 4
    assert len(calls) < 4, [len(c.input_tokens) for c in calls]
    gaps = [b_.t["fire"] - a.t["fire"] for a, b_ in zip(calls, calls[1:])]
    assert all(g >= 0.3 for g in gaps), gaps
    assert q2_calls == 0


def test_f_fallback():
    async def go():
        b, t, em = make(_slow_fast(0.0))
        await start(b)
        await speak(b, "q1", WORDS[:6], every=0.1)
        await asyncio.sleep(0.1)
        await turn(b, "q1", "what salary range are you expecting for this position in Milan")
        await settle(b)
        return t, em

    t, em = run(go())
    assert len(t.by_route("S")) == 1
    assert len(t.by_route("F")) == 1
    assert "salary range" in t.by_route("F")[0].tail and "finished" in t.by_route("F")[0].tail
    assert not em.of("select")
    assert {e["tier"] for e in em.of("delta")} == {"F", "D"}


def test_d_early_and_skip():
    # (a) a stable partial with a cue -> D fires before the endpoint, and is confirmed at the endpoint
    async def early():
        b, t, em = make(_slow_fast(0.0))
        await start(b)
        await speak(b, "q1", WORDS[:10], every=0.1)
        await asyncio.sleep(0.9)  # > 700 ms unchanged
        d_before = len(t.by_route("D"))
        d_deltas_before = len([e for e in em.of("delta") if e["tier"] == "D"])
        await turn(b, "q1", " ".join(WORDS[:10]))
        await settle(b)
        return t, em, d_before, d_deltas_before

    t, em, d_before, d_deltas_before = run(early())
    assert d_before == 1, "D should fire early on a stable cued partial"
    assert d_deltas_before == 0, "early D output is held until the endpoint confirms it"
    assert len(t.by_route("D")) == 1, "no second D after the endpoint"
    assert "still being spoken" in t.by_route("D")[0].tail
    assert em.of("metric", stage="d_confirmed")
    assert [e for e in em.of("delta") if e["tier"] == "D"]

    # (b) bank score 0.9 and Haiku agrees -> no D at all
    def agree(info):
        if info.route == "D":
            return lines_script(DEEP_OK)
        return lines_script(FAST_OK.replace("BANK: none", "BANK: b001"))

    async def skip(responder, score):
        b, t, em = make(responder)
        await start(b)
        await b.handle({"type": "bank_hit", "turn_id": "q2", "bank_id": "b001", "score": score})
        await speak(b, "q2", "can you tell me about yourself please".split(), every=0.1)
        await asyncio.sleep(0.9)
        await turn(b, "q2", "can you tell me about yourself please")
        await settle(b)
        return t, em

    t, em = run(skip(agree, 0.9))
    assert len(t.by_route("D")) == 0
    assert em.of("bank_verdict", turn_id="q2", bank_id="b001", agree=True)
    assert em.of("metric", stage="d_skipped")

    # (c) same, but Haiku disagrees -> D fires at the endpoint, verdict says disagree
    t, em = run(skip(_slow_fast(0.0), 0.9))
    assert len(t.by_route("D")) == 1
    assert em.of("bank_verdict", turn_id="q2", agree=False)
    # (d) a weak bank hit (< 0.85) never skips D
    t, em = run(skip(agree, 0.6))
    assert len(t.by_route("D")) == 1


def test_hedge():
    async def go(slow_lane: int, slow: float, fast: float):
        def responder(info):
            if info.route == "F":
                delay = slow if info.lane == slow_lane else fast
                return lines_script(FAST_OK, first_byte_delay=delay)
            return lines_script(DEEP_OK)
        b, t, em = make(responder)
        await start(b)
        await turn(b, "q1", "what did the pilot achieve?")
        await settle(b, timeout=8)
        return b, t, em

    # lane 0 gives no first byte for 2 s -> a duplicate starts on lane 1 at 1.5 s and wins
    b, t, em = run(go(slow_lane=0, slow=2.0, fast=0.0))
    f = t.by_route("F")
    assert [c.lane for c in f] == [0, 1]
    gap = f[1].t_open - f[0].t_open
    assert 1.45 <= gap <= 1.9, gap  # upper bound leaves room for a loaded machine
    call = next(c for c in b.calls if c.tier == "F")
    assert call.hedged and call.winner_lane == 1
    assert f[0].index in t.cancelled  # the stalled one is closed
    assert len({e["id"] for e in em.of("delta", tier="F")}) == 1
    assert sum(1 for e in em.of("delta", tier="F") if e["text"].startswith("SAY:")) == 1  # no duplicate text

    # lane 0 answers at 1.6 s, before the hedge (started at 1.5 s, 2 s delay) -> lane 0 wins, lane 1 closed
    b, t, em = run(go(slow_lane=1, slow=2.0, fast=1.6))
    f = t.by_route("F")
    call = next(c for c in b.calls if c.tier == "F")
    assert [c.lane for c in f] == [0, 1] and call.winner_lane == 0
    assert f[1].index in t.cancelled

    # a first byte within 1.5 s -> no hedge
    b, t, em = run(go(slow_lane=0, slow=0.2, fast=0.0))
    assert [c.lane for c in t.by_route("F")] == [0]


def test_opener_wrong():
    def responder(info):
        if info.route == "D":
            return lines_script("OPENER_WRONG\n- The question was about the courier pilot, not Lantern (prep:L15)")
        return lines_script(FAST_OK)

    async def go():
        b, t, em = make(responder)
        await start(b)
        await speak(b, "q1", WORDS[:8], every=0.1)
        await turn(b, "q1", " ".join(WORDS[:8]))
        await settle(b)
        return t, em

    t, em = run(go())
    st = em.of("opener_status", turn_id="q1")
    assert len(st) == 1 and st[0]["ok"] is False
    d_deltas = [i for i, e in enumerate(em.events) if e["type"] == "delta" and e["tier"] == "D"]
    assert d_deltas and em.events.index(st[0]) < d_deltas[0]
    assert not any("OPENER" in e["text"] for e in em.of("delta"))
    # D was told what opener is on screen
    assert "OPENER ALREADY SHOWN: Sure, here is the short version." in t.by_route("D")[0].tail


def test_addressee_other():
    async def go(cue: bool):
        b, t, em = make(_slow_fast(0.05))
        await start(b)
        await speak(b, "q1", WORDS[:10], every=0.1, cue=cue)
        await turn(b, "q1", " ".join(WORDS[:10]), addressee="other")
        await settle(b)
        return b, t, em

    b, t, em = run(go(cue=False))
    assert t.calls == []
    assert em.of("metric", stage="for_others", turn_id="q1")
    assert b.turns[-1].text.startswith("so tell me")  # kept in the transcript for later turns

    # speculation already in flight is closed, nothing is shown, and no F/D follows
    b, t, em = run(go(cue=True))
    assert t.by_route("S") and not t.by_route("F") and not t.by_route("D")
    assert not em.of("select") and not em.of("delta")
    assert all(c.discarded for c in b.calls)


def test_refusal_and_429():
    # S refused -> status refusal, no retry, no F; D still answers
    def refuse_s(info):
        if info.route == "D":
            return lines_script(DEEP_OK)
        return lines_script("SAY: I", stop_reason="refusal")

    async def s_refusal():
        b, t, em = make(refuse_s)
        await start(b)
        await speak(b, "q1", WORDS[:6], every=0.1)
        await asyncio.sleep(0.2)
        await turn(b, "q1", " ".join(WORDS[:6]))
        await settle(b)
        return t, em

    t, em = run(s_refusal())
    assert len(t.by_route("S")) == 1 and not t.by_route("F")
    assert em.of("status", state="refusal", turn_id="q1")
    assert not [e for e in em.of("delta") if e["tier"] in ("S", "F")]
    assert len(t.by_route("D")) == 1 and em.of("delta", tier="D")

    # 429 on D -> one retry after retry-after; 429 on F -> dropped, no retry, no status
    n = {"D": 0}

    def limited(info):
        if info.route == "D":
            n["D"] += 1
            if n["D"] == 1:
                return Script(error=RateLimited("429", retry_after=0.4, status=429))
            return lines_script(DEEP_OK)
        return Script(error=RateLimited("429", retry_after=0.4, status=429))

    async def d_429():
        b, t, em = make(limited)
        await start(b)
        await turn(b, "q2", "what did the pilot achieve?")
        await settle(b)
        return t, em

    t, em = run(d_429())
    d = t.by_route("D")
    assert len(d) == 2 and d[1].t_open - d[0].t_open >= 0.4
    assert em.of("delta", tier="D")
    assert len(t.by_route("F")) == 1
    assert not em.of("status", state="rate_limited")
