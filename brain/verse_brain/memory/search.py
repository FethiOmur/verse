"""Hybrid search over the memory index (spec 2.2): FTS5 BM25 + EmbeddingGemma cosine, fused by reciprocal rank, packed into a token
budget and rendered per session; plus the citation format `[<key> <stamp>|summary|prep|chat]` and its validation (spec 3.4).

The question never reaches FTS syntax: it is folded, stripped of stopwords and every word is double-quoted. With no embedder (or
one that fails) the search is FTS only. Pure Python dot products over float16 vectors: no numpy.
"""

from __future__ import annotations

import logging
import re
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime
from operator import mul
from typing import Protocol

from ..runtime.ask import fold, fold_words
from ..runtime.embed import unit
from ..runtime.settings import (MEMORY_CANDIDATES, MEMORY_EXCERPT_TOKENS, MEMORY_RRF_K, MEMORY_SESSION_EXCERPT_TOKENS,
                                MEMORY_SOURCE_WEIGHTS)
from .index import SOURCE_ORDER, SOURCES, ChunkHit, MemoryIndex, SessionInfo

log = logging.getLogger("verse.memory.search")

QUERY_PREFIX = "task: search query | text: "     # bench/embed PREFIX["asym"]
DOC_PREFIX = "task: search result | text: "

CITE_RE = re.compile(r"\[(s[0-9a-hjkmnp-tv-z]{6,8}) (\d{1,2}:\d{2}(?::\d{2})?|summary|prep|chat)\]")

# Common words dropped from the FTS query (at most 40 per language; written folded, applied folded).
_STOP = {
    "en": "the a an and or of to in on at is are was were be been it this that with for from by as i you he she we they "
          "what when who where which how did do does about",
    "it": "il lo la i gli le un uno una di a da in con su per tra fra e o ma che chi cosa come quando dove quale quali "
          "del della dei delle al alla ha ho",
    "tr": "ve veya bir bu su o ne neden nasil kim kime hangi mi mu icin ile de da ki ama gibi daha cok en ben sen biz siz "
          "onlar var yok olarak ise ya her",
}
STOPWORDS: frozenset[str] = frozenset(fold(w) for words in _STOP.values() for w in words.split())


def fts_query(question: str) -> str | None:
    """Folded words of the question minus stopwords, each in double quotes, OR-joined; None when nothing is left."""
    words: list[str] = []
    for w in fold_words(question):
        w = w.replace('"', "")
        if w and w not in STOPWORDS and w not in words:
            words.append(w)
    return " OR ".join(f'"{w}"' for w in words) or None


class _Embedder(Protocol):
    def embed(self, text: str) -> list[float]: ...


class QueryEmbedder:
    """Wraps an `embed(text) -> vector` object with the asymmetric retrieval prefixes and unit length. `model_sha` names the model
    whose vectors the search compares against (None: whatever sha the index recorded)."""

    def __init__(self, embedder: _Embedder, model_sha: str | None = None, *, query_prefix: str = QUERY_PREFIX,
                 doc_prefix: str = DOC_PREFIX) -> None:
        self._e = embedder
        self.model_sha = model_sha
        self.query_prefix = query_prefix
        self.doc_prefix = doc_prefix

    def query(self, text: str) -> list[float]:
        return unit(self._e.embed(self.query_prefix + text.strip()))

    def document(self, text: str) -> list[float]:
        return unit(self._e.embed(self.doc_prefix + text.strip()))


@dataclass
class SessionExcerpt:
    info: SessionInfo
    chunks: list[ChunkHit] = field(default_factory=list)      # (source, ord) time order

    @property
    def tokens(self) -> int:
        return sum(c.tokens for c in self.chunks)


def fuse(fts_ranked: list[int], vec_ranked: list[int], source_of: dict[int, str]) -> list[tuple[int, float]]:
    """Reciprocal rank fusion of the two ranked id lists, times the source weight. Best first, ties by id."""
    score: dict[int, float] = {}
    for ranked in (fts_ranked, vec_ranked):
        for rank, cid in enumerate(ranked, start=1):
            score[cid] = score.get(cid, 0.0) + 1.0 / (MEMORY_RRF_K + rank)
    out = [(cid, s * MEMORY_SOURCE_WEIGHTS.get(source_of.get(cid, "turn"), 1.0)) for cid, s in score.items()]
    out.sort(key=lambda t: (-t[1], t[0]))
    return out


