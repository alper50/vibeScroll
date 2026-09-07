#!/usr/bin/env bash
# Assembles vibeScroll.app from a release build so it runs as a proper menu bar
# app — bundle identifier, LSUIElement, and working notifications all require a
# real bundle, which `swift build` alone does not produce.
#
# Ad-hoc signed for local use. Distribution needs a Developer ID and
# notarization; that is deliberately not automated here yet.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/vibeScroll.app"

# Universal so the same bundle runs on Apple Silicon and Intel.
ARCHS=(--arch arm64 --arch x86_64)

echo "Building ($CONFIG, universal arm64 + x86_64)..."
swift build -c "$CONFIG" "${ARCHS[@]}"
BINDIR="$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)"

echo "Assembling $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINDIR/vibescroll" "$APP/Contents/MacOS/vibescroll"
cp "$ROOT/scripts/AppInfo.plist" "$APP/Contents/Info.plist"

# Bundled alert sounds. `NSSound(named:)` searches Contents/Resources before the
# system sound folders, so copying them here is the whole integration.
# Regenerate with: python3 scripts/make-sounds.py
if [ -d "$ROOT/Resources/Sounds" ]; then
  cp "$ROOT/Resources/Sounds/"*.wav "$APP/Contents/Resources/" 2>/dev/null || true
fi

# Ad-hoc sign so the bundle has a stable identity for the notification centre
# and the keychain; without any signature macOS treats each build as a new app.
codesign --force --sign - "$APP" || echo "warning: codesign failed (continuing unsigned)"

echo "Done: $APP"
echo
echo "Run it:            open '$APP'"
echo "Install hooks:     Settings -> Integrations"
echo "Hook command uses: $APP/Contents/MacOS/vibescroll"
