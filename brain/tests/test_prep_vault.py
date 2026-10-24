import json
import subprocess

import pytest

from verse_brain.prep import vault as vault_mod
from verse_brain.prep.vault import ScriptVault, VaultError, parse_context

SAMPLE = {
    "records": [
        {"id": "md-1", "source": "300-Projects/X/Y.md", "text": "Hello vault text", "kind": "note"},
        {"id": "md-2", "source": "", "text": "no source -> skipped"},
    ],
    "abstained": False,
}


def test_command_is_read_only_and_context_only(tmp_path):
    (tmp_path / "find.py").write_text("")
    v = ScriptVault(tmp_path, python="/usr/bin/python3", audience="public", script_name="find.py")
    cmd = v.command("Lantern pricing", 3, 1500)
    assert "--no-sync" in cmd
    assert cmd[cmd.index("--vault") + 1] == str(tmp_path)
    assert "context" in cmd and cmd[cmd.index("context") + 1] == "Lantern pricing"
    assert cmd[cmd.index("--audience") + 1] == "public"
    assert not any(w in cmd for w in ("sync", "ingest", "note-create", "task-create", "task-update", "receipt", "init"))


def test_search_runs_the_command_and_parses(tmp_path, monkeypatch):
    (tmp_path / "find.py").write_text("")
    seen = {}

    def fake_run(cmd, **kw):
        seen["cmd"] = cmd
        return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps(SAMPLE), stderr="")

    monkeypatch.setattr(vault_mod.subprocess, "run", fake_run)
    recs = ScriptVault(tmp_path, python="py", script_name="find.py").search("q")
    assert "--no-sync" in seen["cmd"]
    assert [r.record_id for r in recs] == ["md-1"] and recs[0].source == "300-Projects/X/Y.md"


def test_failures_raise_vault_error(tmp_path, monkeypatch):
    with pytest.raises(VaultError):
        ScriptVault(tmp_path, script_name="find.py").search("q")  # no script
    (tmp_path / "find.py").write_text("")
    monkeypatch.setattr(vault_mod.subprocess, "run",
                        lambda cmd, **kw: subprocess.CompletedProcess(cmd, 2, stdout="", stderr="boom"))
    with pytest.raises(VaultError):
        ScriptVault(tmp_path, script_name="find.py").search("q")
    with pytest.raises(VaultError):
        parse_context("not json")
    assert parse_context(json.dumps({"abstained": True, "records": [{"id": "x", "source": "s", "text": "t"}]})) == []
