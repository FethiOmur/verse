"""How the brain acts on Haiku's bank verdict (the `BANK:` line of the fast call that answers the turn) for a card that is already
on screen: Swift's lexical hit (`bank_hit` from the app) and the brain's paraphrase hit (`via:"embed"`) alike.

- The fast call of a turn with a hit gets a BANK CHECK block: the entry's id, its question and its paraphrases, and the rule
  (same thing asked, not the same topic), with the BANK line first.
- Positive verdict: the card stays, D gets the entry's prepared deep answer.
- Negative verdict: `bank_verdict agree:false`, the brain drops the hit (D answers from the grounding, without the entry's deep
  answer or its opener), an early D built on the entry is not shown, and the same entry sent again for the turn is ignored.
- Missing verdict (the call finished normally without a BANK line): the card is not confirmed, so it is withdrawn the same way
  (`reason:"missing"`). A failed call gives no verdict: the bank card stays as the only answer.

Stubbed transport only; what the real model writes is measured by tests/live_bank_verdict.py, never asserted here."""

from __future__ import annotations

import asyncio
import time

from test_runtime_helpers import make, partial, run, settle, start, turn

from verse_brain.runtime.fake import Script, default_responder, lines_script
from verse_brain.runtime.prompt import bank_check
from verse_brain.runtime.protocol import load_session
from test_runtime_helpers import FIX
from verse_brain.runtime.transport import Offline

Q = "Can you tell me about yourself please"
CARD = "SAY: Mostly I build LLM tools for logistics.\n- I led Lantern.\n- It cut entry to 2 minutes."   # not the bank opener


def fast(bank_line: str | None, *, first: bool = True, delay: float = 0.0):
    """S/F answer with the BANK line first (as the BANK CHECK asks), last, or not at all; everything else canned."""
    body = CARD if bank_line is None else (f"{bank_line}\n{CARD}" if first else f"{CARD}\n{bank_line}")

    def responder(info):
        if info.route in ("S", "F", "V") and "CURRENT QUESTION" in info.tail and "STATEMENT CHECK" not in info.tail:
            return lines_script(body, per_chunk=delay)
        return default_responder(info)
    return responder


async def ask(responder, score=0.7, via_embed=False, cfg=None):
    b, t, em = make(responder, **(cfg or {}))
    await start(b)
    if via_embed:
        await b.handle({"type": "partial", "turn_id": "q1", "speaker": "remote", "text": Q, "cue": True, "t_audio_end": 0.0})
        b._embed_hit(b.ts["q1"], "b001", 0.93)
    else:
        await b.handle({"type": "bank_hit", "turn_id": "q1", "bank_id": "b001", "score": score})
    await turn(b, "q1", Q, kind="question")
    await settle(b)
    return b, t, em


def d_tails(t) -> list[str]:
    return [c.tail for c in t.by_route("D")]


def shown_d(b, em) -> list:
    """The D calls whose lines reached the screen (a D held for the verdict and then dropped never does)."""
    ids = {e["id"] for e in em.of("delta") if e["tier"] == "D"}
    return [c for c in b.calls if c.tier == "D" and c.id in ids]


def tail_of(c) -> str:
    return c.request["messages"][-1]["content"][-1]["text"]


# ---------------------------------------------------------------- the instruction

def test_fast_tail_carries_the_bank_check_only_with_a_hit():
    async def go():
        b, t, em = make(fast("BANK: b001"))
        await start(b)
        await b.handle({"type": "bank_hit", "turn_id": "q1", "bank_id": "b001", "score": 0.7})
        await turn(b, "q1", Q, kind="question")
        await settle(b)
        await turn(b, "q2", "What is the weather like in Turin today", kind="question")
        await settle(b)
        return t

    t = run(go())
    f = t.by_route("F")
    hit, plain = f[0].tail, f[1].tail
    assert "BANK CHECK" in hit and "[b001]" in hit
    assert "Can you tell me about yourself?" in hit and "Walk us through your background." in hit   # question + paraphrases
    assert hit.index("BANK CHECK") < hit.index("CURRENT QUESTION")
    assert "BANK CHECK" not in plain


def test_bank_check_block_names_the_entry_and_its_phrasings():
    rec = load_session(FIX).bank["b001"]
    block = bank_check(rec, "en")
    assert "BANK: b001" in block and "BANK: none" in block
    assert "- Can you tell me about yourself?" in block and "- Walk us through your background." in block
    assert "cut off" in bank_check(rec, "en", final=False) and "cut off" not in block   # S on a partial
    assert bank_check(None, "en") == ""


