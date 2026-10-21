"""The `memory_index_start` mode of `python -u -m verse_brain.runtime` (P1): protocol over a real child process with the hash
embedder (`--fake`), the lock, the logs. Fixtures: tests/fixtures/memory/sessions (fictional)."""

from __future__ import annotations

import fcntl
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from test_memory_index import FIX, META, SECRET_SENTENCE, fixture_rows, manifest
from verse_brain.memory.index import MemoryIndex

BRAIN = Path(__file__).resolve().parents[1]


def spawn(*args: str) -> subprocess.Popen:
    env = dict(os.environ)
    env["PYTHONPATH"] = str(BRAIN) + os.pathsep + env.get("PYTHONPATH", "")
    return subprocess.Popen([sys.executable, "-m", "verse_brain.runtime", *args], cwd=BRAIN, env=env, stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def line(msg: dict) -> str:
    return json.dumps(msg, ensure_ascii=False) + "\n"


def put_msg(name: str) -> dict:
    title, date, kind, lang, labels = META[name]
    return {"type": "put", "name": name, "dir": str(FIX / name), "fp": f"fp-{name}", "title": title, "date": date, "kind": kind,
            "lang": lang, "labels": labels, "rows": [{"stamp": r.stamp, "speaker": r.speaker, "text": r.text} for r in fixture_rows(name)]}


def run(payload: list[dict | str], *args: str, timeout: int = 60) -> tuple[list[dict], str, int]:
    p = spawn(*args)
    try:
        out, err = p.communicate("".join(m if isinstance(m, str) else line(m) for m in payload), timeout=timeout)
    finally:
        if p.poll() is None:
            p.kill()
    return [json.loads(ln) for ln in out.splitlines() if ln.strip()], err, p.returncode


def start(db: Path, **kw) -> dict:
    return {"type": "memory_index_start", "db": str(db), **kw}


def test_full_run(tmp_path):
    db = tmp_path / "memory" / "index.sqlite"
    names = list(META)
    evs, err, rc = run([start(db), {"type": "sync", "sessions": manifest(names)}, *[put_msg(n) for n in names], {"type": "end"}],
                       "--fake")
    assert rc == 0
    assert evs[0]["type"] == "status" and evs[0]["state"] == "ready"
    assert evs[0]["context"] == {"sessions": 0, "chunks": 0, "vectors": 0, "embed": "on"}
    plan = next(e for e in evs if e["type"] == "sync_plan")
    assert plan["need"] == names and plan["dropped"] == [] and plan["relabelled"] == 0
    done = [e for e in evs if e["type"] == "put_done"]
    assert [e["name"] for e in done] == names
    assert all(e["key"].startswith("s") and 7 <= len(e["key"]) <= 9 and e["chunks"] > 0 and e["ms"] >= 0 for e in done)
    kinds = [e["type"] for e in evs]
    last_progress = max(i for i, k in enumerate(kinds) if k == "embed_progress")
    assert kinds.index("embed_progress") > max(i for i, k in enumerate(kinds) if k == "put_done")
    assert last_progress < len(evs) - 1 and evs[-1]["type"] == "status" and evs[-1]["state"] == "done"
    prog = [e for e in evs if e["type"] == "embed_progress"]
    assert prog[-1]["done"] == prog[-1]["total"] == evs[-1]["context"]["chunks"]
    ctx = evs[-1]["context"]
    assert ctx["sessions"] == 5 and ctx["vectors"] == ctx["chunks"] and ctx["embed"] == "on"
    ix = MemoryIndex.open(db, readonly=True)
    assert {s.name: s.key for s in ix.sessions()} == {e["name"]: e["key"] for e in done}
    ix.close()
    # nothing from the fixtures in the logs
    for text in (SECRET_SENTENCE, "sixty thousand euros", "Rovigo", "Marta", "pilot plan"):
        assert text not in err


def test_embedding_runs_in_batches_of_32(tmp_path):
    big = {**put_msg("halden-kickoff"), "rows": [{"stamp": f"{i // 60}:{i % 60:02d}", "speaker": "Marta", "text": f"row {i} about sensors"}
                                                 for i in range(300)]}
    evs, _, rc = run([start(tmp_path / "memory" / "index.sqlite"), big, {"type": "end"}], "--fake")
    prog = [e for e in evs if e["type"] == "embed_progress"]
    total = evs[-1]["context"]["chunks"]
    assert rc == 0 and total > 32 and [e["done"] for e in prog] == [min(32 * (i + 1), total) for i in range(len(prog))]
    assert prog[-1]["done"] == prog[-1]["total"] == total and len(prog) == -(-total // 32)


def test_second_run_only_needs_what_changed(tmp_path):
    db = tmp_path / "memory" / "index.sqlite"
    names = ["halden-kickoff", "tarla-intro"]
    run([start(db), {"type": "sync", "sessions": manifest(names)}, *[put_msg(n) for n in names], {"type": "end"}], "--fake")
    evs, _, rc = run([start(db), {"type": "sync", "sessions": manifest(["halden-kickoff"], lambda n: "changed")}, {"type": "end"}],
                     "--fake")
    plan = next(e for e in evs if e["type"] == "sync_plan")
    assert rc == 0 and plan["need"] == ["halden-kickoff"] and plan["dropped"] == ["tarla-intro"]
    assert evs[0]["context"]["sessions"] == 2 and evs[-1]["context"]["sessions"] == 1
    # the vectors of the first run are kept (same fake model), none are pending
    assert not [e for e in evs if e["type"] == "embed_progress"] or evs[-1]["context"]["vectors"] == evs[-1]["context"]["chunks"]


def test_no_embed_skips_phase_two(tmp_path):
    db = tmp_path / "memory" / "index.sqlite"
    evs, _, rc = run([start(db), put_msg("halden-kickoff"), {"type": "end"}], "--fake", "--no-embed")
    assert rc == 0 and evs[0]["context"]["embed"] == "off"
    assert not [e for e in evs if e["type"] == "embed_progress"]
    assert evs[-1]["state"] == "done" and evs[-1]["context"]["vectors"] == 0 and evs[-1]["context"]["chunks"] > 0
    evs, _, _ = run([start(db, embed=False), {"type": "end"}], "--fake")
    assert evs[0]["context"]["embed"] == "off" and evs[-1]["context"]["vectors"] == 0


def test_busy_when_the_lock_is_held(tmp_path):
    db = tmp_path / "memory" / "index.sqlite"
    db.parent.mkdir()
    fd = os.open(db.parent / "index.lock", os.O_RDWR | os.O_CREAT)
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    try:
        evs, _, rc = run([start(db), {"type": "sync", "sessions": []}, {"type": "end"}], "--fake")
    finally:
        os.close(fd)
    assert rc == 0 and [(e["type"], e.get("state")) for e in evs] == [("status", "busy")]
    assert not db.exists()
    evs, _, rc = run([start(db), {"type": "end"}], "--fake")                # lock released: the next indexer runs
    assert rc == 0 and evs[0]["state"] == "ready"


def test_bad_requests_are_reported_not_fatal(tmp_path):
    db = tmp_path / "memory" / "index.sqlite"
    broken = put_msg("halden-kickoff")
    del broken["fp"]
    missing_dir = {**put_msg("corvo-design-call"), "dir": str(tmp_path / "gone")}          # no files: rows only, still indexed
    evs, _, rc = run([start(db), {"type": "sync", "sessions": "nope"}, broken, {"type": "put", "name": "x", "kind": "weird"},
                      missing_dir, "not json at all\n", {"type": "end"}], "--fake")
    errs = [e for e in evs if e["type"] == "index_error"]
    assert rc == 0 and [e["kind"] for e in errs] == ["bad_request", "bad_request", "bad_request"]
    assert [e["name"] for e in errs] == ["", "halden-kickoff", "x"]
    assert [e["name"] for e in evs if e["type"] == "put_done"] == ["corvo-design-call"]
    assert evs[-1]["state"] == "done"


def test_unreadable_source_is_an_index_error(tmp_path):
    d = tmp_path / "s"
    d.mkdir()
    (d / "summary.md").write_bytes(b"\xff\xfe broken \x80")
    msg = {**put_msg("halden-kickoff"), "name": "s", "dir": str(d)}
    evs, _, rc = run([start(tmp_path / "memory" / "index.sqlite"), msg, {"type": "end"}], "--fake")
    errs = [e for e in evs if e["type"] == "index_error"]
    assert rc == 0 and len(errs) == 1 and errs[0]["kind"] == "unreadable" and errs[0]["name"] == "s"
    assert not [e for e in evs if e["type"] == "put_done"]


def test_drop_message_and_stdin_eof(tmp_path):
    db = tmp_path / "memory" / "index.sqlite"
    evs, _, rc = run([start(db), put_msg("halden-kickoff"), put_msg("tarla-intro"), {"type": "drop", "names": ["tarla-intro"]}],
                     "--fake")                                                          # EOF instead of `end`: no phase 2
    assert rc == 0 and not [e for e in evs if e["type"] in ("embed_progress",)]
    ix = MemoryIndex.open(db, readonly=True)
    assert [s.name for s in ix.sessions()] == ["halden-kickoff"] and ix.counts()["vectors"] == 0
    ix.close()


def test_no_api_serves_the_index_without_a_transport(tmp_path):
    db = tmp_path / "memory" / "index.sqlite"
    evs, err, rc = run([{"type": "turn", "turn_id": "t", "speaker": "remote", "text": "ignored before the start"},
                        start(db), put_msg("halden-kickoff"), {"type": "end"}], "--no-api", "--fake")
    assert rc == 0 and evs[0]["state"] == "ready" and evs[-1]["state"] == "done"
    assert [e["name"] for e in evs if e["type"] == "put_done"] == ["halden-kickoff"]
    assert "Keychain" not in err and "anthropic" not in err.lower()
