"""The me layer, build side (prep/me.py): distillation with a scripted model, quote verification, trim, refresh, files.

Everything runs offline on the fictional Dana Reyes fixtures (tests/fixtures/me/). No network, no key, no vault."""

from __future__ import annotations

import asyncio
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path

import pytest

from verse_brain.prep import me as M
from verse_brain.prep.model import ModelOutput, PrepError, Usage
from verse_brain.runtime.me import read_emb

FIX = Path(__file__).resolve().parent / "fixtures" / "me"
OUTPUT = (FIX / "model_output.txt").read_text(encoding="utf-8")
NOW = lambda: datetime(2026, 10, 16, 9, 0, tzinfo=timezone.utc)  # noqa: E731


class ScriptedModel:
    model = "claude-sonnet-5-5"

    def __init__(self, *outputs: str) -> None:
        self.outputs = list(outputs)
        self.users: list[str] = []

    async def generate(self, system: str, user: str, max_tokens: int):
        self.users.append(user)
        out = self.outputs.pop(0) if len(self.outputs) > 1 else self.outputs[0]
        return ModelOutput(out, Usage(input=4000, output=900), "end_turn")

    async def count_tokens(self, text: str) -> int:
        return len(text) // 4

    async def count_request_tokens(self, system: str, user: str) -> int:
        return (len(system) + len(user)) // 4


def setup(tmp_path: Path) -> tuple[Path, Path]:
    """-> (profile dir, vault root): writable copies of the Dana sources and a me.sources.json that names them."""
    src = tmp_path / "src"
    shutil.copytree(FIX / "vault", src / "vault")
    shutil.copytree(FIX / "sessions", src / "sessions")
    shutil.copy(FIX / "dana_profile.md", src / "dana_profile.md")
    prof = tmp_path / "profile"
    prof.mkdir()
    sources = [
        {"id": "s1", "kind": "file", "path": str(src / "dana_profile.md"), "label": "dana_profile.md", "enabled": True},
        {"id": "s2", "kind": "vault", "path": str(src / "vault" / "Harbor Ledger.md"), "label": "Harbor Ledger.md", "enabled": True},
        {"id": "s3", "kind": "vault", "path": str(src / "vault" / "Trailhead.md"), "label": "Trailhead.md", "enabled": True},
        {"id": "s4", "kind": "sessions", "path": str(src / "sessions"), "label": "session facts", "enabled": True},
    ]
    (prof / "me.sources.json").write_text(json.dumps(sources), encoding="utf-8")
    return prof, src / "vault"


def build(prof: Path, vault: Path, model: ScriptedModel, **kw) -> M.BuildResult:
    return asyncio.run(M.build_profile(prof, model=model, vault=vault, now=NOW, **kw))


def lines_of(prof: Path) -> dict[str, M.MLine]:
    return {l.id: l for ls in M.parse_md((prof / "me.md").read_text(encoding="utf-8")).values() for l in ls if l.id}


