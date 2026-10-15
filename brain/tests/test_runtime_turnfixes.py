"""V2 turn-handling fixes (synthetic fixtures only).

1. Sentinel lines ("NONE", "SAY: NONE", "- none", "N/A", "SKIP" ...) a model writes for "nothing to say" never reach
   Swift as delta text, on any tier.
2. A bank hit that lands after the turn was closed as statement/fragment re-evaluates the turn (short window, one
   answer).
3. (Swift side, see app/Tests/VerseTurnsTests/TurnFixesTests.swift) topic chips and brain bank hits.
"""

from __future__ import annotations

import asyncio

import pytest
from test_runtime_helpers import DEEP_OK, FAST_OK, lines_script, make, partial, run, settle, start, turn

from verse_brain.runtime.lines import LineAssembler, is_sentinel

STATEMENT = "i will be taking notes during the call, i hope that is not distracting"


def probe_or(probe_body: str, fast_body: str = FAST_OK, deep_body: str = DEEP_OK):
    def responder(info):
        if info.route == "D":
            return lines_script(deep_body)
        if "STATEMENT CHECK" in info.tail:
            return lines_script(probe_body)
        return lines_script(fast_body)
    return responder


def shown(em, tier=None) -> list[str]:
    """Display lines the app assembles from the deltas (a line ends at line_done)."""
    out: dict[str, str] = {}
    done: list[str] = []
    for e in em.of("delta"):
        if tier and e["tier"] != tier:
            continue
        out[e["id"]] = out.get(e["id"], "") + e["text"]
        if e["line_done"]:
            done.append(out.pop(e["id"]).strip())
    done += [v.strip() for v in out.values() if v.strip()]
    return done


def all_text(em) -> str:
    return "\n".join(e["text"] for e in em.of("delta"))


def has_sentinel(em) -> bool:
    return any(is_sentinel(x) for x in shown(em)) or "NONE" in all_text(em).upper().split()


# ---------------------------------------------------------------- bug 1: the helper
@pytest.mark.parametrize("line", ["NONE", "none", "None.", "SAY: NONE", "SAY: none.", "- NONE", "- None", "N/A", "SAY: N/A",
                                  "(none)", "[NONE]", "SKIP", "  none  ", "SAY:  NONE ", "`none`", "null"])
def test_is_sentinel_true(line):
    assert is_sentinel(line)


@pytest.mark.parametrize("line", ["None of my projects failed.", "SAY: None of that was my call.", "- No, we kept it simple.",
                                  "SAY: No problem at all.", "Skip the slides, I'll explain.", "SAY: Sure, go ahead.", "- Nothing blocked us.",
                                  "NONE: no wait", "", "SAY:", "-", "I handled none of the billing."])
def test_is_sentinel_false(line):
    assert not is_sentinel(line)


def feed_chunks(chunks: list[str], hold_first_line=False):
    texts, controls, dropped = [], [], []
    a = LineAssembler(lambda c, d, ln: texts.append((c, d, ln)), controls.append, hold_first_line, on_sentinel=dropped.append)
    for c in chunks:
        a.feed(c)
    a.close()
    return texts, controls, dropped


def test_assembler_holds_a_line_that_may_become_a_sentinel_and_drops_it():
    # word by word, the way the model streams; not one chunk may carry any part of the sentinel
    for chunks in (["NO", "NE", "\n"], ["N", "ONE", "\n"], ["SAY:", " NONE", "\n"], ["SAY:", " no", "ne.", "\n"], ["-", " None", "\n"],
                   ["N/", "A"], ["(", "none", ")", "\n"]):
        texts, controls, dropped = feed_chunks(chunks)
        assert texts == [], chunks
        assert len(dropped) == 1, chunks


