#!/usr/bin/env bash
set -euo pipefail

# Developer ID signing + notarization are OPTIONAL. When all four
# credentials below are present the script produces a signed, hardened,
# notarized, stapled DMG ready for public distribution. When any are
# missing it falls back to the ad-hoc artifact that bundle_app.sh
# produces — runnable for testing, but Gatekeeper will warn end users.
# This lets the release pipeline run (and be exercised) before an Apple
# Developer account / GitHub secrets are configured. See docs/release.md.
DEVELOPER_ID="${DEVELOPER_ID:-}"
APPLE_ID="${APPLE_ID:-}"
APP_PASSWORD="${APP_PASSWORD:-}"
TEAM_ID="${TEAM_ID:-}"

APP_PATH="build/Unison.app"
DMG_PATH="build/Unison.dmg"

# 1. Build + bundle. bundle_app.sh signs with DEVELOPER_ID when set
#    (ad-hoc otherwise) and stamps MARKETING_VERSION / BUILD_VERSION into
#    the bundled Info.plist when those are exported.
CONFIG=release ./scripts/bundle_app.sh

# 2. Notarize + staple — only with a complete credential set.
if [ -n "$DEVELOPER_ID" ] && [ -n "$APPLE_ID" ] && [ -n "$APP_PASSWORD" ] && [ -n "$TEAM_ID" ]; then
  echo "Creating zip for notarization..."
  ditto -c -k --keepParent "$APP_PATH" "build/Unison.zip"

  echo "Submitting to notarytool (this can take a few minutes)..."
  xcrun notarytool submit "build/Unison.zip" \
    --apple-id "$APPLE_ID" \
    --password "$APP_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait

  echo "Stapling ticket to app bundle..."
  xcrun stapler staple "$APP_PATH"
  rm -f "build/Unison.zip"
else
  echo "warning: signing/notarization credentials incomplete — producing an"
  echo "         UNNOTARIZED DMG. Gatekeeper will warn end users. Set"
  echo "         DEVELOPER_ID, APPLE_ID, APP_PASSWORD and TEAM_ID to notarize."
fi

# 3. Pack a DMG with an /Applications drop target so users can drag-install.
#    Staging via a temp dir (vs. -srcfolder on the .app directly) is what
#    lets us drop the /Applications symlink next to the app.
echo "Creating DMG..."
STAGING="$(mktemp -d)"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "Unison" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGING"

# 4. Checksum so downloads can be integrity-verified.
shasum -a 256 "$DMG_PATH" | tee "${DMG_PATH}.sha256"

echo "Build complete: $DMG_PATH"
ls -lh "$DMG_PATH"
