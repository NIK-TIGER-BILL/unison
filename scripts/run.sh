#!/usr/bin/env bash
# Build + bundle + launch Unison for local development.
#
# Signs with a stable self-signed identity if one is available (see
# scripts/make_dev_cert.sh) so macOS stops re-prompting for mic / system-
# audio permissions and the keychain on every rebuild. Falls back to
# ad-hoc with a hint if no identity is set up.
#
# Launches via `open` (Launch Services), not a direct binary exec — and
# the app's own single-instance guard terminates any previously-running
# build, so you won't accumulate menubar icons across runs.
#
# Env knobs:
#   SIGN_IDENTITY  override the signing identity (default: "Unison Dev")
#   CONFIG         swift build configuration (default: debug)
set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:-Unison Dev}"
# `-p codesigning` without `-v`: a self-signed dev cert is untrusted, so
# `-v` would hide it even though codesign signs with it fine.
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$IDENTITY\""; then
  export SIGN_IDENTITY="$IDENTITY"
  echo "Using stable signing identity \"$IDENTITY\"."
else
  unset SIGN_IDENTITY
  echo "warning: code-signing identity \"$IDENTITY\" not found — using ad-hoc signing." >&2
  echo "         Run scripts/make_dev_cert.sh once to stop the per-rebuild" >&2
  echo "         permission / keychain prompts." >&2
fi

CONFIG="${CONFIG:-debug}" scripts/bundle_app.sh

echo "Launching build/Unison.app ..."
open build/Unison.app
