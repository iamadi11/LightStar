#!/bin/bash
# Archive, notarize, staple, and Gatekeeper-assess a Developer ID LightStar build.
# Requires: xcodegen, Xcode, APPLE_ID, TEAM_ID, APP_PASSWORD.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${APPLE_ID:?Set APPLE_ID}"
: "${TEAM_ID:?Set TEAM_ID}"
: "${APP_PASSWORD:?Set APP_PASSWORD (app-specific password)}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen is required (brew install xcodegen)" >&2
  exit 1
fi

xcodegen generate

WORKDIR="${TMPDIR:-/tmp}/lightstar-notarize-$$"
mkdir -p "$WORKDIR"
ARCHIVE="$WORKDIR/LightStar.xcarchive"
EXPORT="$WORKDIR/export"
mkdir -p "$EXPORT"

cat > "$WORKDIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>signingStyle</key><string>manual</string>
</dict>
</plist>
PLIST

xcodebuild archive \
  -project LightStar.xcodeproj \
  -scheme LightStar \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$WORKDIR/ExportOptions.plist"

APP="$EXPORT/LightStar.app"

echo "Verifying signature (not Gatekeeper — the app is not notarized yet)…"
codesign --verify --deep --strict --verbose=2 "$APP"

# Do NOT run spctl here. Gatekeeper rejects a Developer ID app that has not
# been notarized yet; that check belongs after stapler staple.

DMG="$WORKDIR/LightStar-notarize.dmg"
hdiutil create -volname "LightStar" -srcfolder "$APP" -ov -format UDZO "$DMG"

echo "Submitting to notarytool…"
xcrun notarytool submit "$DMG" \
  --apple-id "$APPLE_ID" \
  --password "$APP_PASSWORD" \
  --team-id "$TEAM_ID" \
  --wait

xcrun stapler staple "$APP"
xcrun stapler staple "$DMG"

echo "Gatekeeper assessment after staple:"
spctl --assess --type exec -vv "$APP"

echo "Notarized app: $APP"
echo "Notarized DMG: $DMG"
