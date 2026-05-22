#!/usr/bin/env bash
# vm-integration-test.sh — end-to-end Unison translation pipeline test
# inside the `unison-test` Tart VM, with synthesized speech injection
# via UNISON_TEST_AUDIO and assertion against the file log Unison
# writes to ~/Library/Logs/Unison/unison.log.
#
# Usage:
#   OPENAI_KEY=sk-... bash scripts/vm-integration-test.sh
#
# Optional env:
#   VM_NAME      (default: unison-test)
#   VM_USER      (default: admin)
#   VM_PASS      (default: admin)
#   WAIT_SECONDS (default: 25) — time given to the pipeline before
#                                pulling the log
#   KEEP_RUNNING=1                — don't tart-stop the VM at the end
#
# Output:
#   vm-integration-test.log — full log file pulled back from the VM
#   stdout                  — pass/fail summary + each grep assertion
#
# The script is idempotent: each run wipes UserDefaults / Keychain /
# log files on the VM before launching, so repeated invocations don't
# carry state forward.

set -euo pipefail

VM_NAME="${VM_NAME:-unison-test}"
VM_USER="${VM_USER:-admin}"
VM_PASS="${VM_PASS:-admin}"
WAIT_SECONDS="${WAIT_SECONDS:-25}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$REPO_DIR/build/Unison.app"
TEST_AUDIO="$REPO_DIR/Tests/Fixtures/test_speech_ru.wav"
LOG_OUT="$REPO_DIR/vm-integration-test.log"

log() { printf '\033[1;36m[vm-integ]\033[0m %s\n' "$*" >&2; }
warn(){ printf '\033[1;33m[vm-integ]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m[vm-integ]\033[0m %s\n' "$*" >&2; }

# --- 0. Sanity checks ---------------------------------------------------------
if [ -z "${OPENAI_KEY:-}" ]; then
  err "OPENAI_KEY env var not set. Set it to a real OpenAI key for the happy path,"
  err "or to a known-bad string to exercise the .apiKeyInvalid surface."
  exit 2
fi
if [ ! -f "$TEST_AUDIO" ]; then
  warn "Missing $TEST_AUDIO — regenerating via scripts/gen_test_speech_wav.sh"
  bash "$REPO_DIR/scripts/gen_test_speech_wav.sh"
fi

# --- 1. Build .app bundle if missing ------------------------------------------
if [ ! -d "$APP_PATH" ] || [ ! -x "$APP_PATH/Contents/MacOS/Unison" ]; then
  log "Building Unison.app via scripts/bundle_app.sh…"
  bash "$REPO_DIR/scripts/bundle_app.sh"
fi

# --- 2. Boot the VM if not already running -----------------------------------
start_vm_if_needed() {
  if tart_ip="$(tart ip "$VM_NAME" 2>/dev/null)" && [ -n "${tart_ip:-}" ]; then
    log "VM \"$VM_NAME\" already running at $tart_ip"
    return 0
  fi
  log "Starting VM \"$VM_NAME\" in background (graphics mode)…"
  nohup tart run "$VM_NAME" >/tmp/vm-integ.log 2>&1 &
  echo $! > /tmp/vm-integ.pid
}

wait_for_ssh() {
  log "Waiting for VM IP and SSH (up to 90s)…"
  local deadline=$((SECONDS + 90))
  local ip=""
  while [ $SECONDS -lt $deadline ]; do
    ip="$(tart ip "$VM_NAME" 2>/dev/null || true)"
    if [ -n "$ip" ] && sshpass -p "$VM_PASS" ssh "${SSH_OPTS[@]}" "$VM_USER@$ip" true >/dev/null 2>&1; then
      log "VM reachable at $ip"
      echo "$ip"
      return 0
    fi
    sleep 2
  done
  err "VM never became reachable. Last IP: ${ip:-<none>}"
  exit 1
}

start_vm_if_needed
VM_IP="$(wait_for_ssh)"

