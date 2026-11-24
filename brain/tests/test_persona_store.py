"""persona/store.py: merge rules, owner edits and deletions, contradictions, the write guard; plus the owner profile key and the
vault exclusion that keep the persona from feeding itself. Temp dirs only; fictional content."""

import hashlib
import json
import os
from pathlib import Path

import pytest

from verse_brain.owner import load_owner
from verse_brain.persona.extract import Item
from verse_brain.persona.store import (CORRECTIONS, MARKER, PERSONA_MD, PersonaGuardError, PersonaOff, PersonaStore, parse_doc)
from verse_brain.prep.vault import MarkdownFolderVault, ProviderVault


def it(kind="claim", topic="salary expectation", text="I am looking for around 95,000 euros base.", quote="around 95,000 euros",
       skey="saaaaaa", stamp="0:47", ev="own", question=""):
    return Item(kind, topic, text, quote, skey, stamp, ev, question)


@pytest.fixture
def vault(tmp_path):
    v = tmp_path / "vault"
    v.mkdir()
    (v / "Projects").mkdir()
    (v / "Projects" / "Alpha.md").write_text("alpha notes about streaming\n")
    (v / "Home.md").write_text("home\n")
    return v


def store_in(vault, name="Verse Persona"):
    s = PersonaStore(vault / name, vault.parent / "state" / "persona.meta.json")
    s.load()
    return s


def hashes(root: Path, skip: str) -> dict:
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob("*")) if p.is_file() and skip not in p.parts}


def reload(s):
    s2 = PersonaStore(s.dir, s.state_path)
    s2.load()
    return s2


# ---------------------------------------------------------------- merge and render
def test_items_land_in_their_sections_and_rerendering_is_byte_stable(vault):
    s = store_in(vault)
    r = s.merge([it(), it("style", "answer shape", "I start with the result.", "start with the result", stamp="1:03"),
                 it("answer", "why leaving", "I want a smaller company.", "I want a smaller company", stamp="0:31", ev="read",
                    question="Why are you leaving?")], "acme-intro", "2026-11-17")
    s.save()
    assert r.new == ["p001", "p002", "p003"]
    doc = parse_doc((s.dir / PERSONA_MD).read_text())
    found = doc.entry_lines()
    assert found["p001"][0] == "SAID BEFORE" and found["p002"][0] == "HOW I ANSWER" and found["p003"][0] == "MY ANSWERS BY TOPIC"
    assert '2026-11-17 [saaaaaa 0:47] "around 95,000 euros"' in found["p001"][1]
    text = (s.dir / PERSONA_MD).read_text()
    assert text.startswith("---\ntitle: Verse Persona\ncreated: ") and "type: persona" in text
    s2 = reload(s)
    s2.save()
    assert (s.dir / PERSONA_MD).read_text() == text


def test_a_repeat_adds_evidence_and_the_same_cite_is_not_added_twice(vault):
    s = store_in(vault)
    s.merge([it()], "a", "2026-11-17")
    r = s.merge([it(), it(text="I am looking for around 95,000 euros base salary.", skey="sbbbbbb", stamp="0:10")], "b", "2026-11-20")
    assert r.new == [] and r.repeats == 2
    assert len(s.state["entries"]["p001"]["evidence"]) == 2


def test_an_owner_edit_is_kept_verbatim_and_its_fields_win(vault):
    s = store_in(vault)
    s.merge([it()], "a", "2026-11-17")
    s.save()
    md = s.dir / PERSONA_MD
    edited = "- [p001] salary expectation | I want 100,000 euros base. | my own wording"
    md.write_text(md.read_text().replace(next(l for l in md.read_text().splitlines() if l.startswith("- [p001]")), edited))
    s2 = reload(s)
    s2.merge([it("style", "pace", "I speak slowly and clearly.", "speak slowly and clearly", stamp="1:10")], "a2", "2026-11-18")
    s2.save()
    assert edited in md.read_text().splitlines()
    assert s2.fields(s2.state["entries"]["p001"])["text"] == "I want 100,000 euros base."
    reload(s2).save()
    assert edited in md.read_text().splitlines()


