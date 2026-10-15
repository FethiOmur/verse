"""Final-text embedding pass (V2 follow-up): when a remote turn closes with no bank hit yet, the brain runs one embedding
match on the final text. A hit goes through the existing `_late_hit` path: a statement/fragment turn is answered once.
Synthetic fixtures only (fake embedder, fake transport)."""

from __future__ import annotations

import pytest
from test_runtime_embed import PARA, FakeEmbedder, embed_hits, idle
from test_runtime_embed import make as embed_make
from test_runtime_embed import partial as embed_partial
from test_runtime_embed import start as embed_start
from test_runtime_helpers import run, settle
from test_runtime_turnfixes import QUESTION_TEXT, all_text, f_calls, late_responder, shown

ANSWER = ["SAY: Sure, here is the short version.", "- I led Lantern.", "- It cut entry to 2 minutes."]


async def close_turn(b, tid: str, text: str, kind: str, addressee: str = "me") -> None:
    await b.handle({"type": "turn", "turn_id": tid, "speaker": "remote", "text": text, "addressee": addressee,
                    "kind": kind, "t_audio_end": 0.0})


def answers(t) -> list:
    return [c for c in f_calls(t) if "STATEMENT CHECK" not in c.tail]


@pytest.mark.parametrize("kind", ["statement", "fragment"])
def test_final_text_rescues_a_turn_whose_partials_never_matched(kind):
    """No cue on any partial (nothing was ever embedded), the turn closes as statement/fragment, the final text matches
    a prepared question: answered exactly once, no acknowledgement next to it."""
    async def go():
        fe = FakeEmbedder(PARA, delay=0.2)
        b, t, em = embed_make(fe, late_responder(probe_delay=0.8))
        await embed_start(b)
        for text in ("so", "so how did you", "so how did you end up where you are"):
            await embed_partial(b, "q1", text, cue=False)         # cue never set: the partial path never queues a job
        assert fe.queries == [], "the partials were not embedded"
        await close_turn(b, "q1", QUESTION_TEXT, kind)
        await idle(b)
        await settle(b)
        return b, t, em, fe

    b, t, em, fe = run(go())
    assert fe.queries == [QUESTION_TEXT], "exactly one job: the final text"
    hits = embed_hits(em)
    assert len(hits) == 1 and (hits[0]["turn_id"], hits[0]["bank_id"]) == ("q1", "b001")
    assert em.of("metric", stage="embed_final_queued", turn_id="q1")
    assert em.of("metric", stage="late_hit_rescue", turn_id="q1")
    assert len(answers(t)) == 1, "exactly one answer"
    assert shown(em, "F") == ANSWER
    assert "Thanks, noted." not in all_text(em)
    assert len(t.by_route("D")) == 1


def test_final_text_miss_stays_a_miss():
    async def go():
        fe = FakeEmbedder([("zebra", {"b001": 0.90})], delay=0.0)
        b, t, em = embed_make(fe, late_responder(probe_delay=0.0))
        await embed_start(b)
        await close_turn(b, "q1", QUESTION_TEXT, "statement")      # no rule matches: background score
        await idle(b)
        await settle(b)
        return t, em, fe

    t, em, fe = run(go())
    assert fe.queries == [QUESTION_TEXT]
    assert not embed_hits(em)
    assert not em.of("metric", stage="late_hit_rescue")
    assert shown(em, "F") == ["SAY: Thanks, noted."], "the statement probe's acknowledgement stands"
    assert len(f_calls(t)) == 1


def test_question_turn_gets_the_hit_but_no_second_answer():
    """A turn already answered as a question: the late match may attach the bank hit (Haiku's BANK line is checked against
    it) but starts no second answer."""
    async def go():
        fe = FakeEmbedder(PARA, delay=0.0)
        b, t, em = embed_make(fe, late_responder())
        await embed_start(b)
        await close_turn(b, "q1", QUESTION_TEXT, "question")
        await idle(b)
        await settle(b)
        return b, t, em

    b, t, em = run(go())
    assert len(embed_hits(em)) == 1
    assert not em.of("metric", stage="late_hit_rescue")
    assert len(answers(t)) == 1 and len(t.by_route("D")) == 1
    assert shown(em, "F") == ANSWER


def test_no_final_pass_when_a_hit_already_landed_or_for_others_or_when_short():
    async def go():
        fe = FakeEmbedder(PARA)
        b, t, em = embed_make(fe, late_responder())
        await embed_start(b)
        await b.handle({"type": "bank_hit", "turn_id": "n1", "bank_id": "b002", "score": 0.7})   # Swift's n-gram hit
        await close_turn(b, "n1", QUESTION_TEXT, "question")
        await close_turn(b, "o1", QUESTION_TEXT, "question", addressee="other")
        await close_turn(b, "s1", "how did you", "statement")                                       # under 5 words
        await idle(b)
        await settle(b)
        return fe, em

    fe, em = run(go())
    assert fe.queries == []
    assert not em.of("metric", stage="embed_final_queued")


def test_final_pass_is_queued_once_per_turn():
    async def go():
        fe = FakeEmbedder(PARA)
        b, t, em = embed_make(fe, late_responder())
        await embed_start(b)
        await close_turn(b, "q1", QUESTION_TEXT, "statement")
        await close_turn(b, "q1", QUESTION_TEXT, "statement")      # a repeated turn message
        await idle(b)
        await settle(b)
        return em, fe

    em, fe = run(go())
    assert fe.queries == [QUESTION_TEXT]
    assert len(em.of("metric", stage="embed_final_queued")) == 1


def test_final_pass_can_be_switched_off():
    async def go():
        fe = FakeEmbedder(PARA)
        b, t, em = embed_make(fe, late_responder(), embed_final_pass=False)
        await embed_start(b)
        await close_turn(b, "q1", QUESTION_TEXT, "statement")
        await idle(b)
        await settle(b)
        return fe

    assert run(go()).queries == []


def test_late_final_hit_still_obeys_the_window_and_newer_turns():
    """The window and the newer-turn rules of `_late_hit` apply to a final-pass hit as they do to any late hit."""
    async def go(newer: bool):
        fe = FakeEmbedder(PARA, delay=0.3)
        b, t, em = embed_make(fe, late_responder())
        await embed_start(b)
        await close_turn(b, "q1", QUESTION_TEXT, "fragment")
        if newer:
            await b.handle({"type": "partial", "turn_id": "q2", "speaker": "remote", "text": "okay and", "cue": False,
                            "t_audio_end": 0.0})
        else:
            b.late_hit_window_s = 0.05
        await idle(b)
        await settle(b)
        return t, em

    for newer, reason in ((True, "newer_turn"), (False, "window")):
        t, em = run(go(newer))
        assert not answers(t) and not em.of("delta")
        assert em.of("metric", stage="late_hit_ignored", reason=reason)


def test_double_answer_is_impossible_when_the_probe_already_escalated():
    async def go():
        fe = FakeEmbedder(PARA, delay=0.3)
        resp = late_responder("KIND: question\nSAY: Sure, here is the short version.\n- I led Lantern.\n"
                              "- It cut entry to 2 minutes.\nBANK: b001")
        b, t, em = embed_make(fe, resp)
        await embed_start(b)
        await close_turn(b, "q1", QUESTION_TEXT, "statement")
        await idle(b)
        await settle(b)
        return t, em

    t, em = run(go())
    assert len(f_calls(t)) == 1, "the probe is the answer"
    assert not em.of("metric", stage="late_hit_rescue")
    assert len(t.by_route("D")) == 1
    assert shown(em, "F") == ANSWER

