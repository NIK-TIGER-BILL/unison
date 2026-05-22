#!/usr/bin/env bash
set -euo pipefail

CONFIG="${CONFIG:-release}"
APP_NAME="Unison"
BUNDLE_DIR="build/${APP_NAME}.app"
CONTENTS="${BUNDLE_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "Building executable ($CONFIG)..."
swift build --configuration "$CONFIG" --product Unison

EXEC_PATH=".build/${CONFIG}/Unison"
if [ ! -f "$EXEC_PATH" ]; then
  echo "error: executable not found at $EXEC_PATH"
  exit 1
fi

echo "Constructing $BUNDLE_DIR..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cp "$EXEC_PATH" "$MACOS/Unison"
cp Resources/Info.plist "$CONTENTS/Info.plist"

# BlackHole installers are no longer bundled — the app downloads the
# latest release from GitHub at runtime when the user clicks
# "Установить" in onboarding. See BundledBlackHoleInstaller.swift.

# Optional signing
if [ "${DEVELOPER_ID:-}" != "" ]; then
  echo "Signing with $DEVELOPER_ID..."
  codesign --force \
    --sign "$DEVELOPER_ID" \
    --options runtime \
    --entitlements Resources/Unison.entitlements \
    "$BUNDLE_DIR"
else
  echo "(Skipping signing — set DEVELOPER_ID env var to sign)"
  # Ad-hoc sign so the binary at least loads on local machines
  codesign --force --sign - --entitlements Resources/Unison.entitlements "$BUNDLE_DIR" 2>/dev/null || true
fi

echo "Bundle ready: $BUNDLE_DIR"
ls -lh "$BUNDLE_DIR/Contents/MacOS/"