# ---------------------------------------------------------------- positive / negative / missing, lexical hit

def test_positive_verdict_keeps_the_card_and_the_deep_answer():
    b, t, em = run(ask(fast("BANK: b001")))
    assert em.of("bank_verdict", turn_id="q1", bank_id="b001", agree=True)
    assert b.ts["q1"].bank_hit is not None
    (d,) = d_tails(t)
    assert "PREPARED DEEP ANSWER [b001]" in d


def test_negative_verdict_on_a_lexical_hit_withdraws_the_card():
    b, t, em = run(ask(fast("BANK: none")))
    (v,) = em.of("bank_verdict", turn_id="q1")
    assert v["bank_id"] == "b001" and v["agree"] is False
    assert b.ts["q1"].bank_hit is None, "a lexical hit is dropped like a paraphrase hit"
    (d,) = [tail_of(c) for c in shown_d(b, em)]
    assert "PREPARED DEEP ANSWER" not in d, "D answers from the grounding, not from the rejected entry"
    assert "OPENER ALREADY SHOWN: Mostly I build LLM tools for logistics." in d   # F's own SAY, not the bank opener guess


def test_negative_verdict_with_the_bank_line_last_still_reaches_d_in_time():
    """An S call fired before the hit (no BANK CHECK) writes the BANK line last: D waits for it."""
    b, t, em = run(ask(fast("BANK: none", first=False, delay=0.01)))
    assert em.of("bank_verdict", turn_id="q1", agree=False)
    (d,) = [tail_of(c) for c in shown_d(b, em)]
    assert "PREPARED DEEP ANSWER" not in d


def test_missing_verdict_withdraws_the_card():
    b, t, em = run(ask(fast(None)))
    (v,) = em.of("bank_verdict", turn_id="q1")
    assert v["agree"] is False and v.get("reason") == "missing"
    assert b.ts["q1"].bank_hit is None
    (d,) = shown_d(b, em)
    assert "PREPARED DEEP ANSWER" not in tail_of(d)


def test_failed_fast_call_gives_no_verdict_and_keeps_the_card():
    def responder(info):
        if info.route in ("S", "F") and "CURRENT QUESTION" in info.tail:
            return Script(error=Offline("down"))
        return default_responder(info)

    b, t, em = run(ask(responder))
    assert not em.of("bank_verdict")
    assert b.ts["q1"].bank_hit is not None and b.ts["q1"].bank_hit.bank_id == "b001"


def test_rejected_entry_sent_again_is_ignored():
    """Swift re-sends a hit when its score moves by 0.08: the entry the verdict rejected must not come back for the turn."""
    async def go():
        b, t, em = make(fast("BANK: none"))
        await start(b)
        await b.handle({"type": "bank_hit", "turn_id": "q1", "bank_id": "b001", "score": 0.7})
        await turn(b, "q1", Q, kind="question")
        await settle(b)
        await b.handle({"type": "bank_hit", "turn_id": "q1", "bank_id": "b001", "score": 0.8})
        await settle(b)
        return b, em

    b, em = run(go())
    assert b.ts["q1"].bank_hit is None
    assert len(em.of("bank_verdict", turn_id="q1")) == 1


def test_early_d_built_on_a_rejected_entry_is_not_shown():
    async def go():
        b, t, em = make(fast("BANK: none", first=False, delay=0.02), d_stable_s=0.05)
        await start(b)
        await b.handle({"type": "bank_hit", "turn_id": "q1", "bank_id": "b001", "score": 0.7})
        await partial(b, "q1", Q)
        await asyncio.sleep(0.3)                 # the early D fires on the stable partial, with the entry in its tail
        await turn(b, "q1", Q, kind="question")
        await settle(b)
        return b, t, em

    b, t, em = run(go())
    tails = d_tails(t)
    assert len(tails) == 2 and "PREPARED DEEP ANSWER [b001]" in tails[0]
    assert "PREPARED DEEP ANSWER" not in tails[1]
    shown = {e["id"] for e in em.of("delta") if e["tier"] == "D"}
    early = [c for c in b.calls if c.tier == "D"][0]
    assert early.discarded and early.id not in shown


# ---------------------------------------------------------------- the paraphrase (embedding) hit gets the same treatment

