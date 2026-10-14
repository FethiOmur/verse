"""CLI: python -m verse_brain.prep --prep-note PATH --repo PATH [--repo PATH...] --lang en[,it,tr] --out DIR

--live runs the bundled sample prep note with the real model (budget < $0.50) and prints a summary.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

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
    ap.add_argument("--live", action="store_true",
                    help="smoke run: sample prep note (unless --prep-note), real model, budget 0.45 USD, 24 questions")
    a = ap.parse_args(argv)

    if a.live:
        a.prep_note = a.prep_note or SAMPLE
        a.budget_usd = min(a.budget_usd, 0.45)
        a.max_questions = min(a.max_questions, 24)
    if a.prep_note is None:
        ap.error("--prep-note is required (or use --live)")
    langs = [c for c in a.lang.split(",") if c]
    vault = None if a.no_vault else BeyinVault(a.vault, audience=a.vault_audience)
    key = None
    try:
        key = read_api_key()  # only to scrub error text; the model client reads its own copy
        session = build(a.prep_note, a.repo, langs, a.out, a.max_questions, vault=vault, budget_usd=a.budget_usd)
    except (KeychainError, PrepError, OSError) as e:
        print(f"error: {redact(str(e), key)}", file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001
        print(f"error: {type(e).__name__}: {redact(str(e), key)[:300]}", file=sys.stderr)
        return 1
    meta = json.loads((session / "meta.json").read_text(encoding="utf-8"))
    st = meta["stats"]
    print(f"session: {session}")
    print(f"bank entries: {st['bank_entries']} | facts {st['facts']} | glossary {st['glossary_terms']} | snippets {st['snippets']}")
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
