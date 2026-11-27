"""eval/run_nudges.py plumbing with fakes only: the transcript clock, row indices, arm B's trace (no paid call)."""

from __future__ import annotations

import json
import sys
from pathlib import Path

from verse_brain.runtime.fake import FakeTransport, default_responder, lines_script
from verse_brain.runtime.nudges import fake_judge_line

EVAL = Path(__file__).resolve().parents[2] / "eval"
sys.path.insert(0, str(EVAL))
import run_nudges as RN  # noqa: E402


def _session(tmp_path, rows) -> Path:
    d = tmp_path / "s"
    RN.write_demo(d)
    (d / "transcript.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows), encoding="utf-8")
    return d


def test_small_backward_steps_are_not_new_runs(tmp_path):
    rows = [{"turn_id": f"t{i}", "speaker": "remote" if i % 2 else "me", "text": f"words {i}", "t_audio_end": t,
             "run_start": 1000.0} for i, t in enumerate([10.0, 20.0, 18.5, 30.0, 28.7, 60.0])]
    turns = RN.read_transcript(_session(tmp_path, rows))
    assert [m["t_audio_end"] for m in turns] == [10.0, 20.0, 18.5, 30.0, 28.7, 60.0]
    assert RN.audio_minutes(turns) == round(50 / 60, 2)
    assert [m["_row"] for m in turns] == list(range(6))


def test_a_new_run_start_or_a_large_drop_starts_a_new_run(tmp_path):
    rows = [{"turn_id": "a", "speaker": "me", "text": "one", "t_audio_end": 100.0, "run_start": 1.0},
            {"turn_id": "b", "speaker": "me", "text": "two", "t_audio_end": 5.0, "run_start": 2.0}]
    assert [m["t_audio_end"] for m in RN.read_transcript(_session(tmp_path / "x", rows))] == [100.0, 105.0]
    rows = [{"turn_id": "a", "speaker": "me", "text": "one", "t_audio_end": 100.0},
            {"turn_id": "b", "speaker": "me", "text": "two", "t_audio_end": 99.0},
            {"turn_id": "c", "speaker": "me", "text": "three", "t_audio_end": 5.0}]
    assert [m["t_audio_end"] for m in RN.read_transcript(_session(tmp_path / "y", rows))] == [100.0, 99.0, 105.0]


def test_rows_skip_nothing_but_unparseable_lines(tmp_path):
    rows = [{"turn_id": "a", "speaker": "me", "text": "one", "t_audio_end": 1.0},
            {"turn_id": "b", "speaker": "me", "text": "   ", "t_audio_end": 2.0},
            {"turn_id": "c", "speaker": "remote", "text": "three", "t_audio_end": 3.0}]
    assert [(m["turn_id"], m["_row"]) for m in RN.read_transcript(_session(tmp_path, rows))] == [("a", 0), ("c", 2)]


def test_arm_b_with_a_fake_api_writes_a_trace(tmp_path, capsys):
    session = tmp_path / "demo"
    RN.write_demo(session)
    trace = tmp_path / "trace.jsonl"

    def fake_api():
        return FakeTransport(lambda info: lines_script(fake_judge_line(info.tail)) if "NUDGE CHECK." in info.tail
                             else default_responder(info))

    assert RN.arm_b(session, speed=400.0, runs=1, trace=trace, transport_factory=fake_api) == 0
    out = capsys.readouterr().out
    assert "fire run=1 id=n002 row=2 (r2)" in out and "totals: runs=1" in out
    recs = [json.loads(ln) for ln in trace.read_text(encoding="utf-8").splitlines()]
    turns = [r for r in recs if r["kind"] == "turn"]
    assert [r["row"] for r in turns] == list(range(len(RN.DEMO_TURNS)))
    assert all(set(r) >= {"row", "speaker", "text", "candidates", "skip"} and len(r["text"]) <= 160 for r in turns)
    assert turns[0]["skip"] == "no_candidates" and turns[2]["candidates"] == ["n002"] and turns[2]["skip"] is None
    judges = [r for r in recs if r["kind"] == "judge"]
    assert judges and judges[0]["tail_ids"] == ["n002"] and judges[0]["raw"].startswith("NUDGE: n002")
    assert judges[0]["verdict"] == "fired" and "window" in judges[0]
    assert any(r["kind"] == "retire" for r in recs)          # the 80k in the last turn retires n001
    assert all(r["run"] == 1 for r in recs)


def test_arm_b_default_output_has_no_trace(tmp_path, capsys):
    session = tmp_path / "demo"
    RN.write_demo(session)
    RN.arm_b(session, speed=400.0, runs=1, transport_factory=lambda: FakeTransport(default_responder))
    assert not list(tmp_path.glob("*.jsonl")) and '"kind": "turn"' not in capsys.readouterr().out


def test_arm_b_prints_rejected_picks_per_run(tmp_path, capsys):
    session = tmp_path / "demo"
    RN.write_demo(session)

    def flipped(info):     # the right quote with the wrong speaker: parsed, then rejected by the code
        if "NUDGE CHECK." not in info.tail:
            return default_responder(info)
        line = fake_judge_line(info.tail)
        return lines_script(line.replace("| them", "| XX").replace("| me", "| them").replace("| XX", "| me"))

    RN.arm_b(session, speed=400.0, runs=1, transport_factory=lambda: FakeTransport(flipped), judge="haiku")
    out = capsys.readouterr().out
    assert "reject run=1 row=2 id=n002 reason=who_mismatch" in out and "fire run=" not in out
    assert "judge=haiku" in out and '"rejected": [{' in out
