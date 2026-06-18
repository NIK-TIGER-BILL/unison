#!/usr/bin/env bash
# Wrapper around `swift test` that adds framework search paths so
# Swift Testing's Testing.framework is resolvable on Command Line
# Tools-only setups (no full Xcode.app).
#
# The CLT framework paths are injected ONLY when the active developer
# dir (`xcode-select -p`) is the CommandLineTools one. With full Xcode
# selected, its toolchain resolves Testing.framework itself — and
# injecting a stale CLT Testing.framework on top breaks linking
# (undefined Swift Testing symbols).
set -euo pipefail

FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"

# Full Xcode selected (developer dir inside an .app bundle) → bare swift test.
case "$DEV_DIR" in
  *.app/*) exec swift test "$@" ;;
esac

if [[ "$DEV_DIR" == *CommandLineTools* && -d "$FRAMEWORKS/Testing.framework" ]]; then
  exec swift test \
    -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
    -Xlinker -F -Xlinker "$FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
    "$@"
fi

echo "warning: Testing.framework not found at $FRAMEWORKS — falling back to bare 'swift test'" >&2
exec swift test "$@"
