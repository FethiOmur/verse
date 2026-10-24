"""F2 incremental summary: a rolling Haiku summary on the cached S/F prefix every N finalized turns, a Sonnet merge
into summary.md at stop. Fake streaming transport; the summary never competes with S/F/D."""

from __future__ import annotations

import asyncio
import json
import time

from test_runtime_helpers import (DEEP_OK, FAST_OK, exchange, final_calls, lines_script, make, partial, rolling_calls,
                                  run, session_copy, settle, start, turn)

from verse_brain.prep.model import Usage, spend_usd
from verse_brain.runtime.fake import Script
from verse_brain.runtime.prompt import bp2_index
from verse_brain.runtime.settings import HAIKU, SONNET, route_params, tuple_of
from verse_brain.runtime.summary import Running, norm, parse_line, render_markdown
from verse_brain.runtime.transport import BadRequest

R1 = ("DECISION: We ship the pilot on Friday\nACTION: Tomas — send the deck by Monday\n"
      "OPEN: Who owns the budget?")
R2 = ("DECISION: we ship the pilot on friday.\nACTION: Tomas - Send the deck by Monday\n"
      "OPEN: Who owns the budget?\nOPEN: Is the pilot in Milan or Milan?\nNONE")
FINAL = ("SUMMARY: The team agreed to ship the pilot on Friday and left the budget owner open.\n"
         "DECISION: Ship the pilot on Friday\n"
         "ACTION: Tomas — send the deck by Monday\n"
         "ACTION: the owner — share the pilot plan\n"
         "OPEN: Who owns the budget?\n"
         "CONFLICT: Said the pilot cut entry to 3 minutes; the fact sheet says 2 minutes (f001)")


def responder_for(rolling=(R1, R2), final=FINAL, per_chunk=0.0, final_script=None):
    seen = {"r": 0}

    def responder(info):
        if info.tail.startswith("SUMMARIZE-INCREMENTAL"):
            text = rolling[min(seen["r"], len(rolling) - 1)]
            seen["r"] += 1
            return lines_script(text, per_chunk=per_chunk)
        if info.tail.startswith("SUMMARIZE-FINAL"):
            return final_script or lines_script(final)
        if info.route == "D":
            return lines_script(DEEP_OK)
        return lines_script(FAST_OK)
    return responder


def _json(obj) -> str:
    return json.dumps(obj, sort_keys=True, ensure_ascii=False)


# ---------------------------------------------------------------- pure helpers
def test_parse_and_normalise():
    assert parse_line("DECISION: ship Friday") == ("DECISION", "ship Friday")
    assert parse_line("- **action:** Tomas - send the deck") == ("ACTION", "Tomas — send the deck")
    assert parse_line("OPEN: who owns it?") == ("OPEN", "who owns it?")
    assert parse_line("ACTION: send the deck") == ("ACTION", "Unassigned — send the deck")
    assert parse_line("NONE") is None and parse_line("DECISION: none") is None and parse_line("hello") is None
    assert norm("Tomas — Send the deck!") == norm("tomas - send  the deck") == "tomas send the deck"


def test_running_merge_dedupes_by_normalised_text():
    r = Running()
    assert r.add("DECISION", "We ship on Friday") is True
    assert r.add("DECISION", "we ship on friday.") is False
    assert r.add("ACTION", "Tomas — send the deck") is True
    assert r.add("ACTION", "Tomas - Send the deck") is False
    assert r.add("OPEN", "Budget?") and not r.add("OPEN", "budget")
    assert r.lists() == {"decisions": ["We ship on Friday"], "actions": ["Tomas — send the deck"], "open": ["Budget?"]}
    md = render_markdown(r, text="One line.", meta={"session": "s1", "turns": 4, "model": SONNET}, note=None)
    for h in ("# Meeting summary", "## Decisions", "## Actions", "## Open questions", "## Conflicts with the fact sheet"):
        assert h in md
    assert "- Tomas — send the deck" in md and "One line." in md


