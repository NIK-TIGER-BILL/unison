#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."  # repo root — build/, Resources/, .build/ paths below are repo-relative

TARGET="unison"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

CONFIG="${CONFIG:-release}"

case "$TARGET" in
  unison)
    APP_NAME="Unison"
    PRODUCT="Unison"
    EXEC_NAME="Unison"
    INFO_PLIST="Resources/Info.plist"
    ENTITLEMENTS="Resources/Unison.entitlements"
    ICON_FILE="Resources/AppIcon.icns"
    ;;
  tap-benchmark)
    APP_NAME="TapBenchmark"
    PRODUCT="tap-benchmark"
    EXEC_NAME="tap-benchmark"
    INFO_PLIST="Sources/Tools/TapBenchmark/Info.plist"
    ENTITLEMENTS="Sources/Tools/TapBenchmark/tap-benchmark.entitlements"
    ICON_FILE=""
    ;;
  *)
    echo "Unknown --target: $TARGET (expected: unison | tap-benchmark)" >&2
    exit 1
    ;;
esac

BUNDLE_DIR="build/${APP_NAME}.app"
CONTENTS="${BUNDLE_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "Building $PRODUCT ($CONFIG)..."
swift build --configuration "$CONFIG" --product "$PRODUCT"

EXEC_PATH=".build/${CONFIG}/${PRODUCT}"
if [ ! -f "$EXEC_PATH" ]; then
  echo "error: executable not found at $EXEC_PATH"
  exit 1
fi

echo "Constructing $BUNDLE_DIR..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cp "$EXEC_PATH" "$MACOS/$EXEC_NAME"
cp "$INFO_PLIST" "$CONTENTS/Info.plist"

# Stamp the version when the release pipeline provides it. The repo's
# Info.plist keeps placeholder values (1.0 / 1); the real marketing
# version comes from the git tag, the build number from the release run
# — see scripts/build_release.sh and .github/workflows/release.yml.
# Local `bundle_app.sh` runs without these vars keep the placeholders.
# Must happen BEFORE codesign — signing seals the bundle contents.
if [ -n "${MARKETING_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$CONTENTS/Info.plist" \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $MARKETING_VERSION" "$CONTENTS/Info.plist"
fi
if [ -n "${BUILD_VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$CONTENTS/Info.plist" \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_VERSION" "$CONTENTS/Info.plist"
fi

# App icon (CFBundleIconFile = "AppIcon" → Contents/Resources/AppIcon.icns).
if [ -n "${ICON_FILE:-}" ] && [ -f "$ICON_FILE" ]; then
  cp "$ICON_FILE" "$RESOURCES/AppIcon.icns"
fi

# Signing precedence:
#   1. DEVELOPER_ID  → release: Developer ID + hardened runtime
#      (notarization-ready). unison target only; injected by the
#      release pipeline (see scripts/build_release.sh).
#   2. SIGN_IDENTITY → local dev: a STABLE self-signed identity (create
#      one once with scripts/make_dev_cert.sh). A stable identity gives
#      the bundle a stable designated requirement that survives
#      rebuilds, so macOS stops re-prompting for mic / system-audio
#      (TCC) and for the login keychain (the OpenAI API key's ACL) on
#      every rebuild. No hardened runtime: keeps lldb attach simple and
#      isn't needed for the stability win.
#   3. Otherwise      → ad-hoc: the signature changes every build, which
#      is what causes the per-rebuild permission / keychain prompts.
if [ "$TARGET" = "unison" ] && [ "${DEVELOPER_ID:-}" != "" ]; then
  echo "Signing with $DEVELOPER_ID..."
  codesign --force \
    --sign "$DEVELOPER_ID" \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    "$BUNDLE_DIR"
elif [ "${SIGN_IDENTITY:-}" != "" ]; then
  echo "Signing with local identity \"$SIGN_IDENTITY\"..."
  codesign --force \
    --sign "$SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    "$BUNDLE_DIR"
else
  echo "(Ad-hoc signing — permissions/keychain will re-prompt each rebuild; see scripts/make_dev_cert.sh)"
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BUNDLE_DIR"
fi

echo "Bundle ready: $BUNDLE_DIR"
ls -lh "$BUNDLE_DIR/Contents/MacOS/"
