"""Follow my answer in the engine (fake transport, fake clock-free: real asyncio time with short timers).

One question, a card (F), the owner's own partials. A divergence launches exactly one tier-C call; the `follow` event comes
before its first delta; every C delta carries the card id; covered points are announced against `orig-<turn_id>`; a new
remote question ends follow mode; with the flag off nothing changes."""

from __future__ import annotations

import asyncio
from dataclasses import replace

import pytest
from follow_helpers import ConceptEmbedder
from test_runtime_embed import ESESSION
from test_runtime_helpers import FAST_OK, FIX, lines_script, settle, turn

from verse_brain.runtime.engine import Brain
from verse_brain.runtime.fake import FakeTransport, Script, default_responder
from verse_brain.runtime.follow import FollowParams
from verse_brain.runtime.local_llm import classify
from verse_brain.runtime.prompt import build_request
from verse_brain.runtime.protocol import ListEmitter
from verse_brain.runtime.settings import Config, route_params, tuple_of
from verse_brain.runtime.transport import BadRequest

C_CANNED = ("SAY: And that is where I keep the model on a short leash.\n"
            "- Fields below 0.8 confidence go to a human operator.\n- That was about 7 percent of invoices.")
OFF_CARD = ("Actually the thing I am most proud of is a running app for the marathon, it is called Trailhead and it is on "
            "the App Store with thousands of weekly users")
FAST_PARAMS = FollowParams(lex_only_words=7, lex_only_s=2.0, pause_s=0.15, refresh_gap_s=0.4, quiet_s=0.3, embed_wait_s=0.3, embed_gap_s=0.0, end_silence_s=0.5)


def responder(c_script=C_CANNED, c_delay=0.0, f_body=FAST_OK):
    def r(info):
        if "FOLLOW MY ANSWER" in info.tail:
            return lines_script(c_script, per_chunk=c_delay)
        if info.route in ("S", "F") and not info.tail.startswith("SUMMARIZE") and "STATEMENT CHECK" not in info.tail:
            return lines_script(f_body)
        return default_responder(info)
    return r


def make(resp=None, follow=True, params=FAST_PARAMS, embedder=None, session=FIX, **cfg):
    t = FakeTransport(resp or responder())
    em = ListEmitter()
    conf = Config(follow=params, follow_tick_s=0.02, **cfg)
    fac = (lambda: embedder) if embedder is not None else None
    b = Brain(t, em, conf, embedder_factory=fac)
    b.start_background = False
    return b, t, em, session, follow


async def start(b, session, follow, lang="en"):
    msg = {"type": "start", "session_dir": str(session), "lang": lang}
    if follow is not None:
        msg["follow"] = follow
    await b.handle(msg)
    end = asyncio.get_running_loop().time() + 5
    while b.embed is not None and b.embed.state == "loading" and asyncio.get_running_loop().time() < end:
        await asyncio.sleep(0.01)


async def question(b, tid="q1", text="Can you tell me about yourself?"):
    await turn(b, tid, text, kind="question")
    await settle(b)


async def me(b, text, tid="m1", every=0.004, final=False):
    ws = text.split()
    for i in range(1, len(ws) + 1):
        await b.handle({"type": "partial", "turn_id": tid, "speaker": "me", "text": " ".join(ws[:i]), "cue": False,
                        "t_audio_end": 0.0})
        await asyncio.sleep(every)
    if final:
        await b.handle({"type": "turn", "turn_id": tid, "speaker": "me", "text": text, "addressee": "unknown", "t_audio_end": 0.0})


def c_calls(t):
    return t.by_route("C")


def run(coro):
    return asyncio.run(coro)