# ---------------------------------------------------------------- rolling summary
def test_rolling_fires_after_n_turns_on_the_cached_prefix(tmp_path):
    sess = session_copy(tmp_path)

    async def go():
        b, t, em = make(responder_for())
        await start(b, sess)
        await exchange(b, 1)
        await exchange(b, 2)
        await settle(b)
        before = len(rolling_calls(t))           # 4 finalized turns: not yet
        await exchange(b, 3)                     # 6th finalized turn
        await settle(b)
        after = len(rolling_calls(t))
        await turn(b, "r4", "question 4 about Lantern?")  # an F call over the same 6 turns
        await settle(b)
        return b, t, em, before, after

    b, t, em, before, after = run(go())
    assert before == 0 and after == 1
    r = rolling_calls(t)[0]
    f = next(c for c in t.by_route("F") if "question 4" in c.tail)
    assert r.route == "S" and r.model == HAIKU
    # the S/F settings tuple and the system block, byte for byte; max_tokens is not part of the tuple
    assert _json(tuple_of(r.request)) == _json(tuple_of(f.request)) == _json(tuple_of(route_params("S")))
    assert _json(r.request["system"]) == _json(f.request["system"])
    # system -> pack (bp1) -> finalized turns (bp2): everything but the tail is identical to the F call's prefix
    rc, fc = r.request["messages"][0]["content"], f.request["messages"][0]["content"]
    assert _json(rc[:-1]) == _json(fc[:-1])
    marks = [i for i, blk in enumerate(rc) if "cache_control" in blk]
    assert marks == [0, bp2_index(6) + 1] == [0, 4]
    assert "cache_control" not in rc[-1] and rc[-1]["text"].startswith("SUMMARIZE-INCREMENTAL")
    # the output became events, not deltas
    assert not [e for e in em.of("delta") if e.get("id", "").startswith("r")]
    s = em.of("summary")
    assert len(s) == 1
    assert s[0] == {"type": "summary", "decisions": ["We ship the pilot on Friday"],
                    "actions": ["Tomas — send the deck by Monday"], "open": ["Who owns the budget?"]}
    assert em.of("actions") == [{"type": "actions", "items": ["Tomas — send the deck by Monday"]}]


def test_rolling_dedupes_across_passes(tmp_path):
    async def go():
        b, t, em = make(responder_for())
        await start(b, session_copy(tmp_path))
        for i in range(1, 7):
            await exchange(b, i)
        await settle(b)
        return b, t, em

    b, t, em = run(go())
    assert len(rolling_calls(t)) == 2
    s = em.of("summary")
    assert len(s) == 2
    last = s[-1]
    assert last["decisions"] == ["We ship the pilot on Friday"]          # the re-worded repeat was dropped
    assert last["actions"] == ["Tomas — send the deck by Monday"]
    assert last["open"] == ["Who owns the budget?", "Is the pilot in Milan or Milan?"]
    assert em.of("actions")[-1]["items"] == last["actions"]
    # the second pass is told what is already recorded
    assert "Who owns the budget?" in rolling_calls(t)[1].tail


def test_unchanged_pass_emits_nothing_new(tmp_path):
    async def go():
        b, t, em = make(responder_for(rolling=(R1,)))
        await start(b, session_copy(tmp_path))
        for i in range(1, 7):
            await exchange(b, i)
        await settle(b)
        return t, em

    t, em = run(go())
    assert len(rolling_calls(t)) == 2 and len(em.of("summary")) == 1


def test_time_trigger_counts_speech_time(tmp_path):
    async def go():
        b, t, em = make(responder_for())
        await start(b, session_copy(tmp_path))
        await exchange(b, 1, t_end=10.0)
        await exchange(b, 2, t_end=100.0)         # 4 turns, 90 s of speech: nothing due
        await settle(b)
        early = len(rolling_calls(t))
        await b.handle({"type": "turn", "turn_id": "m3", "speaker": "me", "text": "and one more thing",
                        "addressee": "unknown", "t_audio_end": 200.0})   # 5 turns, 190 s >= 3 min: due
        await settle(b)
        return early, len(rolling_calls(t))

    early, late = run(go())
    assert early == 0 and late == 1


