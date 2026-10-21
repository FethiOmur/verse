"""Memory search (P1): FTS query building, hybrid fusion, weights, packing, rendering, citations.

The live check is opt-in: VERSE_LIVE_EMBED=1 loads the real EmbeddingGemma on LiteRT-LM (no network, no paid call).
"""

from __future__ import annotations

import os
import re

import pytest

from test_memory_index import CALENDAR, put_all
from verse_brain.memory import index as idx
from verse_brain.memory import search as srch
from verse_brain.memory.index import MemoryIndex
from verse_brain.memory.search import CITE_RE, QueryEmbedder, fts_query, fuse, render_excerpts, resolve_citations, search
from verse_brain.runtime.ask import Row, est_tokens
from verse_brain.runtime.settings import MEMORY_EXCERPT_TOKENS, MEMORY_SESSION_EXCERPT_TOKENS


@pytest.fixture
def index(tmp_path):
    ix = MemoryIndex.open(tmp_path / "memory" / "index.sqlite")
    put_all(ix)
    yield ix
    ix.close()


class Scripted:
    """An embedder whose vectors are looked up by a marker inside the text (the retrieval prefixes are ignored)."""

    def __init__(self, table: dict[str, list[float]], default: list[float] | None = None) -> None:
        self.table, self.default = table, default or [0.0, 0.0, 1.0]

    def embed(self, text: str) -> list[float]:
        for marker, vec in self.table.items():
            if marker in text:
                return list(vec)
        return list(self.default)

    def close(self) -> None:
        pass


def sessions_of(excerpts) -> list[str]:
    return [e.info.name for e in excerpts]


# ---------------------------------------------------------------- the FTS query
def test_fts_query_quotes_and_drops_stopwords():
    assert fts_query("What did Marta say about the budget?") == '"marta" OR "say" OR "budget"'
    assert fts_query("the of and") is None
    assert fts_query("   ") is None
    assert fts_query("budget budget Budget") == '"budget"'


def test_stopword_lists_are_small():
    for lang, words in srch._STOP.items():
        assert len(words.split()) <= 40, lang
    assert "the" in srch.STOPWORDS and "della" in srch.STOPWORDS and "icin" in srch.STOPWORDS


def test_hostile_question_does_not_raise(index):
    q = 'what "about NEAR( the * budget - OR AND NOT ) ^ : {x} sixty'
    out = search(index, q, scope=None, embedder=None)
    assert any("sixty thousand" in c.text for e in out for c in e.chunks)
    assert search(index, '"" ** ()', scope=None, embedder=None) == []


def test_folded_matches(index):
    out = search(index, "istanbul", scope=None, embedder=None, sources=("turn",))
    assert sessions_of(out) == [CALENDAR]
    out = search(index, "perche", scope=None, embedder=None, sources=("turn",))
    assert sessions_of(out) == ["corvo-design-call"]


# ---------------------------------------------------------------- scope and sources
def test_scope_never_returns_other_sessions(index):
    q = "pilot plan budget sensor gateway euros"
    assert set(sessions_of(search(index, q, scope=None, embedder=None))) >= {"halden-kickoff", "halden-pilot-review"}
    only = search(index, q, scope=["halden-pilot-review"], embedder=None)
    assert sessions_of(only) == ["halden-pilot-review"]
    assert search(index, q, scope=[], embedder=None) == []
    assert search(index, q, scope=["no-such-session"], embedder=None) == []
    # vectors obey the scope too
    vec = QueryEmbedder(Scripted({"": [1.0, 0.0, 0.0]}), "m1")
    index.use_model("m1")
    index.store_vectors("m1", [(cid, [1.0, 0.0, 0.0]) for cid, _ in index.pending_vectors("m1", 1000)])
    only = search(index, "zzz", scope=["corvo-design-call"], embedder=vec)
    assert only and sessions_of(only) == ["corvo-design-call"]


def test_sources_filter(index):
    out = search(index, "budget sixty", scope=["halden-kickoff"], embedder=None, sources=("summary",))
    assert {c.source for e in out for c in e.chunks} == {"summary"}