def test_assembler_releases_a_held_line_that_turns_out_to_be_text():
    texts, _, dropped = feed_chunks(["SAY:", " No", ",", " not", " yet", "\n"])
    assert not dropped
    assert "".join(c for c, _, _ in texts) == "SAY: No, not yet"
    assert [d for _, d, _ in texts].count(True) == 1 and texts[-1][1] is True
    texts, _, dropped = feed_chunks(["None", " of", " it", " broke", "\n"])
    assert not dropped and "".join(c for c, _, _ in texts) == "None of it broke"
    # a held line that ends as a short real answer is still delivered
    texts, _, dropped = feed_chunks(["SAY:", " No", "\n"])
    assert not dropped and "".join(c for c, _, _ in texts) == "SAY: No"


def test_assembler_sentinel_between_real_lines():
    texts, controls, dropped = feed_chunks(["SAY: Sure.\n", "NONE\n", "- A point.\n", "BANK: none\n"])
    assert [ln for _, d, ln in texts if d] == ["SAY: Sure.", "- A point."]
    assert controls == ["BANK: none"] and dropped == ["NONE"]


def test_assembler_hold_first_line_drops_a_sentinel_first_line():
    texts, controls, dropped = feed_chunks(["NONE\n", "- A point.\n"], hold_first_line=True)
    assert dropped == ["NONE"]
    assert [ln for _, d, ln in texts if d] == ["- A point."]


# ---------------------------------------------------------------- bug 1: through the brain
STATEMENT_BODIES = [
    "KIND: statement\nSAY: NONE",
    "KIND: statement\nSAY: none.",
    "KIND: statement\nNONE",
    "NONE",
    "SAY: NONE",
    "KIND: statement\nSAY: N/A",
]


@pytest.mark.parametrize("body", STATEMENT_BODIES)
def test_statement_probe_never_shows_a_sentinel(body):
    async def go():
        b, t, em = make(probe_or(body))
        await start(b)
        await turn(b, "s1", STATEMENT, kind="statement")
        await settle(b)
        return em

    em = run(go())
    assert not has_sentinel(em), shown(em)
    assert not em.of("delta")
    assert em.of("metric", stage="statement_no_reply", turn_id="s1")


@pytest.mark.parametrize("fast", ["NONE", "SAY: NONE\nBANK: none", "NONE\nBANK: none", "SAY: none.\n- NONE\n- None\nBANK: none",
                                  "SKIP\nBANK: none"])
def test_question_answer_never_shows_a_sentinel(fast):
    async def go():
        b, t, em = make(probe_or("KIND: question", fast_body=fast))
        await start(b)
        await turn(b, "q1", "what did the pilot achieve?", kind="question")
        await settle(b)
        return em

    em = run(go())
    assert not has_sentinel(em), shown(em)
    assert not any(is_sentinel(x) for x in shown(em, "F"))


def test_question_answer_keeps_real_lines_around_a_sentinel():
    fast = "SAY: Sure, here is the short version.\nNONE\n- I led Lantern.\n- None\nBANK: none"

    async def go():
        b, t, em = make(probe_or("KIND: question", fast_body=fast))
        await start(b)
        await turn(b, "q1", "what did the pilot achieve?", kind="question")
        await settle(b)
        return em

    em = run(go())
    assert shown(em, "F") == ["SAY: Sure, here is the short version.", "- I led Lantern."]


def test_escalated_statement_never_shows_a_sentinel():
    async def go():
        b, t, em = make(probe_or("KIND: question\nSAY: Sure, here is the short version.\nNONE\n- I led Lantern.\nBANK: none"))
        await start(b)
        await turn(b, "s1", "walk me through the pilot", kind="statement")
        await settle(b)
        return em

    em = run(go())
    assert not has_sentinel(em), shown(em)
    assert shown(em, "F") == ["SAY: Sure, here is the short version.", "- I led Lantern."]


def test_deep_tier_never_shows_a_sentinel():
    deep = "NONE\n- Lantern ran on supplier invoices (prep:L13)\nNONE\n- None"

    async def go():
        b, t, em = make(probe_or("KIND: question", deep_body=deep))
        await start(b)
        await turn(b, "q1", "what did the pilot achieve?", kind="question")
        await settle(b)
        return em

    em = run(go())
    assert shown(em, "D") == ["- Lantern ran on supplier invoices (prep:L13)"]