def test_never_fires_while_s_f_d_is_in_flight(tmp_path):
    sess = session_copy(tmp_path)

    def slow(info):
        if info.tail.startswith("SUMMARIZE-"):
            return responder_for()(info)
        if info.route == "D":
            return lines_script(DEEP_OK, per_chunk=0.1, first_byte_delay=0.1)
        return lines_script(FAST_OK, per_chunk=0.1, first_byte_delay=0.1)

    async def a_question_is_being_answered():
        b, t, em = make(slow)
        await start(b, sess)
        await exchange(b, 1)
        await exchange(b, 2)
        await settle(b)
        await turn(b, "r3", "question 3 about Lantern?")   # F and D start and take ~1 s
        await turn(b, "m3", "answer 3", speaker="me")      # the 6th finalized turn: a summary is due now
        await asyncio.sleep(0.4)
        mid = len(rolling_calls(t))
        in_flight = [c.tier for c in b.calls if not c.done.is_set()]
        await settle(b, timeout=8)
        return b, t, mid, in_flight

    b, t, mid, in_flight = run(a_question_is_being_answered())
    assert mid == 0 and set(in_flight) >= {"F", "D"}
    (r,) = [c for c in b.calls if c.tier == "R"]
    fd_done = max(c.t["done"] for c in b.calls if c.tier in ("F", "D"))
    assert r.t["fire"] >= fd_done
    assert any(e["stage"] == "summary_deferred" for e in make_events(b))

    # a question still being spoken (partials, no endpoint yet) also holds the summary back
    async def partial_in_progress():
        b, t, em = make(responder_for())
        await start(b, session_copy(tmp_path / "second"))
        await exchange(b, 1)
        await exchange(b, 2)
        await turn(b, "r3", "question 3 about Lantern?")
        await settle(b)
        await partial(b, "r4", "so tell me how exactly did you")      # S fires; the turn is open
        await turn(b, "m3", "answer 3", speaker="me")                   # 6th turn
        await asyncio.sleep(0.3)
        mid = len(rolling_calls(t))
        await turn(b, "r4", "so tell me how exactly did you do it")
        await settle(b, timeout=8)
        return b, t, mid

    (tmp_path / "second").mkdir()
    b, t, mid = run(partial_in_progress())
    assert mid == 0
    (r,) = [c for c in b.calls if c.tier == "R"]
    assert r.t["fire"] >= max(c.t["done"] for c in b.calls if c.tier in ("F", "D") and c.turn_id == "r4")


def make_events(b):
    return [e for e in b.emitter.events if e["type"] == "metric"]


def test_summary_never_delays_the_fast_path(tmp_path):
    async def go():
        b, t, em = make(responder_for(per_chunk=0.15))        # the rolling call streams for seconds
        await start(b, session_copy(tmp_path))
        for i in range(1, 4):
            await exchange(b, i)
        await asyncio.sleep(0.3)
        (r,) = [c for c in b.calls if c.tier == "R"]
        assert not r.done.is_set()
        t0 = time.time()
        await turn(b, "r4", "question 4 about Lantern?")
        await asyncio.sleep(0.15)
        f = next(c for c in b.calls if c.tier == "F" and c.turn_id == "r4")
        fired_after = f.t["fire"] - t0
        r_alive = not r.done.is_set() and not r.discarded
        await settle(b, timeout=10)
        return fired_after, r_alive, f

    fired_after, r_alive, f = run(go())
    assert fired_after < 0.1 and r_alive       # F is not queued behind the summary, and the summary is not killed


