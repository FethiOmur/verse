"""Owner extensions (verse_brain/extensions.py, docs/extensions.md). All extensions here are fictional fixtures
(fixtures/extensions). The end-to-end tests run a child process with VERSE_OWNER_FILE pointing at a throw-away owner file,
because prompts and the private-project list are built once at import from the profile that exists at that moment."""

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from verse_brain import extensions
from verse_brain.extensions import PROMPT_NAMES, Registry, load_extensions

FIX = Path(__file__).parent / "fixtures" / "extensions"
FULL, BROKEN, NOTES = FIX / "full", FIX / "broken", FIX / "notes"
BRAIN = Path(__file__).resolve().parents[1]


def warnings_of(caplog):
    return [r for r in caplog.records if r.name == "verse.extensions" and r.levelname == "WARNING"]


# ------------------------------------------------------------------ every hook
def test_an_extension_can_register_every_hook(caplog):
    reg = load_extensions(FULL, {"harbor_setting": "on"})
    assert warnings_of(caplog) == []
    assert reg.vault_provider is not None
    assert reg.profile_sources == [FULL / "harbor-profile.md"]
    assert sorted(reg.prompt_addenda) == sorted(PROMPT_NAMES)
    assert reg.prompt_addenda["prep"] == ["HARBOR-ADDENDUM-PREP for {owner}."]
    assert reg.private_projects == ["Lighthouse-Private"]


def test_with_addenda_appends_and_fills_the_owner_name():
    reg = load_extensions(FULL, {"harbor_setting": "on"})
    extensions.set_registry(reg)
    try:
        out = extensions.with_addenda("prep", "BASE TEXT\n")
        assert out == "BASE TEXT\n\nHARBOR-ADDENDUM-PREP for Alex Rivera."      # the pinned owner; trailing newline normalised
        assert extensions.with_addenda("script", "X") == "X\n\nHARBOR-ADDENDUM-SCRIPT."
        assert extensions.with_addenda("prep", "X") != "X" and extensions.with_addenda("script", "") != ""
        assert extensions.private_projects() == ("Lighthouse-Private",)
        assert extensions.profile_sources() == (FULL / "harbor-profile.md",)
    finally:
        extensions.set_registry(None)


def test_an_extension_reads_its_own_keys_from_the_owner_file(caplog):
    load_extensions(FULL, {})                         # harbor_hooks asserts harbor_setting == "on"
    assert len(warnings_of(caplog)) == 1 and "harbor_hooks.py" in warnings_of(caplog)[0].getMessage()


def test_hooks_reach_the_core_end_to_end(tmp_path):
    owner = tmp_path / "owner.json"
    projects = tmp_path / "vault" / "Work"
    (projects / "Lighthouse-Private").mkdir(parents=True)
    (projects / "Open").mkdir()
    (projects / "Index.md").write_text("index")
    (projects / "Lighthouse-Private" / "p.md").write_text("private")
    (projects / "Open" / "o.md").write_text("open")
    owner.write_text(json.dumps({
        "display_name": "Dana Reyes", "vault_path": str(tmp_path / "vault"), "projects_folder": "Work",
        "projects_index": "Index.md", "extensions_path": str(FULL), "harbor_setting": "on"}))
    code = """
import json, pathlib, tempfile
from verse_brain.prep import vault, me, prompt as PP, voice, script
from verse_brain.runtime import prompt as RP, ask
v = vault.make_vault(vault.DEFAULT_VAULT, audience="public")
recs = v.search("tides", limit=2)
labels = [s["label"] for s in me.default_sources(sessions=pathlib.Path(tempfile.mkdtemp()))]
print(json.dumps({
  "recs": [(r.record_id, r.source, r.text) for r in recs],
  "skip": list(me.SKIP_PROJECT_FOLDERS), "labels": labels,
  "prep": PP.SYSTEM.endswith("HARBOR-ADDENDUM-PREP for Dana Reyes."),
  "fast": RP.SYSTEM_FAST.endswith("HARBOR-ADDENDUM-FAST."), "deep": RP.SYSTEM_DEEP.endswith("HARBOR-ADDENDUM-DEEP."),
  "fast_me": "HARBOR-ADDENDUM-FAST." in RP.SYSTEM_FAST_ME, "profile": me.SYSTEM.endswith("HARBOR-ADDENDUM-PROFILE."),
  "voice": voice.SYSTEM.endswith("HARBOR-ADDENDUM-VOICE."), "script": script.SYSTEM.endswith("HARBOR-ADDENDUM-SCRIPT."),
  "ask": ask.system_text("Dana Reyes").endswith("HARBOR-ADDENDUM-ASK for Dana Reyes."),
}))
"""
    r = run_child(code, owner)
    assert r.returncode == 0, r.stderr[-800:]
    got = json.loads(r.stdout)
    assert got["recs"][0] == ["h-1", "Harbor/Quay.md", "Harbor note for tides (audience public)"] and len(got["recs"]) == 2
    assert "Lighthouse-Private" in got["skip"]
    assert got["labels"][0] == "harbor-profile.md"                       # the extension's profile source comes first
    assert "Work/Open/o.md" in got["labels"] and not any("Lighthouse" in l for l in got["labels"])
    assert all(got[k] for k in ("prep", "fast", "deep", "fast_me", "profile", "voice", "script", "ask")), got


