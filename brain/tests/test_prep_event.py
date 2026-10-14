"""F5: calendar event JSON -> prep note -> session folder (offline, --fake)."""

import json
from pathlib import Path

import pytest

from verse_brain.prep.__main__ import main
from verse_brain.prep.event import EventError, event_to_prep_note, load_event

EVENT = {
    "id": "evt-123",
    "title": "Halden Freight: technical interview",
    "start": "2026-10-22T15:00:00+02:00",
    "end": "2026-10-22T15:45:00+02:00",
    "attendees": [
        {"name": "Ingrid Solberg", "email": "ingrid@example.invalid"},
        {"name": "Tomas Weir", "email": "tomas@example.invalid"},
        {"email": "recruiter@example.invalid"},
    ],
    "notes": "Agenda:\n- Walk through the Lantern invoice pipeline\n- Discuss the dispatcher pilot planned for Q1 2027\n\n- Questions from the candidate",
    "url": "https://meet.google.com/abc-defg-hij",
    "provider": "meet",
}


def write_event(tmp_path: Path, event: dict = EVENT) -> Path:
    p = tmp_path / "event.json"
    p.write_text(json.dumps(event), encoding="utf-8")
    return p


def test_prep_note_has_title_time_attendees_agenda_provider():
    note = event_to_prep_note(EVENT)
    assert "Halden Freight: technical interview" in note.splitlines()[0]
    assert "22 October 2026" in note and "15:00" in note and "15:45" in note and "45 minutes" in note
    assert "Google Meet" in note and "https://meet.google.com/abc-defg-hij" in note
    assert "- Ingrid Solberg" in note and "- Tomas Weir" in note
    assert "Walk through the Lantern invoice pipeline" in note and "dispatcher pilot planned for Q1 2027" in note


def test_prep_note_is_deterministic_and_keeps_emails_out_when_a_name_exists():
    assert event_to_prep_note(EVENT) == event_to_prep_note(json.loads(json.dumps(EVENT)))
    note = event_to_prep_note(EVENT)
    assert "ingrid@example.invalid" not in note and "tomas@example.invalid" not in note
    assert "- recruiter@example.invalid" in note  # no name: the email is the only handle we have


def test_prep_note_survives_a_sparse_event():
    note = event_to_prep_note({"title": "Quick sync"})
    assert "Quick sync" in note and "Attendees" not in note and "Agenda" not in note


def test_load_event_rejects_bad_input(tmp_path):
    with pytest.raises(EventError):
        load_event(tmp_path / "missing.json")
    bad = tmp_path / "bad.json"
    bad.write_text("[1, 2]", encoding="utf-8")
    with pytest.raises(EventError):
        load_event(bad)
    bad.write_text(json.dumps({"id": "x"}), encoding="utf-8")  # no title
    with pytest.raises(EventError):
        load_event(bad)


def test_from_event_fake_creates_session_with_pack(tmp_path, capsys):
    out = tmp_path / "sessions"
    rc = main(["--from-event", str(write_event(tmp_path)), "--fake", "--no-vault", "--out", str(out), "--lang", "en"])
    assert rc == 0
    sessions = [p for p in out.iterdir() if not p.name.startswith(".")]
    assert len(sessions) == 1
    s = sessions[0]
    assert {p.name for p in s.iterdir()} == {"meta.json", "bank.jsonl", "facts.jsonl", "glossary.jsonl", "snippets.jsonl", "pack.md", "review.md"}
    pack = (s / "pack.md").read_text(encoding="utf-8")
    assert pack.strip()
    assert "Lantern invoice pipeline" in pack
    meta = json.loads((s / "meta.json").read_text(encoding="utf-8"))
    assert meta["prep_spend_usd"] == 0 and meta["stats"]["bank_entries"] >= 1
    bank = [json.loads(ln) for ln in (s / "bank.jsonl").read_text(encoding="utf-8").splitlines()]
    assert all(b["points"] for b in bank)
    assert "session:" in capsys.readouterr().out
    # nothing but the session folder is left under the sessions root, and no temp prep note leaks into it
    assert [p.name for p in out.iterdir()] == [s.name]


def test_from_event_fake_is_deterministic(tmp_path):
    a = tmp_path / "a"
    b = tmp_path / "b"
    for out in (a, b):
        assert main(["--from-event", str(write_event(tmp_path)), "--fake", "--no-vault", "--out", str(out)]) == 0
    ra = next(a.iterdir())
    rb = next(b.iterdir())
    assert (ra / "pack.md").read_text() == (rb / "pack.md").read_text()
    assert (ra / "bank.jsonl").read_text() == (rb / "bank.jsonl").read_text()


def test_from_event_and_prep_note_are_exclusive(tmp_path, capsys):
    with pytest.raises(SystemExit):
        main(["--from-event", str(write_event(tmp_path)), "--prep-note", str(tmp_path / "x.md"), "--fake"])


def test_from_event_bad_file_exits_nonzero(tmp_path, capsys):
    rc = main(["--from-event", str(tmp_path / "nope.json"), "--fake", "--out", str(tmp_path / "o")])
    assert rc == 1
    assert "error" in capsys.readouterr().err
