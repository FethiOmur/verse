"""Phase 2 of the memory index run with chunks the embedding model cannot take as they are (EmbeddingGemma: 1,024 tokens).

A fake embedder raises, like the real engine, a bare RuntimeError on an input over N tokens ("tokens" = words here). All text is
invented. Covers: a chunk over the limit is embedded in pieces, a chunk that still fails is skipped without stopping the run, a
dead engine still stops it, and sessions that stopped an earlier run are finished by the next one without being put again.
"""

from __future__ import annotations

import asyncio
import logging
import math
from pathlib import Path

import pytest

from verse_brain.memory import indexer as ix_mod
from verse_brain.memory.indexer import IndexRuntime, split_text
from verse_brain.memory.index import MemoryIndex
from verse_brain.memory.search import QueryEmbedder
from verse_brain.prep.me import HashEmbedder

LIMIT = 300                         # fake model input, in words (the prefix counts)


class FakeModel:
    """Hash vectors; raises a bare RuntimeError over `limit` words or on a `poison` word; `die_after` calls, then always raises."""

    def __init__(self, limit: int = LIMIT, poison: str | None = None, die_after: int | None = None) -> None:
        self.limit, self.poison, self.die_after = limit, poison, die_after
        self.calls: list[int] = []          # words of every call, refused or not
        self.accepted: list[int] = []       # ...of the calls that returned a vector
        self._h = HashEmbedder()

    def embed(self, text: str) -> list[float]:
        n = len(text.split())
        self.calls.append(n)
        if self.die_after is not None and len(self.calls) > self.die_after:
            raise RuntimeError("Failed to compute embedding.")
        if n > self.limit or (self.poison and self.poison in text):
            raise RuntimeError("Failed to compute embedding.")
        self.accepted.append(n)
        return self._h.embed(text)

    def close(self) -> None:
        pass


class Rec:
    def __init__(self) -> None:
        self.events: list[dict] = []

    def emit(self, ev: dict) -> None:
        self.events.append(ev)

    def of(self, kind: str) -> list[dict]:
        return [e for e in self.events if e["type"] == kind]


class Runtime(IndexRuntime):
    def __init__(self, emitter, model: FakeModel) -> None:
        super().__init__(emitter, fake=True)
        self.model = model

    def _load_embedder(self) -> None:
        self._raw, self.sha = self.model, "fake-model"
        self.embedder = QueryEmbedder(self.model, self.sha)


def words(n: int, tag: str) -> str:
    """Invented prose of n words in sentences (no real meeting content)."""
    return " ".join(f"{tag}{i}" + ("." if i % 12 == 11 else "") for i in range(n))


def make_session(root: Path, name: str, *, summary: str = "", turns: list[str] | None = None) -> dict:
    folder = root / name
    folder.mkdir(parents=True)
    if summary:
        (folder / "summary.md").write_text(summary, encoding="utf-8")
    rows = [{"stamp": f"0:{i:02d}", "speaker": "Ana", "text": t} for i, t in enumerate(turns or ["short invented line"])]
    return {"type": "put", "name": name, "dir": str(folder), "fp": f"fp-{name}", "title": name.title(),
            "date": {"alpha": "2026-11-03T10:00:00+01:00", "beta": "2026-11-02T10:00:00+01:00",
                     "gamma": "2026-11-01T10:00:00+01:00"}.get(name, "2026-10-01T10:00:00+01:00"),
            "kind": "meeting", "lang": "en", "labels": [], "rows": rows}


def drive(db: Path, model: FakeModel, puts: list[dict], manifest_names: list[str] | None = None) -> Rec:
    rec = Rec()
    names = manifest_names if manifest_names is not None else [p["name"] for p in puts]

    async def go() -> None:
        rt = Runtime(rec, model)
        await rt.handle({"type": "memory_index_start", "db": str(db)})
        await rt.handle({"type": "sync", "sessions": [{"name": n, "fp": f"fp-{n}", "labels": []} for n in names]})
        plan = rec.of("sync_plan")[-1]
        for p in puts:
            if p["name"] in plan["need"]:
                await rt.handle(p)
        await rt.handle({"type": "end"})
        await rt.shutdown()

    asyncio.run(go())
    return rec


