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

# Interface translations. The catalogue is the source (see
# scripts/sync-strings.sh); what ships is one compiled .lproj per language in
# Contents/Resources, where AppKit and SwiftUI look for Bundle.main's strings.
# Without Xcode's `xcstringstool` the app still builds and runs — in English.
CATALOG="$ROOT/Resources/Localization/Localizable.xcstrings"
if [ -f "$CATALOG" ]; then
  if xcrun --find xcstringstool >/dev/null 2>&1; then
    python3 "$ROOT/scripts/check-strings.py" "$CATALOG" >/dev/null \
      || echo "warning: the string catalogue has untranslated or mismatched strings (run scripts/check-strings.py)"
    xcrun xcstringstool compile "$CATALOG" --output-directory "$APP/Contents/Resources" >/dev/null
  else
    echo "warning: xcstringstool not found (needs Xcode); building without translations"
  fi
fi

# Ad-hoc sign so the bundle has a stable identity for the notification centre
# and the keychain; without any signature macOS treats each build as a new app.
codesign --force --sign - "$APP" || echo "warning: codesign failed (continuing unsigned)"

echo "Done: $APP"
echo
echo "Run it:            open '$APP'"
echo "Install hooks:     Settings -> Integrations"
echo "Hook command uses: $APP/Contents/MacOS/vibescroll"
