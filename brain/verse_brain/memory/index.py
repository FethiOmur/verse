"""The memory index file (spec 2.1, 3.2): schema, open, session keys, chunking, sync / put / drop, vectors.

One writer at a time (the indexer process holds `index.lock`); readers open the file read-only. The index holds copies of
meeting text, so a delete is a secure delete: `secure_delete = ON`, then a WAL truncate.
Logs carry names and counts, never text.
"""

from __future__ import annotations

import hashlib
import json
import logging
import re
import sqlite3
import struct
import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable, Iterator
from urllib.parse import quote

from ..prep.voice import strip_voice
from ..runtime.ask import Row, est_tokens, fold, load_history
from ..runtime.settings import MEMORY_CHUNK_CHARS, MEMORY_CHUNK_ROWS

log = logging.getLogger("verse.memory.index")

SCHEMA_VERSION = 1
SOURCES = ("turn", "summary", "prep", "chat")
# Time order of the sources of one session: the prep before the call, the call, the summary after it, the chats after that.
SOURCE_ORDER = {"prep": 0, "turn": 1, "summary": 2, "chat": 3}
KINDS = ("meeting", "call", "prepared")
CROCKFORD = "0123456789abcdefghjkmnpqrstvwxyz"

_SCHEMA = """
CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT NOT NULL);
CREATE TABLE sessions(
  name TEXT PRIMARY KEY,
  key TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL, date TEXT NOT NULL,
  kind TEXT NOT NULL,
  lang TEXT NOT NULL DEFAULT '',
  labels TEXT NOT NULL DEFAULT '[]',
  fingerprint TEXT NOT NULL,
  indexed_at TEXT NOT NULL);
CREATE TABLE rows(
  session TEXT NOT NULL REFERENCES sessions(name) ON DELETE CASCADE,
  ix INTEGER NOT NULL, stamp TEXT NOT NULL, speaker TEXT NOT NULL, text TEXT NOT NULL,
  PRIMARY KEY(session, ix));
CREATE INDEX rows_stamp ON rows(session, stamp);
CREATE TABLE chunks(
  id INTEGER PRIMARY KEY,
  session TEXT NOT NULL REFERENCES sessions(name) ON DELETE CASCADE,
  source TEXT NOT NULL,
  ord INTEGER NOT NULL,
  stamp TEXT, stamp_end TEXT,
  row_first INTEGER, row_last INTEGER,
  label TEXT,
  text TEXT NOT NULL, tokens INTEGER NOT NULL);
CREATE INDEX chunks_session ON chunks(session, source, ord);
CREATE VIRTUAL TABLE chunks_fts USING fts5(body, content='', contentless_delete=1,
  tokenize='unicode61 remove_diacritics 2');
CREATE TABLE vectors(
  chunk INTEGER PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
  model_sha TEXT NOT NULL, dim INTEGER NOT NULL, vec BLOB NOT NULL);
"""


class IndexUnavailable(Exception):
    """A read-only open found no usable index (missing file, wrong schema version, not a database)."""


class SourceUnreadable(Exception):
    """A file of the session folder exists and cannot be read as text. The put is skipped, so the next sync retries it."""


@dataclass(frozen=True)
class SessionInfo:
    name: str
    key: str
    title: str
    date: str
    kind: str
    lang: str
    labels: list[str]


@dataclass(frozen=True)
class ChunkHit:
    id: int
    session: str
    source: str
    ord: int
    stamp: str | None
    stamp_end: str | None
    row_first: int | None
    row_last: int | None
    label: str | None
    text: str
    tokens: int


@dataclass(frozen=True)
class SyncPlan:
    need: list[str]
    dropped: list[str]
    relabelled: int


@dataclass(frozen=True)
class PutResult:
    key: str
    chunks: int


@dataclass(frozen=True)
class NewChunk:
    source: str
    ord: int
    text: str
    label: str | None = None
    stamp: str | None = None
    stamp_end: str | None = None
    row_first: int | None = None
    row_last: int | None = None


