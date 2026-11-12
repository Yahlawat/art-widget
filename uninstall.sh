#!/usr/bin/env bash
# Stops ArtWidget and removes it from login. Nothing is deleted: the app and the
# login agent are moved into this folder's _to_delete/ for you to bin.
set -euo pipefail
cd "$(dirname "$0")"

LABEL=com.yashahlawat.artwidget
APP="$HOME/Applications/ArtWidget.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DEST="_to_delete/$(date +%Y-%m-%d_%H%M%S)"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
mkdir -p "$DEST"
[ -e "$AGENT" ] && mv "$AGENT" "$DEST/"
[ -e "$APP" ] && mv "$APP" "$DEST/"
echo "Stopped. Moved the app and login agent to $DEST."
echo "Cached painting and state stay in ~/Library/Application Support/ArtWidget."
