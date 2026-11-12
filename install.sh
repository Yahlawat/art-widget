#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-}" in
  ""|--build-only) ;;
  *) echo "Usage: $0 [--build-only]" >&2; exit 2 ;;
esac

if [[ $(uname -s) != Darwin ]] || [[ $(sw_vers -productVersion | cut -d. -f1) -lt 26 ]]; then
  echo "Art Widget requires macOS 26 or later." >&2
  exit 1
fi
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swift >/dev/null 2>&1; then
  echo "Run xcode-select --install, finish the installation, and run this script again." >&2
  exit 1
fi

LABEL=com.yashahlawat.artwidget
APP="$HOME/Applications/ArtWidget.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
LOG="$HOME/Library/Logs/ArtWidget.log"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ArtWidget"
STAGE=$(mktemp -d "$PWD/.build/install.XXXXXX")
BUNDLE="$STAGE/ArtWidget.app"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$BIN" "$BUNDLE/Contents/MacOS/ArtWidget"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
codesign --force --sign - "$BUNDLE"
codesign --verify --strict "$BUNDLE"

PLIST="$STAGE/$LABEL.plist"
cp Resources/LoginAgent.plist "$PLIST"
/usr/bin/plutil -insert ProgramArguments.0 -string "$APP/Contents/MacOS/ArtWidget" "$PLIST"
/usr/bin/plutil -insert StandardErrorPath -string "$LOG" "$PLIST"
/usr/bin/plutil -lint "$PLIST"

if [[ "${1:-}" == --build-only ]]; then
  printf 'Built %s\n' "$BUNDLE"
  exit 0
fi

mkdir -p "$(dirname "$APP")" "$(dirname "$AGENT")" "$(dirname "$LOG")"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
ditto "$BUNDLE" "$APP"
cp "$PLIST" "$AGENT"
launchctl bootstrap "$DOMAIN" "$AGENT"
printf 'Installed %s and started it. Log: %s\n' "$APP" "$LOG"
