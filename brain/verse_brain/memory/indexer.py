"""The `memory_index_start` mode of `python -u -m verse_brain.runtime` (spec 2.1, 3.3): a short-lived process that is the only writer
of the memory index while it runs.

Swift sends `memory_index_start`, one `sync` (the complete manifest), a `put` for every session in `sync_plan.need`, then `end`.
Phase 1 is the `put`s (rows, chunks and FTS in one transaction each); phase 2, on `end`, embeds every chunk that has no vector for
the current model, newest session first, in batches, with `embed_progress`. A killed process loses nothing: the fingerprint is
written by phase 1's transaction and phase 2 resumes on the next run. One writer: `flock` on `index.lock`; a second indexer
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
from ..runtime.settings import MEMORY_EMBED_BATCH
from .index import KINDS, MemoryIndex, SourceUnreadable
from .search import QueryEmbedder

log = logging.getLogger("verse.memory.indexer")


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
        """On the pool thread (the engine is built, called and closed on one thread)."""
        from ..runtime.embed import EmbedUnavailable
        from ..runtime.me import model_sha

        try:
            if self.fake:
                from ..prep.me import HashEmbedder

                self._raw, self.sha = HashEmbedder(), "fake"
            else:
                from ..runtime.embed import LiteRtEmbedder

                raw = LiteRtEmbedder(self.embed_model or "", self.embed_backend)
                self._raw, self.sha = raw, model_sha(self.embed_model or "")
                if self.sha is None:
                    raise EmbedUnavailable("model file has no sha")
        except EmbedUnavailable as e:
            log.warning("embeddings off: %s", e)
            self._raw, self.sha = None, None
            return
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

    async def _embed_all(self) -> None:
        assert self.index is not None and self.embedder is not None and self.sha
        loop = asyncio.get_running_loop()
        emb, sha = self.embedder, self.sha
        total = self.index.count_pending(sha)
        done = 0
        t0 = time.perf_counter()
        while done < total:
            batch = self.index.pending_vectors(sha, MEMORY_EMBED_BATCH)
            if not batch:
                break
            try:
                vecs = await loop.run_in_executor(self._pool, lambda b=batch: [emb.document(text) for _, text in b])
            except Exception as e:  # noqa: BLE001 - an engine failure turns the vector path off; FTS keeps working
                log.warning("embedding stopped: %s", type(e).__name__)
                self.embedder = None
                return
            self.index.store_vectors(sha, [(cid, v) for (cid, _), v in zip(batch, vecs)])
            done += len(batch)
            self.emitter.emit({"type": "embed_progress", "done": min(done, total), "total": total})
        log.info("embedded %d chunks in %d ms", done, round((time.perf_counter() - t0) * 1000))
