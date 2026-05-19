#!/usr/bin/env bash
set -euo pipefail

DEVELOPER_ID="${DEVELOPER_ID:?DEVELOPER_ID required (Apple Developer ID Application identity)}"
APPLE_ID="${APPLE_ID:?APPLE_ID required}"
APP_PASSWORD="${APP_PASSWORD:?APP_PASSWORD required (app-specific password)}"
TEAM_ID="${TEAM_ID:?TEAM_ID required}"

# 1. Fetch BlackHole pkgs
./scripts/fetch_blackhole.sh

# 2. Build and bundle
CONFIG=release ./scripts/bundle_app.sh

APP_PATH="build/Unison.app"

# 3. Notarize
echo "Creating zip for notarization..."
ditto -c -k --keepParent "$APP_PATH" "build/Unison.zip"

echo "Submitting to notarytool..."
xcrun notarytool submit "build/Unison.zip" \
  --apple-id "$APPLE_ID" \
  --password "$APP_PASSWORD" \
  --team-id "$TEAM_ID" \
  --wait

# 4. Staple
echo "Stapling..."
xcrun stapler staple "$APP_PATH"

# 5. Pack DMG
echo "Creating DMG..."
hdiutil create -volname "Unison" -srcfolder "$APP_PATH" -ov -format UDZO "build/Unison.dmg"

echo "Build complete: build/Unison.dmg"
ls -lh build/Unison.dmg
