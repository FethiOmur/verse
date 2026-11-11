"""History replay after a brain restart mid-call (runtime/protocol.py `history`, engine.Brain.on_history).

Swift's supervisor restarts a brain that crashed during a call and, once the new process is ready, sends it the call's finalized
turns so far. They must join the transcript (later cards and the final summary see them) without firing anything: no S/F/D, no
bank verdict, no card, no API call.

Fictional fixtures only; the transport is the canned fake (no network)."""

from __future__ import annotations

import json
import queue
import threading
import time

import pytest

from test_runtime_helpers import final_calls, make, rolling_calls, run, session_copy, settle, start, turn
from test_runtime_ipc import _collect, _reader, _send, _spawn
from verse_brain.runtime.protocol import HISTORY_MAX_CHARS, HISTORY_MAX_TURNS, history_turns, parse_line

OLD = [
    {"turn_id": "r1", "speaker": "remote", "text": "can you tell me about the Lantern invoice pipeline you built?", "t_audio_end": 4.2,
     "addressee": "me", "kind": "question", "lang": "en"},
    {"turn_id": "m2", "speaker": "me", "text": "sure, it read supplier invoices and cut entry time to two minutes", "t_audio_end": 9.8,
     "addressee": "unknown", "kind": "statement", "lang": "en"},
    {"turn_id": "r3", "speaker": "remote", "text": "what was the hardest part of the courier migration?", "t_audio_end": 14.1,
     "addressee": "me", "kind": "question"},
]

# What a call that answers or matches a turn emits; none of it may appear for a replayed turn.
CARD_TYPES = ("delta", "select", "bank_hit", "bank_verdict", "opener_status", "follow", "covered")


def history(turns) -> dict:
    return {"type": "history", "turns": turns}


def test_replayed_turns_join_the_transcript_without_any_call_or_card(tmp_path):
    async def go():
        b, t, em = make()
        await start(b, session_copy(tmp_path))
        calls_before, events_before = len(t.calls), len(em.events)
        await b.handle(parse_line(json.dumps(history(OLD))))
        await settle(b)
        return b, t, em, calls_before, events_before

    b, t, em, calls_before, events_before = run(go())
    assert [(x.turn_id, x.speaker, x.text) for x in b.turns] == [(o["turn_id"], o["speaker"], o["text"]) for o in OLD]
    assert len(t.calls) == calls_before, "a replayed turn must not cost an API call"
    new = em.events[events_before:]
    assert [e for e in new if e["type"] in CARD_TYPES] == [], f"nothing is shown for a replayed turn: {new}"
    assert b.ts == {}, "no turn state (no tiers) for a replayed turn"
    m = em.of("metric", stage="history_replayed")
    assert len(m) == 1 and (m[0]["turns"], m[0]["skipped"], m[0]["trimmed"]) == (3, 0, 0)


def test_the_final_summary_and_the_next_card_see_the_replayed_turns(tmp_path):
    async def go():
        b, t, em = make()
        await start(b, session_copy(tmp_path))
        await b.handle(history(OLD))
        await turn(b, "r4", "and how long did the courier migration take in the end?", kind="question")
        await settle(b)
        live = [c for c in t.calls if c.tail and "courier migration take" in c.tail]
        await b.handle({"type": "control", "action": "stop"})
        return b, t, em, live

    b, t, em, live = run(go())
    assert [x.turn_id for x in b.turns] == ["r1", "m2", "r3", "r4"]
    assert live, "the live question after the replay is answered"
    assert "supplier invoices" in json.dumps(live[0].request), "the card for a live turn sees the replayed transcript"
    finals = final_calls(t)
    assert len(finals) == 1
    text = json.dumps(finals[0].request, ensure_ascii=False)
    for needle in ("Lantern invoice pipeline", "supplier invoices", "hardest part of the courier migration", "how long did"):
        assert needle in text, f"the final summary call must see {needle!r}"
    sf = em.of("metric", stage="summary_final")
    assert len(sf) == 1 and sf[0]["turns"] == 4


def test_a_turn_the_brain_already_has_is_not_added_twice(tmp_path):
    """A question re-sent live to the restarted brain, or a repeated replay, must not duplicate a transcript row."""
    async def go():
        b, t, em = make()
        await start(b, session_copy(tmp_path))
        await turn(b, "r3", OLD[2]["text"], kind="question")      # re-sent live first
        await settle(b)
        await b.handle(history(OLD))
        await b.handle(history(OLD))                               # once more: nothing new
        return b, em

    b, em = run(go())
    assert [x.turn_id for x in b.turns] == ["r3", "r1", "m2"]
    m = em.of("metric", stage="history_replayed")
    assert [(x["turns"], x["skipped"]) for x in m] == [(2, 1), (0, 3)]


