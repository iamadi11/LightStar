#!/bin/bash
# LightStar installer
# Strips Gatekeeper quarantine, resets stale TCC entries, installs, launches.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/LightStar.app"
BUNDLE_ID="com.adityaraj.LightStar"

echo "Removing Gatekeeper quarantine..."
xattr -rd com.apple.quarantine "$APP" 2>/dev/null || true

# If an old version exists, quit it and remove it cleanly.
if [ -d /Applications/LightStar.app ]; then
    echo "Quitting old LightStar if running..."
    osascript -e 'quit app "LightStar"' 2>/dev/null || true
    sleep 1
    echo "Removing old version..."
    rm -rf /Applications/LightStar.app
fi

# Reset TCC permission entries for this bundle ID.
# macOS ties unsigned-app permissions to the binary hash, so the new binary
# would be silently denied with the old entry. A clean reset forces a fresh
# permission prompt on first launch instead of a silent denial.
echo "Resetting permission entries for clean install..."
tccutil reset Bluetooth "$BUNDLE_ID" 2>/dev/null || true
tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true
tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true
tccutil reset Camera "$BUNDLE_ID" 2>/dev/null || true

echo "Installing to /Applications..."
cp -R "$APP" /Applications/LightStar.app
xattr -rd com.apple.quarantine /Applications/LightStar.app 2>/dev/null || true

echo ""
echo "✓ LightStar installed."
echo ""
echo "On first launch you will be asked to grant:"
echo "  • Bluetooth  — required to connect to your LED bar"
echo "  • Screen Recording  — required for Video/Audio sync"
echo "  • Microphone  — only if you use the Microphone sync source"
echo ""
echo "Launching LightStar..."
open /Applications/LightStar.app