def test_skipped_when_bucket_low_or_budget_nearly_spent(tmp_path):
    async def go():
        b, t, em = make(responder_for())
        await start(b, session_copy(tmp_path))
        lim = b.limiters[HAIKU].buckets["input-tokens"]
        full = lim.level
        lim.level = lim.capacity * 0.1                                   # the Haiku token bucket is nearly empty
        for i in range(1, 4):
            await exchange(b, i)
        await settle(b)
        low = len(rolling_calls(t))
        reasons = [e.get("reason") for e in make_events(b) if e["stage"] == "summary_deferred"]
        lim.level = full
        b.config.budget_usd = 3.0                                        # an explicit cap (the default is none)
        b.spend = b.config.budget_usd * 0.95                             # budget almost gone: keep it for S/F/D
        await exchange(b, 4)
        await settle(b)
        spent = len(rolling_calls(t))
        b.spend = 0.0
        await exchange(b, 5)                                             # both are fine again: it fires, once
        await settle(b)
        return low, reasons, spent, len(rolling_calls(t))

    low, reasons, spent, ok = run(go())
    assert low == 0 and "bucket_low" in reasons
    assert spent == 0
    assert ok == 1


def test_spend_includes_summary_calls(tmp_path):
    usage = {"input_tokens": 120, "output_tokens": 60, "cache_read_input_tokens": 3000,
             "cache_creation_input_tokens": 700}
    want_r = spend_usd(HAIKU, Usage(120, 60, 3000, 700))
    want_a = spend_usd(SONNET, Usage(200, 400, 3500, 0))

    def responder(info):
        if info.tail.startswith("SUMMARIZE-INCREMENTAL"):
            return lines_script(R1, usage=dict(usage))
        if info.tail.startswith("SUMMARIZE-FINAL"):
            return lines_script(FINAL, usage={"input_tokens": 200, "output_tokens": 400,
                                              "cache_read_input_tokens": 3500, "cache_creation_input_tokens": 0})
        if info.route == "D":
            return lines_script(DEEP_OK)
        return lines_script(FAST_OK)

    async def go():
        b, t, em = make(responder)
        await start(b, session_copy(tmp_path))
        for i in range(1, 4):
            await exchange(b, i)
        await settle(b)
        base = b.spend
        await b.handle({"type": "control", "action": "stop"})
        return b, base, em

    b, base, em = run(go())
    # session spend = pre-warms + every call (S/F/D and summaries); the summary passes are part of it
    assert abs(b.spend - base - want_a) < 1e-9
    assert abs(b.summary_spend - (want_r + want_a)) < 1e-9
    costs = {m["id"][0]: m["cost_usd"] for m in make_events(b) if m["stage"] == "done" and m.get("tier") in ("R", "A")}
    assert abs(costs["r"] - round(want_r, 6)) < 1e-9 and abs(costs["a"] - round(want_a, 6)) < 1e-9


# ---------------------------------------------------------------- final merge at stop
def test_stop_writes_summary_md(tmp_path):
    sess = session_copy(tmp_path)

    async def go():
        b, t, em = make(responder_for())
        await start(b, sess)
        for i in range(1, 4):
            await exchange(b, i)
        await settle(b)
        await b.handle({"type": "control", "action": "stop"})
        return b, t, em

    b, t, em = run(go())
    assert b.stopped.is_set()
    (a,) = final_calls(t)
    d = next(c for c in t.by_route("D") if not c.tail.startswith("SUMMARIZE"))
    assert a.route == "D" and a.model == SONNET and a.request["max_tokens"] > route_params("D")["max_tokens"]
    assert _json(tuple_of(a.request)) == _json(tuple_of(d.request)) == _json(tuple_of(route_params("D")))
    assert _json(a.request["system"]) == _json(d.request["system"])
    assert _json(a.request["messages"][0]["content"][0]) == _json(d.request["messages"][0]["content"][0])
    # the draft notes from the rolling pass go into the merge call
    assert "Tomas — send the deck by Monday" in a.tail and "Who owns the budget?" in a.tail

    md = (sess / "summary.md").read_text(encoding="utf-8")
    assert "# Meeting summary" in md
    assert "The team agreed to ship the pilot on Friday" in md
    assert "- Ship the pilot on Friday" in md
    assert "- Tomas — send the deck by Monday" in md and "- the owner — share the pilot plan" in md
    assert "- Who owns the budget?" in md
    assert "## Conflicts with the fact sheet" in md and "fact sheet says 2 minutes (f001)" in md
    assert "DRAFT" not in md
    ev = em.of("summary")[-1]
    assert ev["final"] is True and ev["path"] == str(sess / "summary.md")
    assert ev["actions"] == ["Tomas — send the deck by Monday", "the owner — share the pilot plan"]
    assert ev["conflicts"] and em.of("actions")[-1]["items"] == ev["actions"]
    assert not any(e["type"] == "delta" and e["tier"] in ("A", "R") for e in em.events)