def test_negative_verdict_on_a_paraphrase_hit():
    b, t, em = run(ask(fast("BANK: none"), via_embed=True))
    assert em.of("bank_verdict", turn_id="q1", bank_id="b001", agree=False)
    assert b.ts["q1"].bank_hit is None
    (d,) = shown_d(b, em)
    assert "PREPARED DEEP ANSWER" not in tail_of(d)


def test_positive_verdict_on_a_paraphrase_hit():
    b, t, em = run(ask(fast("BANK: b001"), via_embed=True))
    assert em.of("bank_verdict", turn_id="q1", bank_id="b001", agree=True)
    assert "PREPARED DEEP ANSWER [b001]" in d_tails(t)[0]


# ---------------------------------------------------------------- which call's BANK line is the verdict (engine `_verdict_src`)
#
# A verdict counts only from a call that saw (a) the BANK CHECK of the hit's entry and (b) the text the turn ended with (or that
# text plus trailing fillers, `verdict_text_ok`). The selected S card that does not qualify still shows at once; a hidden verdict
# check V (the F request of the final text, cut after its first line) decides instead.

from verse_brain.runtime.engine import verdict_text_ok  # noqa: E402
from verse_brain.runtime.settings import Config  # noqa: E402
from verse_brain.runtime.transport import Overloaded  # noqa: E402

V_MAX = Config().verdict_check_max_tokens


def is_check(info) -> bool:
    return info.route == "V"


def by_call(s_body: str, v_body: str | Script | None = "BANK: none\nSAY: x", f_body: str | None = None):
    """S answers `s_body`, the verdict check V `v_body` (a Script for errors), F `f_body` (default canned)."""
    def responder(info):
        if info.route in ("S", "F", "V") and "CURRENT QUESTION" in info.tail and "STATEMENT CHECK" not in info.tail:
            if info.route == "S":
                return lines_script(s_body)
            if is_check(info):
                return v_body if isinstance(v_body, Script) else lines_script(v_body)
            if f_body is not None:
                return lines_script(f_body)
        return default_responder(info)
    return responder


def checks(b) -> list:
    return [c for c in b.calls if c.tier == "V"]


async def s_then_turn(responder, partial_text: str, final_text: str, *, hit_before_partial: bool):
    b, t, em = make(responder)
    await start(b)
    if hit_before_partial:
        await b.handle({"type": "bank_hit", "turn_id": "q1", "bank_id": "b001", "score": 0.7})
    await partial(b, "q1", partial_text)
    await asyncio.sleep(0.05)                    # the S call on the partial is done before the turn ends
    if not hit_before_partial:
        await b.handle({"type": "bank_hit", "turn_id": "q1", "bank_id": "b001", "score": 0.7})
    await turn(b, "q1", final_text, kind="question")
    await settle(b)
    return b, t, em


S_AGREES = f"SAY: Mostly I build LLM tools.\n- I led Lantern.\n- It cut entry to 2 minutes.\nBANK: b001"
S_REJECTS = f"BANK: none\n{CARD}"


def test_s_fired_before_the_hit_does_not_confirm_the_card():
    """hn07: the selected S never saw the BANK CHECK, so its BANK line (here agreeing) is no verdict: V decides (here: none)."""
    b, t, em = run(s_then_turn(by_call(S_AGREES, "BANK: none\nSAY: x"), Q, Q, hit_before_partial=False))
    (sel,) = em.of("select", turn_id="q1")
    s = next(c for c in b.calls if c.id == sel["id"])
    assert s.tier == "S" and s.check_id is None and s.bank_id == "b001"
    (v,) = em.of("bank_verdict", turn_id="q1")
    assert v["agree"] is False, "the S line agreed, but S did not see the check: V's `none` is the verdict"
    assert b.ts["q1"].bank_hit is None
    (chk,) = checks(b)
    assert chk.check_id == "b001" and chk.input_text == Q
    (d,) = shown_d(b, em)
    assert "PREPARED DEEP ANSWER" not in tail_of(d), "the D shown is the one fired after V's `none`, without the entry"


