"""persona/rows.py: the headless port of the transcript rules (TranscriptDocument.swift) and the owner-row classification.
Fictional fixtures only (fixtures/persona/sessions)."""

import json
from pathlib import Path

from verse_brain.persona.rows import classify, load_session_rows, stamp

SESSIONS = Path(__file__).parent / "fixtures" / "persona" / "sessions"


def rows_of(name):
    return [(r.stamp, r.role, r.evidence, r.text) for r in load_session_rows(SESSIONS / name).rows]


def test_meeting_route_rows_roles_stamps_and_evidence_are_pinned():
    got = [(s, role, ev) for s, role, ev, _ in rows_of("acme-intro")]
    assert got == [("0:05", "other", None), ("0:14", "me", "own"), ("0:20", "other", None), ("0:31", "me", "read"),
                   ("0:40", "other", None), ("0:47", "me", "own"), ("0:55", "other", None), ("1:03", "me", "own")]


def test_room_route_relabels_and_splits_and_keeps_unlabelled_room_rows():
    got = rows_of("globex-call")
    assert got == [
        ("0:08", "room", None, "So what salary do you expect for this role?"),
        ("0:15", "me", "own", "I expect around 110,000 euros base for this role."),
        ("0:24", "me", "own", "I could start in March."),
        ("0:24", "room", None, "Great, thanks for that answer."),
        ("0:33", "room", None, "I think I would bring a lot of calm to the team."),
    ]


def _write(d: Path, lines, events=()):
    d.mkdir(parents=True)
    (d / "transcript.jsonl").write_text("".join(json.dumps(x) + "\n" for x in lines) + "{broken", encoding="utf-8")
    (d / "events.jsonl").write_text("".join(json.dumps(x) + "\n" for x in events), encoding="utf-8")


def test_legacy_runs_split_on_a_repeated_turn_id_and_are_placed_one_after_another(tmp_path):
    lines = [{"turn_id": "1", "speaker": "remote", "text": "First question?", "t_audio_end": 4.0},
             {"turn_id": "2", "speaker": "me", "text": "first answer", "t_audio_end": 9.0},
             {"turn_id": "2", "speaker": "me", "text": "first answer, corrected", "t_audio_end": 9.5},   # a repeated id starts run 1
             {"turn_id": "3", "speaker": "remote", "text": "Next one?", "t_audio_end": 3.0}]
    _write(tmp_path / "legacy", lines)
    got = [(r.stamp, r.role, r.text) for r in load_session_rows(tmp_path / "legacy").rows]
    # run 0: turns 1, 2 (ends at 9.0); run 1 starts at 9.0: its 9.5 -> 18.5, its 3.0 -> 12.0 (sorted by audio end)
    assert got == [("0:04", "other", "First question?"), ("0:09", "me", "first answer"), ("0:12", "other", "Next one?"),
                   ("0:18", "me", "first answer, corrected")]


def test_forward_runs_use_the_wall_clock_and_dedup_inside_a_run(tmp_path):
    rs1, rs2 = 1795000000.0, 1795000100.0
    lines = [{"turn_id": "a", "speaker": "remote", "text": "Hello?", "t_audio_end": 2.0, "run_start": rs1},
             {"turn_id": "a", "speaker": "remote", "text": "Hello there?", "t_audio_end": 2.5, "run_start": rs1},
             {"turn_id": "b", "speaker": "me", "text": "hi", "t_audio_end": 5.0, "run_start": rs2}]
    _write(tmp_path / "fwd", lines)
    got = [(r.stamp, r.text) for r in load_session_rows(tmp_path / "fwd").rows]
    assert got == [("0:02", "Hello there?"), ("1:45", "hi")]


def test_stamp_format():
    assert [stamp(x) for x in (0, 59.9, 61, 3600, 3725.2)] == ["0:00", "0:59", "1:01", "1:00:00", "1:02:05"]


def test_classify_read_mixed_own():
    card = "I want a smaller company where I can own the product end to end. Ship every week with a small team."
    assert classify("I want a smaller company where I can own the product end to end", [card])[0] == "read"
    assert classify("Well I want a smaller company where I can own the product end to end, but honestly my partner "
                    "moved to Lisbon last spring and we bought a flat near the river", [card])[0] == "mixed"
    assert classify("I enjoy mentoring junior engineers", [card])[0] == "own"
    assert classify("anything at all here", [])[0] == "own"


def test_fingerprint_is_stable_and_follows_the_rows(tmp_path):
    a = load_session_rows(SESSIONS / "acme-intro")
    assert a.fingerprint() == load_session_rows(SESSIONS / "acme-intro").fingerprint()
    lines = [{"turn_id": "1", "speaker": "me", "text": "one", "t_audio_end": 1.0}]
    _write(tmp_path / "x", lines)
    f1 = load_session_rows(tmp_path / "x").fingerprint()
    (tmp_path / "x" / "transcript.jsonl").write_text(json.dumps({**lines[0], "text": "two"}) + "\n")
    assert load_session_rows(tmp_path / "x").fingerprint() != f1
