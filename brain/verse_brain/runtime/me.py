"""The me layer at run time (docs/specs/2026-10-16-verse-anytime-calls-design.md 2.2).

`prep/me.py` builds the files; this module reads them for a session:

- `load_me(spec)`: `me.md` (the core), its meta, the NUMBERS facts, the library chunks and, when they match the embedding
  model, their vectors. `None` when `me.md` is missing (the session then runs without the layer, with a `me_missing` notice).
- `MeLayer.about_block(pack)`: the ABOUT <OWNER> system block. A pure function of the files and of whether the pack has a
  style guide of its own, so every request of a session, and every session started with the same files, shares its bytes.
- `conflicts(me_facts, pack)`: me NUMBERS that disagree with the pack's FACTS (the pack wins; this only reports).
- `LibraryPath`: retrieval of the top chunks for a remote turn on the brain's embedding thread. It never blocks the loop
  and never delays F; D may wait a few ms for the result on the final text.
- `.emb` codec: float16 vectors keyed by the embedding model's sha256 (the file is written by `prep/me.py`).
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import os
import re
import struct
import time
from dataclasses import dataclass, field
from operator import mul
from pathlib import Path
from typing import Callable

from ..owner import OWNER
from ..prep.sources import numbers_in
from ..prep.voice import load_voice
from .embed import PREFIX, EmbedPath, EmbedUnavailable, Embedder, unit
from .prompt import PRIORITIES_HEADING, pack_has_style_guide, render_about_block

log = logging.getLogger("verse.runtime.me")

FACT_KINDS = ("number", "date", "name")


# ---------------------------------------------------------------- data
@dataclass(frozen=True)
class Chunk:
    id: str
    ref: str          # "vault:300-Projects/X/X.md" | "file:NAME.md": what a pack snippet of the same source would carry
    source: str       # short name shown in the tail
    heading: str
    text: str


@dataclass(frozen=True)
class Hit:
    chunk: Chunk
    score: float


@dataclass
class MeLayer:
    core: str
    voice: str | None
    tokens: int
    built_at: str
    facts: list[dict] = field(default_factory=list)
    chunks: list[Chunk] = field(default_factory=list)
    emb_path: Path | None = None

    def about_block(self, pack: str) -> str:
        """ABOUT <OWNER>. His notes (<OWNER>'S NOTES) lead the block under PRIORITIES; without notes the core is used as it is. The
        STYLE GUIDE (voice.md) goes in only when the pack has none."""
        return render_about_block(priorities_first(self.core), None if pack_has_style_guide(pack) else self.voice)

    def info(self) -> dict:
        return {"tokens": self.tokens, "built_at": self.built_at}


_NOTES_HEADING = OWNER.notes_heading.casefold()


def priorities_first(core: str) -> str:
    """`me.md` with the lines of its `## <OWNER>'S NOTES` section moved to the front, under the PRIORITIES heading, and the
    section itself taken out (each note appears once). A pure function of `core`: the same text gives the same bytes. A core
    whose notes section is missing or empty comes back untouched, so a profile without notes renders exactly as before."""
    notes: list[str] = []
    rest: list[str] = []
    in_notes = False
    for ln in core.splitlines():
        s = ln.strip()
        if s.startswith("## "):
            in_notes = s[3:].strip().casefold() == _NOTES_HEADING
            if in_notes:
                continue
        if in_notes:
            if s:
                notes.append(s)
            continue
        rest.append(ln)
    if not notes:
        return core
    return PRIORITIES_HEADING + "\n" + "\n".join(notes) + "\n\n" + "\n".join(rest).strip() + "\n"


def _read_jsonl(p: Path | None) -> list[dict]:
    if p is None or not p.is_file():
        return []
    out = []
    for ln in p.read_text(encoding="utf-8").splitlines():
        if ln.strip():
            try:
                rec = json.loads(ln)
            except json.JSONDecodeError:
                continue
            if isinstance(rec, dict):
                out.append(rec)
    return out


def load_me(spec: object) -> MeLayer | None:
    """Read the layer named by `start.me` ({core, library, facts}). None when there is no usable core file."""
    if not isinstance(spec, dict) or not isinstance(spec.get("core"), str):
        return None
    core_p = Path(spec["core"]).expanduser()
    try:
        core = core_p.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    if not core.strip():
        return None
    meta: dict = {}
    try:
        meta = json.loads(core_p.with_name("me.meta.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        pass
    try:
        voice = load_voice(core_p.with_name("voice.md"))
    except Exception:  # noqa: BLE001 - an unreadable voice file must not take the layer down
        voice = None
    lib_p = Path(spec["library"]).expanduser() if isinstance(spec.get("library"), str) else None
    facts_p = Path(spec["facts"]).expanduser() if isinstance(spec.get("facts"), str) else None
    chunks = [Chunk(str(r["id"]), str(r.get("ref", "")), str(r.get("source", "")), str(r.get("heading", "")),
                    str(r.get("text", ""))) for r in _read_jsonl(lib_p) if r.get("id") and r.get("text")]
    tokens = meta.get("tokens")
    return MeLayer(core=core, voice=voice, tokens=int(tokens) if isinstance(tokens, int) else max(1, len(core) // 4),
                   built_at=str(meta.get("built_at") or ""), facts=_read_jsonl(facts_p), chunks=chunks,
                   emb_path=lib_p.with_suffix(".emb") if lib_p is not None else None)


# ---------------------------------------------------------------- conflicts with the pack
_STOP = frozenset("""the and for with from that this have has had was were are been into about over per each than then
their there they them your you our out any all but not can did does how why who what when where which will would
should could also just more most much only other some such very""".split())
_WORD = re.compile(r"[\w']+", re.UNICODE)
_PACK_FACT = re.compile(r"^\[(f\d+)\]\s+(\w+)\s+\|\s+(.*?)\s+\|\s+(.*?)\s+\|\s+.*$")


def content_words(text: str) -> set[str]:
    out = set()
    for w in _WORD.findall(text.lower()):
        if len(w) < 3 or w in _STOP or w.isdigit():
            continue
        if len(w) > 4 and w.endswith("s") and not w.endswith("ss"):
            w = w[:-1]
        out.add(w)
    return out


def jaccard(a: set[str], b: set[str]) -> float:
    return len(a & b) / len(a | b) if a and b else 0.0


def pack_number_facts(pack: str) -> list[dict]:
    """The pack's `[fNNN] number | text | value | ref` lines. A fact marked as conflicting in its sources has no value
    field and is skipped: the pack already says it does not know."""
    out = []
    for ln in pack.splitlines():
        m = _PACK_FACT.match(ln.strip())
        if m and m.group(2) == "number":
            out.append({"id": m.group(1), "text": m.group(3), "value": m.group(4)})
    return out


def conflicts(me_facts: list[dict], pack: str, min_jaccard: float = 0.5) -> list[dict]:
    """Pairs (me NUMBERS fact, pack FACT) whose labels share >= `min_jaccard` of their content words (Jaccard) while their
    numbers differ. Each me fact reports its best-matching pack fact once."""
    pfacts = pack_number_facts(pack)
    if not pfacts:
        return []
    pw = [(f, content_words(f["text"]), numbers_in(str(f["value"]))) for f in pfacts]
    items = []
    for mf in me_facts:
        if mf.get("kind") != "number":
            continue
        mw, mn = content_words(str(mf.get("text", ""))), numbers_in(str(mf.get("value", "")))
        if not mw or not mn:
            continue
        best = None
        for f, fw, fn in pw:
            j = jaccard(mw, fw)
            if j >= min_jaccard and fn and fn != mn and (best is None or j > best[0]):
                best = (j, f)
        if best is not None:
            items.append({"me": mf["id"], "pack": best[1]["id"], "topic": best[1]["text"]})
    return items


# ---------------------------------------------------------------- .emb codec
def model_sha(path: str | os.PathLike) -> str | None:
    """sha256 of the embedding model file, or None when there is no such file. Memoised by (path, size, mtime)."""
    p = Path(path).expanduser()
    try:
        st = p.stat()
    except OSError:
        return None
    key = (str(p), st.st_size, st.st_mtime_ns)
    hit = _SHA_CACHE.get(key)
    if hit is None:
        h = hashlib.sha256()
        with p.open("rb") as f:
            for blk in iter(lambda: f.read(1 << 20), b""):
                h.update(blk)
        hit = _SHA_CACHE[key] = h.hexdigest()
    return hit


_SHA_CACHE: dict[tuple, str] = {}


def write_emb(path: Path, ids: list[str], vecs: list[list[float]], sha: str) -> None:
    """Header line (JSON: model sha, dim, chunk ids in order) + the unit vectors as little-endian float16."""
    dim = len(vecs[0]) if vecs else 0
    head = json.dumps({"model_sha": sha, "dim": dim, "ids": ids}, separators=(",", ":"))
    body = b"".join(struct.pack(f"<{dim}e", *v) for v in vecs)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_bytes(head.encode("utf-8") + b"\n" + body)
    tmp.replace(path)


def read_emb(path: Path | None, sha: str | None) -> dict[str, list[float]] | None:
    """chunk id -> unit vector, or None when the file is missing, damaged or was made with another model (`sha`)."""
    if path is None or sha is None or not path.is_file():
        return None
    try:
        raw = path.read_bytes()
        nl = raw.index(b"\n")
        head = json.loads(raw[:nl].decode("utf-8"))
        if head.get("model_sha") != sha:
            return None
        dim, ids = int(head["dim"]), list(head["ids"])
        body = raw[nl + 1:]
        if dim <= 0 or len(body) != len(ids) * dim * 2:
            return None
        out = {}
        for i, cid in enumerate(ids):
            out[cid] = unit(list(struct.unpack_from(f"<{dim}e", body, i * dim * 2)))
        return out
    except (OSError, ValueError, KeyError, struct.error, UnicodeDecodeError):
        return None


# ---------------------------------------------------------------- retrieval on the embedding thread
@dataclass
class LibJob:
    turn_id: str
    text: str
    queued: float
    final: bool = False


class LibraryPath:
    """Top-k chunks of the library for a remote turn. Rides the brain's embedding thread (`EmbedPath.run_job`), one query at a
    time, newest first: while one runs, a newer queued job replaces an older one. `on_result(job, hits, ms, wait_ms)` runs
    on the event loop. Without an embedder, or when the model fails, the path stays off and the core is all there is."""

    def __init__(self, layer: MeLayer, embed: EmbedPath, spawn: Callable, model_path: str,
                 on_result: Callable[[LibJob, list[Hit], float, float], None], metric: Callable[..., None],
                 *, floor: float, k: int, batch: int = 16) -> None:
        self.layer = layer
        self.embed = embed
        self._spawn = spawn
        self._model_path = model_path
        self._on_result = on_result
        self._metric = metric
        self.floor = floor
        self.k = k
        self.batch = batch
        self.state = "off"       # off | loading | ready | unavailable
        self.vecs: dict[str, list[float]] = {}
        self._pending: LibJob | None = None
        self._busy = False

    @property
    def ready(self) -> bool:
        return self.state == "ready"

    def start(self) -> None:
        if not self.layer.chunks or self.state != "off":
            return
        self.state = "loading"
        self._spawn(self._load())

    async def _load(self) -> None:
        t0 = time.perf_counter()
        try:
            sha = await self.embed.run_job(lambda e: model_sha(self._model_path))
            vecs = read_emb(self.layer.emb_path, sha) or {}
            missing = [c for c in self.layer.chunks if c.id not in vecs]
            for i in range(0, len(missing), self.batch):
                part = missing[i:i + self.batch]
                got = await self.embed.run_job(lambda e, part=part: [unit(e.embed(PREFIX + c.text)) for c in part])
                vecs.update({c.id: v for c, v in zip(part, got)})   # type: ignore[arg-type]
        except Exception as e:  # noqa: BLE001 - EmbedUnavailable or anything the engine throws: the layer's core still works
            self.state = "unavailable"
            self._pending = None
            self._metric("", "me_library_unavailable", reason=f"{type(e).__name__}: {e}"[:160])
            return
        self.vecs = vecs
        self.state = "ready"
        self._metric("", "me_library_ready", chunks=len(self.layer.chunks), embedded_now=len(missing),
                     ms=round((time.perf_counter() - t0) * 1000, 1))
        self._kick()

    def submit(self, turn_id: str, text: str, final: bool = False) -> bool:
        """Queue a query (a queued, not yet started one is replaced). False when the path cannot serve it."""
        if self.state not in ("loading", "ready"):
            return False
        self._pending = LibJob(turn_id, text, time.perf_counter(), final)
        self._kick()
        return True

    def _kick(self) -> None:
        if self._busy or self._pending is None or not self.ready:
            return
        self._busy = True
        self._spawn(self._drain())

    def _query(self, e: Embedder, job: LibJob) -> tuple[list[Hit], float, float]:
        t0 = time.perf_counter()
        qv = unit(e.embed(PREFIX + job.text.strip()))
        scored = []
        for c in self.layer.chunks:
            v = self.vecs.get(c.id)
            if v is not None:
                scored.append((sum(map(mul, qv, v)), c))
        scored.sort(key=lambda x: -x[0])
        hits = [Hit(c, s) for s, c in scored[:self.k] if s >= self.floor]
        return hits, (time.perf_counter() - t0) * 1000, (t0 - job.queued) * 1000

    async def _drain(self) -> None:
        try:
            while self._pending is not None and self.ready:
                job, self._pending = self._pending, None
                try:
                    hits, ms, wait_ms = await self.embed.run_job(lambda e, job=job: self._query(e, job))   # type: ignore[misc]
                except Exception as e:  # noqa: BLE001
                    self.state = "unavailable"
                    self._metric("", "me_library_unavailable", reason=f"{type(e).__name__}: {e}"[:160])
                    return
                self._on_result(job, hits, ms, wait_ms)
        finally:
            self._busy = False


# ---------------------------------------------------------------- which hits go into a tail
_SNIPPET_REF = re.compile(r"^\[s\d+\]\s+(.*?)\s+\|", re.M)      # a ref may hold spaces: up to the first " | "


def pack_snippet_refs(pack: str) -> set[str]:
    return {m.group(1).lower() for m in _SNIPPET_REF.finditer(pack)}


def _same_source(chunk_ref: str, snippet_ref: str) -> bool:
    a, b = chunk_ref.lower(), snippet_ref.lower()
    if a == b:
        return True
    ta, tb = a.split(":", 1)[-1], b.split(":", 1)[-1]
    return bool(ta) and bool(tb) and (ta.endswith(tb) or tb.endswith(ta))


def select_hits(hits: list[Hit], snippet_refs: set[str], limit: int, max_chars: int) -> list[Hit]:
    """The hits that go into one tail: skip chunks whose source the pack already carries as a snippet, keep `limit` at most
    and stay inside `max_chars` of text (about a quarter of that in tokens)."""
    out, used = [], 0
    for h in hits:
        if any(_same_source(h.chunk.ref, r) for r in snippet_refs):
            continue
        if len(out) >= limit or (out and used + len(h.chunk.text) > max_chars):
            break
        out.append(h)
        used += len(h.chunk.text)
    return out
