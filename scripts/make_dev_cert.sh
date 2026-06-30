#!/usr/bin/env bash
# One-time setup: create a STABLE self-signed code-signing identity
# ("Unison Dev") in your login keychain.
#
# Why: local dev builds are otherwise ad-hoc signed, so their code
# signature (cdhash) changes on every rebuild. macOS keys both TCC
# (microphone / system-audio permission) and the login-keychain ACL
# (the stored OpenAI API key) to the signature's *designated
# requirement* — so every rebuild looks like a brand-new app and you get
# re-prompted for permissions and the keychain again and again. A stable
# signing identity gives a stable designated requirement, so you grant
# once and never again.
#
# Idempotent: re-running once the identity exists is a no-op.
#
# After this, build/run with the identity:
#     SIGN_IDENTITY="Unison Dev" scripts/bundle_app.sh   # or: scripts/run.sh
# The FIRST codesign with the new key shows one "codesign wants to use
# key …" prompt — click **Always Allow** once; it won't ask again.
#
# GUI alternative (no script): Keychain Access → Certificate Assistant →
# Create a Certificate… → Name "Unison Dev", Identity Type "Self Signed
# Root", Certificate Type "Code Signing".
set -euo pipefail

IDENTITY="${1:-Unison Dev}"

# Detect with `-p codesigning` but WITHOUT `-v`: a self-signed cert is
# untrusted (`CSSMERR_TP_NOT_TRUSTED`), so `-v` (valid-only) hides it —
# yet codesign signs with it fine. Treat a present-but-untrusted identity
# as "already set up".
if security find-identity -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  echo "Code-signing identity \"$IDENTITY\" already exists — nothing to do."
  exit 0
fi

KEYCHAIN="$(security default-keychain -d user 2>/dev/null | tr -d ' "')"
[ -n "$KEYCHAIN" ] || KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

echo "Creating self-signed code-signing identity \"$IDENTITY\" in $KEYCHAIN ..."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Self-signed cert with the codeSigning extended key usage. `-addext`
# is supported by the system openssl (LibreSSL 3.x) on macOS 26.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$IDENTITY" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# Bundle key+cert into a PKCS#12, then import as an identity.
# - Legacy PBE/MAC (SHA1 + 3DES) + a non-empty password: macOS's
#   `security import` rejects the system openssl's default p12
#   (empty-password / newer MAC) with "MAC verification failed". The
#   password is an internal throwaway — it only has to match between
#   export and import.
# - `-A` authorizes any app to use the key; `-T /usr/bin/codesign` also
#   names codesign explicitly. Together they minimize the first-use
#   keychain prompt.
openssl pkcs12 -export -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/identity.p12" \
  -passout pass:unison-dev
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P unison-dev -A -T /usr/bin/codesign

# Headless/CI only: let codesign use the key without the interactive
# "Always Allow" click. Needs the keychain password, so it's best-effort
# here — on an interactive Mac just click Always Allow on the first sign.
#   security set-key-partition-list -S apple-tool:,apple:,codesign: \
#     -s -k "<login-password>" "$KEYCHAIN"

echo
echo "Done. \"$IDENTITY\" is ready."
echo "Build with:  SIGN_IDENTITY=\"$IDENTITY\" scripts/bundle_app.sh"
echo "Or just run: scripts/run.sh   (auto-detects the identity)"