def test_a_deleted_id_never_returns_and_my_corrections_are_untouched(vault):
    s = store_in(vault)
    s.merge([it(), it("style", "pace", "I speak slowly.", "speak slowly please", stamp="1:10")], "a", "2026-11-17")
    s.save()
    md = s.dir / PERSONA_MD
    lines = md.read_text().splitlines()
    corrections = ["- I never worked in banking.", "  free text the owner wrote, with | pipes | and [p999] ids"]
    out = []
    for ln in lines:
        if ln.startswith("- [p001]"):
            continue                              # the owner deletes p001
        out.append(ln)
        if ln == f"## {CORRECTIONS}":
            out += corrections
    md.write_text("\n".join(out) + "\n")
    s2 = reload(s)
    assert "p001" in s2.state["deleted"] and "p001" not in s2.state["entries"]
    r = s2.merge([it()], "a", "2026-11-17")          # the same words again (a forced re-run)
    s2.merge([it("claim", "relocation", "I would move to Lisbon.", "move to Lisbon", stamp="2:00")], "c", "2026-11-19")
    s2.save()
    text = md.read_text()
    assert r.deleted == 1 and "[p001]" not in text
    assert "[p003]" in text                           # a new id, never p001 again
    body = text.split(f"## {CORRECTIONS}\n", 1)[1].split("\n## ", 1)[0]
    assert body.splitlines()[:2] == corrections
    assert s2.corrections == ["I never worked in banking."]


def test_a_contradiction_keeps_both_dated_quotes_and_removes_neither(vault):
    s = store_in(vault)
    s.merge([it()], "acme", "2026-11-17")
    r = s.merge([it(text="I expect around 110,000 euros base.", quote="around 110,000 euros base", skey="sbbbbbb", stamp="0:15")],
                "globex", "2026-11-24")
    s.save()
    assert r.new == ["p002"] and r.contradictions == ["c001"]
    ents = s.state["entries"]
    assert ents["p001"]["status"] == ents["p002"]["status"] == "contested"
    line = parse_doc((s.dir / PERSONA_MD).read_text()).entry_lines()["c001"][1]
    assert '2026-11-17 [saaaaaa 0:47] "around 95,000 euros" [p001]' in line
    assert '2026-11-24 [sbbbbbb 0:15] "around 110,000 euros base" [p002]' in line and line.endswith("| open")
    # a third run on the same pair does not add a second contradiction
    assert s.merge([it(text="I expect around 110,000 euros base.", quote="around 110,000 euros base", skey="sbbbbbb",
                       stamp="0:15")], "globex", "2026-11-24").contradictions == []
    # the model can flag one too, by id
    flagged = Item("claim", "pay", "I'd take less for a remote role.", "take less for a remote role", "saaaaaa", "3:00", "own",
                   contradicts="p001")
    r3 = s.merge([flagged], "acme", "2026-11-17")
    assert len(r3.contradictions) == 1


def test_the_owner_settles_a_contradiction_by_editing_its_last_field(vault):
    s = store_in(vault)
    s.merge([it()], "acme", "2026-11-17")
    s.merge([it(text="I expect around 110,000 euros base.", quote="around 110,000 euros base", skey="sbbbbbb", stamp="0:15")],
            "globex", "2026-11-24")
    s.save()
    md = s.dir / PERSONA_MD
    t = md.read_text()
    c_line = next(l for l in t.splitlines() if l.startswith("- [c001]"))
    md.write_text(t.replace(c_line, c_line[: -len("open")] + "keep 2"))
    s2 = reload(s)
    ents = s2.state["entries"]
    assert ents["c001"]["state"] == "resolved" and ents["c001"]["keep"] == "p002"
    assert ents["p002"]["status"] == "live" and ents["p001"]["status"] == "superseded"
    s2.save()
    assert "p001" in md.read_text() and "superseded" in next(l for l in md.read_text().splitlines() if l.startswith("- [p001]"))


