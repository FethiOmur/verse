"""Live controls on the island's answer card: regenerate (`control regenerate`) and the GOOD / BAD marks (`card_mark`).

The marks are only written to events.jsonl, and the after-call review reads them back (persona/rows.py `read_marks`), so the round
trip runs the reader on lines this brain wrote from the exact lines the app sends (fixtures/live_controls/swift_wire.jsonl, which
the Swift test `LiveControlsTests` checks its own encoder against). Fictional text; the transport is the canned fake (no network).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from test_runtime_helpers import run, settle
from test_runtime_me import make, me_spec, session_dir, start
from test_runtime_unprepared import UNPREPARED

from verse_brain.persona.rows import _objects, final_marks, read_marks
from verse_brain.runtime.fake import default_responder, lines_script
from verse_brain.runtime.protocol import parse_line

WIRE = Path(__file__).parent / "fixtures" / "live_controls" / "swift_wire.jsonl"

EN_Q = "How did the Lantern rollout go for the finance team?"
IT_Q1 = "parlami del progetto di cui sei piu orgoglioso adesso"
IT_Q2 = "come hai gestito il team durante il lancio del prodotto"
FAST_ALT = "SAY: Here is another way to put it.\n- First point.\n- Second point.\nBANK: none"


@pytest.fixture(autouse=True)
def _events_on(monkeypatch):
    monkeypatch.setenv("VERSE_EVENTS", "1")      # these tests read the session's events.jsonl (a temp folder)


def wire_lines() -> list[dict]:
    return [parse_line(ln) for ln in WIRE.read_text(encoding="utf-8").splitlines() if ln.strip()]


async def ask(b, tid: str, text: str, lang: str | None = None):
    extra = {"lang": lang} if lang else {}
    await b.handle({"type": "partial", "turn_id": tid, "speaker": "remote", "text": text, "cue": True, "t_audio_end": 0.0, **extra})
    await b.handle({"type": "turn", "turn_id": tid, "speaker": "remote", "text": text, "addressee": "me", "kind": "question",
                    "t_audio_end": 0.0, **extra})
    await settle(b)


def regen_calls(t):
    return [c for c in t.calls if "REGENERATE." in c.tail]


def events_of(sdir: Path) -> list[dict]:
    return _objects(sdir / "events.jsonl")


# ------------------------------------------------------------------------------------------------------------- marks


def test_the_app_wire_lines_parse_and_the_review_reader_reads_back_what_the_brain_wrote(tmp_path):
    sdir = session_dir(tmp_path)

    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, sdir, me=me_spec(), **UNPREPARED)
        for msg in wire_lines():
            if msg["type"] == "card_mark":
                await b.handle(msg)
        return b

    run(go())
    lines = [e for e in events_of(sdir) if e.get("ev") == "card_mark"]
    assert [(e["card"], e["mark"]) for e in lines] == [("f0004", "good"), ("f0004", "cleared"), ("P-r3", "bad")]
    for e in lines:
        assert set(e) == {"t", "ev", "card", "mark", "turn", "question"}
        assert isinstance(e["t"], float) and round(e["t"], 3) == e["t"]
    marks = read_marks(events_of(sdir))
    assert [(m.card, m.mark, m.turn, m.question) for m in marks] == [
        ("f0004", "good", "r2", "How did the Lantern rollout go?"),
        ("f0004", "cleared", "r2", "How did the Lantern rollout go?"),
        ("P-r3", "bad", "r3", "What would you change next time?"),
    ]
    final = final_marks(marks)
    assert set(final) == {"P-r3"}, "pressing GOOD again cleared it; the BAD mark stands"


def test_a_mark_on_a_card_the_brain_showed_takes_the_turn_and_question_from_that_card(tmp_path):
    sdir = session_dir(tmp_path)

    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, sdir, me=me_spec(), **UNPREPARED)
        await ask(b, "r1", EN_Q)
        card = em.of("delta", turn_id="r1")[0]["id"]
        n_calls = len(t.calls)
        # the app's line, with a wrong turn: the brain knows the card's own turn
        await b.handle({"type": "card_mark", "card": card, "mark": "bad", "turn": "r9", "question": "x"})
        await settle(b)
        return card, n_calls, len(t.calls)

    card, before, after = run(go())
    assert before == after, "a mark never starts a call"
    [m] = read_marks(events_of(sdir))
    assert (m.card, m.mark, m.turn, m.question) == (card, "bad", "r1", EN_Q)
    cards = [e for e in events_of(sdir) if e.get("ev") in ("card", "card_done") and e.get("id") == card]
    assert cards, "the mark names the id of the card's own events.jsonl lines"


def test_a_bad_mark_line_is_ignored(tmp_path):
    sdir = session_dir(tmp_path)

    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, sdir, me=me_spec(), **UNPREPARED)
        await b.handle({"type": "card_mark", "card": "", "mark": "good"})
        await b.handle({"type": "card_mark", "card": "f0001", "mark": "great"})

    run(go())
    assert not [e for e in events_of(sdir) if e.get("ev") == "card_mark"]


# ------------------------------------------------------------------------------------------------------------- regenerate


def test_regenerate_answers_the_question_of_the_card_on_screen_again_with_a_fresh_variant(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), **UNPREPARED)
        await ask(b, "r1", EN_Q)
        await ask(b, "r2", "and what would you change next time around there")      # newer turn: regenerate still answers r1
        await b.handle({"type": "control", "action": "regenerate", "turn": "r1", "avoid": "It went well."})
        await settle(b)
        return b, t, em

    b, t, em = run(go())
    [c] = regen_calls(t)
    assert c.tail.startswith("Language: English")
    assert "\"It went well.\"" in c.tail and c.tail.rstrip().endswith(EN_Q)
    m = em.of("metric", stage="regenerate")[0]
    assert m["turn_id"] == "now-1" and m["of"] == "r1" and m["reset"] is False and m["question"] == EN_Q
    assert em.of("delta", turn_id="now-1"), "the new answer streams on its own card-now turn"
    assert em.of("metric", stage="regenerate_done", turn_id="now-1")


def test_regenerate_off_the_dominant_language_answers_in_it_and_resets_the_auto_language(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), lang_auto=True, **UNPREPARED)
        await ask(b, "r1", IT_Q1, "it")
        await ask(b, "r2", IT_Q2, "it")                    # two Italian questions: the dominant language is Italian now
        assert b.dominant.lang == "it"
        b.dominant.note("en", EN_Q)                        # an English run has begun (not a switch yet)
        assert b.dominant.run is not None
        await b.handle({"type": "control", "action": "regenerate", "turn": "r2", "lang": "en", "reset": True})
        await settle(b)
        return b, t, em

    b, t, em = run(go())
    assert b.dominant.lang == "en" and b.dominant.run is None, "reset to the regenerated language, with no run left over"
    flip = em.of("metric", stage="lang_dominant", reason="regenerate")
    assert flip and flip[0]["lang"] == "en" and flip[0]["prev"] == "it"
    [c] = [c for c in t.calls if c.route in ("S", "F") and IT_Q2 in c.tail and "CARD NOW" in c.tail]
    assert c.tail.startswith("Language: English")
    assert {e["lang"] for e in em.of("metric", stage="answer_lang", turn_id="now-1")} == {"en"}


def test_reset_is_ignored_without_auto_and_the_named_language_still_holds(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), **UNPREPARED)
        await ask(b, "r1", EN_Q)
        await b.handle({"type": "control", "action": "regenerate", "turn": "r1", "lang": "it", "reset": True})
        await settle(b)
        return b, t, em

    b, t, em = run(go())
    assert not em.of("metric", stage="lang_dominant", reason="regenerate")
    assert em.of("metric", stage="regenerate")[0]["reset"] is False
    [c] = [c for c in t.calls if "CARD NOW" in c.tail]
    assert c.tail.startswith("Language: Italian")


def test_a_regenerate_while_one_is_in_flight_is_ignored_and_listening_goes_on(tmp_path):
    def slow(info):
        if "CARD NOW" in info.tail:
            return lines_script(FAST_ALT, first_byte_delay=0.4)
        return default_responder(info)

    async def go():
        b, t, em, _ = make(tmp_path, embedder=False, responder=slow)
        await start(b, session_dir(tmp_path), me=me_spec(), **UNPREPARED)
        await ask(b, "r1", EN_Q)
        await b.handle({"type": "control", "action": "regenerate", "turn": "r1"})
        await b.handle({"type": "control", "action": "regenerate", "turn": "r1"})      # pressed again at once: ignored
        await b.handle({"type": "partial", "turn_id": "r3", "speaker": "remote", "text": "tell me about your current role please",
                        "cue": True, "t_audio_end": 0.0})
        await b.handle({"type": "turn", "turn_id": "r3", "speaker": "remote", "text": "tell me about your current role please",
                        "addressee": "me", "kind": "question", "t_audio_end": 0.0})
        await settle(b)
        await b.handle({"type": "control", "action": "regenerate", "turn": "r1"})      # the first one is done: this one runs
        await settle(b)
        return t, em

    t, em = run(go())
    assert [m["turn_id"] for m in em.of("metric", stage="regenerate")] == ["now-1", "now-2"]
    busy = em.of("metric", stage="regenerate_busy")
    assert len(busy) == 1 and busy[0]["by"] == "now-1"
    assert [m["turn_id"] for m in em.of("metric", stage="regenerate_done")] == ["now-1", "now-2"]
    assert em.of("delta", turn_id="r3"), "a new question still gets its card while a regenerate streams"


def test_regenerate_with_nothing_to_answer_starts_no_call(tmp_path):
    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), **UNPREPARED)
        n = len(t.calls)
        await b.handle({"type": "control", "action": "regenerate", "turn": "r7"})
        await b.handle({"type": "control", "action": "regenerate", "turn": "r8", "question": "Why this company?"})
        await settle(b)
        return n, t, em

    n, t, em = run(go())
    assert em.of("metric", stage="regenerate_empty")[0]["of"] == "r7"
    assert [m["question"] for m in em.of("metric", stage="regenerate")] == ["Why this company?"], "the app's question when the brain has none"
    assert len([c for c in t.calls[n:] if "CARD NOW" in c.tail]) == 1


def test_the_wire_regenerate_line_is_a_valid_control(tmp_path):
    [msg] = [m for m in wire_lines() if m["type"] == "control"]
    assert msg["action"] == "regenerate" and msg["reset"] is True and json.dumps(msg)


def test_regenerate_leaves_the_newest_question_its_retries_and_retries_its_own_calls_until_a_newer_turn(tmp_path):
    from types import SimpleNamespace

    from verse_brain.runtime.transport import TransportError

    def call(tid: str, tier: str = "F"):
        return SimpleNamespace(turn_id=tid, tier=tier, discarded=False, first_text_seen=False)

    async def go():
        b, t, em, _ = make(tmp_path, embedder=False)
        await start(b, session_dir(tmp_path), me=me_spec(), **UNPREPARED)
        await ask(b, "r1", EN_Q)
        await ask(b, "r2", "and what would you change next time around there")
        await b.handle({"type": "control", "action": "regenerate", "turn": "r1"})
        await settle(b)
        after_regen = (b.latest_remote_turn, b.retry_ok(call("r2"), TransportError("x")),
                       b.retry_ok(call("r2", "D"), TransportError("x")), b.retry_ok(call("now-1", "D"), TransportError("x")))
        await ask(b, "r3", "tell me about your current role please")
        after_r3 = (b.retry_ok(call("now-1", "D"), TransportError("x")), b.retry_ok(call("r3"), TransportError("x")))
        return after_regen, after_r3

    after_regen, after_r3 = run(go())
    assert after_regen == ("r2", True, True, True), "the newest question keeps its retries; the regenerated card retries its own"
    assert after_r3 == (False, True), "a newer question has started: the regenerated card is no longer the one to save"
