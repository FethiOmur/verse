#!/bin/bash
# Merges the strings the app's sources use into the String Catalog (spec 2.5 "Extraction").
#
#   app/scripts/l10n-sync.sh
#
# 1. `swift build` (debug) writes a .stringsdata file per Swift file with every key used through Text(_:bundle:), a
#    LocalizedStringKey parameter, String(localized:) or a helper that takes String.LocalizationValue (L10n.tr).
# 2. Every .stringsdata under .build whose path belongs to VerseUI or VerseApp (not their test targets) is collected.
# 3. `xcrun xcstringstool sync` adds new keys to app/Sources/VerseUI/Resources/Localizable.xcstrings and marks keys that no
#    source uses any more as stale.
#
# Environment overrides (the tests use them to run against a temp copy without a full build):
#   L10N_CATALOG     the catalog to update       (default: app/Sources/VerseUI/Resources/Localizable.xcstrings)
#   L10N_BUILD_DIR   where to look for .stringsdata (default: app/.build)
#   L10N_SKIP_BUILD  1 = do not run swift build
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="${L10N_CATALOG:-$APP_DIR/Sources/VerseUI/Resources/Localizable.xcstrings}"
BUILD_DIR="${L10N_BUILD_DIR:-$APP_DIR/.build}"

if [ ! -f "$CATALOG" ]; then
  echo "l10n-sync: catalog not found: $CATALOG" >&2
  exit 1
fi

# xcstringstool matches strings to the catalog by its file name (the table), so a copy must keep the name.
if [ "$(basename "$CATALOG")" != "Localizable.xcstrings" ]; then
  echo "l10n-sync: the catalog must be named Localizable.xcstrings (table Localizable): $CATALOG" >&2
  exit 1
fi

if [ "${L10N_SKIP_BUILD:-0}" != "1" ]; then
  (cd "$APP_DIR" && swift build >/dev/null)
fi

# The module's own target folders (VerseUI-t.build, ...) and the app's executable (the `Verse` product builds VerseApp in
# Verse-p.build); VerseUITests-t.build does not match.
FILES=()
while IFS= read -r f; do
  FILES+=("$f")
done < <(find "$BUILD_DIR" -name '*.stringsdata' 2>/dev/null | grep -E '/(VerseUI|VerseApp)-[^/]*\.build/|/Verse-p\.build/' | sort)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "l10n-sync: no .stringsdata found under $BUILD_DIR (did swift build run?)" >&2
  exit 1
fi

ARGS=()
for f in "${FILES[@]}"; do ARGS+=(--stringsdata "$f"); done

xcrun xcstringstool sync "$CATALOG" "${ARGS[@]}"
echo "l10n-sync: ${#FILES[@]} stringsdata files merged into ${CATALOG#$APP_DIR/}"
