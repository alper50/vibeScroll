#!/usr/bin/env bash
# Brings Resources/Localization/Localizable.xcstrings up to date with the source.
#
# The compiler does the finding: `-emit-localized-strings` records every
# `String(localized:)`, every SwiftUI `Text("…")`, `Button("…")`, `.help("…")`
# and the rest, exactly as the app will look them up at runtime — including the
# `%@` / `%lld` a string interpolation turns into. `xcstringstool sync` merges
# that into the catalogue: new strings arrive untranslated, ones no longer in
# the source are marked stale, and translations already made are kept.
#
# Run after changing any user-facing text, then translate what it reports:
#
#   ./scripts/sync-strings.sh
#
# Needs Xcode (not just the Command Line Tools) for `xcstringstool`.
set -euo pipefail

cd "$(dirname "$0")/.."
CATALOG="Resources/Localization/Localizable.xcstrings"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A scratch build of its own, every time. An incremental build only compiles
# what changed, and a file that is not compiled reports no strings — which
# `sync` would then read as every string in it having been deleted.
echo "Extracting strings (clean build, takes a minute)..."
mkdir -p "$WORK/strings"
swift build --scratch-path "$WORK/build" \
  -Xswiftc -emit-localized-strings \
  -Xswiftc -emit-localized-strings-path -Xswiftc "$WORK/strings" >/dev/null

[ -f "$CATALOG" ] || echo '{"sourceLanguage":"en","strings":{},"version":"1.0"}' > "$CATALOG"
xcrun xcstringstool sync "$CATALOG" --stringsdata "$WORK"/strings/*.stringsdata

python3 scripts/check-strings.py "$CATALOG" || true