def test_speculative_answer_never_shows_a_sentinel():
    async def go():
        b, t, em = make(probe_or("KIND: question", fast_body="SAY: NONE\nBANK: none"))
        await start(b)
        for text in ("what did the pilot", "what did the pilot achieve at the"):
            await partial(b, "q1", text)
            await asyncio.sleep(0.4)
        await turn(b, "q1", "what did the pilot achieve at the depot?", kind="question")
        await settle(b)
        return em

    em = run(go())
    assert not has_sentinel(em), shown(em)


def test_real_answers_starting_with_none_or_no_are_untouched():
    fast = "SAY: None of the pilots failed.\n- No, we did not drop any depot.\n- Skip tracing took two minutes.\nBANK: none"

    async def go():
        b, t, em = make(probe_or("KIND: question", fast_body=fast))
        await start(b)
        await turn(b, "q1", "did any pilot fail?", kind="question")
        await settle(b)
        return em

    em = run(go())
    assert shown(em, "F") == ["SAY: None of the pilots failed.", "- No, we did not drop any depot.",
                              "- Skip tracing took two minutes."]


# ---------------------------------------------------------------- bug 2: a bank hit after the turn closed
from test_runtime_embed import FAST_B001, PARA, FakeEmbedder, embed_hits, fast_responder  # noqa: E402
from test_runtime_embed import idle as embed_idle  # noqa: E402
from test_runtime_embed import make as embed_make  # noqa: E402
from test_runtime_embed import partial as embed_partial  # noqa: E402
from test_runtime_embed import start as embed_start  # noqa: E402

QUESTION_TEXT = "How did you end up where you are"


def late_responder(probe_body: str = "KIND: statement\nSAY: Thanks, noted.", probe_delay: float = 0.0):
    base = fast_responder(FAST_B001)

    def responder(info):
        if "STATEMENT CHECK" in info.tail:
            return lines_script(probe_body, first_byte_delay=probe_delay)
        if info.route == "D":
            return lines_script(DEEP_OK)
        return base(info)
    return responder


async def two_partials_then_turn(b, kind, delay_note=True, addressee="me"):
    """Two cued partials (the second one's embedding job is still running when the turn arrives), then the turn."""
    await embed_partial(b, "q1", "How did you end up where")
    await embed_idle(b)
    await embed_partial(b, "q1", QUESTION_TEXT)
    await asyncio.sleep(0.05)                  # job 2 is running (FakeEmbedder delay)
    await b.handle({"type": "turn", "turn_id": "q1", "speaker": "remote", "text": QUESTION_TEXT, "addressee": addressee,
                    "kind": kind, "t_audio_end": 0.0})


def f_calls(t):
    return [c for c in t.by_route("F")]


@pytest.mark.parametrize("kind", ["fragment", "statement"])
def test_late_embed_hit_answers_a_turn_closed_as_fragment_or_statement(kind):
    async def go():
        fe = FakeEmbedder(PARA, delay=0.3)
        b, t, em = embed_make(fe, late_responder(probe_delay=0.6))
        await embed_start(b)
        await two_partials_then_turn(b, kind)
        await embed_idle(b)
        await settle(b)
        return b, t, em

    b, t, em = run(go())
    assert len(embed_hits(em)) == 1 and embed_hits(em)[0]["turn_id"] == "q1"
    assert em.of("metric", stage="late_hit_rescue", turn_id="q1")
    answers = [c for c in f_calls(t) if "STATEMENT CHECK" not in c.tail]
    assert len(answers) == 1, "exactly one answer"
    assert shown(em, "F") == ["SAY: Sure, here is the short version.", "- I led Lantern.", "- It cut entry to 2 minutes."]
    assert "Thanks, noted." not in all_text(em), "no acknowledgement next to the answer"
    assert em.of("bank_verdict", turn_id="q1", agree=True)
    assert len(t.by_route("D")) == 1