# ------------------------------------------------------------------ missing folder
def test_a_missing_folder_warns_once_and_changes_nothing(tmp_path, caplog):
    reg = load_extensions(tmp_path / "does-not-exist", {})
    assert len(warnings_of(caplog)) == 1
    assert reg.vault_provider is None and reg.profile_sources == [] and reg.prompt_addenda == {} and reg.private_projects == []


def test_a_folder_without_a_brain_subfolder_loads_nothing_quietly(tmp_path, caplog):
    reg = load_extensions(tmp_path, {})
    assert warnings_of(caplog) == [] and reg.vault_provider is None


def test_a_missing_folder_does_not_crash_the_brain(tmp_path):
    owner = tmp_path / "owner.json"
    owner.write_text(json.dumps({"display_name": "Dana Reyes", "extensions_path": str(tmp_path / "gone")}))
    r = run_child("from verse_brain.prep import prompt, vault\nassert 'HARBOR' not in prompt.SYSTEM\n"
                  "assert vault.make_vault(None) is None\nprint('ok')", owner)
    assert r.returncode == 0 and r.stdout.strip() == "ok", r.stderr[-600:]
    assert r.stderr.count("extensions folder not found") == 1


# ------------------------------------------------------------------ a module that fails
def test_broken_modules_are_skipped_one_warning_each_and_good_ones_still_load(caplog):
    reg = load_extensions(BROKEN, {})
    msgs = [r.getMessage() for r in warnings_of(caplog)]
    assert len(msgs) == 5, msgs                       # raises in register, on import, no register, SystemExit, bad prompt name
    for name in ("a_raises_in_register", "b_raises_on_import", "c_no_register", "d_exits", "e_bad_prompt_name"):
        assert sum(name in m for m in msgs) == 1
    assert not any("_private_helper" in m for m in msgs)                 # underscore files are never loaded
    assert reg.prompt_addenda == {"prep": ["FINE-ADDENDUM"]}              # nothing from the failed ones, not even partials
    assert reg.private_projects == ["Fine-Project"]


def test_a_second_vault_provider_is_ignored_with_a_warning(tmp_path, caplog):
    for n in ("one", "two"):
        (tmp_path / "brain").mkdir(exist_ok=True)
        (tmp_path / "brain" / f"{n}.py").write_text(
            f"class P:\n    def search(self, q):\n        return [{{'id': '{n}', 'source': 's', 'text': 't'}}]\n"
            "def register(r):\n    r.set_vault_provider(P())\n")
    reg = load_extensions(tmp_path, {})
    assert reg.vault_provider.search("q")[0]["id"] == "one" and len(warnings_of(caplog)) == 1


def test_registry_validates_its_inputs():
    r = Registry()
    with pytest.raises(TypeError):
        r.set_vault_provider(object())
    with pytest.raises(ValueError):
        r.add_prompt_addendum("nope", "x")
    r.add_prompt_addendum("prep", "   ")              # blank: ignored
    r.add_private_project(" ")
    assert r.prompt_addenda == {} and r.private_projects == []


# ------------------------------------------------------------------ no extension: the default
def test_no_extension_changes_nothing(monkeypatch):
    extensions.set_registry(None)
    reg = extensions.registry()
    assert reg.vault_provider is None and reg.prompt_addenda == {} and reg.profile_sources == [] and reg.private_projects == []
    assert extensions.with_addenda("prep", "TEXT") == "TEXT"
    from verse_brain.prep import prompt
    assert "HARBOR" not in prompt.SYSTEM


def test_load_with_no_path_is_empty(caplog):
    reg = load_extensions(None, {})
    assert warnings_of(caplog) == [] and reg.vault_provider is None


