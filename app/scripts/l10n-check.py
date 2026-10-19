#!/usr/bin/env python3
"""Checks the String Catalog (spec 2.5 "Check").

    python3 app/scripts/l10n-check.py [--allow-missing] [--catalog PATH]

Reports
  * keys without an `it` or `tr` translation,
  * stale keys (no source uses them any more; reported, never a failure),
  * placeholder mismatches: the count and kind of %lld, %@, %.2f ... must match the English string.

Exit code 1 when a non-stale key lacks `it` or `tr` (unless --allow-missing) or a placeholder does not match.
"""
import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

DEFAULT_CATALOG = Path(__file__).resolve().parent.parent / "Sources" / "VerseUI" / "Resources" / "Localizable.xcstrings"
LANGS = ("it", "tr")
# %lld %@ %.2f %1$@ %% ... (flags, width, precision, length modifiers, conversion)
PLACEHOLDER = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaA]")
PARTIAL_PLURAL = {"zero", "one", "two", "few", "many"}


def signature(text: str) -> Counter:
    """Kinds of the placeholders in `text`, positions ignored. '%%' is a literal percent sign."""
    text = text.replace("%%", "")
    kinds = Counter()
    for m in PLACEHOLDER.finditer(text):
        kinds[re.sub(r"%\d+\$", "%", m.group(0))] += 1
    return kinds


def leaves(loc: dict, path=()):
    """(path, string) for every string unit under a localization: plain, plural/device variations, substitutions."""
    if "stringUnit" in loc:
        yield path, loc["stringUnit"]
    for kind, table in (loc.get("variations") or {}).items():
        for name, sub in table.items():
            yield from leaves(sub, path + (f"{kind}.{name}",))
    for name, sub in (loc.get("substitutions") or {}).items():
        yield from leaves(sub, path + (f"sub.{name}",))


def has_translation(loc) -> bool:
    if not loc:
        return False
    found = list(leaves(loc))
    return bool(found) and all(u.get("value", "") != "" and u.get("state", "translated") != "new" for _, u in found)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--allow-missing", action="store_true", help="do not fail on keys without it/tr")
    ap.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    args = ap.parse_args()

    data = json.loads(args.catalog.read_text(encoding="utf-8"))
    source_lang = data.get("sourceLanguage", "en")
    strings = data.get("strings", {})

    missing: dict[str, list[str]] = {}
    stale: list[str] = []
    mismatches: list[str] = []
    review: list[str] = []
    checked = 0

    for key, entry in sorted(strings.items()):
        if key == "" or entry.get("shouldTranslate") is False:
            continue
        if entry.get("extractionState") == "stale":
            stale.append(key)
            continue
        checked += 1
        locs = entry.get("localizations") or {}
        # The English string is the key itself unless the catalog carries an explicit `en` value.
        en_loc = locs.get(source_lang)
        en_text = key
        if en_loc:
            en_leaves = [u.get("value", "") for p, u in leaves(en_loc) if not p or p[-1].endswith("other")]
            if en_leaves and en_leaves[0]:
                en_text = en_leaves[0]
        want = signature(en_text)

        for lang in LANGS:
            loc = locs.get(lang)
            if not has_translation(loc):
                missing.setdefault(key, []).append(lang)
                continue
            for path, unit in leaves(loc):
                if unit.get("state") == "needs_review":
                    review.append(f"{lang}: {key!r}")
                got = signature(unit.get("value", ""))
                partial = bool(path) and path[-1].split(".")[-1] in PARTIAL_PLURAL
                ok = (not (got - want)) if partial else (got == want)
                if not ok:
                    where = f" [{'/'.join(path)}]" if path else ""
                    mismatches.append(f"{lang}: {key!r}{where}: English has {dict(want)}, translation has {dict(got)}")

    print(f"l10n-check: {checked} keys checked, {len(stale)} stale, {len(missing)} missing a translation, "
          f"{len(mismatches)} placeholder mismatches")
    for key, langs in missing.items():
        print(f"  missing {'/'.join(langs)}: {key!r}")
    for line in mismatches:
        print(f"  placeholder mismatch: {line}")
    for line in sorted(set(review)):
        print(f"  needs review: {line}")
    if stale:
        print(f"  stale (no source uses them): {len(stale)}")
        for key in stale[:20]:
            print(f"    {key!r}")
        if len(stale) > 20:
            print(f"    ... and {len(stale) - 20} more")

    failed = bool(mismatches) or (bool(missing) and not args.allow_missing)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
