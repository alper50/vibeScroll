#!/usr/bin/env bash
# Fires a realistic burst of hook events at the running app so you can see a
# card without wiring up a real agent first.
#
# It has to run for a while on purpose: the scheduler's dwell gate ignores any
# topic that hasn't been stable for 8 seconds (Normal pacing), which is what
# stops the card strobing while an agent fires tool calls several times a second.
set -euo pipefail

cd "$(dirname "$0")/.."
BIN="${VIBESCROLL_BIN:-build/vibeScroll.app/Contents/MacOS/vibescroll}"
[ -x "$BIN" ] || { echo "not built: $BIN — run ./scripts/build-app.sh first"; exit 1; }

TOPIC="${1:-git}"
case "$TOPIC" in
  git)   TOOL="Bash"; ARG='"command":"git rebase -i origin/main"' ;;
  test)  TOOL="Bash"; ARG='"command":"pytest -q tests/"' ;;
  deps)  TOOL="Bash"; ARG='"command":"npm install express"' ;;
  edit)  TOOL="Edit"; ARG='"file_path":"src/Store.swift"' ;;
  debug) TOOL="Bash"; ARG='"command":"lldb ./app --verbose"' ;;
  *) echo "usage: $0 [git|test|deps|edit|debug]"; exit 2 ;;
esac

SESSION="demo-$(date +%s)"
echo "Simulating a '$TOPIC' session for 14s (session $SESSION)…"

send() {
  echo "{\"session_id\":\"$SESSION\",\"cwd\":\"$PWD\",\"hook_event_name\":\"$1\",\"tool_name\":\"$TOOL\",\"tool_input\":{$ARG}}" \
    | "$BIN" hook --agent claude
}

send SessionStart
for i in $(seq 1 7); do
  send PreToolUse
  printf '  tick %d/7\r' "$i"
  sleep 2
done
echo
send Stop
echo "Done. A card should have appeared in the bottom-right."
