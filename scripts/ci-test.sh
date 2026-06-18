#!/usr/bin/env bash
# Run the test suite with resilience against an intermittent swift-testing
# runner stall.
#
# The swift-testing runner (the `import Testing` engine SwiftPM uses)
# occasionally wedges: the suite stops making progress with the main
# thread parked in `swift_task_asyncMainDrainQueue` and the test tasks
# suspended -- a scheduler heisenbug in the runner, not in app code. The
# same commit passes on a clean re-run, and a process sample shows the
# main thread IDLE (draining the main queue), not blocked on anything we
# call. Left alone the job runs until GitHub's 6 h timeout, flipping a
# green build red at random and blocking merges.
#
# Strategy: cap each attempt's wall-clock; if it stalls past the cap, kill
# it and retry. A genuine test FAILURE (the runner printed a "... failed"
# / "... N issues" summary) is NOT retried -- only stalls/crashes are, so
# this never hides a real regression.
#
# Tunables (env): CI_TEST_ATTEMPTS (default 3), CI_TEST_CAP_SECONDS
# (default 600; the suite normally finishes in well under 60 s).
set -uo pipefail
cd "$(dirname "$0")/.."

ATTEMPTS="${CI_TEST_ATTEMPTS:-3}"
CAP_SECONDS="${CI_TEST_CAP_SECONDS:-600}"

attempt=0
while [ "$attempt" -lt "$ATTEMPTS" ]; do
  attempt=$((attempt + 1))
  echo "::group::swift test (attempt $attempt/$ATTEMPTS)"
  log="$(mktemp)"
  swift test --no-parallel >"$log" 2>&1 &
  pid=$!

  waited=0
  killed=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 5
    waited=$((waited + 5))
    if [ "$waited" -ge "$CAP_SECONDS" ]; then
      echo "attempt $attempt exceeded ${CAP_SECONDS}s -- swift-testing runner stall; killing and retrying" >&2
      kill -9 "$pid" 2>/dev/null || true
      pkill -9 -f swiftpm-testing-helper 2>/dev/null || true
      killed=1
      break
    fi
  done
  wait "$pid"
  rc=$?
  tail -n 25 "$log" || true
  echo "::endgroup::"

  if [ "$killed" -eq 0 ] && [ "$rc" -eq 0 ]; then
    echo "swift test passed on attempt $attempt"
    rm -f "$log"
    exit 0
  fi

  # Tests ran to completion but reported failures -> a real regression,
  # not a stall. Do not waste retries hiding it.
  if [ "$killed" -eq 0 ] && grep -qE "Test run with .*(failed|[1-9][0-9]* issue)" "$log"; then
    echo "swift test reported real failures -- not a stall, not retrying" >&2
    rm -f "$log"
    exit 1
  fi

  echo "attempt $attempt did not complete cleanly (stall or crash); retrying..." >&2
  rm -f "$log"
done

echo "swift test did not pass after $ATTEMPTS attempts" >&2
exit 1