def test_a_save_folds_in_edits_made_after_load(vault):
    s = store_in(vault)
    s.merge([it(), it("style", "pace", "I speak slowly.", "speak slowly please", stamp="1:10")], "a", "2026-11-17")
    s.save()
    s2 = reload(s)                                     # the app's resolve (or the seed import) loads first ...
    md = s.dir / PERSONA_MD
    t = md.read_text()                                 # ... and the owner edits the note before the write
    t = "\n".join(l for l in t.splitlines() if not l.startswith("- [p002]")) + "\n"
    md.write_text(t.replace(f"## {CORRECTIONS}\n", f"## {CORRECTIONS}\n- typed while it ran\n"))
    s2.merge([it("claim", "relocation", "I would move to Lisbon.", "move to Lisbon", stamp="2:00")], "c", "2026-11-19")
    s2.save()
    text = md.read_text()
    assert "- typed while it ran" in text and "[p002]" not in text and "[p003]" in text
    assert "p002" in s2.state["deleted"] and s2.corrections == ["typed while it ran"]


def test_resolve_from_code(vault):
    s = store_in(vault)
    s.merge([it()], "acme", "2026-11-17")
    s.merge([it(text="I expect around 110,000 euros base.", quote="around 110,000 euros base", skey="sbbbbbb", stamp="0:15")],
            "globex", "2026-11-24")
    s.resolve("c001", "1")
    assert s.state["entries"]["p001"]["status"] == "live" and s.state["entries"]["p002"]["status"] == "superseded"


# ---------------------------------------------------------------- the write guard
def test_writes_outside_persona_dir_are_refused(vault):
    s = store_in(vault)
    s.save()
    for rel in ("../Home.md", "../Projects/Alpha.md", "/tmp/x.md", "Log/../../Home.md", "."):
        with pytest.raises(PersonaGuardError):
            s.guard.write(rel, "x")
    os.symlink(vault / "Home.md", s.dir / "link.md")
    with pytest.raises(PersonaGuardError):
        s.guard.write("link.md", "x")
    (s.dir / "Mine.md").write_text("the owner's own note in the folder\n")
    with pytest.raises(PersonaGuardError):
        s.guard.write("Mine.md", "x")                       # a file Verse did not create
    assert (vault / "Home.md").read_text() == "home\n" and (s.dir / "Mine.md").read_text().startswith("the owner's")


def test_a_non_empty_unmarked_folder_is_never_adopted_and_nothing_else_changes(vault):
    target = vault / "Projects"
    before = hashes(vault, "none")
    s = PersonaStore(target, vault.parent / "state.json")
    with pytest.raises(PersonaGuardError):
        s.load()
    with pytest.raises(PersonaGuardError):
        s.save()
    assert hashes(vault, "none") == before and not (target / MARKER).exists()


def test_vault_files_are_unchanged_by_a_full_save(vault):
    before = hashes(vault, "Verse Persona")
    s = store_in(vault)
    s.merge([it()], "a", "2026-11-17")
    s.save()
    s.write_log("2026-11-17", "saaaaaa", "a", [it()], {"quote": 1}, "2026-11-17T10:00:00Z")
    assert hashes(vault, "Verse Persona") == before
    marker = json.loads((s.dir / MARKER).read_text())
    assert sorted(marker["files"]) == ["Log/2026-11-17 saaaaaa.md", PERSONA_MD]
    assert not any(p.name.endswith(".verse-tmp") for p in s.dir.rglob("*"))