# ---------------------------------------------------------------- fusion
def test_vector_branch_finds_what_fts_cannot(index):
    """A Turkish question shares no word with the English meeting; its vector equals the vector of the English chunk."""
    target = next(c for c in index.chunks_of("halden-kickoff", "turn") if "pilot plan by Friday" in c.text)
    index.use_model("m1")
    others = [(cid, [0.0, 1.0, 0.0]) for cid, _ in index.pending_vectors("m1", 1000) if cid != target.id]
    index.store_vectors("m1", others + [(target.id, [1.0, 0.0, 0.0])])
    emb = QueryEmbedder(Scripted({"teslim tarihi": [1.0, 0.0, 0.0]}), "m1")
    q = "teslim tarihi neydi"
    assert fts_query(q) == '"teslim" OR "tarihi" OR "neydi"' and index.fts_ids(fts_query(q), None, idx.SOURCES, 10) == []
    hybrid = search(index, q, scope=None, embedder=emb)
    got = [c.id for e in hybrid for c in e.chunks]
    assert target.id in got
    assert search(index, q, scope=None, embedder=None) == []


def test_embedder_failure_falls_back_to_fts(index):
    class Broken:
        model_sha = "m1"

        def query(self, text):
            raise RuntimeError("engine gone")

    out = search(index, "budget sixty", scope=None, embedder=Broken())
    assert out and all(isinstance(e.info.name, str) for e in out)


def test_fuse_weights_and_ties():
    src = {1: "summary", 2: "prep", 3: "turn", 4: "chat"}
    # rank 1 in one list each: equal raw scores, the source weight decides
    assert [c for c, _ in fuse([1], [2], src)] == [1, 2]
    assert [c for c, _ in fuse([2], [1], src)] == [1, 2]
    # being in both lists beats being first in one
    assert [c for c, _ in fuse([5, 6], [6], {5: "turn", 6: "turn"})] == [6, 5]
    scores = dict(fuse([3], [3], src))
    assert scores[3] == pytest.approx(2 / 61)
    assert [c for c, _ in fuse([4], [3], src)] == [3, 4]


def test_summary_chunk_ranks_before_prep_chunk_at_equal_rank(tmp_path):
    ix = MemoryIndex.open(tmp_path / "i.sqlite")
    d = tmp_path / "s"
    d.mkdir()
    (d / "summary.md").write_text("## Notes\n\nzebra crossing paperwork\n", encoding="utf-8")
    (d / "pack.md").write_text("## Notes\n\nzebra crossing paperwork\n", encoding="utf-8")
    ix.put(name="s", dir=d, fp="f", title="S", date="2026-10-19T17:00:00+02:00", kind="meeting", lang="en", labels=[], rows=[])
    summary, prep = ix.chunks_of("s", "summary")[0], ix.chunks_of("s", "prep")[0]
    ix.use_model("m1")
    ix.store_vectors("m1", [(summary.id, [0.0, 1.0]), (prep.id, [1.0, 0.0])])
    emb = QueryEmbedder(Scripted({"zebra": [1.0, 0.0]}), "m1")
    # FTS ranks one of them first, the vectors rank the other first: equal fused score before the weights
    out = search(ix, "zebra", scope=None, embedder=emb)
    assert [c.source for c in out[0].chunks] == ["prep", "summary"]          # rendered in time order ...
    ranked = fuse(ix.fts_ids('"zebra"', None, idx.SOURCES, 10), [prep.id, summary.id],
                  {summary.id: "summary", prep.id: "prep"})
    assert ranked[0][0] == summary.id                                        # ... but ranked summary first
    ix.close()


# ---------------------------------------------------------------- packing and rendering
def synthetic(tmp_path, sessions: int = 4, rows_each: int = 60) -> MemoryIndex:
    ix = MemoryIndex.open(tmp_path / "big.sqlite")
    for s in range(sessions):
        rows = [Row(f"{i // 60}:{i % 60:02d}", "Marta", ("keyword " + "filler " * 140)[:1000]) for i in range(rows_each)]
        ix.put(name=f"big-{s}", dir=tmp_path / "none", fp="f", title=f"Big {s}", date=f"2026-10-{10 + s:02d}T10:00:00+02:00",
               kind="meeting", lang="en", labels=[], rows=rows)
    return ix


