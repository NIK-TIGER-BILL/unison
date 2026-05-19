#!/usr/bin/env bash
set -euo pipefail
RES_DIR="Resources/blackhole"
mkdir -p "$RES_DIR"

# Pinned to v0.6.0 for reproducibility.
BH2CH_URL="https://github.com/ExistentialAudio/BlackHole/releases/download/v0.6.0/BlackHole2ch.v0.6.0.pkg"
BH16CH_URL="https://github.com/ExistentialAudio/BlackHole/releases/download/v0.6.0/BlackHole16ch.v0.6.0.pkg"

echo "Downloading BlackHole 2ch..."
curl -L -o "$RES_DIR/BlackHole2ch.pkg" "$BH2CH_URL"
echo "Downloading BlackHole 16ch..."
curl -L -o "$RES_DIR/BlackHole16ch.pkg" "$BH16CH_URL"

echo "Verifying signatures..."
pkgutil --check-signature "$RES_DIR/BlackHole2ch.pkg" || echo "warning: BlackHole2ch.pkg signature check failed"
pkgutil --check-signature "$RES_DIR/BlackHole16ch.pkg" || echo "warning: BlackHole16ch.pkg signature check failed"

echo "Done. .pkg files saved to $RES_DIR/"
ls -lh "$RES_DIR/"