def test_divergence_launches_one_c_call_and_streams_the_follow_card():
    async def go():
        b, t, em, sess, fol = make()
        await start(b, sess, fol)
        await question(b)
        await me(b, OFF_CARD)
        await settle(b)
        await asyncio.sleep(0.3)
        await settle(b)
        return b, t, em

    b, t, em = run(go())
    cs = c_calls(t)
    assert len(cs) == 1, [c.tail[:60] for c in cs]
    ev = em.events
    fol = [e for e in ev if e["type"] == "follow"]
    assert len(fol) == 1 and fol[0]["reason"] == "diverged" and fol[0]["turn_id"] == "q1"
    cid = fol[0]["card_id"]
    c_deltas = [e for e in ev if e["type"] == "delta" and e["tier"] == "C"]
    assert c_deltas and all(e["card_id"] == cid == e["id"] and e["turn_id"] == "q1" for e in c_deltas)
    assert ev.index(fol[0]) < ev.index(c_deltas[0]), "the card switches when its first text arrives"
    text = "".join(e["text"] for e in c_deltas)
    assert text.startswith("SAY: And that is where I keep the model on a short leash.") and text.count("- ") == 2
    stages = {e["stage"] for e in ev if e["type"] == "metric"}
    assert {"follow_diverged", "follow_card"} <= stages
    d = next(e for e in ev if e["type"] == "metric" and e["stage"] == "follow_diverged")
    assert d["unmatched"] >= 7 and d["embed"] is None and d["reason"] == "lexical"
    # the request: F's cached prefix byte for byte, the instructions and his words in the tail
    f = t.by_route("F")[0]
    c = cs[0]
    assert c.request["system"] == f.request["system"]
    assert tuple_of(c.request) == tuple_of(f.request)
    assert c.request["messages"][0]["content"][:-1] == f.request["messages"][0]["content"][:-1]
    assert "FOLLOW MY ANSWER" in c.tail and "Trailhead" in c.tail
    assert "SAY: Sure, here is the short version." in c.tail and "- I led Lantern." in c.tail      # the original card
    assert "CURRENT QUESTION (finished): Can you tell me about yourself?" in c.tail
    assert f.index < c.index


def test_reading_the_card_triggers_nothing_and_strikes_the_points():
    async def go():
        b, t, em, sess, fol = make()
        await start(b, sess, fol)
        await question(b)
        await me(b, "Sure, here is the short version. I led Lantern. It cut entry to two minutes.")
        await asyncio.sleep(0.3)
        await settle(b)
        return t, em

    t, em = run(go())
    assert not c_calls(t)
    assert not [e for e in em.events if e["type"] == "follow"]
    cov = [e for e in em.events if e["type"] == "covered"]
    assert {(e["card_id"], e["point"]) for e in cov} == {("orig-q1", 0), ("orig-q1", 1)}
    assert all(e["turn_id"] == "q1" for e in cov)
    assert len([e for e in em.events if e["type"] == "metric" and e["stage"] == "follow_covered"]) == 2


def test_the_flag_off_changes_nothing():
    async def go(flag):
        b, t, em, sess, fol = make(follow=flag)
        await start(b, sess, fol)
        await question(b)
        await me(b, OFF_CARD)
        await me(b, "I led Lantern. It cut entry to two minutes.", tid="m2")
        await asyncio.sleep(0.2)
        await settle(b)
        return t, em

    for flag in (False, None):                      # explicit off, and a sender that does not know the flag
        t, em = run(go(flag))
        assert not c_calls(t)
        assert not [e for e in em.events if e["type"] in ("follow", "covered")]
        assert not [e for e in em.events if e["type"] == "metric" and e["stage"].startswith("follow_diverged")]


def test_other_languages_keep_the_card():
    async def go():
        b, t, em, sess, fol = make()
        await start(b, sess, fol, lang="it")
        await question(b)
        await me(b, OFF_CARD)
        await asyncio.sleep(0.2)
        await settle(b)
        return t, em

    t, em = run(go())
    assert not c_calls(t)
    st = next(e for e in em.events if e["type"] == "metric" and e["stage"] == "follow_state")
    assert st["on"] is False and st["requested"] is True