def test_packing_total_budget(tmp_path):
    ix = synthetic(tmp_path, sessions=12, rows_each=5)           # 60 candidate chunks of about 286 tokens each: 17k > 16k
    out = search(ix, "keyword", scope=None, embedder=None)
    total = sum(e.tokens for e in out)
    assert MEMORY_EXCERPT_TOKENS - 300 < total <= MEMORY_EXCERPT_TOKENS and len(out) >= 10
    assert all(e.tokens <= MEMORY_SESSION_EXCERPT_TOKENS for e in out)
    for e in out:
        assert sum(est_tokens(c.text) for c in e.chunks) == e.tokens
    ix.close()


def test_packing_session_budget(tmp_path):
    ix = synthetic(tmp_path, sessions=1, rows_each=60)           # one long call cannot take more than its share
    out = search(ix, "keyword", scope=None, embedder=None)
    assert len(out) == 1 and MEMORY_SESSION_EXCERPT_TOKENS - 300 < out[0].tokens <= MEMORY_SESSION_EXCERPT_TOKENS
    small = search(ix, "keyword", scope=None, embedder=None, budget_tokens=2000, per_session_tokens=800)
    assert sum(e.tokens for e in small) <= 800
    ix.close()


def test_render_newest_session_first_and_gaps(tmp_path):
    ix = MemoryIndex.open(tmp_path / "r.sqlite")
    old = [Row(f"0:{i:02d}", "Marta", "alpha" if i in (0, 16) else f"filler {i}") for i in range(24)]
    new = [Row(f"0:{i:02d}", "Joe", "alpha beta" if i < 2 else f"other {i}") for i in range(10)]
    ix.put(name="old", dir=tmp_path / "x", fp="f", title="Old Call", date="2026-10-01T09:00:00+02:00", kind="call", lang="en",
           labels=["Marta Velin", "Halden Works"], rows=old)
    ix.put(name="new", dir=tmp_path / "x", fp="f", title="New Call", date="2026-10-19T09:00:00+02:00", kind="meeting", lang="en",
           labels=[], rows=new)
    text = render_excerpts(search(ix, "alpha", scope=None, embedder=None))
    heads = [ln for ln in text.splitlines() if ln.startswith("== ")]
    assert len(heads) == 2 and "New Call" in heads[0] and "Old Call" in heads[1]
    assert re.fullmatch(r"== s[0-9a-z]{6} · Mon 19 Oct 2026 · meeting · New Call", heads[0])
    assert re.fullmatch(r"== s[0-9a-z]{6} · Thu 1 Oct 2026 · call · Old Call · with Marta Velin \(Halden Works\)", heads[1])
    old_part = text.split(heads[1])[1]
    assert old_part.count("[...]") == 1 and old_part.index("[0:00] Marta: alpha") < old_part.index("[...]") < old_part.index("[0:16]")
    assert "[...]" not in text.split(heads[1])[0]
    ix.close()


def test_render_summary_prep_chat_forms(index):
    out = search(index, "rovigo budget facts gateway", scope=["halden-kickoff"], embedder=None)
    text = render_excerpts(out)
    assert re.search(r"^SUMMARY \((Decisions|Summary|Actions|Open questions)\): ", text, re.M)
    assert re.search(r"^PREP \((FACTS|ANSWER BANK)\): ", text, re.M) or "PREP:" in text
    assert re.search(r"^EARLIER CHAT: Q: Who arranges", text, re.M)
    assert "[0:48] Marta: We want sensors" in text or "[3:24] Joe: One risk" in text


# ---------------------------------------------------------------- citations
def test_cite_regex_forms():
    for form in ("12:34", "1:02:03", "summary", "prep", "chat"):
        assert CITE_RE.fullmatch(f"[sk3f9qa {form}]"), form
    assert CITE_RE.fullmatch("[sk3f9qa12 4:05]") and CITE_RE.fullmatch("[sk3f9qa123 4:05]") is None   # 8 characters at most
    assert CITE_RE.search("[s12 1:00]") is None
    assert CITE_RE.search("[sk3f9qa]") is None
    assert CITE_RE.search("[sk3f9qa 12:345]") is None
    assert CITE_RE.search("[sk3f9qi 12:34]") is None            # i is not in the alphabet


