#!/usr/bin/env bash
# Run SwiftLint + Periphery on the project. Downloads pre-built
# binaries on first run if they aren't on PATH, so this works on a
# Command Line Tools-only setup (no full Xcode.app required).
#
# Usage:
#   scripts/lint.sh            # lint + dead-code scan, fail on findings
#   scripts/lint.sh --fix      # also run `swiftlint --fix`
#   scripts/lint.sh swiftlint  # SwiftLint only
#   scripts/lint.sh periphery  # Periphery only

set -euo pipefail

cd "$(dirname "$0")/.."  # repo root

BIN_DIR="scripts/.bin"
mkdir -p "$BIN_DIR"

# Portable SwiftLint / Periphery dlopen system frameworks from
# `$(xcode-select -p)/usr/lib`. On a Command Line Tools-only setup
# the libraries ARE there, but the dynamic loader needs explicit
# DYLD path hints to find them -- full Xcode resolves these through
# its own toolchain plumbing.
_dev_dir=$(xcode-select -p 2>/dev/null || true)
if [[ "$_dev_dir" == *CommandLineTools ]]; then
    export DYLD_FRAMEWORK_PATH="$_dev_dir/usr/lib"
    export DYLD_LIBRARY_PATH="$_dev_dir/usr/lib"
fi

SWIFTLINT_VERSION="0.59.1"
PERIPHERY_VERSION="3.7.4"

# --- SwiftLint ---------------------------------------------------------------

swiftlint_bin() {
    if command -v swiftlint >/dev/null 2>&1; then
        command -v swiftlint
        return
    fi
    local bin="$BIN_DIR/swiftlint"
    if [[ ! -x "$bin" ]]; then
        echo "Downloading SwiftLint $SWIFTLINT_VERSION..." >&2
        local tmp
        tmp=$(mktemp -d)
        curl -fsSL -o "$tmp/swiftlint.zip" \
            "https://github.com/realm/SwiftLint/releases/download/$SWIFTLINT_VERSION/portable_swiftlint.zip"
        unzip -q "$tmp/swiftlint.zip" -d "$tmp"
        mv "$tmp/swiftlint" "$bin"
        chmod +x "$bin"
        rm -rf "$tmp"
    fi
    echo "$bin"
}

# --- Periphery ---------------------------------------------------------------

periphery_bin() {
    if command -v periphery >/dev/null 2>&1; then
        command -v periphery
        return
    fi
    local bin="$BIN_DIR/periphery"
    if [[ ! -x "$bin" ]]; then
        echo "Downloading Periphery $PERIPHERY_VERSION..." >&2
        local tmp
        tmp=$(mktemp -d)
        curl -fsSL -o "$tmp/periphery.zip" \
            "https://github.com/peripheryapp/periphery/releases/download/$PERIPHERY_VERSION/periphery-$PERIPHERY_VERSION.zip"
        unzip -q "$tmp/periphery.zip" -d "$tmp"
        mv "$tmp/periphery" "$bin"
        chmod +x "$bin"
        rm -rf "$tmp"
    fi
    echo "$bin"
}

# --- Dispatch ----------------------------------------------------------------

mode="${1:-all}"
fix=0
if [[ "$mode" == "--fix" ]]; then
    fix=1
    mode="all"
fi

failed=0

run_swiftlint() {
    local sl
    sl=$(swiftlint_bin)
    if [[ $fix -eq 1 ]]; then
        echo "--- SwiftLint --fix ---"
        "$sl" --fix --quiet || true
    fi
    echo "--- SwiftLint ---"
    "$sl" lint --strict --quiet || failed=1
}

run_periphery() {
    local pp
    pp=$(periphery_bin)
    # Periphery's bundled binary loads `libIndexStore.dylib` via
    # `@rpath`. macOS strips DYLD env vars for hardened binaries,
    # so the only place dyld will find the lib is alongside the
    # binary itself -- symlink it from the CLT toolchain.
    if [[ ! -e "$BIN_DIR/libIndexStore.dylib" && -e "/Library/Developer/CommandLineTools/usr/lib/libIndexStore.dylib" ]]; then
        ln -sf /Library/Developer/CommandLineTools/usr/lib/libIndexStore.dylib "$BIN_DIR/libIndexStore.dylib"
    fi
    # Ensure the SwiftPM index exists; Periphery's own build path
    # tries to compile tests that need the `Testing` module from a
    # full Xcode toolchain, so we feed it the pre-built index.
    if [[ ! -d ".build/debug/index/store" ]]; then
        echo "Building project so Periphery has an index to scan..." >&2
        swift build >/dev/null
    fi
    echo "--- Periphery (informational -- does not fail the lint) ---"
    # `--strict` is intentionally OFF: tests don't build on a
    # Command Line Tools-only toolchain (no `Testing` module), so the
    # index excludes them and Periphery flags preview-only API as
    # unused. Findings are surfaced but the script keeps exit 0.
    "$pp" scan \
        --skip-build \
        --index-store-path .build/debug/index/store \
        --exclude-tests \
        --quiet --disable-update-check || true
}

case "$mode" in
    all)
        run_swiftlint
        echo
        run_periphery
        ;;
    swiftlint)
        run_swiftlint
        ;;
    periphery)
        run_periphery
        ;;
    *)
        echo "Unknown mode: $mode" >&2
        echo "Usage: scripts/lint.sh [--fix | swiftlint | periphery]" >&2
        exit 2
        ;;
esac

if [[ $failed -eq 1 ]]; then
    echo
    echo "Lint issues found."
    exit 1
fi
echo
echo "Lint clean."
