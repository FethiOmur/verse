"""The owner profile (verse_brain/owner.py): no personal value is hard-coded; prompts and paths come from owner.json.

The prompt tests run in a child process with VERSE_OWNER_FILE set, because the prompts are built once at import (they are
cache prefixes) from the profile that exists at that moment.
"""

import json
import subprocess
import sys
from pathlib import Path

import pytest

from verse_brain import owner as owner_mod
from verse_brain.owner import GENERIC_NAME, Owner, load_owner

FIXTURE = Path(__file__).parent / "fixtures" / "owner" / "alex_rivera.json"
BRAIN = Path(__file__).resolve().parents[1]

RENDER = r"""
import json
from verse_brain.runtime import prompt as P
from verse_brain.prep import prompt as PP, me as M, voice as V, conversation_prompt as CP
out = {
    "fast": P.SYSTEM_FAST, "deep": P.SYSTEM_DEEP, "fast_me": P.SYSTEM_FAST_ME, "deep_me": P.SYSTEM_DEEP_ME,
    "unprepared": P.SYSTEMS_UNPREPARED["F"], "priorities": P.SYSTEMS_ME_PRIORITIES["F"],
    "about_header": P.ABOUT_HEADER, "files_header": P.FILES_HEADER, "label": P.SPEAKER_LABEL["me"],
    "follow": P.follow_tail("Q?", "en", "my words", ["SAY: a"], [], None, "diverged", True),
    "statement": P.statement_tail("Hello", "en"), "card_now": P.card_now_tail("Hi", "en", True),
    "room": P.statement_tail("Hello", "en", room=True),
    "prep": PP.SYSTEM, "me": M.SYSTEM, "sections": list(M.SECTIONS), "tag": M.OWNER_TAG,
    "legacy": list(V.LEGACY_HEADINGS), "extract": CP.EXTRACT_SYSTEM,
}
print(json.dumps(out))
"""


def render(owner_file: Path) -> dict:
    import os
    env = {**os.environ, "VERSE_OWNER_FILE": str(owner_file), "PYTHONPATH": str(BRAIN)}
    r = subprocess.run([sys.executable, "-I", "-c", "import sys; sys.path.insert(0, %r); exec(%r)" % (str(BRAIN), RENDER)],
                       capture_output=True, text=True, env=env, cwd=str(BRAIN), timeout=120)
    assert r.returncode == 0, r.stderr[-800:]
    return json.loads(r.stdout)


def no_template_tokens(text: str) -> bool:
    return not any(t in text for t in ("{owner}", "{Owner}", "{OWNER}", "{NOTES_HEADING}"))


def test_profile_fixture_is_read():
    o = load_owner(FIXTURE)
    assert o.display_name == "Alex Rivera" and o.named
    assert o.vault_script == "retrieve.py" and o.vault_path == Path("~/Notes/AcmeVault").expanduser()
    assert o.profile_source == Path("~/Downloads/ALEX_PROFILE.md").expanduser()
    assert o.projects_folder == "Work" and o.projects_index == "Index.md"
    assert o.private_project_folders == ("Scratch",) and o.forbidden_vault_folders == ("Journal", "Health")
    assert o.source_tag == "alex-rivera" and o.notes_heading == "ALEX RIVERA'S NOTES"
    assert o.api_key_note == "From Alex's personal API org."


@pytest.mark.parametrize("content", [None, "", "not json", "[1, 2]", '{"display_name": 5}', '{"vault_path": ""}'])
def test_missing_or_broken_profile_is_generic(tmp_path, content):
    p = tmp_path / "owner.json"
    if content is not None:
        p.write_text(content)
    o = load_owner(p)
    assert o == Owner() and o.display_name == GENERIC_NAME and not o.named
    assert o.vault_path is None and o.vault_script is None and o.profile_source is None
    assert o.private_project_folders == () and o.forbidden_vault_folders == ()
    assert o.source_tag == "owner" and o.notes_heading == "MY NOTES"