def test_resolve_citations(index):
    k_kick = index.con.execute("SELECT key FROM sessions WHERE name='halden-kickoff'").fetchone()[0]
    k_pilot = index.con.execute("SELECT key FROM sessions WHERE name='halden-pilot-review'").fetchone()[0]
    k_tarla = index.con.execute("SELECT key FROM sessions WHERE name='tarla-intro'").fetchone()[0]
    answer = (f"Marta asked for it by Friday [{k_kick} 0:48]. Dana agreed [{k_kick} 1:12] [{k_kick} 0:48]. "
              f"Later a weekly report [{k_pilot} summary]. Wrong stamp [{k_kick} 9:59]. Unknown key [sa0a0a0 0:48]. "
              f"Out of scope [{k_tarla} 0:04]. Prep [{k_kick} prep] and chat [{k_kick} chat].")
    got = resolve_citations(index, answer, ["halden-kickoff", "halden-pilot-review"])
    assert [(c["key"], c["kind"], c["stamp"]) for c in got] == [
        (k_kick, "turn", "0:48"), (k_kick, "turn", "1:12"), (k_pilot, "summary", None), (k_kick, "prep", None), (k_kick, "chat", None)]
    first = got[0]
    assert first["session"] == "halden-kickoff" and first["title"] == "Halden Kickoff"
    assert first["date"] == "2026-10-19T17:00:00+02:00" and first["speaker"] == "Marta"
    assert first["text"].startswith("We want sensors on forty trucks")
    assert got[2]["speaker"] is None and got[2]["text"].startswith("Summary: Halden Works approved the pilot plan")
    assert got[4]["text"].startswith("Q: Who arranges the Rovigo depot access?")
    # the same text with the whole index as scope keeps the out-of-scope key
    assert k_tarla in [c["key"] for c in resolve_citations(index, answer, None)]
    assert resolve_citations(index, answer, []) == []


def test_resolve_citation_uses_the_first_row_with_a_stamp(tmp_path):
    ix = MemoryIndex.open(tmp_path / "d.sqlite")
    rows = [Row("0:10", "Marta", "first"), Row("0:10", "Joe", "second")]
    k = ix.put(name="d", dir=tmp_path / "none", fp="f", title="D", date="2026-10-19T17:00:00+02:00", kind="call", lang="en",
               labels=[], rows=rows).key
    got = resolve_citations(ix, f"[{k} 0:10]", None)
    assert got[0]["speaker"] == "Marta" and got[0]["text"] == "first"
    ix.close()


# ---------------------------------------------------------------- live (opt-in)
@pytest.mark.skipif(os.environ.get("VERSE_LIVE_EMBED") != "1", reason="VERSE_LIVE_EMBED=1 loads the real EmbeddingGemma")
def test_live_turkish_question_finds_english_halden_turn(tmp_path, capsys):
    from operator import mul

    from verse_brain.runtime.embed import LiteRtEmbedder
    from verse_brain.runtime.me import model_sha
    from verse_brain.runtime.settings import Config

    cfg = Config()
    raw = LiteRtEmbedder(cfg.embed_model, cfg.embed_backend)
    try:
        sha = model_sha(cfg.embed_model)
        ix = MemoryIndex.open(tmp_path / "live.sqlite")
        put_all(ix)
        ix.use_model(sha)
        qe = QueryEmbedder(raw, sha)
        while True:
            batch = ix.pending_vectors(sha, 32)
            if not batch:
                break
            ix.store_vectors(sha, [(cid, qe.document(t)) for cid, t in batch])
        dims = {r[0] for r in ix.con.execute("SELECT dim FROM vectors")}
        assert len(dims) == 1, dims                                   # the vector dimension is constant
        dim = dims.pop()
        question = "Marta pilot planını ne zaman göndereceğimi söyledi?"
        qv = qe.query(question)
        scored = sorted(((sum(map(mul, qv, v)), cid) for cid, v in ix.vectors(None, ("turn",), sha, dim)), reverse=True)
        hits = ix.chunks_by_ids([cid for _, cid in scored[:10]])
        ranks = [(i + 1, hits[cid].session, hits[cid].stamp, round(sc, 3)) for i, (sc, cid) in enumerate(scored[:10])]
        full = search(ix, question, scope=None, embedder=qe)
        with capsys.disabled():
            print(f"\nLIVE dim={dim} vectors={ix.counts()['vectors']} vector ranks (turn chunks): {ranks[:5]}")
            print(f"LIVE hybrid session order: {[e.info.name for e in full]}")
        assert any(s.startswith("halden-") for _, s, _, _ in ranks[:3]), ranks
    finally:
        raw.close()