def test_summarize_then_stop_runs_one_final_call(tmp_path):
    sess = session_copy(tmp_path)

    async def go():
        b, t, em = make(responder_for())
        await start(b, sess)
        for i in range(1, 3):
            await exchange(b, i)
        await settle(b)
        await b.handle({"type": "control", "action": "summarize"})
        await settle(b)
        assert not b.stopped.is_set()
        mid = [e for e in em.of("summary") if e.get("final")]
        await b.handle({"type": "control", "action": "stop"})
        return b, t, em, mid

    b, t, em, mid = run(go())
    assert len(final_calls(t)) == 1 and len(mid) == 1
    assert (sess / "summary.md").exists() and b.stopped.is_set()
    assert len([e for e in em.of("summary") if e.get("final")]) == 2   # stop re-sends the unchanged result


def test_final_failure_still_leaves_a_draft(tmp_path):
    sess = session_copy(tmp_path)
    boom = Script(error=BadRequest("400 invalid_request_error: nope", status=400))

    async def go():
        b, t, em = make(responder_for(final_script=boom))
        await start(b, sess)
        for i in range(1, 4):
            await exchange(b, i)
        await settle(b)
        await b.handle({"type": "control", "action": "stop"})
        return b, em

    b, em = run(go())
    md = (sess / "summary.md").read_text(encoding="utf-8")
    assert "DRAFT" in md and "bad_request" in md
    assert "- Tomas — send the deck by Monday" in md and "- Who owns the budget?" in md
    ev = em.of("summary")[-1]
    assert ev["final"] is False and ev["path"] == str(sess / "summary.md")
    assert b.stopped.is_set()


def test_stop_without_turns_writes_nothing(tmp_path):
    sess = session_copy(tmp_path)

    async def go():
        b, t, em = make(responder_for())
        await start(b, sess)
        await b.handle({"type": "control", "action": "stop"})
        return t

    t = run(go())
    assert not final_calls(t) and not (sess / "summary.md").exists()


def test_rolling_failure_is_silent(tmp_path):
    """A failed or refused rolling pass must not raise a status the overlay would show for a real answer."""
    def responder(info):
        if info.tail.startswith("SUMMARIZE-INCREMENTAL"):
            return Script(error=BadRequest("400 invalid_request_error", status=400))
        return responder_for()(info)

    async def go():
        b, t, em = make(responder)
        await start(b, session_copy(tmp_path))
        for i in range(1, 4):
            await exchange(b, i)
        await settle(b)
        return t, em

    t, em = run(go())
    assert len(rolling_calls(t)) == 1
    assert not em.of("status", state="error") and not em.of("summary")


def test_no_cap_by_default(tmp_path):
    """the owner (2026-10-14): no spend limits; the Anthropic API credit pays. A large spend must not halt the brain."""
    async def go():
        b, t, em = make(responder_for())
        await start(b, session_copy(tmp_path))
        assert b.config.budget_usd is None
        b.spend = 500.0
        await exchange(b, 1)
        await settle(b)
        return b.halted
    assert not asyncio.run(go())
