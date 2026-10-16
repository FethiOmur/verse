"""Calls without a prepared session: an empty pack, the room route's one mic (speaker "room"), card-now, and the language control.

Fictional fixtures only; the transport is the canned fake (no network)."""

from __future__ import annotations

import asyncio
import json
import queue
import threading
import time

from test_runtime_helpers import FIX, partial, run, settle, turn
from test_runtime_ipc import _collect, _reader, _send, _spawn
from test_runtime_me import LibEmbedder, bp_count, lib_ready, make, me_spec, session_dir, start, until

from verse_brain.runtime.fake import CARD_NOW_CANNED
from verse_brain.runtime.prompt import NO_PACK_LINE

UNPREPARED = {"mode": "unprepared"}


def room(**extra) -> dict:
    return {"mode": "unprepared", "route": "room", **extra}


def blocks_text(req: dict) -> str:
    return "\n".join(b["text"] for b in req["messages"][0]["content"])


# ---------------------------------------------------------------- what is answered in an unprepared call
def test_unprepared_question_is_answered_from_the_me_layer_with_no_bank(tmp_path):
    async def go():
        b, t, em, emb = make(tmp_path)
        await start(b, session_dir(tmp_path), me=me_spec(), **UNPREPARED)
        await turn(b, "r1", "tell me about the project you are proudest of")
        await settle(b)
        return b, t, em, emb

    b, t, em, emb = run(go())
    f = t.by_route("F")[0]
    assert "ABOUT OWNER" in f.request["system"][0]["text"] and "write BANK: none" in f.request["system"][0]["text"]
    assert NO_PACK_LINE in blocks_text(f.request) and "[m401]" in f.request["system"][1]["text"]
    assert len(t.by_route("D")) == 1                                      # D runs as in a prepared session
    assert em.of("bank_verdict") == [] and em.of("bank_hit") == []         # no bank, so nothing to confirm or reject
    assert em.of("metric", stage="embed") == []                            # the paraphrase matcher is idle
    assert any(e["type"] == "delta" and e["tier"] == "F" for e in em.events)
    assert b.unprepared and b.session.pack == ""


def test_unprepared_without_the_layer_says_nothing_was_prepared(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), **UNPREPARED)
        await turn(b, "r1", "tell me about the project you are proudest of")
        await settle(b)
        return t

    f = run(go()).by_route("F")[0]
    assert len(f.request["system"]) == 1 and "(none: unprepared call)" in f.request["system"][0]["text"] and bp_count(f.request) == 1


def test_remote_statements_of_four_words_or_more_get_the_probe_and_shorter_ones_nothing(tmp_path):
    async def go(text, kind, mode):
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path, bank=mode == "prepared"), mode=mode, me=me_spec())
        await turn(b, "r1", text, kind=kind)
        await settle(b)
        return t, em

    t, em = run(go("Thanks for joining the call today", "statement", "unprepared"))
    assert len(t.by_route("F")) == 1 and "STATEMENT CHECK" in t.by_route("F")[0].tail
    t, em = run(go("Good morning to all", "statement", "unprepared"))           # 4 words: still a probe
    assert len(t.by_route("F")) == 1
    t, em = run(go("Okay great thanks", "statement", "unprepared"))              # 3 words: nothing
    assert t.by_route("F") == [] and em.of("metric", stage="statement_skipped")[0]["words"] == 3
    t, em = run(go("Okay great thanks", "statement", "prepared"))                # a prepared session is unchanged: it probes
    assert len(t.by_route("F")) == 1
    t, em = run(go("so the thing is that we", "fragment", "unprepared"))         # fragments: nothing
    assert t.by_route("F") == [] and em.of("metric", stage="fragment_skipped")


def test_stop_writes_the_summary_into_the_adhoc_folder(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        sd = session_dir(tmp_path)
        await start(b, sd, me=me_spec(), **UNPREPARED)
        await turn(b, "r1", "tell me about the project you are proudest of")
        await settle(b)
        await turn(b, "m1", "I led a payments reconciliation service", speaker="me")
        await b.handle({"type": "control", "action": "stop"})
        return sd

    sd = run(go())
    assert (sd / "summary.md").is_file() and json.loads((sd / "meta.json").read_text())["kind"] == "adhoc"


# ---------------------------------------------------------------- card now
def f_calls(t):
    return [c for c in t.by_route("F") if "SUMMARIZE" not in c.tail]


def test_card_now_answers_the_open_partial_past_every_gate(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), **UNPREPARED)
        # no cue at all, a remark rather than a question: nothing fires by itself
        await partial(b, "r1", "so I was looking at your last project", cue=False)
        await asyncio.sleep(0.05)
        assert f_calls(t) == [] and t.by_route("S") == []
        await b.handle({"type": "control", "action": "card_now"})
        await settle(b)
        # the real turn follows with the same words: no second card
        await turn(b, "r1", "so I was looking at your last project", addressee="me", kind="statement")
        await settle(b)
        return t, em

    t, em = run(go())
    f = f_calls(t)
    assert len(f) == 1 and f[0].tail.startswith("Language: English\nCARD NOW.")
    assert f[0].tail.endswith("CURRENT QUESTION (still being spoken, may be cut off): so I was looking at your last project")
    deltas = [e for e in em.of("delta") if e["turn_id"] == "now-1"]
    assert deltas and {e["tier"] for e in deltas} >= {"F"} and "Here is what I can say right now." in "".join(e["text"] for e in deltas)
    m = em.of("metric", stage="card_now")[0]
    assert m["turn_id"] == "now-1" and 0 <= m["ms"] < 1000
    assert em.of("metric", stage="card_now_covers_turn")[0]["by"] == "now-1"
    assert len(t.by_route("D")) == 1                                       # D follows, like for any card