def test_the_no_extension_default_prompts_are_byte_identical(tmp_path):
    base = tmp_path / "base.json"
    base.write_text(json.dumps({"display_name": "Dana Reyes"}))
    with_empty = tmp_path / "with.json"
    empty = tmp_path / "empty-ext"
    (empty / "brain").mkdir(parents=True)
    with_empty.write_text(json.dumps({"display_name": "Dana Reyes", "extensions_path": str(empty)}))
    code = ("import json\nfrom verse_brain.prep import prompt as P, me, voice\nfrom verse_brain.runtime import prompt as R\n"
            "print(json.dumps([P.SYSTEM, me.SYSTEM, voice.SYSTEM, R.SYSTEM_FAST, R.SYSTEM_DEEP, R.SYSTEM_FAST_ME]))")
    a, b = run_child(code, base), run_child(code, with_empty)
    assert a.returncode == 0 and b.returncode == 0, a.stderr[-300:] + b.stderr[-300:]
    assert a.stdout == b.stdout


# ------------------------------------------------------------------ loading only from the owner-configured path
def test_nothing_is_loaded_from_the_working_directory_or_sys_path(tmp_path, monkeypatch):
    marker = tmp_path / "marker.txt"
    evil = tmp_path / "cwd" / "brain"
    evil.mkdir(parents=True)
    (evil / "evil.py").write_text(f"open({str(marker)!r}, 'w').write('loaded')\ndef register(r):\n    pass\n")
    monkeypatch.chdir(tmp_path / "cwd")
    monkeypatch.syspath_prepend(str(tmp_path / "cwd"))
    before = list(sys.path)
    load_extensions(None, {})
    load_extensions(tmp_path / "elsewhere", {})
    extensions.set_registry(None)
    extensions.registry()                                              # the pinned owner has no extensions_path
    assert not marker.exists() and sys.path == before


def test_loading_does_not_add_the_extension_folder_to_sys_path():
    before = list(sys.path)
    load_extensions(FULL, {"harbor_setting": "on"})
    assert sys.path == before and str(FULL) not in sys.path


def run_child(code: str, owner_file: Path) -> subprocess.CompletedProcess:
    env = {**os.environ, "VERSE_OWNER_FILE": str(owner_file), "VERSE_EVENTS": "0"}
    return subprocess.run([sys.executable, "-I", "-c", f"import sys; sys.path.insert(0, {str(BRAIN)!r}); exec({code!r})"],
                          capture_output=True, text=True, env=env, cwd=str(BRAIN), timeout=120)


# ------------------------------------------------------------------ the registry while it is loading
def test_registry_while_loading_is_loud_and_private_projects_fail_closed(monkeypatch, caplog):
    extensions.set_registry(None)
    monkeypatch.setattr(extensions, "_loading", True)
    try:
        with caplog.at_level("WARNING", logger="verse.extensions"):
            assert extensions.registry().private_projects == []
        assert any("while the extensions are loading" in r.getMessage() for r in warnings_of(caplog))
        with pytest.raises(RuntimeError):                      # the security-relevant reader never answers from a partial registry
            extensions.private_projects()
    finally:
        extensions.set_registry(None)


def test_private_projects_are_honoured_when_a_consumer_is_imported_during_loading(tmp_path):
    ext = tmp_path / "ext"
    (ext / "brain").mkdir(parents=True)
    (ext / "brain" / "early.py").write_text(           # an extension that imports core modules at the top, then registers
        "from verse_brain.prep import me, vault\n"
        "def register(r):\n    r.add_private_project('Cloaked')\n")
    root = tmp_path / "vault"
    for rel in ("Work/Index.md", "Work/Cloaked/c.md", "Work/Open/o.md"):
        f = root / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text("tides and ferry\n")
    owner = tmp_path / "owner.json"
    owner.write_text(json.dumps({"display_name": "Dana Reyes", "vault_path": str(root), "projects_folder": "Work",
                                 "projects_index": "Index.md", "extensions_path": str(ext)}))
    code = """
import json, pathlib, tempfile
from verse_brain import extensions
extensions.registry()                      # loading: the extension imports me.py and vault.py before it registers
from verse_brain.prep import me, vault
labels = [s["label"] for s in me.default_sources(sessions=pathlib.Path(tempfile.mkdtemp()))]
found = [r.source for r in vault.make_vault(vault.DEFAULT_VAULT).search("ferry", limit=10)]
print(json.dumps({"labels": labels, "found": found, "skip": list(me.SKIP_PROJECT_FOLDERS)}))
"""
    r = run_child(code, owner)
    assert r.returncode == 0, r.stderr[-800:]
    got = json.loads(r.stdout)
    assert "Cloaked" in got["skip"]
    assert not any("Cloaked" in l for l in got["labels"]) and "Work/Open/o.md" in got["labels"], got
    assert not any("Cloaked" in s for s in got["found"]) and "Work/Open/o.md" in got["found"], got
