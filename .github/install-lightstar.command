#!/bin/bash
# LightStar installer — strips Gatekeeper quarantine, copies to /Applications, launches.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/LightStar.app"

echo "Removing Gatekeeper quarantine..."
xattr -rd com.apple.quarantine "$APP" 2>/dev/null || true

echo "Copying to /Applications..."
cp -R "$APP" /Applications/LightStar.app
xattr -rd com.apple.quarantine /Applications/LightStar.app 2>/dev/null || true

echo "Done! Launching LightStar..."
open /Applications/LightStar.app
