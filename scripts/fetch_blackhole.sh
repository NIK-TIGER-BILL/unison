#!/usr/bin/env bash
# Fetch BlackHole .pkg installers into Resources/blackhole/.
#
# Upstream BlackHole stopped attaching .pkg files to GitHub releases as
# of v0.6.x — assets are now distributed only through
# https://existential.audio/blackhole/ behind an email signup. This
# script tries the historic GitHub release URLs first; if they 404 it
# tells the user to manually drop the .pkg files into the resources
# directory.
#
# `--fail` halts on HTTP errors so we never silently write a 404 HTML
# body to disk (the previous script produced 9-byte "Not Found"
# placeholders that compiled cleanly into the .app and only blew up at
# install time).
set -euo pipefail
RES_DIR="Resources/blackhole"
mkdir -p "$RES_DIR"

VERSION="v0.6.0"
BH2CH_URL="https://github.com/ExistentialAudio/BlackHole/releases/download/${VERSION}/BlackHole2ch.${VERSION}.pkg"
BH16CH_URL="https://github.com/ExistentialAudio/BlackHole/releases/download/${VERSION}/BlackHole16ch.${VERSION}.pkg"

download() {
    local url="$1"
    local out="$2"
    echo "Downloading $(basename "$url")..."
    if ! curl --fail --location --silent --show-error -o "$out" "$url"; then
        echo "error: failed to download $url" >&2
        rm -f "$out"
        return 1
    fi
    # Reject HTML/text payloads — only accept actual installer archives.
    if ! file "$out" | grep -q "xar archive"; then
        echo "error: $out is not a valid pkg (file says: $(file -b "$out"))" >&2
        head -c 200 "$out" >&2
        echo >&2
        rm -f "$out"
        return 1
    fi
    return 0
}

manual_instructions() {
    cat <<'EOF' >&2

BlackHole .pkg installers are no longer attached to GitHub releases.
To install BlackHole into Unison.app:

  1. Visit https://existential.audio/blackhole/ and request BlackHole
     2ch and BlackHole 16ch (free; email signup required).
  2. Save the two .pkg files into this repo as:
       Resources/blackhole/BlackHole2ch.pkg
       Resources/blackhole/BlackHole16ch.pkg
  3. Re-run `bash scripts/bundle_app.sh`.

You can also install BlackHole system-wide via Homebrew:
  brew install blackhole-2ch
  brew install blackhole-16ch
and Unison will detect the installed devices without bundling the
installer payloads.

EOF
    exit 1
}

ok=0
download "$BH2CH_URL"  "$RES_DIR/BlackHole2ch.pkg"  || ok=1
download "$BH16CH_URL" "$RES_DIR/BlackHole16ch.pkg" || ok=1
if [ "$ok" -ne 0 ]; then
    manual_instructions
fi

echo "Verifying signatures..."
pkgutil --check-signature "$RES_DIR/BlackHole2ch.pkg" || echo "warning: BlackHole2ch.pkg signature check failed"
pkgutil --check-signature "$RES_DIR/BlackHole16ch.pkg" || echo "warning: BlackHole16ch.pkg signature check failed"

echo "Done. .pkg files saved to $RES_DIR/"
ls -lh "$RES_DIR/"