# ---------------------------------------------------------------- keys
def _crockford(digest: bytes, n: int) -> str:
    bits = int.from_bytes(digest, "big")
    total = len(digest) * 8
    return "".join(CROCKFORD[(bits >> (total - 5 * (i + 1))) & 31] for i in range(n))


def session_key(name: str, taken: set[str]) -> str:
    """`s` + the first 6 base32 (Crockford, lowercase) characters of SHA-256(name); 8 on a collision with a key in `taken`.
    Depends on the name only, so an undone trash gets its key back."""
    digest = hashlib.sha256(name.encode()).digest()
    key = "s" + _crockford(digest, 6)
    return key if key not in taken else "s" + _crockford(digest, 8)


# ---------------------------------------------------------------- chunking
def index_text(label: str | None, text: str) -> str:
    """What is folded into the FTS body and embedded for a chunk: the heading of a summary / prep chunk is part of its meaning."""
    return f"{label}\n{text}" if label else text


def turn_chunks(rows: list[Row]) -> list[NewChunk]:
    """Consecutive rows, at most MEMORY_CHUNK_ROWS rows and MEMORY_CHUNK_CHARS characters, cut on row boundaries; a row longer
    than the cap is a chunk of its own."""
    out: list[NewChunk] = []
    cur: list[tuple[int, Row]] = []
    chars = 0

    def flush() -> None:
        nonlocal cur, chars
        if cur:
            out.append(NewChunk("turn", len(out), "\n".join(r.line for _, r in cur), stamp=cur[0][1].stamp,
                                stamp_end=cur[-1][1].stamp, row_first=cur[0][0], row_last=cur[-1][0]))
        cur, chars = [], 0

    for ix, r in enumerate(rows):
        n = len(r.line) + 1
        if cur and (len(cur) >= MEMORY_CHUNK_ROWS or chars + n > MEMORY_CHUNK_CHARS):
            flush()
        cur.append((ix, r))
        chars += n
    flush()
    return out


_GENERATED = re.compile(r"_generated.*_")
_EMPTY_BODY = {"- (none)", "(none)", "(none yet)", "(not available)"}


def summary_chunks(text: str) -> list[NewChunk]:
    """One chunk per `## ` section of summary.md (`label` = its heading). The `_generated…_` line, a `> DRAFT` line, the `Metrics`
    section and an empty "- (none)" body are skipped."""
    out: list[NewChunk] = []
    label: str | None = None
    body: list[str] = []

    def close() -> None:
        if label is None or label == "Metrics":
            return
        t = "\n".join(body).strip()
        if t and t not in _EMPTY_BODY:
            out.append(NewChunk("summary", len(out), t, label=label))

    for ln in text.splitlines():
        s = ln.strip()
        if ln.startswith("## "):
            close()
            label, body = ln[3:].strip(), []
        elif label is None or _GENERATED.fullmatch(s) or s.startswith("> DRAFT"):
            continue
        else:
            body.append(ln.rstrip())
    close()
    return out


def prep_chunks(pack: str) -> list[NewChunk]:
    """pack.md without its STYLE GUIDE, cut at `## ` headings and then at MEMORY_CHUNK_CHARS on line boundaries."""
    sections: list[tuple[str | None, list[str]]] = []
    label: str | None = None
    lines: list[str] = []
    for ln in strip_voice(pack).splitlines():
        if ln.startswith("## "):
            sections.append((label, lines))
            label, lines = ln[3:].strip(), []
        else:
            lines.append(ln.rstrip())
    sections.append((label, lines))
    out: list[NewChunk] = []
    for lab, body in sections:
        cur: list[str] = []
        chars = 0

        def flush() -> None:
            nonlocal cur, chars
            t = "\n".join(cur).strip()
            if t:
                out.append(NewChunk("prep", len(out), t, label=lab))
            cur, chars = [], 0

        for ln in body:
            n = len(ln) + 1
            if cur and chars + n > MEMORY_CHUNK_CHARS:
                flush()
            cur.append(ln)
            chars += n
        flush()
    return out