def test_verdict_check_is_the_f_request_cut_short_and_the_card_is_not_delayed():
    b, t, em = run(s_then_turn(by_call(S_AGREES, "BANK: b001\nSAY: x"), Q, Q, hit_before_partial=False))
    (info,) = [c for c in t.calls if is_check(c)]
    assert info.request["max_tokens"] == V_MAX and not [c for c in t.by_route("F")], "V is the only F-shaped request"
    assert "BANK CHECK" in info.tail and "[b001]" in info.tail
    assert info.tail.rstrip().endswith(f"CURRENT QUESTION (finished): {Q}")
    s_id = em.of("select", turn_id="q1")[0]["id"]
    first_s = next(i for i, e in enumerate(em.events) if e["type"] == "delta" and e.get("id") == s_id)
    verdict = next(i for i, e in enumerate(em.events) if e["type"] == "bank_verdict")
    assert first_s < verdict, "the S card is on screen before the verdict check answers"
    assert not [e for e in em.events if e["type"] == "delta" and e.get("tier") == "V"], "V is never shown"
    assert em.of("bank_verdict", turn_id="q1", agree=True)


def test_s_on_a_cut_off_partial_does_not_pull_the_card():
    """A true paraphrase judged on a prefix: the S saw the check but not the question. Its `none` must not pull the card."""
    partial_text, final_text = "Can you tell me about", "Can you tell me about yourself please"
    b, t, em = run(s_then_turn(by_call(S_REJECTS, "BANK: b001\nSAY: x"), partial_text, final_text, hit_before_partial=True))
    s = next(c for c in b.calls if c.id == em.of("select", turn_id="q1")[0]["id"])
    assert s.check_id == "b001" and s.bank_id == "none"
    (v,) = em.of("bank_verdict", turn_id="q1")
    assert v["agree"] is True
    assert b.ts["q1"].bank_hit is not None
    assert len(checks(b)) == 1 and checks(b)[0].input_text == final_text


def test_s_on_the_final_text_plus_fillers_is_the_verdict_and_no_check_runs():
    b, t, em = run(s_then_turn(by_call(S_REJECTS, "BANK: b001\nSAY: x"), Q, Q + ", thank you.", hit_before_partial=True))
    assert not checks(b), "a qualifying S needs no second fast call"
    (v,) = em.of("bank_verdict", turn_id="q1")
    assert v["agree"] is False                   # S's own `none`
    assert b.ts["q1"].bank_hit is None


def test_f_with_the_check_is_the_verdict_and_no_check_runs():
    b, t, em = run(ask(fast("BANK: b001")))
    assert not checks(b)
    assert em.of("bank_verdict", turn_id="q1", agree=True)


def test_hit_after_f_was_fired_gets_a_check():
    """Swift's hit lands right after the turn, after F was launched without the check but before D was decided: F's BANK
    line (written against the whole answer bank, not this entry's phrasings) is no verdict; V decides."""
    async def go():
        b, t, em = make(by_call(S_AGREES, "BANK: none\nSAY: x", f_body=S_AGREES))
        await start(b)
        await turn(b, "q1", Q, kind="question")
        await b.handle({"type": "bank_hit", "turn_id": "q1", "bank_id": "b001", "score": 0.7})
        await settle(b)
        return b, t, em

    b, t, em = run(go())
    assert b.ts["q1"].fast.tier == "F" and b.ts["q1"].fast.bank_id == "b001" and b.ts["q1"].fast.check_id is None
    (v,) = em.of("bank_verdict", turn_id="q1")
    assert v["agree"] is False
    assert len(checks(b)) == 1
    (d,) = shown_d(b, em)
    assert "PREPARED DEEP ANSWER" not in tail_of(d)


def test_hit_after_the_turn_was_answered_and_d_decided_needs_no_check():
    """The final-text pass lands after F answered and D was fired without the entry: nothing left to confirm or pull."""
    async def go():
        b, t, em = make(by_call(S_AGREES, "BANK: none\nSAY: x", f_body=S_AGREES))
        await start(b)
        await turn(b, "q1", Q, kind="question")
        await settle(b)
        b._embed_hit(b.ts["q1"], "b001", 0.93)
        await settle(b)
        return b, t, em

    b, t, em = run(go())
    assert not checks(b) and not em.of("bank_verdict")
    assert em.of("metric", stage="verdict_check", why="moot", launched=False)
    assert len(t.by_route("D")) == 1


def test_failed_check_gives_no_verdict_and_keeps_the_card():
    b, t, em = run(s_then_turn(by_call(S_REJECTS, Script(error=Offline("down"))), Q, Q, hit_before_partial=False))
    assert len(checks(b)) == 1 and checks(b)[0].error is not None
    assert not em.of("bank_verdict"), "S's `none` is no verdict and V failed: nothing confirms or pulls the card"
    assert b.ts["q1"].bank_hit is not None
    assert d_tails(t), "D still runs once V is over"


