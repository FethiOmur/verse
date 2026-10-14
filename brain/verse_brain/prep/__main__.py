"""CLI: python -m verse_brain.prep --prep-note PATH --repo PATH [--repo PATH...] --lang en[,it,tr] --out DIR

--live runs the bundled sample prep note with the real model (budget < $0.50) and prints a summary.
--from-event EVENT.json builds the prep note from a calendar event (F5); add --fake for an offline run (no network, no key).
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

from .event import EventError, FakeEventModel, event_to_prep_note, load_event
from .keychain import KeychainError, read_api_key, redact
from .model import PrepError
from .pipeline import build
from .vault import DEFAULT_VAULT, BeyinVault

SAMPLE = Path(__file__).resolve().parents[2] / "tests" / "fixtures" / "prep" / "prep_note.md"
DEFAULT_OUT = Path("~/Library/Application Support/Verse/sessions")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m verse_brain.prep", description=__doc__)
    ap.add_argument("--prep-note", type=Path)
    ap.add_argument("--repo", type=Path, action="append", default=[])
    ap.add_argument("--lang", default="en", help="comma-separated: en,it,tr (first = language of canonical questions)")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT, help="sessions root; a <session-id> folder is created in it")
    ap.add_argument("--max-questions", type=int, default=80)
    ap.add_argument("--vault", type=Path, default=DEFAULT_VAULT)
    ap.add_argument("--no-vault", action="store_true", help="skip beyin.py retrieval")
    ap.add_argument("--vault-audience", choices=["internal", "public"], default="internal")
    ap.add_argument("--budget-usd", type=float, default=1.0, help="hard cap used to size max_tokens")
    ap.add_argument("--from-event", type=Path, metavar="EVENT.json",
                    help="build the prep note from a calendar event JSON (id, title, start, end, attendees, notes, url, provider)")
    ap.add_argument("--fake", action="store_true",
                    help="with --from-event: deterministic offline model, no network, no key, no spend")
    ap.add_argument("--live", action="store_true",
                    help="smoke run: sample prep note (unless --prep-note), real model, budget 0.45 USD, 24 questions")
    a = ap.parse_args(argv)

    if a.live:
        a.prep_note = a.prep_note or SAMPLE
        a.budget_usd = min(a.budget_usd, 0.45)
        a.max_questions = min(a.max_questions, 24)
    if a.from_event is not None and a.prep_note is not None:
        ap.error("--from-event and --prep-note are mutually exclusive")
    if a.fake and a.from_event is None:
        ap.error("--fake needs --from-event")
    if a.prep_note is None and a.from_event is None:
        ap.error("--prep-note is required (or use --from-event or --live)")
    langs = [c for c in a.lang.split(",") if c]
    vault = None if (a.no_vault or a.fake) else BeyinVault(a.vault, audience=a.vault_audience)
    key = None
    note_dir: tempfile.TemporaryDirectory | None = None
    try:
        if a.from_event is not None:
            note_dir = tempfile.TemporaryDirectory(prefix="verse-event-")
            a.prep_note = Path(note_dir.name) / "event-prep-note.md"
            a.prep_note.write_text(event_to_prep_note(load_event(a.from_event)), encoding="utf-8")
        if a.fake:
            session = build(a.prep_note, a.repo, langs, a.out, a.max_questions, model=FakeEventModel(), vault=None,
                            budget_usd=a.budget_usd)
        else:
            key = read_api_key()  # only to scrub error text; the model client reads its own copy
            session = build(a.prep_note, a.repo, langs, a.out, a.max_questions, vault=vault, budget_usd=a.budget_usd)
    except (KeychainError, PrepError, EventError, OSError) as e:
        print(f"error: {redact(str(e), key)}", file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001
        print(f"error: {type(e).__name__}: {redact(str(e), key)[:300]}", file=sys.stderr)
        return 1
    finally:
        if note_dir is not None:
            note_dir.cleanup()
    meta = json.loads((session / "meta.json").read_text(encoding="utf-8"))
    st = meta["stats"]
    print(f"session: {session}")
    print(f"bank entries: {st['bank_entries']} | facts {st['facts']} | glossary {st['glossary_terms']} | snippets {st['snippets']}")
    if st.get("conflicts"):
        print(f"CONFLICTS: {st['conflicts']} figure(s) differ between sources; {st.get('conflict_bank_entries', 0)} bank "
              f"entries use them (see review.md, top section)")
    print(f"dropped unsourced points: {meta['dropped_unsourced_points']} "
          f"(unsupported quote {st.get('points_dropped_unsupported_quote', 0)}, "
          f"unsupported number {st.get('points_dropped_unsupported_number', 0)})")
    print(f"pack tokens: {st['pack_tokens']} / cap {st['pack_cap']} (trimmed {st['pack_trimmed']})")
    u = meta["prep_usage"]
    print(f"usage: in {u['input']} out {u['output']} cache_read {u['cache_read']} cache_write {u['cache_write']}")
    print(f"spend: ${meta['prep_spend_usd']:.4f}")
    for w in meta["warnings"]:
        print(f"warning: {w}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