def test_a_new_question_ends_follow_mode_and_drops_the_old_follow_card():
    async def go():
        b, t, em, sess, fol = make(responder(c_delay=0.05))      # a slow C: still streaming when q2 arrives
        await start(b, sess, fol)
        await question(b)
        await me(b, OFF_CARD)
        await asyncio.sleep(0.12)
        assert [c for c in b.calls if c.tier == "C" and not c.done.is_set()], "the follow call is in flight"
        await question(b, "q2", "What is your biggest weakness?")
        n_after_q2 = len(c_calls(t))
        mark = len(em.events)
        await me(b, "I used to over engineer every early prototype and I changed that habit completely", tid="m2")
        await asyncio.sleep(0.4)
        await settle(b)
        return b, t, em, mark, n_after_q2

    b, t, em, mark, n_after = run(go())
    assert n_after == 1
    old = [c for c in b.calls if c.tier == "C" and c.turn_id == "q1"][0]
    assert old.discarded, "the old follow card must not land on the new question"
    late = [e for e in em.events[mark:] if e["type"] == "delta" and e["tier"] == "C" and e["turn_id"] == "q1"]
    assert not late
    assert b.follow.turn_id == "q2"
    # and the new card is the reference: the original card id belongs to q2
    assert all(e["turn_id"] == "q2" for e in em.events[mark:] if e["type"] == "covered")


def test_a_failed_follow_call_is_silent_and_leaves_the_card():
    def r(info):
        if "FOLLOW MY ANSWER" in info.tail:
            return Script(error=BadRequest("nope"))
        return responder()(info)

    async def go():
        b, t, em, sess, fol = make(r)
        await start(b, sess, fol)
        await question(b)
        await me(b, OFF_CARD)
        await asyncio.sleep(0.3)
        await settle(b)
        return t, em

    t, em = run(go())
    assert len(c_calls(t)) == 1
    assert not [e for e in em.events if e["type"] == "follow"]
    assert not [e for e in em.events if e["type"] == "status" and e["state"] == "error"]


def test_a_refresh_follows_at_his_sentence_end_not_before():
    async def go():
        b, t, em, sess, fol = make()
        await start(b, sess, fol)
        await question(b)
        await me(b, OFF_CARD)
        await asyncio.sleep(0.1)
        await settle(b)
        assert len(c_calls(t)) == 1
        mark = len(em.events)
        # he goes on, mid-sentence nothing happens...
        words = "and last month we passed fifty thousand runs with a new training plan feature for beginners".split()
        for i in range(1, len(words) + 1):
            await b.handle({"type": "partial", "turn_id": "m2", "speaker": "me", "text": " ".join(words[:i]), "cue": False,
                            "t_audio_end": 0.0})
            await asyncio.sleep(0.03)
            assert len(c_calls(t)) == 1, "no refresh while he is still talking"
        # ...and at the pause it comes
        await asyncio.sleep(0.5)
        await settle(b)
        return t, em, mark

    t, em, mark = run(go())
    assert len(c_calls(t)) == 2
    f2 = [e for e in em.events[mark:] if e["type"] == "follow"]
    assert len(f2) == 1 and f2[0]["reason"] == "refresh"
    assert "THE FOLLOW CARD ON HIS SCREEN NOW" in c_calls(t)[1].tail
    assert any(e["type"] == "metric" and e["stage"] == "follow_refresh" for e in em.events)


def test_the_embedder_keeps_a_paraphrase_on_the_card_and_sees_a_new_topic():
    async def go(text):
        b, t, em, sess, fol = make(embedder=ConceptEmbedder(), session=ESESSION)
        await start(b, sess, fol)
        await question(b)
        await me(b, text, every=0.01)
        await asyncio.sleep(0.5)
        await settle(b)
        return b, t, em

    para = "Yeah so I was the lead on a project that reads supplier invoices automatically and pulls the fields out for us"
    b, t, em = run(go(para))
    assert not c_calls(t) and not [e for e in em.events if e["type"] == "follow"]
    assert b.embed is not None and b.embed.state == "ready"
    b, t, em = run(go(OFF_CARD))
    assert c_calls(t), "the new topic got a follow card"
    assert next(e for e in em.events if e["type"] == "follow")["reason"] == "diverged"
    assert sum(1 for e in em.events if e["type"] == "metric" and e["stage"] == "follow_diverged") == 1
    d = next(e for e in em.events if e["type"] == "metric" and e["stage"] == "follow_diverged")
    assert d["reason"] == "lexical+embed" and d["embed"] is not None and d["embed"] < 0.80


