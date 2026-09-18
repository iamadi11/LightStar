#!/bin/bash
# LightStar installer
# Strips Gatekeeper quarantine, copies to /Applications, launches.
# Does NOT reset TCC — a stable Developer ID / self-signed identity must keep
# Bluetooth, Screen Recording and Microphone grants across updates.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/LightStar.app"
DEST="/Applications/LightStar.app"

if [ ! -d "$APP" ]; then
    echo "error: LightStar.app not found next to this script" >&2
    exit 1
fi

echo "Removing Gatekeeper quarantine from the disk image copy..."
xattr -rd com.apple.quarantine "$APP" 2>/dev/null || true

STAGE="$(mktemp -d /tmp/lightstar-install.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
echo "Staging copy..."
cp -R "$APP" "$STAGE/LightStar.app"
if [ ! -x "$STAGE/LightStar.app/Contents/MacOS/LightStar" ]; then
    echo "error: staged copy is missing the LightStar executable — aborting without touching /Applications" >&2
    exit 1
fi

if [ -d "$DEST" ]; then
    echo "Quitting old LightStar if running..."
    osascript -e 'quit app "LightStar"' 2>/dev/null || true
    sleep 1
    echo "Removing old version..."
    rm -rf "$DEST"
fi

echo "Installing to /Applications..."
cp -R "$STAGE/LightStar.app" "$DEST"
xattr -rd com.apple.quarantine "$DEST" 2>/dev/null || true

echo ""
echo "LightStar installed."
echo ""
echo "On first launch (or after a signing-identity change) grant:"
echo "  • Bluetooth  — required to connect to your LED bar"
echo "  • Screen Recording  — required for Video/Audio sync"
echo "  • Microphone  — only if you use the Microphone sync source"
echo ""
echo "Launching LightStar..."
open "$DEST"
