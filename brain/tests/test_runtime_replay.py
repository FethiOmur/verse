"""The live replay must never write into the session folder it replays (it once dropped `summary.md` into the
fixture `tests/fixtures/runtime/session/`, which broke `test_stop_without_turns_writes_nothing` twice)."""

from __future__ import annotations

import json
import shutil
from pathlib import Path

import pytest

from verse_brain.runtime import replay

FIXTURE = Path(__file__).parent / "fixtures" / "runtime" / "session"


def session_copy(tmp_path: Path) -> Path:
    dst = tmp_path / "session"
    shutil.copytree(FIXTURE, dst)
    return dst


def files(folder: Path) -> dict[str, bytes]:
    return {str(p.relative_to(folder)): p.read_bytes() for p in sorted(folder.rglob("*")) if p.is_file()}


def test_fixture_has_no_summary():
    """The state the other tests rely on; if this fails, a replay (or a run) polluted the committed fixture."""
    assert not (FIXTURE / "summary.md").exists()


def test_outputs_go_to_the_out_directory_not_the_session(tmp_path, monkeypatch):
    sess = session_copy(tmp_path)
    before = files(sess)
    seen: dict[str, Path] = {}

    def fake_run(work, out, word_ms, budget, fake=False):
        seen["work"] = work
        assert work != sess and work.name == sess.name, "the run must get a copy"
        (work / "summary.md").write_text("# Summary\n", encoding="utf-8")
        (work / "meta.json").write_text('{"changed": true}', encoding="utf-8")
        return {"session": str(work), "summary_events": [{"type": "summary", "path": str(work / "summary.md")}]}

    monkeypatch.setattr(replay, "_run_on", fake_run)
    out = tmp_path / "out" / "metrics.json"
    res = replay.run_live(sess, out, word_ms=1, budget=0.1, fake=True)

    assert files(sess) == before, "the replayed session folder changed"
    assert not seen["work"].exists(), "the temporary copy is removed"
    kept = out.parent / replay.OUTPUTS_DIRNAME
    assert (kept / "summary.md").read_text(encoding="utf-8") == "# Summary\n"
    assert json.loads((kept / "meta.json").read_text(encoding="utf-8")) == {"changed": True}
    assert res["session"] == str(sess)
    assert res["session_outputs"] == {"dir": str(kept), "files": ["meta.json", "summary.md"]}
    assert res["summary_events"][0]["path"] == str(kept / "summary.md"), "paths point at the kept copy"


def test_no_outputs_means_no_outputs_directory(tmp_path, monkeypatch):
    sess = session_copy(tmp_path)
    monkeypatch.setattr(replay, "_run_on", lambda work, out, word_ms, budget, fake=False: {"session": str(work)})
    out = tmp_path / "out" / "metrics.json"
    res = replay.run_live(sess, out, word_ms=1, budget=0.1, fake=True)
    assert res["session_outputs"] == {"dir": None, "files": []}
    assert not (out.parent / replay.OUTPUTS_DIRNAME).exists()


def test_not_a_session_folder_is_refused(tmp_path):
    with pytest.raises(SystemExit):
        replay.run_live(tmp_path, tmp_path / "out" / "m.json", word_ms=1, budget=0.1, fake=True)


def test_fake_replay_end_to_end_leaves_the_session_alone(tmp_path):
    """The real harness against the fake transport (about 15 s): the brain does write summary.md, into the copy."""
    sess = session_copy(tmp_path)
    before = files(sess)
    out = tmp_path / "out" / "metrics.json"
    assert replay.main(["--fake", "--session", str(sess), "--out", str(out), "--word-ms", "1"]) == 0
    assert files(sess) == before, "the replayed session folder changed"
    kept = out.parent / replay.OUTPUTS_DIRNAME
    assert (kept / "summary.md").is_file(), "the final summary is kept with the metrics"
    res = json.loads(out.read_text(encoding="utf-8"))
    assert res["session"] == str(sess)
    assert "summary.md" in res["session_outputs"]["files"]
    final = [e for e in res["summary_events"] if e.get("final") is not None]
    assert final and final[-1]["path"] == str(kept / "summary.md")