def counts(db: Path) -> dict:
    ix = MemoryIndex.open(db, readonly=True)
    try:
        return ix.counts()
    finally:
        ix.close()


# ---------------------------------------------------------------- splitting
def test_split_text_keeps_everything_and_cuts_on_sentences():
    text = words(400, "w")
    pieces = split_text(text, 500)
    assert all(len(p) <= 500 for p in pieces) and len(pieces) > 1
    assert " ".join(pieces).split() == text.split()                  # nothing dropped
    assert all(p.endswith(".") for p in pieces[:-1])                 # cut after a sentence end, not mid-sentence


def test_split_text_short_text_is_whole_and_unbroken_text_is_hard_cut_losslessly():
    assert split_text("a short invented line", 500) == ["a short invented line"]
    blob = "x" * 1050
    pieces = split_text(blob, 400)
    assert [len(p) for p in pieces] == [400, 400, 250] and "".join(pieces) == blob


# ---------------------------------------------------------------- long chunks
def test_a_chunk_over_the_model_limit_is_embedded_in_pieces(tmp_path):
    db = tmp_path / "memory" / "index.sqlite"
    long_section = "## Notes\n" + words(900, "n")                        # ~6,000 characters, 900 words: far over 300
    model = FakeModel()
    rec = drive(db, model, [make_session(tmp_path, "alpha", summary=long_section, turns=["short invented line"])])
    c = counts(db)
    assert c["chunks"] == 2 and c["vectors"] == 2                       # the turn chunk and the long summary chunk, both embedded
    assert max(model.accepted) <= LIMIT and max(model.calls) > LIMIT    # the first try was refused, what was kept fits
    assert len(model.accepted) >= 3                                     # the turn chunk and at least two pieces of the long one
    assert rec.of("status")[-1]["state"] == "done" and rec.of("status")[-1]["context"]["embed"] == "on"
    prog = rec.of("embed_progress")
    assert prog[-1]["done"] == prog[-1]["total"] == 2
    ix = MemoryIndex.open(db, readonly=True)
    (_, v), *_ = ix.vectors(None, ("summary",), "fake-model", 64)
    ix.close()
    assert math.sqrt(sum(x * x for x in v)) == pytest.approx(1.0, abs=1e-2)   # unit length (float16 on disk)


def test_an_ordinary_chunk_is_embedded_exactly_as_before(tmp_path):
    db = tmp_path / "memory" / "index.sqlite"
    model = FakeModel()
    drive(db, model, [make_session(tmp_path, "alpha", turns=["we agreed the invented plan"])])
    ix = MemoryIndex.open(db, readonly=True)
    (_, v), = ix.vectors(None, ("turn",), "fake-model", 64)
    ix.close()
    ix = MemoryIndex.open(db, readonly=True)
    (chunk,) = ix.chunks_of("alpha", "turn")
    ix.close()
    want = QueryEmbedder(FakeModel(), "x").document(chunk.text)
    assert v == pytest.approx(want, abs=1e-3)
    assert len(model.calls) == 1                                        # one call, no probe, no split


# ---------------------------------------------------------------- one bad chunk
def test_a_failing_chunk_is_skipped_and_the_run_continues(tmp_path, caplog):
    db = tmp_path / "memory" / "index.sqlite"
    model = FakeModel(poison="zxqpoison")
    puts = [make_session(tmp_path, "alpha", turns=["first invented line", "zxqpoison cannot be embedded " * 20,
                                                     "third invented line"] + [f"filler row {i} " * 40 for i in range(30)]),
            make_session(tmp_path, "beta", turns=["another invented line"])]
    with caplog.at_level(logging.INFO, logger="verse.memory.indexer"):
        rec = drive(db, model, puts)
    c = counts(db)
    assert c["chunks"] - c["vectors"] == 1                              # only the chunk with the poison word has no vector
    assert rec.of("status")[-1]["state"] == "done" and rec.of("status")[-1]["context"]["embed"] == "on"
    prog = rec.of("embed_progress")
    assert prog[-1]["done"] == prog[-1]["total"] == c["chunks"]         # skipped chunks count as handled: progress reaches the end
    skipped = [r.getMessage() for r in caplog.records if "skipped chunk" in r.getMessage()]
    assert len(skipped) == 1 and "of session alpha" in skipped[0]
    assert any("skipped 1 chunks" in r.getMessage() for r in caplog.records)
    assert "zxqpoison" not in caplog.text and "invented line" not in caplog.text      # ids and names only
    ix = MemoryIndex.open(db, readonly=True)
    assert [n for n, in ix.con.execute("SELECT DISTINCT session FROM chunks c JOIN vectors v ON v.chunk = c.id")]
    assert any(s == "beta" for s, in ix.con.execute("SELECT c.session FROM chunks c JOIN vectors v ON v.chunk = c.id"))
    ix.close()


