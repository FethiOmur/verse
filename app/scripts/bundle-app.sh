#!/bin/bash
# Builds the Verse menu-bar app in release mode and assembles app/build/Verse.app (ad-hoc signed).
#
#   app/scripts/bundle-app.sh            # build + bundle
#   VERSE_BRAIN_DIR=/path/to/brain app/scripts/bundle-app.sh   # record a different brain folder
#
# The brain is found at run time via VERSE_BRAIN_DIR, else the repo's brain/ folder recorded here in Info.plist
# (key VerseBrainDir). Nothing secret goes into the bundle: the API key stays in the Keychain.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$APP_DIR/.." && pwd)"
BRAIN_DIR="${VERSE_BRAIN_DIR:-$REPO_DIR/brain}"
OUT="$APP_DIR/build/Verse.app"

if [ ! -d "$BRAIN_DIR/verse_brain" ]; then
  echo "bundle-app: brain folder not found: $BRAIN_DIR" >&2
  exit 1
fi

cd "$APP_DIR"
swift build -c release --product Verse
BIN="$(swift build -c release --show-bin-path)/Verse"

# Replace only our own bundle (the path is fixed under app/build).
case "$OUT" in
  */app/build/Verse.app) rm -rf "$OUT" ;;
  *) echo "bundle-app: unexpected output path $OUT" >&2; exit 1 ;;
esac
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/Verse"
cp "$APP_DIR/Sources/VerseApp/Info.plist" "$OUT/Contents/Info.plist"
cp "$APP_DIR/Resources/AppIcon/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$OUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :VerseBrainDir string $BRAIN_DIR" "$OUT/Contents/Info.plist"
printf 'APPL????' > "$OUT/Contents/PkgInfo"

# Resource bundles SwiftPM produced for dependencies (if any) go next to the executable's resources.
for b in "$(dirname "$BIN")"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$OUT/Contents/Resources/"
done

codesign --force --sign - --timestamp=none "$OUT"
codesign --verify --strict "$OUT"
plutil -lint "$OUT/Contents/Info.plist" >/dev/null
echo "bundle-app: $OUT"
echo "bundle-app: bundle id $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OUT/Contents/Info.plist"), LSUIElement $(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$OUT/Contents/Info.plist"), brain $BRAIN_DIR"