# ---------------------------------------------------------------- build
def test_build_keeps_verified_lines_and_drops_the_rest(tmp_path):
    prof, vault = setup(tmp_path)
    r = build(prof, vault, ScriptedModel(OUTPUT))
    got = lines_of(prof)
    # a quote that is not in its source, one whose number is not in its quote, one for a source that does not exist
    assert "m002" not in got and "m203" not in got and "m406" not in got and "m303" not in got
    assert r.dropped == {"quote_not_in_source": 2, "number_not_in_quote": 1, "unknown_source": 1}
    assert sorted(got) == ["m001", "m101", "m102", "m201", "m202", "m301", "m302", "m401", "m402", "m403", "m404", "m405",
                           "m501", "m502", "m601"]
    # section order, one id range per section, the notes section last and empty
    md = (prof / "me.md").read_text(encoding="utf-8")
    heads = [l for l in md.splitlines() if l.startswith("## ")]
    assert heads == ["## WHO I AM", "## EXPERIENCE", "## PROJECTS", "## SKILLS", "## NUMBERS", "## STORIES", "## LOOKING FOR",
                     "## MY NOTES"]
    # the src of a line is rewritten from what was verified: a real reference with the line number
    assert got["m001"].src == "file:dana_profile.md#L3"
    assert got["m405"].src.startswith("vault:Harbor Ledger.md#L")
    # files
    for name in ("me.md", "me.meta.json", "me.sources.json", "me.facts.jsonl", "me.library.jsonl"):
        assert (prof / name).is_file(), name
    meta = json.loads((prof / "me.meta.json").read_text(encoding="utf-8"))
    assert meta["built_at"] == "2026-10-16T09:00:00+00:00" and meta["tokens"] == r.tokens and meta["model"] == "claude-sonnet-5-5"
    assert meta["spend_usd"] == pytest.approx(0.017, abs=1e-6) and set(meta["sources"]) == {"s1", "s2", "s3", "s4"}
    assert set(meta["lines"]) == set(got)                      # the hash of every generated line
    assert meta["library"]["chunks"] > 0


def test_numbers_become_facts_in_the_facts_jsonl_schema(tmp_path):
    prof, vault = setup(tmp_path)
    build(prof, vault, ScriptedModel(OUTPUT))
    recs = [json.loads(l) for l in (prof / "me.facts.jsonl").read_text(encoding="utf-8").splitlines()]
    assert [r["id"] for r in recs] == ["m401", "m402", "m403", "m404", "m405"]
    for r in recs:
        assert set(r) == {"id", "kind", "text", "value", "sources"}
        assert r["kind"] in ("number", "date", "name") and r["text"] and r["value"]
        s = r["sources"][0]
        assert set(s) == {"kind", "ref", "quote"} and s["ref"] and s["quote"]
    assert recs[0]["value"] == "41000" and recs[3]["kind"] == "date" and recs[3]["value"] == "2027-01"


def test_session_facts_skip_samples_and_fixture_preps(tmp_path):
    root = tmp_path / "sessions"
    for name, meta, fact in (("sample-demo", {}, "from a sample"), ("real-one", {"prep_note": "/Users/x/note.md"}, "from a real prep"),
                             ("fixture-run", {"prep_note": "/repo/brain/tests/fixtures/prep/prep_note.md"}, "from a fixture")):
        (root / name).mkdir(parents=True)
        (root / name / "meta.json").write_text(json.dumps(meta), encoding="utf-8")
        (root / name / "facts.jsonl").write_text(json.dumps({"id": "f001", "kind": "number", "text": fact, "value": "1"}) + "\n",
                                                  encoding="utf-8")
        (root / name / "bank.jsonl").write_text(json.dumps({"id": "b001", "question": "BANK ANSWER"}) + "\n", encoding="utf-8")
    text = M.session_facts_text(root)
    assert "from a real prep" in text and "from a sample" not in text and "from a fixture" not in text
    assert "BANK ANSWER" not in text            # bank answers are meeting-specific: never read


def test_fake_cli_builds_offline_and_show_reports(tmp_path, capsys):
    prof, vault = setup(tmp_path)
    assert M.me_main(["build", "--fake", "--profile-dir", str(prof)]) == 0
    out = capsys.readouterr()
    assert out.out.strip() == str(prof)                             # stdout is the profile dir
    assert "tokens" in out.err and "spend $" in out.err
    assert "[m001]" in (prof / "me.md").read_text(encoding="utf-8")
    assert M.me_main(["show", "--profile-dir", str(prof)]) == 0
    shown = capsys.readouterr().out
    assert "tokens" in shown and "WHO I AM" in shown and "stale sources: none" in shown
    (tmp_path / "src" / "vault" / "Trailhead.md").write_text("# Trailhead\n\nChanged text of the note, long enough to matter.\n",
                                                             encoding="utf-8")
    M.me_main(["show", "--profile-dir", str(prof)])
    assert "stale sources: Trailhead.md" in capsys.readouterr().out