def test_owner_file_location_can_be_overridden(monkeypatch, tmp_path):
    monkeypatch.setenv("VERSE_OWNER_FILE", str(tmp_path / "x.json"))
    assert owner_mod.owner_file() == tmp_path / "x.json"
    monkeypatch.delenv("VERSE_OWNER_FILE")
    assert owner_mod.owner_file() == Path("~/Library/Application Support/Verse/owner.json").expanduser()


def test_fill_tokens():
    o = load_owner(FIXTURE)
    assert o.fill("{Owner} said {owner}'s {OWNER} / {NOTES_HEADING}") == "Alex Rivera said Alex Rivera's ALEX RIVERA / ALEX RIVERA'S NOTES"
    g = Owner()
    assert g.fill("{Owner} is here, {owner}'s {OWNER}") == "The user is here, the user's THE USER"


def test_prompts_rendered_with_the_fixture_profile():
    r = render(FIXTURE)
    assert r["fast"].startswith("You are Verse, a live meeting assistant for Alex Rivera. Alex Rivera is on a call")
    assert "SAY: <one short sentence Alex Rivera can say at once" in r["fast"]
    assert r["deep"].startswith("You are the deep tier of Verse, a live meeting assistant for Alex Rivera. Alex Rivera is on a call.")
    assert "ABOUT ALEX RIVERA is the second block" in r["fast_me"] and "FROM ALEX RIVERA'S FILES" in r["fast_me"]
    assert "never tell Alex Rivera what to do" in r["fast_me"] and "Never invent a fact about Alex Rivera." in r["unprepared"]
    assert "holds Alex Rivera's own notes" in r["priorities"]
    assert r["about_header"].startswith("ABOUT ALEX RIVERA (his permanent profile") and r["files_header"].startswith("FROM ALEX RIVERA'S FILES")
    assert r["label"] == "Alex Rivera"
    assert "WHAT ALEX RIVERA HAS SAID SO FAR: my words" in r["follow"] and "ABOUT ALEX RIVERA have nothing grounded" in r["follow"]
    assert "invites Alex Rivera to explain" in r["statement"] and "acknowledgement Alex Rivera can say" in r["statement"]
    assert r["card_now"].count("CARD NOW. Alex Rivera pressed the card key") == 1
    assert "ask or invite ALEX RIVERA to explain" in r["room"] and "whether ALEX RIVERA has done" in r["room"]
    assert "you turn Alex Rivera's own material" in r["prep"] and "ask Alex Rivera in this meeting" in r["prep"]
    assert "shows Alex Rivera short lines" in r["me"] and "## ALEX RIVERA'S NOTES\n(leave this section empty" in r["me"]
    assert r["sections"][-1] == "ALEX RIVERA'S NOTES" and r["tag"] == "alex-rivera"
    assert r["legacy"] == ["## VOICE", "## ALEX RIVERA'S VOICE"]
    assert "candidate_said" in r["extract"]
    for k, v in r.items():
        assert no_template_tokens(json.dumps(v)), k


def test_prompts_rendered_without_a_profile(tmp_path):
    r = render(tmp_path / "does-not-exist.json")
    assert r["fast"].startswith("You are Verse, a live meeting assistant for the user. The user is on a call")
    assert "SAY: <one short sentence the user can say at once" in r["fast"]
    assert "ABOUT THE USER is the second block" in r["fast_me"]
    assert r["label"] == "the user" and r["about_header"].startswith("ABOUT THE USER (his permanent")
    assert "WHAT THE USER HAS SAID SO FAR" in r["follow"]
    assert "you turn the user's own material" in r["prep"]
    assert r["sections"][-1] == "MY NOTES" and "## MY NOTES\n(leave this section empty" in r["me"]
    assert r["tag"] == "owner" and r["legacy"] == ["## VOICE"]
    for k, v in r.items():
        assert no_template_tokens(json.dumps(v)), k