def test_late_hit_after_the_probe_escalated_does_not_answer_twice():
    async def go():
        fe = FakeEmbedder(PARA, delay=0.3)
        resp = late_responder("KIND: question\nSAY: Sure, here is the short version.\n- I led Lantern.\n- It cut entry to 2 minutes.\nBANK: b001")
        b, t, em = embed_make(fe, resp)
        await embed_start(b)
        await two_partials_then_turn(b, "statement")
        await embed_idle(b)
        await settle(b)
        return t, em

    t, em = run(go())
    assert len(f_calls(t)) == 1, "the probe is the answer"
    assert not em.of("metric", stage="late_hit_rescue")
    assert len(t.by_route("D")) == 1


def test_late_hit_after_an_acknowledgement_was_shown_does_not_add_a_second_answer():
    async def go():
        fe = FakeEmbedder(PARA, delay=0.5)
        b, t, em = embed_make(fe, late_responder("KIND: statement\nSAY: Thanks, noted."))
        await embed_start(b)
        await two_partials_then_turn(b, "statement")
        await embed_idle(b)
        await settle(b)
        return t, em

    t, em = run(go())
    assert len(f_calls(t)) == 1
    assert shown(em, "F") == ["SAY: Thanks, noted."]
    assert em.of("metric", stage="late_hit_ignored", reason="ack_shown")


def test_late_hit_outside_the_window_is_ignored():
    async def go():
        fe = FakeEmbedder(PARA, delay=0.3)
        b, t, em = embed_make(fe, late_responder())
        b.late_hit_window_s = 0.1
        await embed_start(b)
        await two_partials_then_turn(b, "fragment")
        await embed_idle(b)
        await settle(b)
        return t, em

    t, em = run(go())
    assert not f_calls(t) and not em.of("delta")
    assert em.of("metric", stage="late_hit_ignored", reason="window")


def test_late_hit_is_ignored_once_a_newer_turn_started():
    async def go():
        fe = FakeEmbedder(PARA, delay=0.3)
        b, t, em = embed_make(fe, late_responder())
        await embed_start(b)
        await two_partials_then_turn(b, "fragment")
        await b.handle({"type": "partial", "turn_id": "q2", "speaker": "remote", "text": "okay and", "cue": False, "t_audio_end": 0.0})
        await embed_idle(b)
        await settle(b)
        return t, em

    t, em = run(go())
    assert not f_calls(t) and not em.of("delta")
    assert em.of("metric", stage="late_hit_ignored", reason="newer_turn")


def test_late_hit_is_ignored_when_the_turn_is_for_someone_else():
    async def go():
        fe = FakeEmbedder(PARA, delay=0.3)
        b, t, em = embed_make(fe, late_responder())
        await embed_start(b)
        await two_partials_then_turn(b, "fragment", addressee="other")
        await embed_idle(b)
        await settle(b)
        return t, em

    t, em = run(go())
    assert not f_calls(t) and not em.of("delta")


@pytest.mark.parametrize("kind", ["fragment", "statement"])
def test_late_swift_bank_hit_answers_once(kind):
    async def go():
        b, t, em = make(late_responder(probe_delay=0.4))
        await start(b)
        await turn(b, "q1", QUESTION_TEXT, kind=kind)
        await b.handle({"type": "bank_hit", "turn_id": "q1", "bank_id": "b001", "score": 0.7})
        await b.handle({"type": "bank_hit", "turn_id": "q1", "bank_id": "b002", "score": 0.7})   # a second hit: no second answer
        await settle(b)
        return t, em

    t, em = run(go())
    answers = [c for c in f_calls(t) if "STATEMENT CHECK" not in c.tail]
    assert len(answers) == 1
    assert shown(em, "F")[0] == "SAY: Sure, here is the short version."
    assert "Thanks, noted." not in all_text(em)