def test_a_replay_does_not_start_a_rolling_summary_pass(tmp_path):
    """Ten replayed turns are more than `summary_every_turns`; they are not new speech, so the next live turn alone does not
    make a rolling pass due (it would be an API call caused by the replay)."""
    many = [{"turn_id": f"h{i}", "speaker": "remote" if i % 2 else "me", "text": f"old turn number {i} about Lantern",
             "t_audio_end": float(i * 30)} for i in range(10)]

    async def go():
        b, t, em = make()
        await start(b, session_copy(tmp_path))
        await b.handle(history(many))
        await turn(b, "m11", "that is right, it was the supplier invoices", speaker="me", addressee="unknown")
        await settle(b)
        return b, t

    b, t = run(go())
    assert len(b.turns) == 11
    assert rolling_calls(t) == []


def test_history_before_start_or_after_stop_is_ignored(tmp_path):
    async def go():
        b, t, em = make()
        await b.handle(history(OLD))                               # no session yet
        assert b.turns == []
        await start(b, session_copy(tmp_path))
        await b.handle({"type": "control", "action": "stop"})
        await b.handle(history(OLD))
        return b

    assert run(go()).turns == []


# ---------------------------------------------------------------- the wire format
@pytest.mark.parametrize("bad", [
    {"type": "history"},
    {"type": "history", "turns": "r1"},
    {"type": "history", "turns": ["r1"]},
    {"type": "history", "turns": [{"turn_id": 1, "speaker": "remote", "text": "x"}]},
    {"type": "history", "turns": [{"turn_id": "r1", "speaker": "remote", "text": None}]},
    {"type": "history", "turns": [{"turn_id": "r1", "speaker": "boss", "text": "x"}]},
    {"type": "history", "turns": [{"turn_id": "r1", "speaker": "remote", "text": "x", "t_audio_end": True}]},
    {"type": "history", "turns": [{"turn_id": "r1", "speaker": "remote", "text": "x", "t_audio_end": "4.2"}]},
    {"type": "history", "turns": [{"turn_id": "r1", "speaker": "remote", "text": "x", "kind": "rant"}]},
    {"type": "history", "turns": [{"turn_id": "r1", "speaker": "remote", "text": "x", "addressee": "boss"}]},
    {"type": "history", "turns": [{"turn_id": "r1", "speaker": "remote", "text": "x", "lang": "xx"}]},
])
def test_a_malformed_history_line_is_rejected_whole(bad):
    with pytest.raises(ValueError):
        parse_line(json.dumps(bad))


def test_a_minimal_history_line_is_accepted():
    msg = parse_line(json.dumps({"type": "history", "turns": [{"turn_id": "r1", "speaker": "room", "text": "hello"}]}))
    assert msg is not None and msg["turns"][0]["speaker"] == "room"
    assert parse_line(json.dumps({"type": "history", "turns": []})) == {"type": "history", "turns": []}


def test_the_replay_keeps_the_newest_turns_within_the_bounds():
    over = [{"turn_id": f"h{i}", "speaker": "remote", "text": "x"} for i in range(HISTORY_MAX_TURNS + 25)]
    kept, trimmed = history_turns({"turns": over})
    assert len(kept) == HISTORY_MAX_TURNS and trimmed == 25
    assert kept[0]["turn_id"] == "h25" and kept[-1]["turn_id"] == f"h{HISTORY_MAX_TURNS + 24}", "the newest, oldest first"
    long = [{"turn_id": f"l{i}", "speaker": "me", "text": "y" * (HISTORY_MAX_CHARS // 4)} for i in range(6)]
    kept, trimmed = history_turns({"turns": long})
    assert [t["turn_id"] for t in kept] == ["l2", "l3", "l4", "l5"] and trimmed == 2


# ---------------------------------------------------------------- over the pipes (the real process, --fake)
def test_history_over_the_pipes(tmp_path):
    sd = session_copy(tmp_path)
    p = _spawn()
    try:
        q: queue.Queue = queue.Queue()
        threading.Thread(target=_reader, args=(p, q), daemon=True).start()
        _send(p, {"type": "start", "session_dir": str(sd), "lang": "en"})
        got = []
        end = time.time() + 10
        while time.time() < end and not any(e.get("state") == "ready" for _, e in got):
            got += _collect(q, time.time() + 1)
        _send(p, history(OLD))
        events = [e for _, e in _collect(q, time.time() + 1.5)]
        replayed = [e for e in events if e["type"] == "metric" and e.get("stage") == "history_replayed"]
        assert replayed and replayed[0]["turns"] == 3, events
        assert not any(e["type"] in CARD_TYPES for e in events)
        _send(p, {"type": "control", "action": "stop"})
        assert p.wait(timeout=8) == 0
        assert (sd / "summary.md").is_file(), "the final merge ran on the replayed transcript"
    finally:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=5)