def test_the_two_renderings_differ_only_by_the_name(tmp_path):
    with_profile, without = render(FIXTURE)["fast_me"], render(tmp_path / "none.json")["fast_me"]
    assert with_profile.replace("Alex Rivera", "@").replace("ALEX RIVERA", "@") == \
        without.replace("The user", "@").replace("the user", "@").replace("THE USER", "@")


def test_no_vault_without_a_profile(tmp_path):
    code = ("from verse_brain.prep import vault, me\n"
            "assert vault.DEFAULT_VAULT is None and me.DOWNLOADS_PROFILE is None\n"
            "assert vault.make_vault(None) is None and me.forbidden_vault_path(__import__('pathlib').Path('/tmp/x')) is False\n"
            "import tempfile, pathlib\n"
            "s = me.default_sources(sessions=pathlib.Path(tempfile.mkdtemp()))\n"
            "assert [x['kind'] for x in s] == ['sessions'], s\n"
            "print('ok')")
    import os
    env = {**os.environ, "VERSE_OWNER_FILE": str(tmp_path / "none.json")}
    r = subprocess.run([sys.executable, "-I", "-c", f"import sys; sys.path.insert(0, {str(BRAIN)!r}); exec({code!r})"],
                       capture_output=True, text=True, env=env, cwd=str(BRAIN), timeout=60)
    assert r.returncode == 0 and r.stdout.strip() == "ok", r.stderr[-600:]


def test_vault_layout_comes_from_the_profile(tmp_path):
    vault = tmp_path / "vault"
    (vault / "Work" / "Alpha").mkdir(parents=True)
    (vault / "Work" / "Scratch").mkdir()
    (vault / "Work" / "Index.md").write_text("index")
    (vault / "Work" / "Alpha" / "a.md").write_text("alpha")
    (vault / "Work" / "Scratch" / "s.md").write_text("scratch")
    (vault / "Journal").mkdir()
    (vault / "Journal" / "j.md").write_text("private")
    code = ("import pathlib, sys\n"
            "from verse_brain.prep import me\n"
            f"v = pathlib.Path({str(vault)!r})\n"
            "labels = [s['label'] for s in me.default_sources(vault=v, downloads_profile=None, sessions=v / 'none')]\n"
            "assert labels[:2] == ['Work/Index.md', 'Work/Alpha/a.md'] and not any('Scratch' in l for l in labels), labels\n"
            "assert me.forbidden_vault_path(v / 'Journal' / 'j.md', v) and not me.forbidden_vault_path(v / 'Work' / 'Index.md', v)\n"
            "print('ok')")
    import os
    env = {**os.environ, "VERSE_OWNER_FILE": str(FIXTURE)}
    r = subprocess.run([sys.executable, "-I", "-c", f"import sys; sys.path.insert(0, {str(BRAIN)!r}); exec({code!r})"],
                       capture_output=True, text=True, env=env, cwd=str(BRAIN), timeout=60)
    assert r.returncode == 0 and r.stdout.strip() == "ok", r.stderr[-600:]


def test_script_vault_uses_the_profile_script_name(tmp_path, monkeypatch):
    from verse_brain.prep.vault import ScriptVault, VaultError
    (tmp_path / "find.py").write_text("")
    v = ScriptVault(tmp_path, python="py", script_name="find.py")
    assert v.script == tmp_path / "find.py" and v.command("q", 2, 100)[1] == str(tmp_path / "find.py")
    with pytest.raises(VaultError):
        ScriptVault(None)
    with pytest.raises(VaultError):
        ScriptVault(tmp_path, script_name="missing.py").search("q")


def test_keychain_account_is_the_current_user_at_runtime(monkeypatch):
    from verse_brain.prep import keychain
    seen = {}

    class R:
        returncode, stdout = 0, "sk-ant-api03-not-a-real-key-0000\n"

    def fake_run(cmd, **kw):
        seen["cmd"] = cmd
        return R()

    monkeypatch.setattr(keychain.subprocess, "run", fake_run)
    monkeypatch.setenv("USER", "someone-else")
    keychain.read_api_key()
    assert seen["cmd"][seen["cmd"].index("-a") + 1] == "someone-else"