def test_overloaded_check_gives_no_verdict():
    b, t, em = run(s_then_turn(by_call(S_REJECTS, Script(error=Overloaded("busy"))), Q, Q, hit_before_partial=False))
    assert not em.of("bank_verdict") and b.ts["q1"].bank_hit is not None


def test_check_cut_off_before_its_bank_line_gives_no_verdict():
    v = lines_script("SAY: Mostly I build LLM tools for", stop_reason="max_tokens")
    b, t, em = run(s_then_turn(by_call(S_REJECTS, v), Q, Q, hit_before_partial=False))
    assert not em.of("bank_verdict") and b.ts["q1"].bank_hit is not None


def test_verdict_text_rule():
    q = "How much did it cost to run?"
    assert verdict_text_ok(q, q)
    assert verdict_text_ok("how much did it cost to run", "How much did it cost to run?")          # case, punctuation
    assert verdict_text_ok(q, "How much did it cost to run, please?")
    assert verdict_text_ok(q, "How much did it cost to run? Thank you. Um")
    assert verdict_text_ok("Quanto è costato", "Quanto è costato, per favore?")
    assert verdict_text_ok("Ne kadar tuttu", "Ne kadar tuttu acaba?")
    assert not verdict_text_ok("How much did it cost to", q), "a cut-off prefix is another question"
    assert not verdict_text_ok("How much did it cost", "How much did it cost to hire the team?")
    assert not verdict_text_ok("Did you turn left or", "Did you turn left or right?")
    assert not verdict_text_ok("What does it cost", "What does it cost now?")
    assert not verdict_text_ok(q, "How much did it cost to run it")
    assert not verdict_text_ok("How much did it cost to run", "How much did the team cost to run")   # a revised word
    assert not verdict_text_ok(q, "How much did it cost")                                          # the final got shorter
    assert not verdict_text_ok("", q)


def test_card_call_cut_off_before_its_bank_line_gives_no_verdict():
    """max_tokens is no decision: a qualifying F that stops there without a BANK line neither confirms nor pulls the card."""
    def responder(info):
        if info.route == "F" and "CURRENT QUESTION" in info.tail:
            return lines_script(CARD, stop_reason="max_tokens")
        return default_responder(info)

    b, t, em = run(ask(responder))
    assert not em.of("bank_verdict") and b.ts["q1"].bank_hit is not None


# ---------------------------------------------------------------- D does not wait for the verdict: it is fired at once and held

def slow_v(v_line: str, delay: float = 0.3, error=None):
    """S fired before the hit (so V decides); V's BANK line comes after `delay`; D answers at once."""
    def responder(info):
        if info.route == "S" and "CURRENT QUESTION" in info.tail:
            return lines_script(S_AGREES)
        if info.route == "V":
            return Script(first_byte_delay=delay, error=error) if error else lines_script(f"{v_line}\nSAY: x", first_byte_delay=delay)
        return default_responder(info)
    return responder


def timeline(b, t, em):
    d_calls = [c for c in b.calls if c.tier == "D"]
    d_open = [i.t_open for i in t.by_route("D")]
    vt = [tm for e, tm in zip(em.events, em.times) if e["type"] == "bank_verdict"]
    first_d_delta = [tm for e, tm in zip(em.events, em.times) if e["type"] == "delta" and e["tier"] == "D"]
    return d_calls, d_open, (vt[0] if vt else None), (min(first_d_delta) if first_d_delta else None)


def test_agree_d_starts_before_the_verdict_and_is_shown_after_it():
    b, t, em = run(s_then_turn(slow_v("BANK: b001"), Q, Q, hit_before_partial=False))
    d_calls, d_open, vt, first_d = timeline(b, t, em)
    assert em.of("bank_verdict", agree=True)
    assert len(d_calls) == 1, "one D: no refire on agreement"
    assert "PREPARED DEEP ANSWER [b001]" in tail_of(d_calls[0])
    assert d_open[0] < vt, "D was fired before the verdict, not after it"
    assert first_d is not None and first_d >= vt, "nothing of the held D reached the screen before the verdict"
    assert em.of("metric", stage="d_speculative") and em.of("metric", stage="d_confirmed", held=True)


