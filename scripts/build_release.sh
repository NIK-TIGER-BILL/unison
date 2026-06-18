#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."  # repo root — build/ and scripts/ paths below are repo-relative

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

# Notarize only with a complete credential set; otherwise degrade to ad-hoc.
CAN_NOTARIZE=0
if [ -n "$DEVELOPER_ID" ] && [ -n "$APPLE_ID" ] && [ -n "$APP_PASSWORD" ] && [ -n "$TEAM_ID" ]; then
  CAN_NOTARIZE=1
fi

# Submit a path to Apple's notary service and block until it's done.
notarize() {
  xcrun notarytool submit "$1" \
    --apple-id "$APPLE_ID" \
    --password "$APP_PASSWORD" \
    --team-id "$TEAM_ID" \
    --wait
}

# 1. Build + bundle. bundle_app.sh signs with DEVELOPER_ID when set
#    (ad-hoc otherwise) and stamps MARKETING_VERSION / BUILD_VERSION into
#    the bundled Info.plist when those are exported.
CONFIG=release ./scripts/bundle_app.sh

# 2. Notarize + staple the APP so the installed app launches offline — the
#    ticket then travels inside the .app even when copied out of the DMG.
if [ "$CAN_NOTARIZE" -eq 1 ]; then
  echo "Notarizing app (this can take a few minutes)..."
  ditto -c -k --keepParent "$APP_PATH" "build/Unison.zip"
  notarize "build/Unison.zip"
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

# 4. Notarize + staple the DMG itself — it's the artifact users download
#    (and the one that carries the quarantine flag), so its first open
#    should be clean offline, not just the app inside it.
if [ "$CAN_NOTARIZE" -eq 1 ]; then
  echo "Notarizing DMG (this can take a few minutes)..."
  notarize "$DMG_PATH"
  xcrun stapler staple "$DMG_PATH"
fi

# 5. Checksum — computed last, because stapling rewrites the DMG.
shasum -a 256 "$DMG_PATH" | tee "${DMG_PATH}.sha256"

echo "Build complete: $DMG_PATH"
ls -lh "$DMG_PATH"