def test_pending_vectors_skip_keeps_given_up_chunks_out_of_the_batch(tmp_path):
    ix = MemoryIndex.open(tmp_path / "i.sqlite")
    folder = tmp_path / "s"
    folder.mkdir()
    ix.put(name="s", dir=folder, fp="f", title="S", date="2026-11-01T10:00:00+01:00", kind="meeting", lang="en", labels=[],
           rows=[__import__("verse_brain.runtime.ask", fromlist=["Row"]).Row("0:0%d" % i, "Ana", f"line {i} " * 80) for i in range(9)])
    ids = [i for i, _ in ix.pending_vectors("m", 100)]
    assert len(ids) >= 3
    assert [i for i, _ in ix.pending_vectors("m", 2, {ids[0]})] == ids[1:3]
    assert ix.chunk_sessions(ids[:2]) == {ids[0]: "s", ids[1]: "s"}
    ix.close()


# ---------------------------------------------------------------- dead engine
def test_a_dead_engine_still_stops_the_run(tmp_path, caplog):
    db = tmp_path / "memory" / "index.sqlite"
    model = FakeModel(die_after=0)
    puts = [make_session(tmp_path, "alpha", turns=["first invented line"]), make_session(tmp_path, "beta", turns=["second one"])]
    with caplog.at_level(logging.INFO, logger="verse.memory.indexer"):
        rec = drive(db, model, puts)
    c = counts(db)
    assert c["chunks"] == 2 and c["vectors"] == 0
    assert rec.of("status")[-1]["state"] == "done" and rec.of("status")[-1]["context"]["embed"] == "off"
    assert any("embedding stopped" in r.getMessage() for r in caplog.records)
    assert not any("skipped chunk" in r.getMessage() for r in caplog.records)     # not mistaken for bad chunks
    assert len(model.calls) == 2                                        # the failed chunk and the probe, then nothing more


def test_an_engine_that_dies_midway_keeps_what_it_embedded(tmp_path):
    db = tmp_path / "memory" / "index.sqlite"
    model = FakeModel(die_after=3)
    drive(db, model, [make_session(tmp_path, "alpha", turns=[f"invented row {i} " * 60 for i in range(40)])])
    c = counts(db)
    assert c["chunks"] > 5 and c["vectors"] == 3


# ---------------------------------------------------------------- earlier failures
def test_sessions_that_stopped_an_earlier_run_are_finished_by_the_next(tmp_path):
    db = tmp_path / "memory" / "index.sqlite"
    puts = [make_session(tmp_path, "alpha", turns=["alpha line one", "alpha line two " * 60]),
            make_session(tmp_path, "beta", turns=["beta line one"]),
            make_session(tmp_path, "gamma", summary="## Notes\n" + words(900, "g"))]
    # Run 1: the engine dies after the first chunk; every session is put, so the manifest fingerprints are recorded.
    rec1 = drive(db, FakeModel(die_after=1), puts)
    before = counts(db)
    assert before["vectors"] == 1 and before["chunks"] > 1 and rec1.of("status")[-1]["context"]["embed"] == "off"
    # Run 2: same manifest, the sync plan needs nothing, and phase 2 still embeds every chunk that has no vector.
    rec2 = drive(db, FakeModel(), puts)
    assert rec2.of("sync_plan")[-1]["need"] == [] and not rec2.of("put_done")
    after = counts(db)
    assert after["chunks"] == before["chunks"] and after["vectors"] == after["chunks"]
    assert rec2.of("status")[-1]["context"]["embed"] == "on"
