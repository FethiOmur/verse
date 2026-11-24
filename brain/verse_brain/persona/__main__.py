"""CLI: python -m verse_brain.persona [--persona-dir DIR] [--state FILE] [--profile-dir DIR] COMMAND ...

Commands (all headless; the app is never needed):

  update SESSION_DIR [--force] [--budget-usd N] [--no-compile] [--compile-out DIR] [--no-seed] [--fake]
        one finished session into the persona (one model request that also reviews its answers, unless its fingerprint is
        unchanged), then compile
  backfill --sessions-root DIR --include NAME [NAME ...] [--exclude-prefix P ...] [--dry-run] [--force] [--budget-usd N]
           [--no-compile] [--compile-out DIR] [--no-seed] [--fake]
        the named session folders, oldest call first; `sim-*`, general-core and persona-core are always left out. Each
        session's request also carries the after-call review (review.py): weak answers get a better answer from confirmed
        sources, strong ones become the bank's wording, and a Review note is written per session.
        --dry-run prints each session, its owner-row counts (own / read / mixed), other and room rows, the projected input
        tokens, the output cap and the worst-case cost, the review's share (question pairs, marked pairs, extra input tokens,
        projected output tokens and their cost), and the totals. It builds no client, spends nothing and writes nothing.
  update and backfill first import the general prep (<sessions root>/general-core) once when the persona has no seed yet,
  as the app does, so one command does the whole job; --no-seed leaves it out (the dry run says whether it would happen).
  import-general [--from DIR | --sessions-root DIR]
        the one-time import of the general prep folder (default <sessions root>/general-core) as seed entries; read only
  compile [--out DIR | --sessions-root DIR]
        the files an unprepared call loads, into DIR (default <sessions root>/persona-core)
  show
        counts of the persona: entries by kind and status, open contradictions, sessions learned, spend
  resolve CID KEEP
        settle an open contradiction: KEEP is 1, 2 or one of its two entry ids

`persona_dir` comes from the owner profile unless --persona-dir is given; without either every command but a dry run refuses.
--fake answers every request with an empty item list (no network, no Keychain).
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path

from .runtime import SESSIONS_DIR, PROFILE_DIR, default_state, excluded, plan_session, read_me_texts


def _store(args):
    from ..owner import OWNER
    from .store import PersonaStore

    return PersonaStore(Path(args.persona_dir).expanduser() if args.persona_dir else OWNER.persona_dir, args.state)


def _client(args):
    from ..runtime.ask import FakeAskClient, make_client
    from .runtime import fake_persona_responder

    return FakeAskClient(fake_persona_responder) if args.fake else make_client()


def _me(args) -> list[str]:
    d = Path(args.profile_dir).expanduser()
    return read_me_texts(d / "me.md", d / "me.notes.md")


def _owner() -> str:
    from ..owner import OWNER

    return OWNER.display_name


def _book(args, store):
    from .review import SourceBook

    return SourceBook.build(_me(args), store)


def _seed(args, store, root: Path) -> dict | None:
    """The one-time import of the general prep before the first update, as the app does (`seed_from_general`)."""
    from .compile import GENERAL_NAME, import_general_core
    from .runtime import commit, general_ready

    if getattr(args, "no_seed", False) or store.state.get("seed") or not general_ready(root / GENERAL_NAME):
        return None
    with commit():
        counts = import_general_core(store, root / GENERAL_NAME)
    print(f"imported the general prep first: {counts}")
    return counts


def _compile_out(args, root: Path | None) -> Path:
    if getattr(args, "compile_out", None):
        return Path(args.compile_out).expanduser()
    return (root or SESSIONS_DIR.expanduser()) / "persona-core"


def _print_result(r) -> None:
    dropped = ", ".join(f"{k} {v}" for k, v in r.dropped.items() if v) or "none"
    if r.skipped:
        print(f"{r.session}: skipped ({r.skipped})")
    else:
        rv = r.review or {}
        review = (f", review: pairs {rv.get('pairs', 0)} weak {rv.get('weak', 0)} strong {rv.get('strong', 0)} "
                  f"improved {rv.get('improved', 0)} adopted {rv.get('adopted', 0)} kept {rv.get('kept', 0)} "
                  f"no_better {rv.get('no_better', 0)} marks {rv.get('marks', 0)}") if rv else ", review: no question pairs"
        review += (f" fine {rv.get('fine', 0)}" if rv else "") + (f", replaced {len(r.retracted)} from the earlier run"
                                                                 if r.retracted else "")
        print(f"{r.session}: kept {r.kept} (dropped: {dropped}), new {len(r.new)}, repeats {r.repeats}, "
              f"contradictions {len(r.contradictions)}, ${r.cost_usd:.4f}{review}")


def select_sessions(root: Path, include: list[str], exclude_prefixes: list[str]) -> tuple[list[Path], list[str]]:
    """(session folders to run, oldest call first; notes on names left out). Only names given in `include` are considered."""
    from .runtime import session_date

    picked, notes = [], []
    for name in dict.fromkeys(include):
        d = root / name
        if excluded(name, tuple(exclude_prefixes)):
            notes.append(f"{name}: excluded")
        elif not (d / "transcript.jsonl").is_file():
            notes.append(f"{name}: no transcript.jsonl")
        else:
            picked.append(d)
    picked.sort(key=lambda d: (session_date(d), d.name))
    return picked, notes


async def _update(args) -> int:
    from .compile import compile_async
    from .runtime import update_session

    store = _store(args)
    client = _client(args)
    try:
        with store.locked():
            store.load()
            seeded = _seed(args, store, Path(args.session_dir).expanduser().parent)
            r = await update_session(store, Path(args.session_dir), client, owner=_owner(), me_texts=_me(args),
                                     budget_usd=args.budget_usd, force=args.force)
            _print_result(r)
            if (r.changed or seeded) and not args.no_compile:
                out = await compile_async(store, _compile_out(args, Path(args.session_dir).expanduser().parent))
                print(f"compiled: {out}")
    finally:
        await client.aclose()
    return 0


def _dry_run(args, sessions: list[Path]) -> int:
    from .store import PersonaError

    from .compile import GENERAL_NAME
    from .runtime import general_ready

    lines, state_sessions, store, seeded = [], {}, None, False
    try:
        store = _store(args)
        store.load()
        lines, state_sessions, seeded = store.persona_lines(), store.state.get("sessions", {}), bool(store.state.get("seed"))
    except PersonaError as e:
        store = None
        print(f"(persona not readable: {e}; projecting with an empty persona)")
    root = Path(args.sessions_root).expanduser()
    if not seeded and not args.no_seed and general_ready(root / GENERAL_NAME):
        print(f"seed: the general prep ({GENERAL_NAME}) would be imported first (no model call)")
    book = _book(args, store)
    tot_rows = tot_in = tot_out = tot_pairs = r_in = r_out = 0
    tot_cost = r_cost = 0.0
    for d in sessions:
        p = plan_session(d, lines, _owner(), state_sessions, args.budget_usd, args.force, book=book,
                         reviews=store.state.get("reviews") if store is not None else None)
        c = p.counts()
        note = " [unchanged: would be skipped]" if p.unchanged else ""
        if p.request is None:
            print(f"{p.name}: owner_rows=0 (nothing to send){note}")
            continue
        if p.budget_error:
            note += f" [budget: {p.budget_error}]"
        rv = p.review_est or {"pairs": 0, "marked": 0, "extra_input_tokens": 0, "est_output_tokens": 0, "extra_cost_usd": 0.0}
        print(f"{p.name}: date={p.day} owner_rows={c['owner_rows']} (own {c['own']}, read {c['read']}, mixed {c['mixed']}) "
              f"other_rows={c['other_rows']} room_rows={c['room_rows']} est_input_tokens={p.request.est_input_tokens} "
              f"max_output_tokens={p.max_tokens} max_cost_usd={p.max_cost_usd:.4f} rows_cut={p.request.rows_cut}{note}")
        print(f"  review: pairs={rv['pairs']} marked={rv['marked']} extra_input_tokens={rv['extra_input_tokens']} "
              f"est_output_tokens={rv['est_output_tokens']} extra_cost_usd={rv['extra_cost_usd']:.4f}")
        if not p.unchanged:
            tot_rows += c["owner_rows"]
            tot_in += p.request.est_input_tokens
            tot_out += p.max_tokens
            tot_cost += p.max_cost_usd
            tot_pairs += rv["pairs"]
            r_in += rv["extra_input_tokens"]
            r_out += rv["est_output_tokens"]
            r_cost += rv["extra_cost_usd"]
    print(f"TOTAL sessions={len(sessions)} owner_rows={tot_rows} est_input_tokens={tot_in} max_output_tokens={tot_out} "
          f"max_cost_usd={tot_cost:.4f} (dry run: nothing sent, nothing written)")
    print(f"TOTAL review: pairs={tot_pairs} extra_input_tokens={r_in} est_output_tokens={r_out} extra_cost_usd={r_cost:.4f} "
          f"(included in est_input_tokens and inside max_output_tokens above; the review rides in the same request)")
    return 0


async def _backfill(args) -> int:
    from .compile import compile_async
    from .runtime import PersonaRunError, update_session

    root = Path(args.sessions_root).expanduser()
    sessions, notes = select_sessions(root, args.include, args.exclude_prefix)
    for n in notes:
        print(n)
    if args.dry_run:
        return _dry_run(args, sessions)
    store = _store(args)
    client = _client(args)
    failures = 0
    try:
        with store.locked():
            store.load()
            changed = bool(_seed(args, store, root))
            for d in sessions:
                try:
                    r = await update_session(store, d, client, owner=_owner(), me_texts=_me(args), budget_usd=args.budget_usd,
                                             force=args.force)
                except PersonaRunError as e:
                    failures += 1
                    print(f"{d.name}: error {e.kind}: {e}")
                    if e.kind in ("auth", "credit_exhausted", "offline"):
                        break
                    continue
                _print_result(r)
                changed = changed or r.changed
            if changed and not args.no_compile:
                print(f"compiled: {await compile_async(store, _compile_out(args, root))}")
    finally:
        await client.aclose()
    return 1 if failures else 0


def _import(args) -> int:
    from .compile import import_general_core

    src = Path(args.from_dir).expanduser() if args.from_dir else Path(args.sessions_root or SESSIONS_DIR).expanduser() / "general-core"
    store = _store(args)
    with store.locked():
        store.load()
        print(f"imported: {import_general_core(store, src)}")
    return 0


async def _compile(args) -> int:
    from .compile import compile_async

    out = Path(args.out).expanduser() if args.out else Path(args.sessions_root or SESSIONS_DIR).expanduser() / "persona-core"
    store = _store(args)
    with store.locked():
        store.load()
        print(f"compiled: {await compile_async(store, out)}")
    return 0


def _show(args) -> int:
    store = _store(args)
    store.load()
    by: dict[str, int] = {}
    for e in store.state["entries"].values():
        k = f"{e['kind']}/{e.get('state') or e.get('status', 'live')}"
        by[k] = by.get(k, 0) + 1
    for k in sorted(by):
        print(f"{k}: {by[k]}")
    print(f"sessions learned: {len(store.state.get('sessions', {}))}; deleted ids: {len(store.state.get('deleted', []))}; "
          f"seed: {'yes' if store.state.get('seed') else 'no'}; spend_usd: {store.state.get('spend_usd', 0.0):.4f}")
    return 0


def _resolve(args) -> int:
    store = _store(args)
    with store.locked():
        store.load()
        store.resolve(args.cid, args.keep)
        store.save()
    print(f"{args.cid}: resolved")
    return 0


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="python -m verse_brain.persona", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--persona-dir", default=None, help="override owner.json persona_dir")
    ap.add_argument("--state", default=str(default_state()), help="the persona state file (outside the vault)")
    ap.add_argument("--profile-dir", default=str(PROFILE_DIR), help="where me.md / me.notes.md live (confirmed sources)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    u = sub.add_parser("update")
    u.add_argument("session_dir")
    b = sub.add_parser("backfill")
    b.add_argument("--sessions-root", required=True)
    b.add_argument("--include", nargs="+", required=True, help="session folder names (explicit list)")
    b.add_argument("--exclude-prefix", action="append", default=[], help="leave out names starting with this (repeatable)")
    b.add_argument("--dry-run", action="store_true")
    for p in (u, b):
        p.add_argument("--force", action="store_true", help="run even when the session's fingerprint is unchanged")
        p.add_argument("--budget-usd", type=float, default=None, help="spend cap per session request (default 0.40)")
        p.add_argument("--no-compile", action="store_true")
        p.add_argument("--compile-out", default=None)
        p.add_argument("--fake", action="store_true", help="empty answers: no network, no Keychain")
        p.add_argument("--no-seed", action="store_true", help="do not import the general prep first when the persona has no seed")
    i = sub.add_parser("import-general")
    i.add_argument("--from", dest="from_dir", default=None)
    i.add_argument("--sessions-root", default=None)
    c = sub.add_parser("compile")
    c.add_argument("--out", default=None)
    c.add_argument("--sessions-root", default=None)
    sub.add_parser("show")
    r = sub.add_parser("resolve")
    r.add_argument("cid")
    r.add_argument("keep")
    return ap


def main(argv: list[str] | None = None) -> int:
    import logging

    from ..prep.keychain import KeychainError
    from .runtime import PersonaRunError
    from .store import PersonaError

    args = build_parser().parse_args(argv)
    logging.basicConfig(stream=sys.stderr, level="WARNING", format="%(asctime)s %(name)s %(levelname)s %(message)s")
    try:
        if args.cmd == "update":
            return asyncio.run(_update(args))
        if args.cmd == "backfill":
            return asyncio.run(_backfill(args))
        if args.cmd == "import-general":
            return _import(args)
        if args.cmd == "compile":
            return asyncio.run(_compile(args))
        if args.cmd == "show":
            return _show(args)
        return _resolve(args)
    except KeychainError as e:
        print(f"error (auth): {e}", file=sys.stderr)
        return 2
    except (PersonaRunError, PersonaError) as e:
        print(f"error ({getattr(e, 'kind', 'error')}): {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