def test_card_now_without_an_open_partial_answers_the_last_final_remote_turn(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), **UNPREPARED)
        await turn(b, "m0", "my own earlier words", speaker="me")
        # a remark aimed at someone else: no card by itself (addressee other)
        await turn(b, "r1", "Tomas could you share the slide with everyone", addressee="other", kind="statement")
        await settle(b)
        assert f_calls(t) == []
        await b.handle({"type": "control", "action": "card_now"})
        await settle(b)
        await b.handle({"type": "control", "action": "card_now"})            # again: the next id
        await settle(b)
        return t, em

    t, em = run(go())
    f = f_calls(t)
    assert len(f) == 2 and all("Tomas could you share the slide with everyone" in c.tail and "CARD NOW." in c.tail for c in f)
    assert "(finished)" in f[0].tail
    assert {e["turn_id"] for e in em.of("delta") if e["tier"] == "F"} == {"now-1", "now-2"}


def test_card_now_with_nothing_heard_gives_a_status_message_and_calls_nothing(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), **UNPREPARED)
        await turn(b, "m0", "only my own words so far", speaker="me")
        await b.handle({"type": "control", "action": "card_now"})
        await asyncio.sleep(0.05)
        return t, em

    t, em = run(go())
    assert t.calls == []
    last = [e for e in em.of("status")][-1]
    assert last["state"] == "ready" and "nothing" in last["message"]


def test_something_said_after_card_now_still_gets_its_own_card(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), **UNPREPARED)
        await partial(b, "r1", "so I was looking at your last project", cue=False)
        await b.handle({"type": "control", "action": "card_now"})
        await settle(b)
        await turn(b, "r1", "so I was looking at your last project and what I would really like to know is how you "
                            "handled the data quality problems that came up in production", kind="question")
        await settle(b)
        return t

    assert len(f_calls(run(go()))) == 2


# ---------------------------------------------------------------- room route
def test_room_turn_without_a_cue_fires_nothing_but_stays_in_the_transcript(tmp_path):
    async def go(**turn_kw):
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), **room())
        await turn(b, "q1", "we talked about budgets", speaker="room", addressee="other", **turn_kw)
        await settle(b)
        n_first = len(t.calls)
        await turn(b, "q2", "how did you handle the reconciliation of late payments", speaker="room", kind="question")
        await settle(b)
        return b, t, em, n_first

    b, t, em, n_first = run(go(kind="statement"))
    assert n_first == 0 and em.of("metric", stage="room_skipped")[0]["cue"] is False
    f = f_calls(t)
    assert len(f) == 1 and "Language: English" in f[0].tail                    # the second turn: a cue and 9 words
    assert "[Room] we talked about budgets" in blocks_text(f[0].request)
    assert [x.speaker for x in b.turns] == ["room", "room"]
    # no kind and no cue from the partials: the same
    b, t, em, n_first = run(go())
    assert n_first == 0


def test_room_turn_needs_six_words_and_the_setting_on(tmp_path):
    async def go(words: str, **extra):
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), **room(**extra))
        await turn(b, "q1", words, speaker="room", kind="question")
        await settle(b)
        return t, em

    t, em = run(go("what did you build there"))                                  # 5 words
    assert t.calls == [] and em.of("metric", stage="room_skipped")[0]["words"] == 5
    t, em = run(go("what did you build there exactly"))                          # 6 words
    assert len(f_calls(t)) == 1
    t, em = run(go("what did you build there exactly", room_auto="off"))        # automatic cards off: only card-now
    assert t.calls == []
    # a question-kind turn of six words fires (a statement of 8+ words is probed instead: test_runtime_room.py)
    t, em = run(go("thanks everybody for coming along today"))
    assert len(f_calls(t)) == 1


def test_room_partials_with_a_cue_speculate_and_the_turn_selects(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), **room())
        words = "what is the hardest bug you fixed in production".split()
        for n in range(4, len(words) + 1):
            await partial(b, "q1", " ".join(words[:n]), cue=True, speaker="room")
            await asyncio.sleep(0.02)
        await turn(b, "q1", " ".join(words), speaker="room", kind="question")
        await settle(b)
        return t, em, b

    t, em, b = run(go())
    assert len(t.by_route("S")) >= 1 and em.of("select")                          # the room mic feeds the remote pipeline
    assert b.follow_on is False                                                    # no `me` channel in the room route: no follow