def chat_chunks(path: Path) -> list[NewChunk]:
    """One chunk per answered Q/A pair after the last `reset` of chat.jsonl (the same reader as Ask this meeting)."""
    return [NewChunk("chat", i, f"Q: {q}\nA: {a}") for i, (q, a) in enumerate(load_history(path, limit=10**9))]


def _read_text(p: Path) -> str | None:
    if not p.is_file():
        return None
    try:
        return p.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as e:
        raise SourceUnreadable(f"{p.name}: {type(e).__name__}") from e


def build_chunks(folder: Path, rows: list[Row]) -> list[NewChunk]:
    out = turn_chunks(rows)
    summary = _read_text(folder / "summary.md")
    if summary:
        out += summary_chunks(summary)
    pack = _read_text(folder / "pack.md")
    if pack:
        out += prep_chunks(pack)
    out += chat_chunks(folder / "chat.jsonl")
    return out


# ---------------------------------------------------------------- the index
def _date_key(s: str) -> float:
    try:
        return datetime.fromisoformat(s).timestamp()
    except ValueError:
        return 0.0


def _marks(n: int) -> str:
    return ",".join("?" * n)


class MemoryIndex:
    def __init__(self, con: sqlite3.Connection, path: Path, *, readonly: bool, rebuilt_from: Path | None = None) -> None:
        self.con = con
        self.path = path
        self.readonly = readonly
        self.rebuilt_from = rebuilt_from      # the set-aside file when the index was unreadable and a new one was made

    # ------------------------------------------------------------ open / close
    @classmethod
    def open(cls, path: Path | str, *, readonly: bool = False) -> "MemoryIndex":
        path = Path(path)
        if readonly:
            try:
                con = sqlite3.connect(f"file:{quote(str(path))}?mode=ro", uri=True, isolation_level=None)
                ver = con.execute("PRAGMA user_version").fetchone()[0]
            except sqlite3.Error as e:
                raise IndexUnavailable(f"{type(e).__name__}") from e
            if ver != SCHEMA_VERSION:
                con.close()
                raise IndexUnavailable(f"schema version {ver}")
            return cls(con, path, readonly=True)
        path.parent.mkdir(parents=True, exist_ok=True)
        aside: Path | None = None
        for _ in range(2):
            con = sqlite3.connect(path, isolation_level=None)
            try:
                ver = con.execute("PRAGMA user_version").fetchone()[0]
                tables = con.execute("SELECT count(*) FROM sqlite_master").fetchone()[0]
                if (ver == 0 and tables != 0) or ver not in (0, SCHEMA_VERSION):
                    raise sqlite3.DatabaseError("unexpected schema version")
                con.execute("PRAGMA journal_mode=WAL")
                con.execute("PRAGMA foreign_keys=ON")
                con.execute("PRAGMA secure_delete=ON")
                if ver == 0:
                    con.executescript(_SCHEMA + f"PRAGMA user_version = {SCHEMA_VERSION};")
                else:
                    con.execute("SELECT 1 FROM sessions LIMIT 1")
                    con.execute("SELECT 1 FROM chunks_fts LIMIT 1")
                return cls(con, path, readonly=False, rebuilt_from=aside)
            except sqlite3.DatabaseError:
                con.close()
                aside = cls._set_aside(path)
        raise sqlite3.DatabaseError("the index could not be created")     # unreachable in practice

    @staticmethod
    def _set_aside(path: Path) -> Path:
        """Rename an unreadable index (and its -wal / -shm) to `index.sqlite.unreadable-<yyyyMMdd-HHmmss>`. Never deletes it."""
        stamp = time.strftime("%Y%m%d-%H%M%S")
        target = path.with_name(f"{path.name}.unreadable-{stamp}")
        n = 1
        while target.exists():
            n += 1
            target = path.with_name(f"{path.name}.unreadable-{stamp}-{n}")
        path.rename(target)
        for suffix in ("-wal", "-shm"):
            side = path.with_name(path.name + suffix)
            if side.exists():
                side.rename(target.with_name(target.name + suffix))
        log.warning("memory index unreadable, set aside as %s", target.name)
        return target

    def close(self) -> None:
        try:
            self.con.close()
        except sqlite3.Error:
            pass

    @contextmanager
    def _tx(self) -> Iterator[None]:
        self.con.execute("BEGIN IMMEDIATE")
        try:
            yield
        except BaseException:
            self.con.execute("ROLLBACK")
            raise
        self.con.execute("COMMIT")

    # ------------------------------------------------------------ sync / put / drop
    def plan_sync(self, manifest: list[dict]) -> SyncPlan:
        """Compares the manifest ([{name, fp, labels}]) with the index. Sessions absent from it are dropped and sessions whose
        labels alone changed are relabelled, both committed before this returns; the rest of the answer is what to `put`."""
        wanted: dict[str, tuple[str, list[str]]] = {}
        for e in manifest:
            wanted[str(e["name"])] = (str(e["fp"]), [str(x) for x in (e.get("labels") or [])])
        present = {n: (fp, json.loads(lab)) for n, fp, lab in
                   self.con.execute("SELECT name, fingerprint, labels FROM sessions")}
        dropped = sorted(n for n in present if n not in wanted)
        need: list[str] = []
        relabel: list[tuple[str, list[str]]] = []
        for name, (fp, labels) in wanted.items():
            if name not in present or present[name][0] != fp:
                need.append(name)
            elif present[name][1] != labels:
                relabel.append((name, labels))
        if relabel:
            with self._tx():
                for name, labels in relabel:
                    self.con.execute("UPDATE sessions SET labels=? WHERE name=?",
                                     (json.dumps(labels, ensure_ascii=False), name))
        if dropped:
            self.drop(dropped)
        return SyncPlan(need, dropped, len(relabel))

    def _clear_session_chunks(self, name: str) -> None:
        ids = [r[0] for r in self.con.execute("SELECT id FROM chunks WHERE session=?", (name,))]
        self.con.executemany("DELETE FROM chunks_fts WHERE rowid=?", ((i,) for i in ids))
        self.con.execute("DELETE FROM chunks WHERE session=?", (name,))      # vectors cascade
        self.con.execute("DELETE FROM rows WHERE session=?", (name,))

    def put(self, *, name: str, dir: Path, fp: str, title: str, date: str, kind: str, lang: str,
            labels: list[str], rows: list[Row]) -> PutResult:
        """Phase 1 for one session, in one transaction: rows, chunks and FTS entries (replacing what the session had)."""
        chunks = build_chunks(Path(dir), rows)          # reads the folder before the transaction; may raise SourceUnreadable
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        with self._tx():
            have = self.con.execute("SELECT key FROM sessions WHERE name=?", (name,)).fetchone()
            if have:
                key = have[0]
                self._clear_session_chunks(name)
                self.con.execute("UPDATE sessions SET title=?, date=?, kind=?, lang=?, labels=?, fingerprint=?, indexed_at=? "
                                 "WHERE name=?", (title, date, kind, lang, json.dumps(labels, ensure_ascii=False), fp, now, name))
            else:
                taken = {r[0] for r in self.con.execute("SELECT key FROM sessions")}
                key = session_key(name, taken)
                self.con.execute("INSERT INTO sessions(name,key,title,date,kind,lang,labels,fingerprint,indexed_at) "
                                 "VALUES(?,?,?,?,?,?,?,?,?)",
                                 (name, key, title, date, kind, lang, json.dumps(labels, ensure_ascii=False), fp, now))
            self.con.executemany("INSERT INTO rows(session,ix,stamp,speaker,text) VALUES(?,?,?,?,?)",
                                 ((name, i, r.stamp, r.speaker, r.text) for i, r in enumerate(rows)))
            for c in chunks:
                cur = self.con.execute(
                    "INSERT INTO chunks(session,source,ord,stamp,stamp_end,row_first,row_last,label,text,tokens) "
                    "VALUES(?,?,?,?,?,?,?,?,?,?)",
                    (name, c.source, c.ord, c.stamp, c.stamp_end, c.row_first, c.row_last, c.label, c.text, est_tokens(c.text)))
                self.con.execute("INSERT INTO chunks_fts(rowid, body) VALUES(?,?)",
                                 (cur.lastrowid, fold(index_text(c.label, c.text))))
        return PutResult(key, len(chunks))

    def drop(self, names: Iterable[str]) -> None:
        """Secure delete: the sessions' rows, chunks, FTS entries and vectors go in one transaction (`secure_delete = ON` zeroes
        the freed bytes, the folded terms of the FTS index included), then the WAL is checkpointed and truncated."""
        names = list(names)
        if not names:
            return
        with self._tx():
            for n in names:
                self._clear_session_chunks(n)
                self.con.execute("DELETE FROM sessions WHERE name=?", (n,))
        self.con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        log.info("dropped %d sessions", len(names))

    # ------------------------------------------------------------ vectors
    def embed_sha(self) -> str | None:
        r = self.con.execute("SELECT v FROM meta WHERE k='embed_sha'").fetchone()
        return r[0] if r else None

    def use_model(self, sha: str) -> bool:
        """Records the embedding model sha. A different one than before clears every vector (they would not compare); returns
        True when it did."""
        if self.embed_sha() == sha:
            return False
        with self._tx():
            self.con.execute("DELETE FROM vectors")
            self.con.execute("INSERT OR REPLACE INTO meta(k,v) VALUES('embed_sha',?)", (sha,))
        return True

    def _pending_where(self) -> str:
        return "LEFT JOIN vectors v ON v.chunk = c.id WHERE (v.chunk IS NULL OR v.model_sha != ?)"

    def count_pending(self, model_sha: str) -> int:
        return self.con.execute(f"SELECT count(*) FROM chunks c {self._pending_where()}", (model_sha,)).fetchone()[0]

    def pending_vectors(self, model_sha: str, limit: int) -> list[tuple[int, str]]:
        """(chunk id, text to embed) of chunks without a vector for this model, newest session first."""
        cur = self.con.execute(
            f"SELECT c.id, c.label, c.text FROM chunks c JOIN sessions s ON s.name = c.session {self._pending_where()} "
            "ORDER BY s.date DESC, c.id LIMIT ?", (model_sha, limit))
        return [(i, index_text(lab, text)) for i, lab, text in cur]

    def store_vectors(self, model_sha: str, items: list[tuple[int, list[float]]]) -> None:
        with self._tx():
            self.con.executemany(
                "INSERT OR REPLACE INTO vectors(chunk, model_sha, dim, vec) VALUES(?,?,?,?)",
                ((cid, model_sha, len(v), struct.pack(f"<{len(v)}e", *v)) for cid, v in items))

    def vectors(self, scope: list[str] | None, sources: tuple[str, ...], model_sha: str | None,
                dim: int) -> list[tuple[int, list[float]]]:
        """The stored vectors (unit length, float16 on disk) of the scope's chunks of these sources."""
        sql = "SELECT v.chunk, v.vec FROM vectors v JOIN chunks c ON c.id = v.chunk WHERE v.dim = ?"
        params: list = [dim]
        if model_sha is not None:
            sql += " AND v.model_sha = ?"
            params.append(model_sha)
        sql += f" AND c.source IN ({_marks(len(sources))})"
        params += list(sources)
        if scope is not None:
            sql += f" AND c.session IN ({_marks(len(scope))})"
            params += scope
        fmt = f"<{dim}e"
        return [(cid, list(struct.unpack(fmt, blob))) for cid, blob in self.con.execute(sql, params)]

    # ------------------------------------------------------------ reads
    def counts(self) -> dict:
        sha = self.embed_sha()
        sessions = self.con.execute("SELECT count(*) FROM sessions").fetchone()[0]
        chunks = self.con.execute("SELECT count(*) FROM chunks").fetchone()[0]
        vecs = (self.con.execute("SELECT count(*) FROM vectors WHERE model_sha=?", (sha,)).fetchone()[0] if sha else 0)
        return {"sessions": sessions, "chunks": chunks, "vectors": vecs}

    @staticmethod
    def _info(r: tuple) -> SessionInfo:
        return SessionInfo(r[0], r[1], r[2], r[3], r[4], r[5], json.loads(r[6]))

    _INFO_COLS = "name, key, title, date, kind, lang, labels"

    def sessions(self, scope: list[str] | None = None) -> list[SessionInfo]:
        """The sessions of the scope (None = all), newest first."""
        if scope is not None and not scope:
            return []
        sql = f"SELECT {self._INFO_COLS} FROM sessions"
        params: list = []
        if scope is not None:
            sql += f" WHERE name IN ({_marks(len(scope))})"
            params = list(scope)
        out = [self._info(r) for r in self.con.execute(sql, params)]
        out.sort(key=lambda s: (_date_key(s.date), s.name), reverse=True)
        return out

    def session_by_key(self, key: str) -> SessionInfo | None:
        r = self.con.execute(f"SELECT {self._INFO_COLS} FROM sessions WHERE key=?", (key,)).fetchone()
        return self._info(r) if r else None

    def rows_at(self, name: str, stamp: str) -> list[Row]:
        cur = self.con.execute("SELECT stamp, speaker, text FROM rows WHERE session=? AND stamp=? ORDER BY ix", (name, stamp))
        return [Row(*r) for r in cur]

    def first_last_rows(self, name: str, first: int, last: int) -> list[Row]:
        cur = self.con.execute("SELECT stamp, speaker, text FROM rows WHERE session=? AND ix BETWEEN ? AND ? ORDER BY ix",
                               (name, first, last))
        return [Row(*r) for r in cur]

    _CHUNK_COLS = "id, session, source, ord, stamp, stamp_end, row_first, row_last, label, text, tokens"

    def chunks_of(self, name: str, source: str) -> list[ChunkHit]:
        cur = self.con.execute(f"SELECT {self._CHUNK_COLS} FROM chunks WHERE session=? AND source=? ORDER BY ord", (name, source))
        return [ChunkHit(*r) for r in cur]

    def chunks_by_ids(self, ids: list[int]) -> dict[int, ChunkHit]:
        out: dict[int, ChunkHit] = {}
        for i in range(0, len(ids), 500):
            part = ids[i:i + 500]
            for r in self.con.execute(f"SELECT {self._CHUNK_COLS} FROM chunks WHERE id IN ({_marks(len(part))})", part):
                out[r[0]] = ChunkHit(*r)
        return out

    def fts_ids(self, match: str, scope: list[str] | None, sources: tuple[str, ...], limit: int) -> list[int]:
        """Chunk ids matching an FTS expression, best BM25 first, inside the scope and the sources."""
        sql = ("SELECT c.id FROM chunks_fts JOIN chunks c ON c.id = chunks_fts.rowid WHERE chunks_fts MATCH ?"
               f" AND c.source IN ({_marks(len(sources))})")
        params: list = [match, *sources]
        if scope is not None:
            sql += f" AND c.session IN ({_marks(len(scope))})"
            params += scope
        sql += " ORDER BY bm25(chunks_fts), c.id LIMIT ?"
        params.append(limit)
        return [r[0] for r in self.con.execute(sql, params)]
