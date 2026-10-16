"""Switching the audio route or the language in the middle of a call: the brain keeps the call (anytime-swap).

Swift swaps its listen pipeline in place and tells the brain with `control route` / `control lang`. The session, the transcript
and the follow state stay; only the room gate and follow mode follow the route.

Fictional fixtures only; the transport is the canned fake (no network)."""

from __future__ import annotations

import json
import queue
import threading
import time

from test_runtime_helpers import final_calls, partial, run, settle, turn
from test_runtime_ipc import _collect, _reader, _send, _spawn
from test_runtime_me import make, session_dir, start

ROOM_Q = "can you tell me how the reconciliation service worked in the end"


def route(b, name, **extra):
    return b.handle({"type": "control", "action": "route", "route": name, **extra})


def test_route_control_turns_follow_off_in_the_room_and_back_on_in_the_meeting(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), follow=True)
        assert b.follow_on and b.follow is not None
        machine = b.follow
        await route(b, "room", room_auto="questions", follow=True)           # the setting says follow; the room has no `me`
        assert b.route_kind == "room" and not b.follow_on and b.follow is None
        await route(b, "room")                                                # repeating the route changes nothing
        assert not b.follow_on
        await route(b, "meeting", follow=True)
        assert b.route_kind == "meeting" and b.follow_on and b.follow is not None and b.follow is not machine
        again = b.follow
        await route(b, "meeting")                                             # no change: the running machine is kept
        assert b.follow is again
        return b, em

    b, em = run(go())
    assert [e["route"] for e in em.of("metric", stage="route_change")] == ["room", "meeting"]
    states = [(e["on"], e["requested"]) for e in em.of("metric", stage="follow_state")]
    assert states == [(True, True), (False, True), (True, True)]


def test_a_call_that_began_in_the_room_gets_follow_when_it_moves_to_the_meeting(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), mode="unprepared", route="room", follow=False)    # Swift sends follow && !room
        assert not b.follow_on
        await route(b, "meeting", follow=True)
        return b

    assert run(go()).follow_on


def test_route_control_without_follow_keeps_what_start_asked_for(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), follow=True)
        await route(b, "room")
        assert not b.follow_on
        await route(b, "meeting")                                             # `_follow_want` is still True from start
        return b

    assert run(go()).follow_on


def test_an_unknown_route_or_language_is_ignored(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), follow=True)
        await route(b, "submarine")
        await b.handle({"type": "control", "action": "route"})
        await b.handle({"type": "control", "action": "lang", "lang": "xx"})
        return b, em

    b, em = run(go())
    assert b.route_kind == "meeting" and b.lang == "en" and b.follow_on
    assert em.of("metric", stage="route_change") == []


def test_a_language_change_that_leaves_follow_as_it_was_keeps_the_machine(tmp_path):
    """en -> it turns follow off (English only), it -> en builds a new machine; a repeated lang does nothing."""
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), follow=True)
        machine = b.follow
        await b.handle({"type": "control", "action": "lang", "lang": "en"})    # same language
        assert b.follow is machine
        await b.handle({"type": "control", "action": "lang", "lang": "it"})
        assert not b.follow_on and b.follow is None
        await b.handle({"type": "control", "action": "lang", "lang": "en"})
        assert b.follow_on and b.follow is not machine
        return b

    run(go())


def test_room_auto_comes_with_the_route_control(tmp_path):
    """A call that began in the meeting never got `room_auto` in `start`; the route control carries the setting."""
    async def go(room_auto):
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), mode="unprepared")
        await route(b, "room", room_auto=room_auto)
        await turn(b, "r1", ROOM_Q, speaker="room", addressee="unknown", kind="question")
        await settle(b)
        return t, em

    t, em = run(go("questions"))
    assert len(t.by_route("F")) == 1 and em.of("metric", stage="room_skipped") == []
    t, em = run(go("off"))
    assert t.by_route("F") == [] and em.of("metric", stage="room_skipped")[0]["room_auto"] == "off"


def test_the_call_goes_on_across_a_route_change_and_one_summary_covers_both_halves(tmp_path):
    sd = session_dir(tmp_path)

    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, sd, mode="unprepared", route="room")
        await turn(b, "r1", ROOM_Q, speaker="room", addressee="unknown", kind="question")
        await settle(b)
        prefix_before = [c.request["system"] for c in t.calls[-1:]]
        pid_turns = list(b.turns)
        await route(b, "meeting", follow=False)
        await turn(b, "r2", "so what did you build before that for the courier company", addressee="me", kind="question")
        await settle(b)
        await turn(b, "m3", "mostly the planning service and the depot dashboard", speaker="me", addressee="unknown")
        await b.handle({"type": "control", "action": "stop"})
        return b, t, em, pid_turns, prefix_before

    b, t, em, before, prefix_before = run(go())
    assert [x.turn_id for x in before] == ["r1"]
    assert [x.turn_id for x in b.turns] == ["r1", "r2", "m3"], "the transcript is one list across the switch"
    # the room turn of the first half is still labelled as it was said; the meeting turns after it are what they are
    assert [x.speaker for x in b.turns] == ["room", "remote", "me"]
    finals = final_calls(t)
    assert len(finals) == 1, "one final merge for the whole call"
    text = json.dumps(finals[0].request, ensure_ascii=False)
    for needle in ("reconciliation service", "courier company", "depot dashboard"):
        assert needle in text, f"the summary call must see {needle!r}"
    sf = em.of("metric", stage="summary_final")
    assert len(sf) == 1 and sf[0]["turns"] == 3
    assert (sd / "summary.md").is_file()
    # the cached prefix (system blocks) is the same object content before and after: the route is not part of it
    assert t.calls[-1].request["system"][0] == prefix_before[0][0]


# ---------------------------------------------------------------- over the pipes (the real process, --fake)
def test_route_control_over_the_pipes(tmp_path):
    sd = session_dir(tmp_path)
    p = _spawn()
    try:
        q: queue.Queue = queue.Queue()
        threading.Thread(target=_reader, args=(p, q), daemon=True).start()
        _send(p, {"type": "start", "session_dir": str(sd), "lang": "en", "mode": "unprepared", "route": "room", "room_auto": "questions"})
        got = []
        end = time.time() + 10
        while time.time() < end and not any(e.get("state") == "ready" for _, e in got):
            got += _collect(q, time.time() + 1)
        _send(p, {"type": "turn", "turn_id": "r1", "speaker": "room", "kind": "question", "t_audio_end": time.time(), "text": ROOM_Q})
        _send(p, {"type": "control", "action": "route", "route": "meeting", "follow": False})
        _send(p, {"type": "turn", "turn_id": "r2", "speaker": "remote", "kind": "question", "addressee": "me", "t_audio_end": time.time(),
                  "text": "and how long did the whole migration take you in the end"})
        events = [e for _, e in _collect(q, time.time() + 2)]
        assert any(e["type"] == "metric" and e.get("stage") == "route_change" and e["route"] == "meeting" for e in events)
        assert any(e["type"] == "delta" and e["turn_id"] == "r2" for e in events)
        assert p.poll() is None
        _send(p, {"type": "control", "action": "stop"})
        assert p.wait(timeout=8) == 0
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=5)