def search(index: MemoryIndex, query: str, *, scope: list[str] | None, embedder: QueryEmbedder | None,
           budget_tokens: int = MEMORY_EXCERPT_TOKENS, per_session_tokens: int = MEMORY_SESSION_EXCERPT_TOKENS,
           sources: tuple[str, ...] = SOURCES) -> list[SessionExcerpt]:
    """Excerpts for a question, newest session first. `scope` is a list of session names (None = every indexed session)."""
    if scope is not None and not scope:
        return []
    fts_ids: list[int] = []
    match = fts_query(query)
    if match:
        try:
            fts_ids = index.fts_ids(match, scope, sources, MEMORY_CANDIDATES)
        except sqlite3.Error as e:      # cannot happen with a quoted query; never fail the question for it
            log.warning("fts query failed: %s", type(e).__name__)
    vec_ids: list[int] = []
    if embedder is not None:
        try:
            qv = embedder.query(query)
            vecs = index.vectors(scope, sources, embedder.model_sha or index.embed_sha(), len(qv))
            scored = [(sum(map(mul, qv, v)), cid) for cid, v in vecs]
            scored.sort(key=lambda t: (-t[0], t[1]))
            vec_ids = [cid for _, cid in scored[:MEMORY_CANDIDATES]]
        except Exception as e:  # noqa: BLE001 - any embedder failure turns the vector branch off for this question
            log.warning("vector search off: %s", type(e).__name__)
    ids = list(dict.fromkeys(fts_ids + vec_ids))
    hits = index.chunks_by_ids(ids)
    ranked = fuse(fts_ids, vec_ids, {i: h.source for i, h in hits.items()})
    total = 0
    per: dict[str, int] = {}
    chosen: list[ChunkHit] = []
    for cid, _ in ranked:
        h = hits.get(cid)
        if h is None:
            continue
        if total + h.tokens > budget_tokens or per.get(h.session, 0) + h.tokens > per_session_tokens:
            continue
        total += h.tokens
        per[h.session] = per.get(h.session, 0) + h.tokens
        chosen.append(h)
    by_session: dict[str, list[ChunkHit]] = {}
    for h in chosen:
        by_session.setdefault(h.session, []).append(h)
    out: list[SessionExcerpt] = []
    for info in index.sessions(list(by_session)):          # newest first
        cs = sorted(by_session[info.name], key=lambda h: (SOURCE_ORDER[h.source], h.ord))
        out.append(SessionExcerpt(info, cs))
    return out


# ---------------------------------------------------------------- rendering
def _date_text(iso: str) -> str:
    try:
        d = datetime.fromisoformat(iso)
    except ValueError:
        return iso
    return f"{d:%a} {d.day} {d:%b %Y}"


def labels_text(labels: list[str]) -> str:
    """`Marta Velin (Halden Works)`: the first label, the others in parentheses (the app sends person, then company)."""
    if not labels:
        return ""
    return labels[0] if len(labels) == 1 else f"{labels[0]} ({', '.join(labels[1:])})"


def header_line(info: SessionInfo) -> str:
    parts = [info.key, _date_text(info.date), info.kind, info.title]
    if info.labels:
        parts.append("with " + labels_text(info.labels))
    return "== " + " · ".join(parts)


def render_excerpts(excerpts: list[SessionExcerpt]) -> str:
    blocks: list[str] = []
    for ex in excerpts:
        lines = [header_line(ex.info)]
        prev: ChunkHit | None = None
        for c in ex.chunks:
            if c.source == "turn":
                if prev is not None and prev.source == "turn" and c.ord != prev.ord + 1:
                    lines.append("[...]")
                lines.append(c.text)
            elif c.source == "summary":
                lines.append(f"SUMMARY ({c.label}): {c.text}" if c.label else f"SUMMARY: {c.text}")
            elif c.source == "prep":
                lines.append(f"PREP ({c.label}): {c.text}" if c.label else f"PREP: {c.text}")
            else:
                lines.append(f"EARLIER CHAT: {c.text}")
            prev = c
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


# ---------------------------------------------------------------- citations
_CITE_TEXT_CAP = 240


def _source_text(index: MemoryIndex, name: str, source: str) -> str:
    """The hover-card text of a non-turn citation: the first chunk of that source, its heading and first line."""
    chunks = index.chunks_of(name, source)
    if not chunks:
        return ""
    c = chunks[0]
    first = next((ln.strip() for ln in c.text.splitlines() if ln.strip()), "")
    if source != "chat" and first.startswith("- "):
        first = first[2:]
    text = f"{c.label}: {first}" if c.label else first
    return text if len(text) <= _CITE_TEXT_CAP else text[:_CITE_TEXT_CAP - 1].rstrip() + "…"


def resolve_citations(index: MemoryIndex, text: str, scope: list[str] | None) -> list[dict]:
    """The valid citations of an answer, in order of first appearance, as the objects of spec 3.4. Valid: the key belongs to a
    session of the scope and, for a stamp, the `rows` table has that stamp for that session. Others are dropped."""
    allowed = {s.key: s for s in index.sessions(scope)}
    out: list[dict] = []
    seen: set[tuple[str, str]] = set()
    for m in CITE_RE.finditer(text):
        key, form = m.group(1), m.group(2)
        if (key, form) in seen or key not in allowed:
            continue
        info = allowed[key]
        base = {"key": key, "session": info.name, "title": info.title, "date": info.date}
        if ":" in form:
            rows = index.rows_at(info.name, form)
            if not rows:
                continue
            out.append({**base, "kind": "turn", "stamp": form, "speaker": rows[0].speaker, "text": rows[0].text})
        else:
            out.append({**base, "kind": form, "stamp": None, "speaker": None, "text": _source_text(index, info.name, form)})
        seen.add((key, form))
    return out
