#!/usr/bin/env bash
# LightStar — Developer ID sign, notarize, staple, DMG
# Usage: APPLE_ID=you@email.com TEAM_ID=XXXXXXXXXX APP_PASSWORD=xxxx-xxxx-xxxx-xxxx ./scripts/notarize.sh
set -euo pipefail

: "${APPLE_ID:?Set APPLE_ID env var}"
: "${TEAM_ID:?Set TEAM_ID env var}"
: "${APP_PASSWORD:?Set APP_PASSWORD env var (app-specific password from appleid.apple.com)}"

SCHEME="LightStar"
ARCHIVE="build/LightStar.xcarchive"
EXPORT_DIR="build/export"
APP="$EXPORT_DIR/LightStar.app"
DMG="build/LightStar.dmg"

echo "==> Cleaning build dir"
rm -rf build && mkdir -p build

echo "==> Archiving"
xcodebuild -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" \
  archive

echo "==> Exporting with Developer ID"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist scripts/ExportOptions.plist

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type exec --verbose "$APP"

echo "==> Creating DMG"
hdiutil create \
  -volname "LightStar" \
  -srcfolder "$APP" \
  -ov -format UDZO \
  "$DMG"

echo "==> Notarizing"
xcrun notarytool submit "$DMG" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_PASSWORD" \
  --wait

echo "==> Stapling"
xcrun stapler staple "$DMG"

echo "==> Verifying Gatekeeper"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

echo ""
echo "Done: $DMG"
echo "Share this file — Gatekeeper will accept it on any Mac."
