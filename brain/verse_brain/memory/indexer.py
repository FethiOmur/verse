"""The `memory_index_start` mode of `python -u -m verse_brain.runtime` (spec 2.1, 3.3): a short-lived process that is the only writer
of the memory index while it runs.

Swift sends `memory_index_start`, one `sync` (the complete manifest), a `put` for every session in `sync_plan.need`, then `end`.
Phase 1 is the `put`s (rows, chunks and FTS in one transaction each); phase 2, on `end`, embeds every chunk that has no vector for
the current model, newest session first, in batches, with `embed_progress`. A killed process loses nothing: the fingerprint is
written by phase 1's transaction and phase 2 resumes on the next run (it embeds whatever chunk has no vector, whether or not the
sync plan asks for the session again). A chunk longer than the model's input is embedded in pieces whose vectors are averaged;
one chunk that cannot be embedded is skipped and counted, a dead engine stops the run. One writer: `flock` on `index.lock`; a second indexer
answers `status busy` and exits. Logs carry names, counts and timings, never meeting text.
"""

from __future__ import annotations

import asyncio
import fcntl
import logging
import os
import sqlite3
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from ..runtime.ask import parse_rows
from ..runtime.protocol import Emitter, INDEX_ERROR_KINDS
from ..runtime.settings import MEMORY_EMBED_BATCH, MEMORY_EMBED_MIN_PIECE_CHARS, MEMORY_EMBED_PIECE_CHARS
from .index import KINDS, MemoryIndex, SourceUnreadable
from .search import QueryEmbedder

log = logging.getLogger("verse.memory.indexer")


# ---------------------------------------------------------------- embedding a chunk of any length
class EngineFailed(Exception):
    """The embedder fails even on a tiny text: the engine is gone, not the chunk."""


class ChunkFailed(Exception):
    """This chunk cannot be embedded (the engine is alive). The run skips it."""


def _cut_point(text: str, limit: int) -> int:
    """Where to cut `text[:limit]`: after the last blank line, line break, sentence end or space in its second half; else at `limit`."""
    floor = limit // 2
    for seps in (("\n\n",), ("\n",), (". ", "? ", "! ", "; "), (" ",)):
        cut = max((text.rfind(sep, 0, limit) + len(sep) for sep in seps if sep in text[:limit]), default=-1)
        if cut > floor:
            return cut
    return limit


def split_text(text: str, limit: int) -> list[str]:
    """`text` cut into pieces of at most `limit` characters on paragraph, line, sentence or word boundaries (a hard cut only when a
    stretch has none). Nothing is dropped except the whitespace at the cuts; a text within the limit comes back whole."""
    if len(text) <= limit:
        return [text]
    out: list[str] = []
    rest = text
    while len(rest) > limit:
        cut = _cut_point(rest, limit)
        piece, rest = rest[:cut].strip(), rest[cut:]
        if piece:
            out.append(piece)
    if rest.strip():
        out.append(rest.strip())
    return out or [text[:limit]]


def mean_unit(vecs: list[list[float]], weights: list[int]) -> list[float]:
    """Length-weighted mean of unit vectors, scaled back to unit length (what the engine's own chunk-and-average does)."""
    dim = len(vecs[0])
    acc = [0.0] * dim
    for v, w in zip(vecs, weights):
        for i in range(dim):
            acc[i] += v[i] * w
    n = sum(x * x for x in acc) ** 0.5
    return [x / n for x in acc] if n > 0 else acc