def test_reject_discards_the_held_d_and_refires_it_without_the_entry():
    b, t, em = run(s_then_turn(slow_v("BANK: none"), Q, Q, hit_before_partial=False))
    d_calls, d_open, vt, first_d = timeline(b, t, em)
    assert em.of("bank_verdict", agree=False)
    assert len(d_calls) == 2
    held, again = d_calls
    assert "PREPARED DEEP ANSWER [b001]" in tail_of(held) and held.discarded
    assert "PREPARED DEEP ANSWER" not in tail_of(again) and not again.discarded
    assert d_open[0] < vt <= d_open[1]
    assert {c.id for c in shown_d(b, em)} == {again.id}, "the held D never reached the screen"
    assert em.of("metric", stage="d_refired")


def test_no_verdict_in_time_releases_the_held_d_at_the_timeout():
    async def go():
        b, t, em = make(slow_v("BANK: none", delay=0.6), bank_verdict_wait_s=0.15)
        await start(b)
        await partial(b, "q1", Q)
        await asyncio.sleep(0.05)
        await b.handle({"type": "bank_hit", "turn_id": "q1", "bank_id": "b001", "score": 0.7})
        t_turn = time.monotonic()
        await turn(b, "q1", Q, kind="question")
        await settle(b)
        return b, t, em, t_turn

    b, t, em, t_turn = run(go())
    d_calls, d_open, vt, first_d = timeline(b, t, em)
    assert len(d_calls) == 1 and "PREPARED DEEP ANSWER [b001]" in tail_of(d_calls[0])
    assert first_d - t_turn >= 0.14, "held until the wait ran out"
    assert vt is not None and first_d < vt, "released at the timeout, before the late verdict, as today"
    assert em.of("metric", stage="d_confirmed", held=True, verdict=False)


def test_failed_check_releases_the_held_d_with_the_entry():
    b, t, em = run(s_then_turn(slow_v("", delay=0.1, error=Offline("down")), Q, Q, hit_before_partial=False))
    d_calls, *_ = timeline(b, t, em)
    assert not em.of("bank_verdict")
    assert len(d_calls) == 1 and [c.id for c in shown_d(b, em)] == [d_calls[0].id]
    assert "PREPARED DEEP ANSWER [b001]" in tail_of(d_calls[0])


def test_strong_lexical_hit_still_waits_for_the_verdict():
    """An agreeing verdict on a strong lexical hit skips D: firing it speculatively would waste the Sonnet call."""
    async def go():
        b, t, em = make(slow_v("BANK: b001"))
        await start(b)
        await partial(b, "q1", Q)
        await asyncio.sleep(0.05)
        await b.handle({"type": "bank_hit", "turn_id": "q1", "bank_id": "b001", "score": 0.95})
        await turn(b, "q1", Q, kind="question")
        await settle(b)
        return b, t, em

    b, t, em = run(go())
    assert em.of("bank_verdict", agree=True)
    assert not t.by_route("D") and em.of("metric", stage="d_skipped", bank_id="b001")


# ---------------------------------------------------------------- prefer_bank: the fit is judged before and apart from the prepared card

def test_prefer_bank_tail_puts_the_check_before_the_prepared_answer(tmp_path):
    import json as _json
    from test_runtime_helpers import session_copy
    d = session_copy(tmp_path)
    (d / "call.json").write_text(_json.dumps({"prefer_bank": True}))

    async def go():
        b, t, em = make(fast("BANK: b001"))
        await start(b, d)
        await b.handle({"type": "bank_hit", "turn_id": "q1", "bank_id": "b001", "score": 0.7})
        await turn(b, "q1", Q, kind="question")
        await settle(b)
        return t

    t = run(go())
    (f,) = t.by_route("F")
    tail, system = f.tail, str(f.request["system"])
    assert tail.index("BANK CHECK") < tail.index("PREPARED ANSWER [b001]") < tail.index("CURRENT QUESTION")
    assert "PREPARED ANSWER block below is not part of this decision" in tail
    assert "plays no part in the BANK CHECK" in tail
    assert "applies only after the BANK line is written" in system


def test_bank_check_without_prefer_bank_is_unchanged():
    rec = load_session(FIX).bank["b001"]
    assert "PREPARED ANSWER" not in bank_check(rec, "en") and "PREPARED ANSWER" in bank_check(rec, "en", prepared=True)
