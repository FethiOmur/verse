"""Running the persona: one session's update, the backfill plan, and the `persona_start` process mode the app starts after a call.

`update_session` is the one code path for the app and the command line: lock, read the store (folding in the owner's edits), read
the session's rows headless (rows.py), skip it when its fingerprint is unchanged (and it was already reviewed by this review
version), send ONE request that both extracts the items and reviews every question -> answer pair (review.py), verify the items
(extract.py) and the review, leave out items cited in a weak answer, merge the items (store.py), add the review's better answers,
replace what an earlier run of the same session wrote and this run did not write again (store.py `retract`; the owner's
edits and rejections stay), append the session's Log note, write its Review note, save, and optionally compile (compile.py). Spend is recorded even when the
answer cannot be read.

Sessions never learned from: `sim-*`, the general prep folder and the compiled folder (`excluded`); the app also leaves out the
session being recorded, and the backfill takes extra name prefixes.

The process mode (runtime/__main__.py routes a first message `persona_start` here):

  Swift -> brain   persona_start{action: "update" (default) | "compile" | "import_general" | "status" | "resolve",
                                 session_dir      the finished session (update),
                                 sessions_root    default: the parent of session_dir,
                                 persona_dir      default: owner.json persona_dir (unset -> persona_error off),
                                 state            default: ~/Library/Application Support/Verse/profile/persona.meta.json,
                                 me               {core, notes}: me.md / me.notes.md, the confirmed sources for card-read rows,
                                 compile          default true: compile after an update that changed the persona,
                                 compile_out      default: <sessions_root>/persona-core,
                                 general_core     default: <sessions_root>/general-core (import_general),
                                 seed_from_general default false: before an update, compile or resolve, import the general prep
                                                  once when the persona has no seed yet (the app sends true, so the first
                                                  compiled persona never drops the standing answers),
                                 id, keep         resolve: the contradiction id and "1" | "2" | one of its two entry ids,
                                 force, budget_usd, owner_name}
                   `status` reads only (no write); `resolve` settles one open contradiction, saves and compiles.
                   Only `update` reads the Keychain (runtime/__main__.py); the other actions never call the model.
  brain -> Swift   status{state:"warming"}; status{state:"ready", context:{owner_rows, own, read, mixed, other_rows, room_rows,
                   est_input_tokens, max_tokens}} right before the request; then exactly one of
                   persona_done{action, session, skipped: null|"unchanged"|"no_owner_rows", kept, dropped{kind,cite,quote,number,name,
                                unconfirmed,empty,weak}, new, repeats, contradictions[ids], open_contradictions, cost_usd, usage,
                                review: {pairs, reviewed, weak, strong, fine, marks, improved, adopted, kept, no_better, rejected,
                                         not_banked, better: [ids], demoted: [ids], note: "Review/<date> <skey>.md"|null,
                                         dropped{...}} | null,
                                compiled: {out,bank,facts,glossary,snippets,unsettled,pack_tokens_est}|null, compile_error, imported,
                                open: [{id, topic, a:{id,text,quote,date,ref}, b:{...}}], ms_total}
                   persona_error{kind, message, retry_after?, session?}; kinds: PERSONA_ERROR_KINDS (runtime/protocol.py)
  The process then ends (`stopped`). Logs carry counts and timings, never transcript or item text.

A kill never leaves the notes half-written: every file is replaced atomically, and SIGTERM is held back while a commit (the
Log note, Persona.md, the state file, the compiled folder) is being written, so the app's Stop-on-call-start lands before or
after it, never inside it. Before the commit nothing is written but the state file's spend.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import signal
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from ..memory.index import session_key
from ..prep.model import PRICES, spend_usd
from ..runtime.ask import error_kind, now_iso, usage_of
from ..runtime.protocol import PERSONA_ACTIONS, PERSONA_ERROR_KINDS, Emitter
from ..runtime.settings import PERSONA_CONTEXT_TOKENS, PERSONA_ROWS_TOKENS, persona_params
from ..runtime.transport import TransportError
from .compile import COMPILED_NAME, GENERAL_NAME, compile_async, import_general_core
from .extract import Confirmed, Request, build_request, parse_items, verify_items
from .rows import SessionRows, _objects, load_session_rows
from .review import (REVIEW_VERSION, SourceBook, apply_review, build_pairs, estimate, note_rel, parse_reviews, render_note,
                     review_blocks, verify_reviews)
from .store import PersonaError, PersonaStore, one_line

log = logging.getLogger("verse.persona")

PROFILE_DIR = Path("~/Library/Application Support/Verse/profile")
SESSIONS_DIR = Path("~/Library/Application Support/Verse/sessions")
STATE_NAME = "persona.meta.json"
ALWAYS_EXCLUDED_PREFIXES = ("sim-",)
ALWAYS_EXCLUDED_NAMES = (GENERAL_NAME, COMPILED_NAME)


class PersonaRunError(PersonaError):
    def __init__(self, kind: str, message: str, retry_after: float | None = None) -> None:
        super().__init__(message)
        self.kind = kind
        self.retry_after = retry_after


# ---------------------------------------------------------------- the commit section
_commit_depth = 0
_deferred: list[int] = []


def _terminate() -> None:
    """The held-back SIGTERM, delivered now that the files are whole (the default action ends the process)."""
    os.kill(os.getpid(), signal.SIGTERM)


@contextmanager
def commit(on_deferred=None):
    """Hold SIGTERM while the persona's files are written, then deliver it. Nested sections hold it until the outermost one
    ends. Only the main thread can install a handler; elsewhere (a test's worker thread) this is a plain block. Every write is
    atomic on its own, so a SIGKILL still leaves whole files; this keeps the set of files consistent too."""
    global _commit_depth
    prev = None
    if _commit_depth == 0 and threading.current_thread() is threading.main_thread():
        try:
            prev = signal.signal(signal.SIGTERM, lambda signum, frame: _deferred.append(signum))
        except (ValueError, OSError):
            prev = None
    _commit_depth += 1
    try:
        yield
    finally:
        _commit_depth -= 1
        if _commit_depth == 0 and prev is not None:
            signal.signal(signal.SIGTERM, prev)
            if _deferred:
                _deferred.clear()
                log.info("persona: a stop arrived during a commit; delivered after it")
                (on_deferred or _terminate)()


def default_state() -> Path:
    return (PROFILE_DIR / STATE_NAME).expanduser()


def excluded(name: str, prefixes: tuple[str, ...] = ()) -> bool:
    return name in ALWAYS_EXCLUDED_NAMES or name.startswith(ALWAYS_EXCLUDED_PREFIXES + tuple(prefixes))


def session_date(session_dir: Path) -> str:
    """YYYY-MM-DD of the call: the first wall clock of its transcript, else meta.json created_at, else the folder's mtime."""
    for o in _objects(session_dir / "transcript.jsonl"):
        for k in ("t_wall", "run_start"):
            v = o.get(k)
            if isinstance(v, (int, float)) and not isinstance(v, bool) and v > 0:
                return datetime.fromtimestamp(v).date().isoformat()
    try:
        meta = json.loads((session_dir / "meta.json").read_text(encoding="utf-8"))
        c = meta.get("created_at") if isinstance(meta, dict) else None
        if isinstance(c, str) and len(c) >= 10:
            return c[:10]
    except (OSError, ValueError):
        pass
    try:
        return datetime.fromtimestamp(session_dir.stat().st_mtime).date().isoformat()
    except OSError:
        return datetime.now().date().isoformat()


def read_me_texts(core: Path | None, notes: Path | None) -> list[str]:
    out = []
    for p in (core, notes):
        if p is None:
            continue
        try:
            out.append(Path(p).expanduser().read_text(encoding="utf-8", errors="replace"))
        except OSError:
            continue
    return out


def session_lang(srows: SessionRows) -> str:
    langs = [r.lang for r in srows.owner_rows]
    return max(set(langs), key=langs.count) if langs else "en"


# ---------------------------------------------------------------- the plan of one session (no spend)
@dataclass
class Plan:
    name: str
    skey: str
    day: str
    rows: SessionRows
    fp: str
    request: Request | None
    max_tokens: int = 0
    max_cost_usd: float = 0.0
    unchanged: bool = False
    budget_error: str | None = None
    pairs: list = field(default_factory=list)          # review.py Pair: the question -> answer pairs reviewed in the request
    review_est: dict = field(default_factory=dict)     # review.py `estimate`: the review's share of the request
    offered: set = field(default_factory=set)          # the CONFIRMED SOURCES ids the request shows
    book: SourceBook | None = None                     # this session's confirmed sources (its focus and earlier answers set)

    def counts(self) -> dict:
        r = self.rows
        return {"owner_rows": r.count("me"), "own": r.count("me", "own"), "read": r.count("me", "read"),
                "mixed": r.count("me", "mixed"), "other_rows": r.count("other"), "room_rows": r.count("room")}


def plan_session(session_dir: Path, persona_lines: list[str], owner: str, sessions_state: dict, budget_usd: float | None,
                 force: bool = False, book: SourceBook | None = None, review: bool = True, reviews: dict | None = None) -> Plan:
    """The request of one session (no spend). `book` is the confirmed sources (copied here, never changed); `reviews` (the
    state's review records) adds his strong and fine answers in other calls as sources."""
    d = Path(session_dir).expanduser()
    srows = load_session_rows(d)
    key = session_key(d.name, set())
    fp = srows.fingerprint()
    prev = sessions_state.get(d.name) or {}
    same = prev.get("fp") == fp and (not review or prev.get("review") == REVIEW_VERSION)
    plan = Plan(d.name, key, session_date(d), srows, fp, None, unchanged=(same and not force))
    if not srows.owner_rows:
        return plan
    plan.request = build_request(key, srows, persona_lines, owner, rows_tokens=PERSONA_ROWS_TOKENS,
                                 persona_tokens=PERSONA_CONTEXT_TOKENS)
    if review:
        plan.pairs = build_pairs(srows, upto=len(srows.rows) - plan.request.rows_cut)
        focus = " ".join(f"{p.question_text} {p.answer_text}" for p in plan.pairs)
        book = SourceBook(dict(book.lines) if book else {}, focus=focus)
        book.add_earlier_answers(reviews or {}, d.name, focus)
        plan.book = book
        rsys, ruser = review_blocks(key, plan.pairs, book)
        plan.review_est = estimate(plan.pairs, rsys, ruser)
        if plan.pairs:
            plan.offered = book.offered()
            plan.request = build_request(key, srows, persona_lines, owner, rows_tokens=PERSONA_ROWS_TOKENS,
                                         persona_tokens=PERSONA_CONTEXT_TOKENS, review_system=rsys, review_user=ruser)
    try:
        params = persona_params(plan.request.est_input_tokens, budget_usd)
        plan.max_tokens = params["max_tokens"]
        pin, pout, _ = PRICES[params["model"]]
        plan.max_cost_usd = round((plan.request.est_input_tokens * pin + plan.max_tokens * pout) / 1e6, 4)
    except ValueError as e:
        plan.budget_error = str(e)
    return plan


# ---------------------------------------------------------------- one session
@dataclass
class UpdateResult:
    session: str
    skipped: str | None = None
    kept: int = 0
    dropped: dict = field(default_factory=dict)
    new: list[str] = field(default_factory=list)
    repeats: int = 0
    contradictions: list[str] = field(default_factory=list)
    cost_usd: float = 0.0
    usage: dict = field(default_factory=dict)
    changed: bool = False
    review: dict | None = None
    retracted: list[str] = field(default_factory=list)   # what an earlier run of this session wrote and this one did not


async def _ask(client, req: dict) -> tuple[str, dict, str, str | None]:
    chunks: list[str] = []
    usage: dict = {}
    model_used = req["model"]
    stop_reason = None
    agen = client.stream(req)
    try:
        async for ev in agen:
            if ev.kind == "start":
                usage = dict(ev.usage)
                model_used = ev.model or model_used
            elif ev.kind == "text":
                chunks.append(ev.text)
            elif ev.kind == "stop":
                stop_reason = ev.stop_reason
                usage = dict(ev.usage) or usage
    finally:
        try:
            await agen.aclose()          # type: ignore[attr-defined]
        except Exception:  # noqa: BLE001
            pass
    return "".join(chunks), usage, model_used, stop_reason


async def update_session(store: PersonaStore, session_dir: Path, client, *, owner: str, me_texts: list[str],
                         budget_usd: float | None = None, force: bool = False, on_ready=None) -> UpdateResult:
    """One session into the persona. Call inside `store.locked()` after `store.load()`. Raises PersonaRunError."""
    d = Path(session_dir).expanduser()
    if excluded(d.name):
        raise PersonaRunError("excluded", "this session is never learned from")
    if not (d / "transcript.jsonl").is_file():
        raise PersonaRunError("no_session", "the session folder has no transcript")
    sessions = store.state.setdefault("sessions", {})
    book = SourceBook.build(me_texts, store)
    plan = plan_session(d, store.persona_lines(), owner, sessions, budget_usd, force, book=book,
                        reviews=store.state.get("reviews"))
    book = plan.book or book
    res = UpdateResult(d.name)
    if plan.unchanged:
        res.skipped = "unchanged"
        return res
    if plan.request is None:
        res.skipped = "no_owner_rows"
        sessions[d.name] = {"fp": plan.fp, "at": now_iso(), "key": plan.skey, "date": plan.day, "kept": 0, "owner_rows": 0,
                            "review": REVIEW_VERSION}
        with commit():
            store.save(persona=False)
        return res
    if plan.budget_error:
        raise PersonaRunError("budget", plan.budget_error)
    req = persona_params(plan.request.est_input_tokens, budget_usd)
    req["system"] = [{"type": "text", "text": plan.request.system}]
    req["messages"] = [{"role": "user", "content": plan.request.user}]
    if on_ready is not None:
        on_ready({**plan.counts(), "est_input_tokens": plan.request.est_input_tokens, "max_tokens": req["max_tokens"]})
    try:
        text, usage, model_used, stop = await _ask(client, req)
    except TransportError as e:
        raise PersonaRunError(error_kind(e), str(e)[:200] or type(e).__name__, getattr(e, "retry_after", None)) from None
    u = usage_of(usage)
    res.usage = u.as_dict()
    res.cost_usd = round(spend_usd(model_used if model_used in PRICES else req["model"], u), 6)
    store.state["spend_usd"] = round(float(store.state.get("spend_usd", 0.0)) + res.cost_usd, 6)
    if stop == "refusal":
        store.save(persona=False)
        raise PersonaRunError("refusal", "the model declined this session")
    raw = parse_items(text)
    if raw is None:
        store.save(persona=False)
        log.warning("persona: unreadable model output (stop=%s, chars=%d)", stop, len(text))
        raise PersonaRunError("bad_output", "the model's answer could not be read; nothing was merged")
    confirmed = Confirmed(me_texts + store.confirmed_texts())
    ver = verify_items(raw, plan.skey, plan.rows, confirmed)
    rv = verify_reviews(parse_reviews(text), plan.pairs, book, plan.rows, confirmed, store.is_rejected, plan.offered)
    weak = rv.weak_stamps
    items = [it for it in ver.items if it.stamp not in weak]          # a weak answer is never learned as style or fact
    ver.dropped["weak"] = len(ver.items) - len(items)
    ver.items = items
    before = store.contribution(d.name)              # what an earlier run of this session wrote: replaced, never duplicated
    merged = store.merge(ver.items, d.name, plan.day, session_lang(plan.rows))
    res.kept, res.dropped = len(ver.items), ver.dropped
    res.new, res.repeats, res.contradictions = merged.new, merged.repeats, merged.contradictions
    made = apply_review(store, rv, session=d.name, skey=plan.skey, day=plan.day, book=book) if rv.pairs else {}
    better = [i for k in ("improved", "adopted", "kept") for i in made.get(k, [])]
    sigs = {(it.skey, it.stamp, one_line(it.quote).casefold()) for it in ver.items}
    retracted = store.retract(d.name, before, merged.touched | set(better), sigs) if before else []
    res.retracted = retracted
    res.changed = bool(merged.new or merged.repeats or merged.contradictions or better or made.get("demoted") or retracted)
    rel = note_rel(plan.day, plan.skey) if rv.pairs else None
    res.review = {**rv.counts(), "better": better, "demoted": made.get("demoted", []), "note": rel,
                  "dropped": {k: v for k, v in rv.dropped.items() if v}} if rv.pairs else None
    sessions[d.name] = {"fp": plan.fp, "at": now_iso(), "key": plan.skey, "date": plan.day, "kept": res.kept,
                        "owner_rows": plan.counts()["owner_rows"], "dropped": ver.dropped, "cost_usd": res.cost_usd,
                        "usage": res.usage, "rows_cut": plan.request.rows_cut, "review": REVIEW_VERSION,
                        "review_counts": rv.counts()}
    with commit():
        store.write_log(plan.day, plan.skey, d.name, ver.items, ver.dropped, now_iso())
        if rel is not None:
            note, lines = render_note(store, d.name, plan.skey, plan.day, open_list(store))
            store.write_note(rel, note, lines)
        store.save()
    log.info("persona update: rows=%d kept=%d new=%d repeats=%d contradictions=%d pairs=%d weak=%d better=%d cost=%.4f",
             plan.counts()["owner_rows"], res.kept, len(res.new), res.repeats, len(res.contradictions), len(rv.pairs),
             rv.counts()["weak"], len(better), res.cost_usd)
    return res


def open_contradictions(store: PersonaStore) -> int:
    return sum(1 for c in store.entries("contradiction") if c.get("state") == "open")


def _side(store: PersonaStore, eid: str) -> dict:
    """One side of a contradiction as the app shows it: the entry's text and its first verbatim quote with date and cite."""
    o = store.state["entries"].get(eid)
    if not o:
        return {"id": eid, "text": "", "quote": "", "date": "", "ref": ""}
    f = store.fields(o)
    evs = o.get("evidence") or []
    if evs:
        ev = evs[0]
        return {"id": eid, "text": one_line(f.get("text", "")), "quote": one_line(ev.get("quote", "")),
                "date": str(ev.get("date", "")), "ref": f"{ev.get('skey', '')} {ev.get('stamp', '')}".strip()}
    seed = one_line(" ".join(x for x in (f.get("text", ""), f.get("value", "")) if x))
    return {"id": eid, "text": seed, "quote": seed, "date": str(o.get("date", "")), "ref": str(o.get("origin", ""))}


def open_list(store: PersonaStore) -> list[dict]:
    """The open contradictions with both sides (the app's Me page lists them; nothing here is logged)."""
    return [{"id": c["id"], "topic": one_line(store.fields(c).get("topic") or c.get("topic", "")),
             "a": _side(store, c["a"]), "b": _side(store, c["b"])}
            for c in store.entries("contradiction") if c.get("state") == "open"]


def general_ready(folder: Path | None) -> bool:
    """The general prep folder has a non-empty pack (what Swift's GeneralPrep.isAvailable checks)."""
    try:
        return folder is not None and (folder / "pack.md").stat().st_size > 0
    except OSError:
        return False


# ---------------------------------------------------------------- the process mode
def fake_persona_responder(request: dict, n: int):
    """`--fake`: an answer with no items (no network, no key)."""
    from ..runtime.ask import words_script

    return words_script('{"items": []}', model=request.get("model"))


class PersonaRuntime:
    """One `persona_start`, one action, then `stopped`."""

    def __init__(self, client, emitter: Emitter) -> None:
        self.client = client
        self.emitter = emitter
        self.stopped = asyncio.Event()

    async def handle(self, msg: dict) -> None:
        if msg.get("type") != "persona_start":
            return
        try:
            await self._run(msg)
        finally:
            self.stopped.set()

    async def shutdown(self) -> None:
        await self.client.aclose()

    def _error(self, kind: str, message: str, retry_after: float | None = None, session: str | None = None) -> None:
        assert kind in PERSONA_ERROR_KINDS, kind
        ev = {"type": "persona_error", "kind": kind, "message": message}
        if retry_after is not None:
            ev["retry_after"] = retry_after
        if session:
            ev["session"] = session
        self.emitter.emit(ev)

    async def _run(self, msg: dict) -> None:
        from ..owner import OWNER

        t0 = time.monotonic()
        action = msg.get("action") or "update"
        if action not in PERSONA_ACTIONS:
            self._error("bad_request", f"unknown action {action!r}")
            return
        sd = msg.get("session_dir")
        session_dir = Path(sd).expanduser() if isinstance(sd, str) and sd else None
        if action == "update" and session_dir is None:
            self._error("bad_request", "persona_start update needs session_dir")
            return
        root = msg.get("sessions_root")
        sessions_root = Path(root).expanduser() if isinstance(root, str) and root else (session_dir.parent if session_dir else None)
        pd = msg.get("persona_dir")
        persona_dir = Path(pd).expanduser() if isinstance(pd, str) and pd else OWNER.persona_dir
        st = msg.get("state")
        state = Path(st).expanduser() if isinstance(st, str) and st else default_state()
        me = msg.get("me") if isinstance(msg.get("me"), dict) else {}
        me_texts = read_me_texts(*(Path(me[k]) if isinstance(me.get(k), str) and me.get(k) else None for k in ("core", "notes")))
        owner = " ".join(str(msg.get("owner_name") or OWNER.display_name).split()) or OWNER.display_name
        budget = msg.get("budget_usd") if isinstance(msg.get("budget_usd"), (int, float)) and not isinstance(msg.get("budget_usd"), bool) else None
        do_compile = msg.get("compile", True) is not False
        co = msg.get("compile_out")
        compile_out = Path(co).expanduser() if isinstance(co, str) and co else (sessions_root / COMPILED_NAME if sessions_root else None)
        gc = msg.get("general_core")
        general = Path(gc).expanduser() if isinstance(gc, str) and gc else (sessions_root / GENERAL_NAME if sessions_root else None)
        name = session_dir.name if session_dir else None
        seed_first = msg.get("seed_from_general") is True and action in ("update", "compile", "resolve")
        self.emitter.status("warming", "reading the persona")
        done = {"type": "persona_done", "action": action, "session": name, "skipped": None, "kept": 0, "dropped": {}, "new": [],
                "repeats": 0, "contradictions": [], "cost_usd": 0.0, "usage": {}, "compiled": None, "compile_error": None,
                "imported": None, "review": None}
        try:
            store = PersonaStore(persona_dir, state)
            with store.locked():
                store.load()
                changed = False
                if seed_first and not store.state.get("seed") and general_ready(general):
                    with commit():
                        done["imported"] = import_general_core(store, general)
                    changed = True
                if action == "resolve":
                    cid, keep = msg.get("id"), msg.get("keep")
                    if not isinstance(cid, str) or not isinstance(keep, str) or not cid or not keep:
                        raise PersonaRunError("bad_request", "resolve needs id and keep")
                    store.resolve(cid, keep)
                    with commit():
                        store.save()
                    changed = True
                elif action == "update":
                    res = await update_session(store, session_dir, self.client, owner=owner, me_texts=me_texts, budget_usd=budget,
                                               force=bool(msg.get("force")),
                                               on_ready=lambda ctx: self.emitter.status("ready", "", context=ctx))
                    done.update(skipped=res.skipped, kept=res.kept, dropped=res.dropped, new=res.new, repeats=res.repeats,
                                contradictions=res.contradictions, cost_usd=res.cost_usd, usage=res.usage, review=res.review)
                    changed = changed or res.changed
                elif action == "import_general":
                    if general is None:
                        raise PersonaRunError("bad_request", "import_general needs sessions_root or general_core")
                    if store.state.get("seed"):
                        raise PersonaRunError("already_imported", "the general prep was already imported")
                    done["imported"] = import_general_core(store, general)
                    changed = True
                if do_compile and compile_out is not None and action != "status" and (changed or action == "compile"):
                    try:
                        with commit():
                            done["compiled"] = await compile_async(store, compile_out)
                    except PersonaError as e:
                        if action == "compile":
                            raise PersonaRunError("empty" if "empty" in str(e) else getattr(e, "kind", "error"), str(e)) from None
                        done["compile_error"] = str(e)
                done["open_contradictions"] = open_contradictions(store)
                done["open"] = open_list(store)
        except PersonaRunError as e:
            kind = e.kind if e.kind in PERSONA_ERROR_KINDS else "error"
            self._error(kind, str(e), e.retry_after, name)
            return
        except PersonaError as e:
            kind = getattr(e, "kind", "error")
            self._error(kind if kind in PERSONA_ERROR_KINDS else "error", str(e), session=name)
            return
        except OSError as e:
            log.warning("persona: file error %s", type(e).__name__)
            self._error("error", f"file error ({type(e).__name__})", session=name)
            return
        done["ms_total"] = round((time.monotonic() - t0) * 1000)
        self.emitter.emit(done)