class DocumentEmbedder:
    """Embeds a chunk of any length with `QueryEmbedder.document`. The model takes at most 1,024 tokens; the tokenizer is not
    reachable from here and the engine's error says nothing ("Failed to compute embedding."), so the size is handled like this:
    a text within MEMORY_EMBED_PIECE_CHARS goes in as one piece (every ordinary chunk, so its vector is what it always was), a longer
    one is cut on natural boundaries into pieces of that size; a piece the engine refuses is halved and tried again, down to
    MEMORY_EMBED_MIN_PIECE_CHARS. A refusal is told from a dead engine by a probe: a tiny text that must embed. The vectors of the
    pieces are averaged. Runs on the embedding thread."""

    PROBE = "ok"

    def __init__(self, embedder: QueryEmbedder, *, piece_chars: int = MEMORY_EMBED_PIECE_CHARS,
                 min_chars: int = MEMORY_EMBED_MIN_PIECE_CHARS) -> None:
        self._e = embedder
        self.piece_chars = piece_chars
        self.min_chars = min_chars
        self.split = 0                      # chunks that went through in more than one piece

    def document(self, text: str) -> list[float]:
        pieces = split_text(text, self.piece_chars)
        if len(pieces) > 1:
            self.split += 1
        return self._pieces(pieces)

    def _pieces(self, pieces: list[str]) -> list[float]:
        vecs = [self._piece(p) for p in pieces]
        return vecs[0] if len(vecs) == 1 else mean_unit(vecs, [len(p) for p in pieces])

    def _piece(self, text: str) -> list[float]:
        try:
            return self._e.document(text)
        except Exception as e:  # noqa: BLE001 - the engine raises a bare RuntimeError for every kind of refusal
            if not self._alive():
                raise EngineFailed(type(e).__name__) from e
            if len(text) <= self.min_chars:
                raise ChunkFailed(type(e).__name__) from e
        return self._pieces(split_text(text, -(-len(text) // 2)))

    def _alive(self) -> bool:
        try:
            self._e.document(self.PROBE)
        except Exception:  # noqa: BLE001
            return False
        return True


class IndexRuntime:
    def __init__(self, emitter: Emitter, *, fake: bool = False, no_embed: bool = False,
                 embed_model: str | None = None, embed_backend: str = "gpu") -> None:
        self.emitter = emitter
        self.fake = fake
        self.no_embed = no_embed
        self.embed_model = embed_model
        self.embed_backend = embed_backend
        self.stopped = asyncio.Event()
        self.index: MemoryIndex | None = None
        self.embedder: QueryEmbedder | None = None
        self.sha: str | None = None
        self._raw = None                    # the embedder object, built, used and closed on the pool thread
        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="memory-embed")
        self._lock_fd: int | None = None

    # ------------------------------------------------------------------ events
    def _status(self, state: str, **extra) -> None:
        self.emitter.emit({"type": "status", "state": state, "message": "", **extra})

    def _context(self) -> dict:
        assert self.index is not None
        return {**self.index.counts(), "embed": "on" if self.embedder is not None else "off"}

    def _error(self, name: str, kind: str, message: str) -> None:
        assert kind in INDEX_ERROR_KINDS, kind
        self.emitter.emit({"type": "index_error", "name": name, "kind": kind, "message": message})

    # ------------------------------------------------------------------ dispatch
    async def handle(self, msg: dict) -> None:
        t = msg.get("type")
        if t == "memory_index_start":
            await self._start(msg)
        elif self.index is None:
            return                                          # not started (busy or failed): nothing else is served
        elif t == "sync":
            self._on_sync(msg)
        elif t == "put":
            self._on_put(msg)
        elif t == "drop":
            self._on_drop(msg)
        elif t == "end":
            await self._on_end()
        elif t == "control" and msg.get("action") == "stop":
            self.stopped.set()

    async def shutdown(self) -> None:
        if self.index is not None:
            self.index.close()
            self.index = None
        if self._raw is not None:
            raw, self._raw = self._raw, None
            try:
                await asyncio.get_running_loop().run_in_executor(self._pool, raw.close)
            except Exception as e:  # noqa: BLE001 - closing must never fail the exit
                log.warning("embedder close failed: %s", type(e).__name__)
        self._pool.shutdown(wait=False)
        if self._lock_fd is not None:
            os.close(self._lock_fd)                         # releases the flock
            self._lock_fd = None

    # ------------------------------------------------------------------ start
    def _acquire(self, db: Path) -> bool:
        db.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(db.parent / "index.lock", os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            return False
        self._lock_fd = fd
        return True

    def _load_embedder(self) -> None:
        """On the pool thread (the engine is built, called and closed on one thread). Any failure to bring the embedder up leaves
        embeddings off; the indexer goes on with its phase 1."""
        from ..runtime.embed import EmbedUnavailable
        from ..runtime.me import model_sha

        raw = None
        try:
            if self.fake:
                from ..prep.me import HashEmbedder

                raw, sha = HashEmbedder(), "fake"
            else:
                from ..runtime.embed import LiteRtEmbedder

                raw = LiteRtEmbedder(self.embed_model or "", self.embed_backend)
                sha = model_sha(self.embed_model or "")
                if sha is None:
                    raise EmbedUnavailable("model file has no sha")
        except Exception as e:  # noqa: BLE001 - EmbedUnavailable, or whatever else the engine or the hash throws
            if isinstance(e, EmbedUnavailable):
                log.warning("embeddings off: %s", e)
            else:
                log.warning("embeddings off: %s: %s", type(e).__name__, e)
            self._raw, self.sha = None, None
            close = getattr(raw, "close", None)      # an engine that was built but is not used must not leak (we are on its thread)
            if close is not None:
                try:
                    close()
                except Exception as ce:  # noqa: BLE001 - closing must never fail the start
                    log.warning("embedder close failed: %s", type(ce).__name__)
            return
        self._raw, self.sha = raw, sha
        self.embedder = QueryEmbedder(self._raw, self.sha)

    async def _start(self, msg: dict) -> None:
        db = msg.get("db")
        if not isinstance(db, str) or not db:
            self._error("", "bad_request", "memory_index_start needs db")
            self.stopped.set()
            return
        path = Path(db).expanduser()
        try:
            locked = self._acquire(path)
        except OSError as e:
            self._error("", "db", type(e).__name__)
            self.stopped.set()
            return
        if not locked:
            self._status("busy")
            self.stopped.set()
            return
        try:
            self.index = MemoryIndex.open(path)
        except (sqlite3.Error, OSError) as e:
            self._error("", "db", type(e).__name__)
            self.stopped.set()
            return
        if self.index.rebuilt_from is not None:
            log.warning("index rebuilt; the old file is %s", self.index.rebuilt_from.name)
        if msg.get("embed", True) is not False and not self.no_embed:
            await asyncio.get_running_loop().run_in_executor(self._pool, self._load_embedder)
        if self.embedder is not None and self.sha:
            self.index.use_model(self.sha)
        self._status("ready", context=self._context())

    # ------------------------------------------------------------------ phase 1
    def _on_sync(self, msg: dict) -> None:
        assert self.index is not None
        sessions = msg.get("sessions")
        try:
            if not isinstance(sessions, list) or not all(isinstance(e, dict) and "name" in e and "fp" in e for e in sessions):
                raise ValueError("sessions")
            plan = self.index.plan_sync(sessions)
        except (ValueError, TypeError, KeyError):
            self._error("", "bad_request", "sync needs sessions [{name, fp, labels}]")
            return
        except sqlite3.Error as e:
            self._error("", "db", type(e).__name__)
            return
        log.info("sync plan: need %d, dropped %d, relabelled %d", len(plan.need), len(plan.dropped), plan.relabelled)
        self.emitter.emit({"type": "sync_plan", "need": plan.need, "dropped": plan.dropped, "relabelled": plan.relabelled})

    def _on_put(self, msg: dict) -> None:
        assert self.index is not None
        name = msg.get("name") if isinstance(msg.get("name"), str) else ""
        t0 = time.perf_counter()
        try:
            strs = {k: msg.get(k) for k in ("name", "dir", "fp", "title", "date")}
            kind = msg.get("kind")
            labels = msg.get("labels") or []
            if (not all(isinstance(v, str) and v for v in strs.values()) or kind not in KINDS
                    or not isinstance(labels, list) or not isinstance(msg.get("rows") or [], list)):
                raise ValueError("put")
            res = self.index.put(name=name, dir=Path(strs["dir"]).expanduser(), fp=strs["fp"], title=strs["title"],
                                 date=strs["date"], kind=kind,
                                 lang=msg["lang"] if isinstance(msg.get("lang"), str) else "",
                                 labels=[str(x) for x in labels], rows=parse_rows(msg.get("rows") or []))
        except ValueError:
            self._error(name, "bad_request", "put needs name, dir, fp, title, date, kind and rows")
            return
        except SourceUnreadable as e:
            self._error(name, "unreadable", str(e))
            return
        except sqlite3.Error as e:
            self._error(name, "db", type(e).__name__)
            return
        ms = round((time.perf_counter() - t0) * 1000)
        log.info("put %s: %s, %d chunks, %d ms", name, res.key, res.chunks, ms)
        self.emitter.emit({"type": "put_done", "name": name, "key": res.key, "chunks": res.chunks, "ms": ms})

    def _on_drop(self, msg: dict) -> None:
        assert self.index is not None
        names = msg.get("names")
        if not isinstance(names, list) or not all(isinstance(n, str) for n in names):
            self._error("", "bad_request", "drop needs names")
            return
        try:
            self.index.drop(names)
        except sqlite3.Error as e:
            self._error("", "db", type(e).__name__)

    # ------------------------------------------------------------------ phase 2
    async def _on_end(self) -> None:
        assert self.index is not None
        if self.embedder is not None and self.sha:
            await self._embed_all()
        self._status("done", context=self._context())
        self.stopped.set()

    def _embed_batch(self, doc: DocumentEmbedder, batch: list[tuple[int, str]]) -> tuple[list[tuple[int, list[float]]], list[int], bool]:
        """On the pool thread: (vectors, ids of chunks that could not be embedded, engine dead). A dead engine ends the batch."""
        ok: list[tuple[int, list[float]]] = []
        bad: list[int] = []
        for cid, text in batch:
            try:
                ok.append((cid, doc.document(text)))
            except ChunkFailed:
                bad.append(cid)
            except EngineFailed:
                return ok, bad, True
        return ok, bad, False

    async def _embed_all(self) -> None:
        assert self.index is not None and self.embedder is not None and self.sha
        loop = asyncio.get_running_loop()
        doc = DocumentEmbedder(self.embedder)
        sha = self.sha
        total = self.index.count_pending(sha)
        done = 0
        skipped: set[int] = set()
        t0 = time.perf_counter()
        while done + len(skipped) < total:
            batch = self.index.pending_vectors(sha, MEMORY_EMBED_BATCH, skipped)
            if not batch:
                break
            try:
                ok, bad, dead = await loop.run_in_executor(self._pool, self._embed_batch, doc, batch)
            except Exception as e:  # noqa: BLE001 - not an embedder failure (those come back in `dead`): the vector path stops
                log.warning("embedding stopped: %s", type(e).__name__)
                self.embedder = None
                return
            if ok:
                self.index.store_vectors(sha, ok)
                done += len(ok)
            if bad:
                skipped.update(bad)
                sessions = self.index.chunk_sessions(bad)
                for cid in bad:
                    log.warning("embedding skipped chunk %d of session %s", cid, sessions.get(cid, "?"))
            if dead:
                log.warning("embedding stopped: engine failed (%d embedded, %d skipped so far)", done, len(skipped))
                self.embedder = None
                return
            self.emitter.emit({"type": "embed_progress", "done": min(done + len(skipped), total), "total": total})
        if skipped:
            log.warning("embedding skipped %d chunks that could not be embedded; they stay pending", len(skipped))
        log.info("embedded %d chunks (%d in pieces) in %d ms", done, doc.split, round((time.perf_counter() - t0) * 1000))