def test_the_log_note_is_append_only(vault):
    s = store_in(vault)
    s.write_log("2026-11-17", "saaaaaa", "a", [it()], {}, "T1")
    first = (s.dir / "Log" / "2026-11-17 saaaaaa.md").read_text()
    s.write_log("2026-11-17", "saaaaaa", "a", [], {"cite": 2}, "T2")
    second = (s.dir / "Log" / "2026-11-17 saaaaaa.md").read_text()
    assert second.startswith(first.rstrip("\n")) and "## Run T2" in second and "cite 2" in second


def test_without_persona_dir_the_feature_is_off(tmp_path):
    with pytest.raises(PersonaOff):
        PersonaStore(None, tmp_path / "s.json")
    assert list(tmp_path.iterdir()) == []


def test_parent_of_persona_dir_must_exist(tmp_path):
    s = PersonaStore(tmp_path / "no-vault" / "Verse Persona", tmp_path / "s.json")
    s.load()
    with pytest.raises(PersonaGuardError):
        s.save()
    assert not (tmp_path / "no-vault").exists()


def test_concurrent_runs_are_refused(vault):
    from verse_brain.persona.store import PersonaBusy

    s = store_in(vault)
    with s.locked():
        with pytest.raises(PersonaBusy):
            with reload(s).locked():
                pass


# ---------------------------------------------------------------- owner.json and the vault reader
def test_owner_persona_dir_is_absolute_or_relative_to_the_vault(tmp_path):
    f = tmp_path / "owner.json"
    f.write_text(json.dumps({"vault_path": str(tmp_path / "v"), "persona_dir": "Verse Persona"}))
    assert load_owner(f).persona_dir == tmp_path / "v" / "Verse Persona"
    f.write_text(json.dumps({"vault_path": str(tmp_path / "v"), "persona_dir": str(tmp_path / "elsewhere")}))
    assert load_owner(f).persona_dir == tmp_path / "elsewhere"
    f.write_text(json.dumps({"persona_dir": "Verse Persona"}))
    assert load_owner(f).persona_dir is None                  # relative without a vault: off
    f.write_text(json.dumps({"vault_path": str(tmp_path / "v")}))
    assert load_owner(f).persona_dir is None


def test_the_vault_reader_never_returns_persona_notes(vault):
    s = store_in(vault)
    s.merge([it(topic="streaming platform", text="I moved alpha to streaming.", quote="alpha to streaming")], "a", "2026-11-17")
    s.save()
    plain = MarkdownFolderVault(vault, forbidden=[], private=[], persona_dir=vault / "nowhere").search("streaming alpha", limit=5)
    assert any(r.source.startswith("Verse Persona") for r in plain)       # the fixture really would match
    recs = MarkdownFolderVault(vault, forbidden=[], private=[], persona_dir=s.dir).search("streaming alpha", limit=5)
    assert recs and not any(r.source.startswith("Verse Persona") for r in recs)

    class P:
        def search(self, query, limit=3):
            return [{"source": "Verse Persona/Persona.md", "text": "x"}, {"source": "verse persona/Log/a.md", "text": "y"},
                    {"source": "Projects/Alpha.md", "text": "z"}]

    from verse_brain.prep import vault as vault_mod

    old = vault_mod.OWNER
    vault_mod.OWNER = old.__class__(**{**{k: getattr(old, k) for k in old.__dataclass_fields__}, "persona_dir": s.dir})
    try:
        got = ProviderVault(P(), vault).search("q", limit=5)
    finally:
        vault_mod.OWNER = old
    assert [r.source for r in got] == ["Projects/Alpha.md"]


def test_a_lost_state_file_keeps_the_notes_and_never_reuses_their_ids(vault):
    s = store_in(vault)
    s.merge([it()], "a", "2026-11-17")
    s.save()
    s.state_path.unlink()
    s2 = reload(s)
    r = s2.merge([it("style", "pace", "I speak slowly.", "speak slowly please", stamp="1:10")], "b", "2026-11-18")
    s2.save()
    text = (s.dir / PERSONA_MD).read_text()
    assert r.new == ["p002"] and text.count("[p001]") == 1 and "95,000" in text