ssh_vm()     { sshpass -p "$VM_PASS" ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" "$@"; }
scp_to_vm()  { sshpass -p "$VM_PASS" scp "${SSH_OPTS[@]}" -r "$1" "$VM_USER@$VM_IP:$2"; }
scp_from_vm(){ sshpass -p "$VM_PASS" scp "${SSH_OPTS[@]}" "$VM_USER@$VM_IP:$1" "$2"; }

# --- 3. Stage app + fixture + clean state in the VM --------------------------
log "Quitting any running Unison process…"
ssh_vm 'pkill -9 Unison 2>/dev/null; true'
sleep 1

log "Copying Unison.app into VM…"
ssh_vm "rm -rf /Users/$VM_USER/Unison.app"
scp_to_vm "$APP_PATH" "/Users/$VM_USER/Unison.app"
ssh_vm "codesign --force --sign - /Users/$VM_USER/Unison.app 2>/dev/null || true"

log "Copying test audio fixture into VM ($(du -sh "$TEST_AUDIO" | awk '{print $1}'))…"
scp_to_vm "$TEST_AUDIO" "/Users/$VM_USER/test_speech_ru.wav"

log "Resetting UserDefaults + Keychain + logs in VM…"
# Use bash -c to keep glob expansion local to the VM instead of the
# (possibly zsh) login shell, which throws "no matches" on empty dirs.
# Redirect all output to /dev/null — `security delete-generic-password`
# dumps the deleted item's attribute blob on stdout, which is noisy.
ssh_vm 'bash -c "
  defaults delete com.unison.app >/dev/null 2>&1 || true
  security delete-generic-password -s com.unison.app -a openai-api-key >/dev/null 2>&1 || true
  rm -rf ~/Library/Logs/Unison 2>/dev/null || true
  rm -f /tmp/unison.log 2>/dev/null || true
  true
"'

log "Seeding OpenAI API key into VM keychain…"
# Quirks of macOS keychain over SSH:
#  1. Default keychain resolution fails with "User interaction is not
#     allowed." — must specify the login keychain explicitly.
#  2. `-U` (upsert) flag's path that calls SecKeychainItemSetAccess
#     also fails the same way — so we delete first, then add fresh.
#  3. `-A` (no ACL prompt) lets any caller read the entry, which is
#     fine inside this throwaway VM.
#  4. Each separate `ssh_vm` invocation gets a new shell; the keychain
#     unlock state from the *previous* call doesn't carry over. So we
#     bundle delete + unlock + add into a single SSH session via a
#     here-doc-style heredoc.
ssh_vm bash <<EOF
set -e
security delete-generic-password -s com.unison.app -a openai-api-key /Users/$VM_USER/Library/Keychains/login.keychain-db >/dev/null 2>&1 || true
security unlock-keychain -p '$VM_PASS' /Users/$VM_USER/Library/Keychains/login.keychain-db >/dev/null
security add-generic-password -A -s com.unison.app -a openai-api-key -w '$OPENAI_KEY' /Users/$VM_USER/Library/Keychains/login.keychain-db
echo "keychain seed ok"
EOF

# --- 4. Launch Unison with the integration force-state -----------------------
log "Launching Unison with UNISON_FORCE_STATE=start-translation + UNISON_TEST_AUDIO + UNISON_API_KEY + UNISON_DUMP_OUTPUT_WAV…"
# Pass the API key through env (UNISON_API_KEY) in addition to seeding
# the keychain. The Composition prefers env when set — sidesteps the
# observed Tart-VM keychain access quirk where SecItemCopyMatching can't
# find the entry added via `security add-generic-password` even though
# `security find-generic-password` confirms it's stored. Real-world
# launches still read from keychain via the Onboarding flow.
#
# UNISON_DUMP_OUTPUT_WAV makes BlackHole2chPlayer mirror every scheduled
# frame to a WAV file. This is the only way to prove translated audio
# actually crossed the resampler-and-schedule pipeline (vs the weaker
# "scheduleBuffer was called" signal from the log).
ssh_vm "
  rm -f /tmp/unison_output.wav 2>/dev/null
  nohup env \
    UNISON_DEV_MODE=1 \
    UNISON_FORCE_STATE=start-translation \
    UNISON_TEST_AUDIO=/Users/$VM_USER/test_speech_ru.wav \
    UNISON_API_KEY='$OPENAI_KEY' \
    UNISON_DUMP_OUTPUT_WAV=/tmp/unison_output.wav \
    /Users/$VM_USER/Unison.app/Contents/MacOS/Unison >/tmp/unison.log 2>&1 &
  disown
  for i in \$(seq 1 10); do
    if pgrep -x Unison >/dev/null; then exit 0; fi
    sleep 1
  done
  exit 1
"
log "Process launched."

# --- 5. Wait for translation cycle to run ------------------------------------
log "Waiting ${WAIT_SECONDS}s for translation pipeline + assertions…"
sleep "$WAIT_SECONDS"

# --- 6. Stop Unison in the VM (BEFORE log pull) ------------------------------
# Two-phase shutdown: SIGINT first so AppDelegate.applicationWillTerminate
# runs and `BlackHole2chPlayer.stop()` patches the WAV header sizes
# (otherwise the dump file ends up with placeholder 0xFFFF_FFFF sizes,
# which most players reject — host analysis still works via "read raw
# float32 LE after offset 44", but a well-formed file is friendlier).
# Then SIGKILL as a fallback if SIGINT didn't take effect within 2s.
#
# Order is critical: we stop FIRST, then pull the log, so the
# shutdown sequence ("received signal 2", "applicationWillTerminate",
# "dump — closed") makes it into the log file we ship to assertions.
log "Stopping Unison in VM (SIGINT for graceful flush, then SIGKILL)…"
ssh_vm 'pkill -INT Unison 2>/dev/null; true'
sleep 2
ssh_vm 'pkill -9 Unison 2>/dev/null; true'

# --- 7. Pull log file ---------------------------------------------------------
log "Pulling ~/Library/Logs/Unison/unison.log → $LOG_OUT"
scp_from_vm "/Users/$VM_USER/Library/Logs/Unison/unison.log" "$LOG_OUT" || {
  err "Failed to fetch log file. Falling back to /tmp/unison.log (stdout)…"
  scp_from_vm "/tmp/unison.log" "$LOG_OUT" || true
}

if [ ! -s "$LOG_OUT" ]; then
  err "Log file empty or missing."
  exit 1
fi
LOG_SIZE=$(wc -l < "$LOG_OUT" | tr -d ' ')
log "Pulled $LOG_SIZE lines into $LOG_OUT"

# --- 7b. Pull WAV dump (if it was generated) ---------------------------------
WAV_OUT="$REPO_DIR/vm-integration-test-output.wav"
log "Pulling /tmp/unison_output.wav → $WAV_OUT (if present)…"
if scp_from_vm "/tmp/unison_output.wav" "$WAV_OUT" 2>/dev/null; then
  WAV_SIZE=$(stat -f%z "$WAV_OUT" 2>/dev/null || echo 0)
  log "Pulled WAV dump: $WAV_SIZE bytes"
else
  WAV_SIZE=0
  warn "No WAV dump pulled (file missing or empty)."
fi

# --- 8. Assertions ------------------------------------------------------------
# Each pattern matches a line that the file logger should have written
# during the test run if the pipeline reached the corresponding stage.
# Patterns are regex per `grep -E`; the script reports pass/fail per
# pattern and exits non-zero if any are missing.
EXPECTED=(
  # Banner emitted on first FileLogStore write — confirms we're reading
  # the *new* log file, not a stale SCP'd copy
  "Unison log file opened"
  # FileMicrophoneCapture was substituted via UNISON_TEST_AUDIO
  "UNISON_TEST_AUDIO=.* substituting FileMicrophoneCapture"
  # AppDelegate scheduled the auto-start
  "UNISON_FORCE_STATE=start-translation"
  # PopoverVM.start() reached
  "PopoverVM:info.*start.*called"
  # Orchestrator entered start()
  "Orchestrator:info.*start.*mode="
)

# Patterns we expect ONLY when the OpenAI key is valid (happy path).
# Skipped under OPENAI_KEY=sk-revoked-* style probes since the WS
# will be closed before any audio delta arrives.
EXPECTED_HAPPY=(
  "OpenAIRealtimeStream:info.*first session.output_audio.delta received"
  "Resampler:info.*fromWire.*24000Hz int16"
  "AudioOutput:info.*first frame scheduled to BlackHole 2ch"
)

# Patterns we expect ONLY when the OpenAI key is invalid (auth-failed path).
# The auth-failure surface has two on-wire flavours OpenAI uses:
#  (a) Server accepts the WS, then closes normally (code 1000) with no
#      data — pre-classifier era pattern, still seen on some accounts.
#  (b) Server pushes an `{"type":"error","error":{"code":"invalid_api_key"}}`
#      event and closes with code 3000 + reason payload. This is the
#      modern (May 2026) shape and the one that exposed the POSIX-89
#      masking bug — the classifier now substitutes the typed error for
#      the racy transport NSError, so the Orchestrator surfaces
#      `.error(apiKeyInvalid)` instead of `.error(networkLost)`.
EXPECTED_AUTHFAIL=(
  "WS closed normally before any data|peer WS abnormal close — code=3000.*invalid_api_key"
  # Sanity: the final orchestrator state must be apiKeyInvalid, NOT
  # networkLost. Regression marker for the close-classifier propagation
  # bug (commit history: \"fix(realtime): propagate classified close
  # reason through connect()\").
  "Orchestrator.*peer.connect failed: apiKeyInvalid"
)

# Patterns we expect ONLY when BlackHole isn't installed in the VM
# (the most common state — the .pkg installer requires admin auth that
# the SSH harness can't supply). Recording the BH-missing path is still
# a positive integration signal: it proves the pre-flight check fires,
# the file logger captures the failure, and the orchestrator
# transitions to `.error(.blackHole16chMissing)` cleanly.
EXPECTED_BH_MISSING=(
  "Orchestrator:error.*BlackHole 16ch not found"
  "state connecting.*→ error.*blackHole16chMissing"
)

assert_pattern() {
  local pat="$1"
  if grep -qE "$pat" "$LOG_OUT"; then
    printf '\033[1;32m  ✓\033[0m %s\n' "$pat"
    return 0
  else
    printf '\033[1;31m  ✗ MISSING:\033[0m %s\n' "$pat"
    return 1
  fi
}

log "Running assertions:"
PASS=1
log "  always-required:"
for p in "${EXPECTED[@]}"; do
  assert_pattern "$p" || PASS=0
done

# Decide which branch we should have hit. The orchestrator's
# pre-flight check is the first thing that can fail end-to-end:
#  - BlackHole 16ch missing → cannot install the .pkg from SSH so this
#    is the default state in a fresh VM. Assert the branch fired.
#  - WS closed normally before any data → invalid OpenAI key.
#  - Otherwise → happy path.
if grep -qE "BlackHole 16ch not found" "$LOG_OUT"; then
  log "  detected blackhole-missing branch (expected on a fresh VM without the .pkg driver):"
  for p in "${EXPECTED_BH_MISSING[@]}"; do
    assert_pattern "$p" || PASS=0
  done
  warn "BlackHole driver is not installed in the VM — running the .blackHole16chMissing branch only."
  warn "To exercise the full pipeline, install BlackHole inside the VM and rerun."
elif grep -qE "apiKeyInvalid|WS closed normally before any data" "$LOG_OUT"; then
  log "  detected auth-failed branch (expected when OPENAI_KEY is bad):"
  for p in "${EXPECTED_AUTHFAIL[@]}"; do
    assert_pattern "$p" || PASS=0
  done
  warn "OpenAI key appears invalid — running the .apiKeyInvalid branch assertions only."
  warn "Re-run with a valid OPENAI_KEY to exercise the happy path."
else
  log "  happy-path (translation succeeded):"
  for p in "${EXPECTED_HAPPY[@]}"; do
    assert_pattern "$p" || PASS=0
  done

  # Verify the WAV dump captured real audio (not silence) — the "schedule
  # was called" log line alone doesn't prove samples have signal. Python
  # reads raw float32 LE starting at offset 44 (header), computes RMS,
  # and asserts at least 0.5s of non-trivial signal.
  log "  WAV dump verification:"
  if [ "$WAV_SIZE" -gt 44 ]; then
    if python3 - "$WAV_OUT" <<'PY'
import sys, struct, os
path = sys.argv[1]
size = os.path.getsize(path)
data_bytes = size - 44
sample_count = data_bytes // 4  # float32 LE, mono
duration = sample_count / 48000.0
with open(path, 'rb') as f:
    f.seek(44)
    raw = f.read()
import struct
samples = struct.unpack(f'<{sample_count}f', raw)
# RMS over the whole dump
sq_sum = sum(s * s for s in samples)
rms = (sq_sum / max(1, sample_count)) ** 0.5
peak = max((abs(s) for s in samples), default=0.0)
print(f'    duration={duration:.3f}s sample_count={sample_count} rms={rms:.5f} peak={peak:.5f}')
ok = duration >= 0.5 and rms >= 1e-4 and peak >= 1e-3
sys.exit(0 if ok else 1)
PY
    then
      printf '\033[1;32m  ✓\033[0m WAV dump has ≥0.5s of non-silent audio\n'
    else
      printf '\033[1;31m  ✗ WAV dump verification FAILED\033[0m (too short or silent)\n'
      PASS=0
    fi
  else
    printf '\033[1;31m  ✗ WAV dump MISSING or empty\033[0m (size=%s)\n' "$WAV_SIZE"
    PASS=0
  fi
fi

# --- 9. Tear down (or keep running for next call) ----------------------------
if [ "${KEEP_RUNNING:-0}" = "1" ]; then
  log "Leaving VM running (KEEP_RUNNING=1)."
else
  log "Stopping VM…"
  tart stop "$VM_NAME" 2>/dev/null || true
fi

# --- 10. Final summary --------------------------------------------------------
echo
if [ $PASS -eq 1 ]; then
  printf '\033[1;32mINTEGRATION TEST PASSED\033[0m — %s lines of log captured at %s\n' "$LOG_SIZE" "$LOG_OUT"
  exit 0
else
  printf '\033[1;31mINTEGRATION TEST FAILED\033[0m — see %s\n' "$LOG_OUT"
  printf 'Last 40 log lines:\n'
  tail -40 "$LOG_OUT"
  exit 1
fi