# ---------------------------------------------------------------- size
def _lines(section: str, n: int, base: int, words: int = 30) -> list[M.MLine]:
    fields = {M.WHO: 1, M.STORIES: 2, M.SKILLS: 2, M.PROJECTS: 5, M.EXPERIENCE: 4, M.NUMBERS: 3}[section]
    out = []
    for i in range(n):
        f = [f"{section.lower()} item {i} " + "word " * words] * fields
        if section == M.NUMBERS:
            f = ["number", f"fact {i} " + "word " * words, str(1000 + i)]
        out.append(M.make_line(section, f"m{base + i + 1:03d}", f, "file:x.md"))
    return out


def _merged(per: dict[str, list[M.MLine]], protected: set[str] | None = None) -> M.Merged:
    return M.Merged({s: per.get(s, []) for s in M.SECTIONS}, set(protected or ()))


def test_trim_order_stories_then_skills_then_projects_then_experience():
    per = {M.WHO: _lines(M.WHO, 3, 0), M.NUMBERS: _lines(M.NUMBERS, 6, 400), M.STORIES: _lines(M.STORIES, 4, 500),
           M.SKILLS: _lines(M.SKILLS, 4, 300), M.PROJECTS: _lines(M.PROJECTS, 4, 200), M.EXPERIENCE: _lines(M.EXPERIENCE, 4, 100)}
    count = lambda t: asyncio.sleep(0, len(t) // 4)  # noqa: E731
    full = len(M.render_md(per)) // 4
    seen: list[dict] = []
    tok = lambda sec: sum(len(l.text) + 1 for l in per[sec]) // 4   # noqa: E731
    one = lambda sec: len(per[sec][-1].text) // 8                    # noqa: E731  (half of the last line, in tokens)
    st, sk, pr = tok(M.STORIES), tok(M.SKILLS), tok(M.PROJECTS)
    for cap in (full - one(M.STORIES), full - st - one(M.SKILLS), full - st - sk - one(M.PROJECTS), full - st - sk - pr - one(M.EXPERIENCE)):
        m = _merged({s: list(ls) for s, ls in per.items()})
        md, tokens, cut = asyncio.run(M.trim_to_cap(m, count, cap))
        assert tokens <= cap
        seen.append(cut)
        # NUMBERS and WHO I AM are never trimmed
        assert len(m.sections[M.NUMBERS]) == 6 and len(m.sections[M.WHO]) == 3
        # the tail goes first: what is left of a trimmed section is its head
        for s in M.TRIM_ORDER:
            ids = [l.id for l in sorted(m.sections[s], key=lambda l: M.id_number(l.id))]
            assert ids == sorted(ids) and ids == [f"m{(M.section_base(s) + i + 1):03d}" for i in range(len(ids))]
    c = [s for s in seen]
    assert c[0][M.STORIES] > 0 and c[0][M.SKILLS] == 0 and c[0][M.PROJECTS] == 0 and c[0][M.EXPERIENCE] == 0
    assert c[1][M.STORIES] == 4 and c[1][M.SKILLS] > 0 and c[1][M.PROJECTS] == 0
    assert c[2][M.SKILLS] == 4 and c[2][M.PROJECTS] > 0 and c[2][M.EXPERIENCE] == 0
    assert c[3][M.PROJECTS] == 4 and c[3][M.EXPERIENCE] > 0


def test_trim_never_touches_protected_lines_and_fails_when_only_they_remain():
    per = {M.NUMBERS: _lines(M.NUMBERS, 8, 400), M.STORIES: _lines(M.STORIES, 3, 500)}
    edited = per[M.STORIES][0].id
    count = lambda t: asyncio.sleep(0, len(t) // 4)  # noqa: E731
    m = _merged(per, {edited})
    md, tokens, cut = asyncio.run(M.trim_to_cap(m, count, len(M.render_md(per)) // 4 - 150))
    assert [l.id for l in m.sections[M.STORIES]] == [edited]       # the line he edited stays, the others went
    m2 = _merged({M.NUMBERS: _lines(M.NUMBERS, 8, 400)})
    with pytest.raises(M.MeError, match="cap"):
        asyncio.run(M.trim_to_cap(m2, count, 100))


def test_build_trims_to_the_cap(tmp_path, monkeypatch):
    prof, vault = setup(tmp_path)
    full = build(prof, vault, ScriptedModel(OUTPUT)).tokens
    monkeypatch.setattr(M, "CAP_TOKENS", full - 90)
    r = build(prof, vault, ScriptedModel(OUTPUT))
    assert r.tokens <= full - 90 and r.trimmed[M.STORIES] > 0                 # the stories' tail went first
    got = lines_of(prof)
    assert {"m401", "m402", "m403", "m404", "m405", "m001", "m601"} <= set(got)      # NUMBERS, WHO I AM, LOOKING FOR stay
    meta = json.loads((prof / "me.meta.json").read_text(encoding="utf-8"))
    assert meta["cap_tokens"] == full - 90 and meta["trimmed"][M.STORIES] == r.trimmed[M.STORIES]


# ---------------------------------------------------------------- refresh
def edit_md(prof: Path, fn) -> None:
    p = prof / "me.md"
    p.write_text(fn(p.read_text(encoding="utf-8")), encoding="utf-8")


def test_refresh_keeps_an_edited_line_and_a_deleted_id_and_skips_unchanged_sources(tmp_path):
    prof, vault = setup(tmp_path)
    m1 = ScriptedModel(OUTPUT)
    build(prof, vault, m1)
    before = lines_of(prof)

    def human(md: str) -> str:
        md = md.replace("Owns the claims-triage model and its serving stack.", "Owns the claims-triage model (my own wording).")
        md = "\n".join(l for l in md.splitlines() if not l.startswith("[m301]"))             # he deletes the Python skill
        return md.replace("## STORIES", "[m320] Rust | side projects at weekends | owner\n## STORIES")  # ...and adds a line

    edit_md(prof, human)
    # nothing changed in the sources: refresh does nothing and spends nothing
    m2 = ScriptedModel(OUTPUT)
    r = build(prof, vault, m2, refresh=True)
    assert r.unchanged and m2.users == [] and r.spend_usd == 0.0
    # a source changes: the model runs again, and it writes the old wording, the deleted skill (also under a new id) and a new line
    (tmp_path / "src" / "vault" / "Trailhead.md").write_text(
        (tmp_path / "src" / "vault" / "Trailhead.md").read_text(encoding="utf-8") + "\nThe app is also on the web.\n", encoding="utf-8")
    again = OUTPUT.replace("[m301] Python | Harbor Ledger", "[m309] Python | Harbor Ledger")
    again = again.replace("## NUMBERS", '[m303] Rust | none | SRC: S1 "Stack: Python, PostgreSQL, Kafka"\n## NUMBERS')
    m3 = ScriptedModel(again)
    r = build(prof, vault, m3, refresh=True)
    after = lines_of(prof)
    assert not r.unchanged and len(m3.users) == 1
    assert "Owns the claims-triage model (my own wording)." in after["m102"].text                 # the edit survived
    assert "m301" not in after and "m309" not in after                                           # a deleted id stays deleted
    assert not any(l.fields and l.fields[0] == "Python" for l in after.values())                 # not under another id either
    assert after["m320"].text == "[m320] Rust | side projects at weekends | owner"              # his own line, verbatim
    assert "m303" in after and after["m303"].fields[0] == "Rust"                                 # new generated lines come in
    assert after["m101"].text == before["m101"].text                                             # an untouched line is still there
    meta = json.loads((prof / "me.meta.json").read_text(encoding="utf-8"))
    assert "m102" in meta["lines"] and "m320" not in meta["lines"]                              # the edit keeps its generated hash
    assert {"id": "m301"}.items() <= meta["deleted"][0].items()
    # and a second refresh with the same sources is a no-op again
    assert build(prof, vault, ScriptedModel(again), refresh=True).unchanged


def test_notes_are_kept_never_regenerated_and_a_deleted_note_stays_deleted(tmp_path):
    prof, vault = setup(tmp_path)
    (prof / "me.notes.md").write_text("- I prefer calls in the morning.\n- My notice period is 30 days.\n", encoding="utf-8")
    model = ScriptedModel(OUTPUT)
    build(prof, vault, model)
    notes = M.parse_md((prof / "me.md").read_text(encoding="utf-8"))[M.NOTES]
    assert [l.text for l in notes] == ["[m701] I prefer calls in the morning. | owner", "[m702] My notice period is 30 days. | owner"]
    assert "I prefer calls in the morning." in model.users[0]      # the notes are a source for the other sections too
    edit_md(prof, lambda md: md.replace("[m702] My notice period is 30 days. | owner", "[m702] My notice period is 60 days. | owner")
            .replace("[m701] I prefer calls in the morning. | owner\n", ""))
    (prof / "me.notes.md").write_text("- I prefer calls in the morning.\n- My notice period is 30 days.\n- I speak Portuguese.\n",
                                      encoding="utf-8")
    build(prof, vault, ScriptedModel(OUTPUT), refresh=True)
    notes = M.parse_md((prof / "me.md").read_text(encoding="utf-8"))[M.NOTES]
    assert [l.text for l in notes] == ["[m702] My notice period is 60 days. | owner", "[m703] I speak Portuguese. | owner"]


def test_a_full_build_moves_the_old_file_aside(tmp_path):
    prof, vault = setup(tmp_path)
    build(prof, vault, ScriptedModel(OUTPUT))
    edit_md(prof, lambda md: md + "\n")
    r = build(prof, vault, ScriptedModel(OUTPUT))
    assert (prof / "me.md.bak").is_file() and any("moved to me.md.bak" in w for w in r.warnings)


# ---------------------------------------------------------------- sources and the vault
def test_default_sources_follow_the_spec_and_skip_private_folders(tmp_path):
    vault = tmp_path / "vault"
    proj = vault / "🏰 300-Projects"
    for rel in ("Projects.md", "TrailheadX/TrailheadX.md", "YouTube/A.md", "YouTube/B.md", "AgentLogs/agent-output.md", "Archive-Private/t.md",
                "../800-Journal/secret.md", "../700-Health/b.md", "../400-Private/v.md", "../daily/d.md", "../receipts/r.md", "../Inbox/i.md"):
        f = proj / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text("# note\n\nsome words in the note\n", encoding="utf-8")
    dl = tmp_path / "ENGINEERING_PROFILE.md"
    dl.write_text("# profile\n", encoding="utf-8")
    sessions = tmp_path / "sessions"
    sessions.mkdir()
    srcs = M.default_sources(vault, dl, sessions)
    paths = [Path(s["path"]).relative_to(tmp_path).as_posix() if Path(s["path"]).is_relative_to(tmp_path) else s["path"] for s in srcs]
    assert paths == ["ENGINEERING_PROFILE.md", "vault/🏰 300-Projects/Projects.md", "vault/🏰 300-Projects/TrailheadX/TrailheadX.md",
                     "vault/🏰 300-Projects/YouTube/A.md", "vault/🏰 300-Projects/YouTube/B.md", "sessions"]
    assert [s["kind"] for s in srcs] == ["file", "vault", "vault", "vault", "vault", "sessions"]
    assert all(s["enabled"] for s in srcs)
    for bad in ("800-Journal/secret.md", "700-Health/b.md", "400-Private/v.md", "daily/d.md", "receipts/r.md", "Inbox/i.md", "850-Notes/x.md"):
        assert M.forbidden_vault_path(vault / bad, vault), bad
    assert not M.forbidden_vault_path(proj / "Projects.md", vault)
    assert not M.forbidden_vault_path(tmp_path / "elsewhere" / "800-Journal" / "x.md", vault)   # only inside the vault


def test_a_source_inside_a_private_vault_folder_is_refused_and_never_read(tmp_path):
    vault = tmp_path / "vault"
    secret = vault / "800-Journal" / "diary.md"
    secret.parent.mkdir(parents=True)
    secret.write_text("PRIVATE TEXT THAT MUST NOT BE READ\n", encoding="utf-8")
    ok = tmp_path / "ok.md"
    ok.write_text("# ok\n\nA readable source with a few words in it.\n", encoding="utf-8")
    prof = tmp_path / "profile"
    docs, warnings = M.read_sources(M.Paths(prof), [{"id": "s1", "kind": "vault", "path": str(secret), "enabled": True},
                                                    {"id": "s2", "kind": "file", "path": str(ok), "enabled": True}], vault)
    assert [d.label for d in docs] == ["ok.md"] and any("private vault folder" in w for w in warnings)
    assert all("PRIVATE" not in d.text for d in docs)


def test_a_disabled_or_missing_source_is_skipped(tmp_path):
    ok = tmp_path / "ok.md"
    ok.write_text("# ok\n\nA readable source with a few words in it.\n", encoding="utf-8")
    docs, warnings = M.read_sources(M.Paths(tmp_path / "p"), [
        {"id": "s1", "kind": "file", "path": str(ok), "enabled": False},
        {"id": "s2", "kind": "file", "path": str(tmp_path / "gone.md"), "enabled": True}], tmp_path)
    assert docs == [] and warnings == ["source missing: gone.md"]


# ---------------------------------------------------------------- library
def test_chunks_follow_the_headings_and_stay_inside_the_limits():
    big = "# Doc\n\n## Long\n" + " ".join(f"Sentence number {i} is here." for i in range(300)) + "\n\n## Short\nA short section with enough words.\n"
    d = M.Doc("S1", "s1", "file", "file:big.md", "big.md", big)
    chunks = M.chunk_doc(d)
    assert chunks and all(len(c["text"]) <= M.CHUNK_CHARS for c in chunks)
    assert any(c["heading"] == "Short" and c["text"].startswith("## Short") for c in chunks)
    assert len({c["id"] for c in chunks}) == len(chunks)
    assert sum(1 for c in chunks if c["heading"] == "Long") >= 3                  # the long section was split
    many = M.Doc("S2", "s2", "file", "file:many.md", "many.md", "\n".join(f"## H{i}\nSome body text for section {i}, long enough." for i in range(500)))
    chunks, truncated = M.build_library([many, M.Doc("S3", "s3", "sessions", "session:x", "x", "# a\nplenty of words here, not chunked")])
    assert len(chunks) == M.MAX_CHUNKS and truncated
    assert all(c["ref"] != "session:x" for c in chunks)                          # session facts are not in the library


def test_vectors_are_written_with_the_model_key_and_read_back(tmp_path):
    prof, vault = setup(tmp_path)
    r = build(prof, vault, ScriptedModel(OUTPUT), embedder_factory=M.HashEmbedder)
    assert r.embedded and (prof / "me.library.emb").is_file()
    ids = [json.loads(l)["id"] for l in (prof / "me.library.jsonl").read_text(encoding="utf-8").splitlines()]
    vecs = read_emb(prof / "me.library.emb", "fake")
    assert vecs is not None and list(vecs) == ids and len(next(iter(vecs.values()))) == 64
    assert read_emb(prof / "me.library.emb", "another-model") is None              # made with another model: ignored
    raw = (prof / "me.library.emb").read_bytes()
    (prof / "me.library.emb").write_bytes(raw[:-5])
    assert read_emb(prof / "me.library.emb", "fake") is None                       # damaged: ignored


def test_an_unavailable_embedder_still_builds_the_library(tmp_path):
    prof, vault = setup(tmp_path)

    def broken():
        raise RuntimeError("no gpu")

    r = build(prof, vault, ScriptedModel(OUTPUT), embedder_factory=broken)
    assert not r.embedded and r.chunks > 0 and not (prof / "me.library.emb").exists()
    assert any("chunk vectors not written" in w for w in r.warnings)


def test_nothing_verifies_means_nothing_is_written(tmp_path):
    prof, vault = setup(tmp_path)
    with pytest.raises(PrepError, match="verified"):
        build(prof, vault, ScriptedModel('## WHO I AM\n[m001] An invented claim about the person. | SRC: S1 "a quote that is nowhere in the sources"\n'))
    assert not (prof / "me.md").exists() and not (prof / "me.meta.json").exists()


def test_the_prompt_carries_the_sources_but_the_session_facts_are_labelled(tmp_path):
    prof, vault = setup(tmp_path)
    model = ScriptedModel(OUTPUT)
    build(prof, vault, model)
    user = model.users[0]
    assert '<source id="S1" ref="file:dana_profile.md">' in user and '<source id="S2" ref="vault:Harbor Ledger.md">' in user
    assert "# session dana-interview" in user and "sample session fact" not in user
    assert M.SYSTEM.count("SRC: S") >= 1 and "(10 to 160 characters" in M.SYSTEM


# ---------------------------------------------------------------- an extra source file in me.sources.json
def test_an_extra_source_file_listed_in_me_sources_json_is_read_by_build_and_refresh(tmp_path):
    prof, vault = setup(tmp_path)
    extra = tmp_path / "extra_notes.txt"
    extra.write_text("Dana also teaches a weekend workshop on reconciliation for new engineers.\n", encoding="utf-8")
    sources = json.loads((prof / "me.sources.json").read_text(encoding="utf-8"))
    # a plain file outside the vault, any extension, added at the end of the list: the next build reads it as the next S handle
    sources.append({"id": "s5", "kind": "file", "path": str(extra), "label": "extra_notes.txt", "enabled": True})
    (prof / "me.sources.json").write_text(json.dumps(sources), encoding="utf-8")

    m1 = ScriptedModel(OUTPUT)
    build(prof, vault, m1)
    assert "weekend workshop on reconciliation" in m1.users[0] and 'ref="file:extra_notes.txt"' in m1.users[0]
    assert json.loads((prof / "me.meta.json").read_text(encoding="utf-8"))["sources"]["s5"]

    # refresh: a source added after the first build counts as a changed source, and its line is verified against it
    later = tmp_path / "later.md"
    later.write_text("# Later\nDana mentors two junior engineers at Larkspur Health.\n", encoding="utf-8")
    sources.append({"id": "s6", "kind": "file", "path": str(later), "label": "later.md", "enabled": True})
    (prof / "me.sources.json").write_text(json.dumps(sources), encoding="utf-8")
    handle = len([s for s in sources if s["id"] != "s6"]) + 1          # S-number of the new file among the readable ones
    line = f'[m204] Mentoring | Mentors two junior engineers | SRC: S{handle} "Dana mentors two junior engineers at Larkspur Health"'
    grown = OUTPUT.replace("## SKILLS", line.replace("[m204] Mentoring | ", "[m204] Mentoring | volunteer | none | none | ") + "\n## SKILLS", 1)
    m2 = ScriptedModel(grown)
    r = build(prof, vault, m2, refresh=True)
    assert not r.unchanged and "mentors two junior engineers" in m2.users[0].lower()
    assert "m204" in lines_of(prof) and "later.md" not in " ".join(r.warnings)