def test_summary_md_carries_the_follow_counts(tmp_path):
    from test_runtime_helpers import session_copy

    async def go():
        sess = session_copy(tmp_path)
        b, t, em, _, fol = make()
        await start(b, sess, fol)
        await question(b)
        await me(b, OFF_CARD, final=True)
        await asyncio.sleep(0.2)
        await settle(b)
        await b.handle({"type": "control", "action": "stop"})
        return sess

    sess = run(go())
    md = (sess / "summary.md").read_text()
    assert "## Metrics" in md and "Follow my answer: 1 divergences" in md


def test_the_c_route_is_the_f_tuple_and_gemma_answers_it_like_f():
    assert tuple_of(route_params("C")) == tuple_of(route_params("F")) == tuple_of(route_params("S"))
    req = build_request("C", route_params("C"), "PACK", [], "tail")
    assert classify("C", req) == "answer"


# ---------------------------------------------------------------------------------------------- degraded mode (Gemma)
def test_pre_warm_and_follow_call_share_one_prompt_cache_entry():
    async def go():
        b, t, em, sess, fol = make()
        await start(b, sess, fol)
        await question(b)
        await me(b, OFF_CARD)
        await asyncio.sleep(0.2)
        await settle(b)
        return t

    t = run(go())
    warm = t.creates[0]["request"]
    c = c_calls(t)[0].request
    assert warm["system"] == c["system"] and tuple_of(warm) == tuple_of(c)
    assert warm["messages"][0]["content"][0] == c["messages"][0]["content"][0], "the cached pack block is byte-identical"


def _degraded_rig(**cfg):
    from test_runtime_fallback import rig as fb_rig
    from verse_brain.runtime.transport import Offline
    return fb_rig(fault=Offline("simulated"), follow=FAST_PARAMS, follow_tick_s=0.02, **cfg)


def test_in_degraded_mode_the_follow_card_is_written_by_gemma_like_f():
    async def go():
        b, em, ft, prim, api, backend = _degraded_rig()
        await b.handle({"type": "start", "session_dir": str(FIX), "lang": "en", "follow": True})
        await question(b)
        assert ft.degraded
        await me(b, OFF_CARD)
        await asyncio.sleep(0.4)
        await settle(b, 8.0)
        return em, backend

    em, backend = run(go())
    fol = [e for e in em.events if e["type"] == "follow"]
    assert fol and fol[0]["reason"] == "diverged"
    assert any("FOLLOW MY ANSWER" in m for m in backend.sent), "Gemma got the follow instructions in its message"
    assert [e for e in em.events if e["type"] == "delta" and e["tier"] == "C" and e["card_id"] == fol[0]["card_id"]]


def test_when_gemma_cannot_write_the_follow_card_the_original_stays():
    async def go():
        b, em, ft, prim, api, backend = _degraded_rig()
        await b.handle({"type": "start", "session_dir": str(FIX), "lang": "en", "follow": True})
        await question(b)
        backend.fail_send = True                 # Gemma breaks after the first answer
        await me(b, OFF_CARD)
        await asyncio.sleep(0.4)
        await settle(b, 8.0)
        return em

    em = run(go())
    assert not [e for e in em.events if e["type"] == "follow"]
    assert not [e for e in em.events if e["type"] == "delta" and e["tier"] == "C"]


def test_a_bug_in_the_follow_machine_turns_it_off_and_never_touches_the_answer(monkeypatch):
    from verse_brain.runtime import follow as fmod

    def boom(self, *a, **k):
        raise RuntimeError("boom")

    monkeypatch.setattr(fmod.FollowMachine, "on_me", boom)

    async def go():
        b, t, em, sess, fol = make()
        await start(b, sess, fol)
        await question(b)
        await me(b, OFF_CARD)
        await question(b, "q2", "What is your biggest weakness?")      # the next question is answered as usual
        await settle(b)
        return b, t, em

    b, t, em = run(go())
    assert [e for e in em.events if e["type"] == "metric" and e["stage"] == "follow_error"]
    assert b.follow is None and len(t.by_route("F")) + len(t.by_route("S")) >= 2
    assert not c_calls(t)
