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
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$IDENTITY\""; then
  echo "Code-signing identity \"$IDENTITY\" already exists — nothing to do."
  exit 0
fi

KEYCHAIN="$(security default-keychain -d user 2>/dev/null | tr -d ' "')"
[ -n "$KEYCHAIN" ] || KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

echo "Creating self-signed code-signing identity \"$IDENTITY\" in $KEYCHAIN ..."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Self-signed cert with the codeSigning extended key usage. `-addext`
# is supported by both the system LibreSSL 3.x and Homebrew openssl 3.x.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$IDENTITY" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# Bundle key+cert into a PKCS#12, then import as an identity.
# - Legacy PBE/MAC (SHA1 + 3DES) + a non-empty password for
#   `security import` compatibility: newer openssl (3.x — e.g. a Homebrew
#   `openssl` ahead of LibreSSL on PATH) defaults to AES-256 PBE / SHA-256
#   MAC, which macOS's `security import` rejects ("MAC verification
#   failed"); an empty password is likewise rejected. Legacy SHA1/3DES +
#   a throwaway password import cleanly on both the system LibreSSL and
#   Homebrew openssl. The password only has to match export ↔ import.
# - `-T /usr/bin/codesign` authorizes codesign to use the private key. We
#   deliberately do NOT pass `-A` (which would let *any* app use the key
#   silently); codesign still prompts once on first use — click
#   "Always Allow".
openssl pkcs12 -export -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/identity.p12" \
  -passout pass:unison-dev
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P unison-dev -T /usr/bin/codesign

# Headless/CI only: let codesign use the key without the interactive
# "Always Allow" click. Needs the keychain password, so it's best-effort
# here — on an interactive Mac just click Always Allow on the first sign.
#   security set-key-partition-list -S apple-tool:,apple:,codesign: \
#     -s -k "<login-password>" "$KEYCHAIN"

echo
echo "Done. \"$IDENTITY\" is ready."
echo "Build with:  SIGN_IDENTITY=\"$IDENTITY\" scripts/bundle_app.sh"
echo "Or just run: scripts/run.sh   (auto-detects the identity)"