def test_room_partials_below_six_words_do_not_speculate(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), **room())
        await partial(b, "q1", "what is the hardest bug", cue=True, speaker="room")        # 5 words
        await asyncio.sleep(0.9)                                                            # D's stable window passes too
        return t

    assert run(go()).calls == []


def test_card_now_works_in_the_room_route_with_the_automatic_cards_off(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), **room(room_auto="off"))
        await turn(b, "q1", "so tell me how the reconciliation service worked in the end", speaker="room", kind="question")
        await settle(b)
        assert t.calls == []
        await b.handle({"type": "control", "action": "card_now"})
        await settle(b)
        return t

    f = f_calls(run(go()))
    assert len(f) == 1 and "reconciliation service worked in the end" in f[0].tail


# ---------------------------------------------------------------- language
def test_lang_control_changes_the_language_of_later_tails_and_a_turn_lang_wins(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), **UNPREPARED)
        await turn(b, "r1", "tell me about the project you are proudest of")
        await settle(b)
        await b.handle({"type": "control", "action": "lang", "lang": "it"})
        await turn(b, "r2", "parlami del progetto di cui sei piu orgoglioso")
        await settle(b)
        await b.handle({"type": "partial", "turn_id": "r3", "speaker": "remote", "text": "anlatir misin", "cue": True, "lang": "tr", "t_audio_end": 0.0})
        await b.handle({"type": "turn", "turn_id": "r3", "speaker": "remote", "text": "bana en gurur duydugun projeyi anlatir misin", "addressee": "me",
                        "lang": "tr", "t_audio_end": 0.0})
        await settle(b)
        await b.handle({"type": "control", "action": "lang", "lang": "xx"})          # not a language: ignored
        return b, t, em

    b, t, em = run(go())
    langs = [c.tail.split("\n")[0] for c in f_calls(t)]
    assert langs == ["Language: English", "Language: Italian", "Language: Turkish"]
    assert b.lang == "it" and em.of("metric", stage="lang_change")[0]["lang"] == "it"


# ---------------------------------------------------------------- over the pipes (the real process, --fake)
def test_the_new_messages_over_the_pipes(tmp_path):
    sd = session_dir(tmp_path)
    p = _spawn()
    try:
        q: queue.Queue = queue.Queue()
        threading.Thread(target=_reader, args=(p, q), daemon=True).start()
        _send(p, {"type": "start", "session_dir": str(sd), "lang": "en", "mode": "unprepared", "route": "room", "room_auto": "questions",
                  "me": me_spec()})
        got = []
        end = time.time() + 10
        while time.time() < end and not any(e.get("state") == "ready" for _, e in got):
            got += _collect(q, time.time() + 1)
        ready = [e for _, e in got if e.get("state") == "ready"]
        assert ready and ready[0]["me"]["tokens"] == 640
        _send(p, {"type": "control", "action": "card_now"})             # nothing said yet
        _send(p, {"type": "turn", "turn_id": "q1", "speaker": "room", "kind": "question", "lang": "en", "t_audio_end": time.time(),
                  "text": "what was the hardest bug you fixed in production"})
        _send(p, {"type": "control", "action": "lang", "lang": "it"})
        events = [e for _, e in _collect(q, time.time() + 1.5)]
        assert any(e["type"] == "status" and "nothing" in e.get("message", "") for e in events)
        assert any(e["type"] == "delta" and e["tier"] == "F" and e["turn_id"] == "q1" for e in events)
        # a message the brain does not know is still ignored, and a missing me file is a notice, not a crash
        _send(p, {"type": "control", "action": "something_new"})
        assert p.poll() is None
        _send(p, {"type": "control", "action": "stop"})
        assert p.wait(timeout=8) == 0
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=5)


def test_missing_me_files_over_the_pipes_give_a_notice(tmp_path):
    sd = session_dir(tmp_path)
    p = _spawn()
    try:
        q: queue.Queue = queue.Queue()
        threading.Thread(target=_reader, args=(p, q), daemon=True).start()
        _send(p, {"type": "start", "session_dir": str(sd), "lang": "en", "mode": "unprepared",
                  "me": {"core": str(tmp_path / "gone" / "me.md"), "library": "a", "facts": "b"}})
        got = []
        end = time.time() + 10
        while time.time() < end and not any(e.get("state") == "ready" for _, e in got):
            got += _collect(q, time.time() + 1)
        events = [e for _, e in got]
        assert {"type": "notice", "kind": "me_missing"} in events
        assert [e for e in events if e.get("state") == "ready"][0]["me"] is None
        _send(p, {"type": "control", "action": "stop"})
        assert p.wait(timeout=8) == 0
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=5)
