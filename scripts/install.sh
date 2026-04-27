#!/usr/bin/env bash
# install.sh — deploy cc-statusline-widgets to ~/.claude/scripts/cc-statusline/
# and bootstrap launchd daemon. Idempotent.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="$HOME/.claude/scripts/cc-statusline"
PLIST_NAME="com.user.cc-statusline-daemon.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

mkdir -p "$DEST"
mkdir -p "$HOME/Library/LaunchAgents"

cp "$REPO_ROOT/scripts/wrapper.sh"      "$DEST/"
cp "$REPO_ROOT/scripts/daemon.sh"       "$DEST/"
cp "$REPO_ROOT/scripts/free-memory.sh"  "$DEST/"
cp "$REPO_ROOT/scripts/cpu-usage.sh"    "$DEST/"
chmod +x "$DEST"/*.sh

cp "$REPO_ROOT/launchd/$PLIST_NAME" "$PLIST_DEST"

launchctl bootout "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"

echo "Installed scripts to $DEST"
echo "Daemon started (com.user.cc-statusline-daemon)"
echo
echo "Next: ~/.claude/settings.json statusLine.command should be:"
echo "  $DEST/wrapper.sh"
echo
echo "Verify daemon running:"
echo "  ps aux | grep cc-statusline-widgets | grep -v grep"
echo "  ls -la /tmp/cc-widget-cache/"
