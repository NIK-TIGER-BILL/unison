#!/usr/bin/env bash
# Wrapper around `swift test` that adds framework search paths so
# Swift Testing's Testing.framework is resolvable on Command Line
# Tools-only setups (no full Xcode.app).
#
# On machines with Xcode.app installed, bare `swift test` also works.
set -euo pipefail

FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

if [ ! -d "$FRAMEWORKS/Testing.framework" ]; then
  echo "warning: Testing.framework not found at $FRAMEWORKS — falling back to bare 'swift test'" >&2
  exec swift test "$@"
fi

exec swift test \
  -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
  -Xlinker -F -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  "$@"
