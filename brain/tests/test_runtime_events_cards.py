"""`card_done` in events.jsonl (F1, docs/specs/2026-10-20-verse-five-features-design.md 3.1): when a card call finishes, the log gets
its whole SAY and points (each line up to 240 characters), so the app's transcript can show the card under the row it answered.
`card` keeps its 60-character first line. Fictional person (Dana Reyes) only; time is a fake clock."""

from __future__ import annotations

import json
from pathlib import Path

from test_runtime_helpers import run, settle
from test_runtime_me import make, me_spec, session_dir, start
from test_runtime_room_reading import Clock, events_of, rturn

from verse_brain.runtime.events import CARD_FULL_CHARS
from verse_brain.runtime.fake import lines_script

LONG_SAY = ("Certo, in due anni ho portato Harbor Ledger da prototipo a prodotto usato da dodici team finanziari, "
            "e la parte che mi rende piu fiero e la chiusura mensile passata da sei giorni a due, perche ha cambiato il ritmo del lavoro "
            "di tutti, non solo il mio, e ha ridotto gli errori di riconciliazione quasi a zero ogni mese.")
LONG_POINT = ("Harbor Ledger: " + "dodici team, sei giorni a due, errori quasi a zero, " * 6).strip()
SHORT_POINT = "Prima ho costruito Trailhead."


def responder(info):
    tail = info.tail
    if "STATEMENT CHECK" in tail:
        return lines_script("KIND: statement\nNONE")
    if info.route == "D":
        return lines_script("OPENER_OK\n- Un dettaglio (f001)\n- Un altro dettaglio (f002)")
    if "parli di lei" in tail:
        return lines_script(f"SAY: {LONG_SAY}\n- {SHORT_POINT}\n- {LONG_POINT}\nBANK: none")
    return lines_script("SAY: Certo, ecco la risposta breve.\n- Primo punto.\nBANK: none")


def session(tmp_path, monkeypatch):
    monkeypatch.setenv("VERSE_EVENTS", "1")
    b, t, em, _ = make(tmp_path, embedder=False, responder=responder)
    b._clock = Clock()
    sdir = session_dir(tmp_path)
    return b, t, em, sdir, start(b, sdir, me=me_spec(), mode="unprepared", route="room", lang="it", follow=True)


async def ask(b, tid="r1"):
    await rturn(b, tid, "mi parli di lei e della sua esperienza", kind="question", cue=True, cue_why="mi parli", cue_strong=True)
    await settle(b)


def test_card_done_holds_the_full_say_and_points_clipped_at_240(tmp_path, monkeypatch):
    async def go():
        b, t, em, sdir, coro = session(tmp_path, monkeypatch)
        await coro
        await ask(b)
        return sdir

    rows = events_of(run(go()))
    done = [r for r in rows if r["ev"] == "card_done"]
    # One event per finished call of the turn: the fast tier (the card) and D (its points, "(f001)" refs resolved to the facts).
    assert [r["tier"] for r in done] == ["F", "D"] and len({r["id"] for r in done}) == 2
    assert done[1]["turn"] == "r1" and "say" not in done[1] and len(done[1]["points"]) == 2
    d = done[0]
    assert d["turn"] == "r1" and d["tier"] in ("S", "F") and d["id"][0] in "sf"
    assert len(LONG_SAY) > CARD_FULL_CHARS and len(LONG_POINT) > CARD_FULL_CHARS
    assert d["say"] == LONG_SAY[:CARD_FULL_CHARS].rstrip() + "…"                  # clipped at 240, not at 60
    assert len(d["say"]) <= CARD_FULL_CHARS + 1
    assert len(d["points"]) == 2 and d["points"][0] == SHORT_POINT                   # a short line whole, in order
    assert d["points"][1].endswith("…") and len(d["points"][1]) <= CARD_FULL_CHARS + 1
    card = next(r for r in rows if r["ev"] == "card" and r["id"] == d["id"])       # `card` still logs the 60-character first line
    assert card["text"] == d["say"][:60].rstrip() + "…" and len(card["text"]) <= 61
    assert list(rows).index(card) < list(rows).index(d)                            # the card line is logged before the card is done


def test_a_short_card_is_logged_whole_and_once(tmp_path, monkeypatch):
    async def go():
        b, t, em, sdir, coro = session(tmp_path, monkeypatch)
        await coro
        await rturn(b, "r2", "mi dica di un progetto di cui e fiero", kind="question", cue=True, cue_why="mi dica", cue_strong=True)
        await settle(b)
        return sdir

    done = [r for r in events_of(run(go())) if r["ev"] == "card_done" and r["tier"] == "F"]
    assert len(done) == 1                                                            # once per call, never twice
    assert done[0]["say"] == "Certo, ecco la risposta breve." and done[0]["points"] == ["Primo punto."]


def test_no_card_done_for_a_statement_probe_or_a_turn_with_no_card(tmp_path, monkeypatch):
    async def go():
        b, t, em, sdir, coro = session(tmp_path, monkeypatch)
        await coro
        await rturn(b, "y1", "ha avuto esperienza nel presentare i risultati", kind="statement")   # probed: statement
        await rturn(b, "z1", "grazie mille", kind="statement")
        await settle(b)
        return sdir

    rows = events_of(run(go()))
    assert not [r for r in rows if r["ev"] == "card_done"]
    assert not any(k in json.dumps(rows) for k in ("audio_bytes", "pcm"))                              # text only


def test_card_done_is_not_written_when_the_log_is_off(tmp_path, monkeypatch):
    async def go():
        b, t, em, sdir, coro = session(tmp_path, monkeypatch)
        monkeypatch.setenv("VERSE_EVENTS", "0")
        await coro
        await ask(b)
        return sdir

    assert not (Path(run(go())) / "events.jsonl").exists()
