"""Memory index (P1): schema, keys, chunking, sync / put / drop, secure delete, vectors, FTS folding.

Fixtures: tests/fixtures/memory/sessions (fictional: Marta Velin and Joe Arkwright of Halden Works, Giulia Ferri of Corvo Studio,
Emre Kaya of Tarla Labs, owner Dana Reyes). The helpers below are shared with test_memory_search.py and test_runtime_memory_index.py.
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path

import pytest

from verse_brain.memory import index as idx
from verse_brain.memory.index import MemoryIndex, session_key
from verse_brain.runtime.ask import Row, parse_rows

FIX = Path(__file__).resolve().parent / "fixtures" / "memory" / "sessions"

META = {
    "halden-kickoff": ("Halden Kickoff", "2026-10-19T17:00:00+02:00", "meeting", "en", ["Marta Velin", "Halden Works"]),
    "halden-pilot-review": ("Halden Pilot Review", "2026-10-26T10:00:00+01:00", "meeting", "en", ["Marta Velin", "Halden Works"]),
    "corvo-design-call": ("Corvo Design Call", "2026-10-20T15:00:00+02:00", "call", "it", ["Giulia Ferri", "Corvo Studio"]),
    "tarla-intro": ("Tarla Intro", "2026-10-21T09:00:00+02:00", "call", "tr", ["Emre Kaya", "Tarla Labs"]),
    "halden-weekly-prep": ("Halden Weekly Prep", "2026-10-27T09:00:00+01:00", "prepared", "en", ["Joe Arkwright", "Halden Works"]),
}
CALENDAR = "tarla-intro"          # the session the delete tests drop
SECRET_SENTENCE = "Mavi ahtapot protokolü için imzalı ek gerekiyor"


def fixture_rows(name: str) -> list[Row]:
    p = FIX / name / "rows.json"
    return parse_rows(json.loads(p.read_text(encoding="utf-8"))) if p.is_file() else []


def put_fixture(index: MemoryIndex, name: str, fp: str | None = None, labels: list[str] | None = None):
    title, date, kind, lang, lab = META[name]
    return index.put(name=name, dir=FIX / name, fp=fp or f"fp-{name}", title=title, date=date, kind=kind, lang=lang,
                     labels=lab if labels is None else labels, rows=fixture_rows(name))


def put_all(index: MemoryIndex) -> dict[str, str]:
    return {n: put_fixture(index, n).key for n in META}


def manifest(names, fp_of=lambda n: f"fp-{n}") -> list[dict]:
    return [{"name": n, "fp": fp_of(n), "labels": META[n][4]} for n in names]


def rows_of(n: int, prefix: str = "line") -> list[Row]:
    return [Row(f"0:{i:02d}", "Dana" if i % 2 else "Marta", f"{prefix} number {i} about the plan") for i in range(n)]


@pytest.fixture
def index(tmp_path):
    ix = MemoryIndex.open(tmp_path / "memory" / "index.sqlite")
    yield ix
    ix.close()


def tables(con) -> set[str]:
    return {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type IN ('table','view')")}


# ---------------------------------------------------------------- schema
def test_schema_and_reopen(tmp_path):
    path = tmp_path / "memory" / "index.sqlite"
    ix = MemoryIndex.open(path)
    assert ix.con.execute("PRAGMA user_version").fetchone()[0] == idx.SCHEMA_VERSION == 1
    assert ix.con.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
    assert ix.con.execute("PRAGMA foreign_keys").fetchone()[0] == 1
    assert ix.con.execute("PRAGMA secure_delete").fetchone()[0] == 1
    assert {"meta", "sessions", "rows", "chunks", "chunks_fts", "vectors"} <= tables(ix.con)
    put_fixture(ix, "halden-kickoff")
    n = ix.counts()["chunks"]
    ix.close()
    again = MemoryIndex.open(path)
    assert again.counts()["chunks"] == n and [s.name for s in again.sessions()] == ["halden-kickoff"]
    again.close()
    ro = MemoryIndex.open(path, readonly=True)
    assert ro.counts()["sessions"] == 1
    with pytest.raises(sqlite3.OperationalError):
        ro.con.execute("DELETE FROM sessions")
    ro.close()


def test_readonly_of_missing_or_foreign_file_is_unavailable(tmp_path):
    with pytest.raises(idx.IndexUnavailable):
        MemoryIndex.open(tmp_path / "none.sqlite", readonly=True)
    bad = tmp_path / "bad.sqlite"
    bad.write_bytes(b"not a database " * 100)
    with pytest.raises(idx.IndexUnavailable):
        MemoryIndex.open(bad, readonly=True)


def test_unreadable_file_is_set_aside_not_deleted(tmp_path):
    path = tmp_path / "memory" / "index.sqlite"
    path.parent.mkdir()
    garbage = b"\x00garbage bytes, not sqlite " * 64
    path.write_bytes(garbage)
    ix = MemoryIndex.open(path)
    aside = sorted(path.parent.glob("index.sqlite.unreadable-*"))
    assert len(aside) == 1 and aside[0].read_bytes() == garbage
    assert ix.rebuilt_from == aside[0]
    assert ix.counts() == {"sessions": 0, "chunks": 0, "vectors": 0}
    ix.close()


def test_other_schema_version_is_set_aside(tmp_path):
    path = tmp_path / "index.sqlite"
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE sessions(x)")
    con.execute("PRAGMA user_version = 7")
    con.close()
    ix = MemoryIndex.open(path)
    assert len(list(tmp_path.glob("index.sqlite.unreadable-*"))) == 1
    assert ix.con.execute("PRAGMA user_version").fetchone()[0] == 1
    ix.close()


# ---------------------------------------------------------------- keys
def test_session_key():
    k = session_key("halden-kickoff", set())
    assert len(k) == 7 and k[0] == "s" and set(k[1:]) <= set(idx.CROCKFORD)
    assert session_key("halden-kickoff", set()) == k
    long = session_key("halden-kickoff", {k})
    assert len(long) == 9 and long.startswith(k)
    assert session_key("halden-pilot-review", set()) != k


def test_key_survives_a_drop_and_a_new_put(index):
    k = put_fixture(index, "tarla-intro").key
    index.drop(["tarla-intro"])
    assert put_fixture(index, "tarla-intro").key == k
    assert index.session_by_key(k).name == "tarla-intro"


# ---------------------------------------------------------------- chunking
def test_turn_chunks_by_rows_and_by_chars():
    chunks = idx.turn_chunks(rows_of(20))
    assert [c.row_last - c.row_first + 1 for c in chunks] == [8, 8, 4]
    assert [c.ord for c in chunks] == [0, 1, 2]
    assert chunks[0].stamp == "0:00" and chunks[0].stamp_end == "0:07" and chunks[1].stamp == "0:08"
    assert chunks[0].text.splitlines()[0] == "[0:00] Marta: line number 0 about the plan"
    long = rows_of(3) + [Row("1:00", "Marta", "x" * 2000)] + rows_of(2, "tail")
    cs = idx.turn_chunks(long)
    assert [(c.row_first, c.row_last) for c in cs] == [(0, 2), (3, 3), (4, 5)]
    assert len(cs[1].text) > 2000


def test_summary_prep_and_chat_chunks(index):
    put_fixture(index, "halden-kickoff")
    summ = index.chunks_of("halden-kickoff", "summary")
    assert [c.label for c in summ] == ["Summary", "Decisions", "Actions", "Open questions"]
    joined = "\n".join(c.text for c in summ)
    assert "_generated" not in joined and "DRAFT" not in joined
    prep = index.chunks_of("halden-kickoff", "prep")
    assert {c.label for c in prep} == {None, "FACTS", "ANSWER BANK"}        # None: the title line before the first heading
    assert "Short sentences. Plain words" not in "\n".join(c.text for c in prep)
    assert not any("STYLE GUIDE" in (c.label or "") or "lantern-green" in c.text for c in prep)
    chat = index.chunks_of("halden-kickoff", "chat")
    assert len(chat) == 1 and chat[0].text.startswith("Q: Who arranges the Rovigo depot access?\nA: Joe arranges")
    every = "\n".join(r[0] for r in index.con.execute("SELECT text FROM chunks"))
    assert "invoices" not in every                       # the pair before the reset
    # a "- (none)" section is not a chunk, and neither is the Metrics section
    put_fixture(index, "halden-pilot-review")
    assert [c.label for c in index.chunks_of("halden-pilot-review", "summary")] == ["Summary", "Decisions", "Actions"]


def test_prepared_session_has_prep_chunks_only(index):
    put_fixture(index, "halden-weekly-prep")
    n = {s: len(index.chunks_of("halden-weekly-prep", s)) for s in idx.SOURCES}
    assert n["turn"] == 0 and n["summary"] == 0 and n["chat"] == 0 and n["prep"] >= 2


def test_prep_chunks_cut_at_the_character_cap():
    pack = "## Notes\n" + "\n".join(f"line {i} " + "y" * 90 for i in range(40))
    cs = idx.prep_chunks(pack)
    assert len(cs) >= 3 and all(len(c.text) <= 1200 for c in cs) and {c.label for c in cs} == {"Notes"}


def test_unreadable_source_skips_the_put(tmp_path, index):
    d = tmp_path / "s"
    d.mkdir()
    (d / "summary.md").write_bytes(b"\xff\xfe\x00 not utf-8 \x80\x81")
    with pytest.raises(idx.SourceUnreadable):
        index.put(name="s", dir=d, fp="f", title="S", date="2026-10-19T17:00:00+02:00", kind="meeting", lang="en",
                  labels=[], rows=rows_of(3))
    assert index.sessions() == []


# ---------------------------------------------------------------- sync
def test_plan_sync(index):
    put_all(index)
    index.store_vectors("m1", [(c.id, [1.0, 0.0]) for c in index.chunks_of("tarla-intro", "turn")])
    keep = [n for n in META if n != "tarla-intro"]
    plan = index.plan_sync(manifest(keep))
    assert plan.dropped == ["tarla-intro"] and plan.need == [] and plan.relabelled == 0
    assert "tarla-intro" not in [s.name for s in index.sessions()]
    for t, col in (("rows", "session"), ("chunks", "session")):
        assert index.con.execute(f"SELECT count(*) FROM {t} WHERE {col}='tarla-intro'").fetchone()[0] == 0
    assert index.con.execute("SELECT count(*) FROM vectors").fetchone()[0] == 0
    assert index.fts_ids('"ahtapot"', None, idx.SOURCES, 10) == []
    # changed fingerprint -> need; changed labels only -> relabelled, not need
    changed = manifest(keep, lambda n: "new-fp" if n == "halden-kickoff" else f"fp-{n}")
    changed[1]["labels"] = ["Joe Arkwright"]                       # halden-pilot-review: labels only
    plan = index.plan_sync(changed)
    assert plan.need == ["halden-kickoff"] and plan.relabelled == 1 and plan.dropped == []
    assert next(s for s in index.sessions() if s.name == "halden-pilot-review").labels == ["Joe Arkwright"]
    # a session the index has never seen (tarla-intro was dropped above)
    plan = index.plan_sync(manifest(keep + ["tarla-intro"], lambda n: "new-fp" if n == "halden-kickoff" else f"fp-{n}"))
    assert plan.need == ["halden-kickoff", "tarla-intro"] and plan.dropped == [] and plan.relabelled == 1   # pilot-review: labels back


def test_fts_entries_follow_the_chunks_through_a_drop(index):
    put_all(index)
    index.drop(["tarla-intro", "corvo-design-call"])
    ids = {r[0] for r in index.con.execute("SELECT id FROM chunks")}
    assert ids
    hits = set(index.fts_ids('"pilot" OR "plan" OR "marta" OR "budget" OR "gateway" OR "sensor"', None, idx.SOURCES, 1000))
    assert hits and hits <= ids                              # no FTS entry of a dropped chunk is left
    assert index.fts_ids('"preventivo" OR "ahtapot"', None, idx.SOURCES, 10) == []


def test_put_twice_replaces(index):
    first = put_fixture(index, "halden-kickoff")
    n = index.con.execute("SELECT count(*) FROM chunks").fetchone()[0]
    second = put_fixture(index, "halden-kickoff", fp="fp-2")
    assert second.key == first.key and second.chunks == first.chunks
    assert index.con.execute("SELECT count(*) FROM chunks").fetchone()[0] == n
    assert index.con.execute("SELECT count(*) FROM rows WHERE session='halden-kickoff'").fetchone()[0] == len(fixture_rows("halden-kickoff"))
    rov = index.fts_ids('"rovigo"', None, ("turn",), 50)
    assert len(rov) == 1                                     # one chunk holds both Rovigo rows; matched once, not once per put
    fts_rows = index.con.execute("SELECT count(*) FROM chunks_fts WHERE chunks_fts MATCH '\"sixty\"'").fetchone()[0]
    in_chunks = index.con.execute("SELECT count(*) FROM chunks WHERE lower(text) LIKE '%sixty%'").fetchone()[0]
    assert fts_rows == in_chunks
    assert index.con.execute("SELECT fingerprint FROM sessions").fetchone()[0] == "fp-2"


# ---------------------------------------------------------------- secure delete
def test_secure_delete_leaves_no_text_in_the_file_or_the_wal(tmp_path):
    path = tmp_path / "memory" / "index.sqlite"
    ix = MemoryIndex.open(path)
    put_all(ix)
    ix.close()
    ix = MemoryIndex.open(path)
    ix.drop([CALENDAR])
    ix.close()
    blob = path.read_bytes()
    wal = path.with_name(path.name + "-wal")
    if wal.exists():
        blob += wal.read_bytes()
    assert SECRET_SENTENCE.encode() not in blob
    assert b"ahtapot" not in blob and "ahtapot".encode() not in blob      # the folded word of the FTS index, too
    assert b"Emre Kaya" not in blob
    # control: the other sessions' text is still there
    assert b"sixty thousand euros" in blob


def test_secure_delete_inside_a_merged_segment(tmp_path):
    # the dropped session's terms sit in one large merged segment together with the others' terms
    path = tmp_path / "memory" / "index.sqlite"
    ix = MemoryIndex.open(path)
    put_all(ix)
    ix.con.execute("INSERT INTO chunks_fts(chunks_fts) VALUES('optimize')")
    ix.con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    ix.close()
    ix = MemoryIndex.open(path)
    ix.drop([CALENDAR])
    assert ix.con.execute("SELECT count(*) FROM chunks_fts WHERE chunks_fts MATCH 'ahtapot'").fetchone()[0] == 0
    ix.close()
    blob = path.read_bytes()
    wal = path.with_name(path.name + "-wal")
    if wal.exists():
        blob += wal.read_bytes()
    assert "ahtapot".encode() not in blob
    assert SECRET_SENTENCE.encode() not in blob
    assert b"sixty thousand euros" in blob


def test_a_locked_index_is_not_set_aside(tmp_path):
    # a busy/locked file is transient: it must raise, not be renamed aside with its text still inside
    path = tmp_path / "memory" / "index.sqlite"
    ix = MemoryIndex.open(path)
    put_all(ix)
    ix.close()
    holder = sqlite3.connect(path, isolation_level=None)
    holder.execute("PRAGMA locking_mode=EXCLUSIVE")
    holder.execute("BEGIN EXCLUSIVE")
    try:
        with pytest.raises(sqlite3.OperationalError):
            MemoryIndex.open(path)
    finally:
        holder.execute("ROLLBACK")
        holder.close()
    assert path.exists()
    assert not list(path.parent.glob("*.unreadable-*"))


# ---------------------------------------------------------------- vectors
def test_vectors_pending_store_and_new_model(index):
    put_fixture(index, "halden-kickoff")
    put_fixture(index, "corvo-design-call")
    total = index.con.execute("SELECT count(*) FROM chunks").fetchone()[0]
    pend = index.pending_vectors("m1", 1000)
    assert len(pend) == total == index.count_pending("m1")
    # newest session first: halden-kickoff (19 Oct) is older than corvo-design-call (20 Oct)
    first_session = index.con.execute("SELECT session FROM chunks WHERE id=?", (pend[0][0],)).fetchone()[0]
    assert first_session == "corvo-design-call"
    assert len(index.pending_vectors("m1", 5)) == 5
    index.store_vectors("m1", [(cid, [0.6, 0.8]) for cid, _ in pend])
    assert index.pending_vectors("m1", 1000) == []
    assert len(index.pending_vectors("m2", 1000)) == total
    blob = index.con.execute("SELECT vec FROM vectors LIMIT 1").fetchone()[0]
    assert len(blob) == 4                                   # two float16 values
    got = index.vectors(None, idx.SOURCES, "m1", 2)
    assert len(got) == total and got[0][1] == pytest.approx([0.6, 0.8], abs=1e-3)
    assert index.vectors(None, idx.SOURCES, "m1", 3) == []


def test_use_model_clears_vectors_only_on_a_change(index):
    put_fixture(index, "halden-kickoff")
    assert index.use_model("m1") is True
    index.store_vectors("m1", [(c.id, [1.0, 0.0]) for c in index.chunks_of("halden-kickoff", "turn")])
    assert index.use_model("m1") is False and index.counts()["vectors"] > 0
    assert index.use_model("m2") is True
    assert index.con.execute("SELECT count(*) FROM vectors").fetchone()[0] == 0
    assert index.counts()["chunks"] > 0


def test_drop_removes_vectors(index):
    put_fixture(index, "tarla-intro")
    index.use_model("m1")
    index.store_vectors("m1", [(cid, [1.0, 0.0]) for cid, _ in index.pending_vectors("m1", 100)])
    assert index.counts()["vectors"] > 0
    index.drop(["tarla-intro"])
    assert index.con.execute("SELECT count(*) FROM vectors").fetchone()[0] == 0


# ---------------------------------------------------------------- FTS folding
def match(index, q: str, sources=("turn",)) -> list[int]:
    return index.fts_ids(" OR ".join(f'"{w}"' for w in q.split()), None, sources, 20)


def test_fts_folding(index):
    put_all(index)
    rows = lambda ids: {index.chunks_by_ids(ids)[i].session for i in ids}     # noqa: E731
    assert "tarla-intro" in rows(match(index, "istanbul"))                    # "İstanbul"
    assert "corvo-design-call" in rows(match(index, "perche"))               # "perché"
    assert "tarla-intro" in rows(match(index, "ahtapot"))                    # plain ascii finds ...
    assert "corvo-design-call" in rows(match(index, "identita"))             # "identità"


def test_rows_and_chunk_geometry(index):
    put_fixture(index, "halden-kickoff")
    rows = index.rows_at("halden-kickoff", "1:12")
    assert [(r.speaker, r.text[:12]) for r in rows] == [("Dana", "Yes, I will ")]
    c = index.chunks_of("halden-kickoff", "turn")[0]
    got = index.first_last_rows("halden-kickoff", c.row_first, c.row_last)
    assert got[0].stamp == c.stamp and got[-1].stamp == c.stamp_end and len(got) == 8
    assert index.rows_at("halden-kickoff", "9:99") == []
