#!/usr/bin/env bash
# vm-audio-capture.sh — drive a REAL Unison translation session inside the
# `unison-test` Tart VM (real app, real device render clock, real Gemini/OpenAI
# session), capture the translated playback to a WAV, pull it back, and scan it
# with scripts/analyze_audio.py for clicks / dropouts / sudden RMS jumps / clip.
#
# This is the autonomous "test the audio in a VM without a human" path for the
# LIVE-specific issues (the "внезапные деградации") that don't reproduce in the
# offline dev-machine harness. Clicks are deterministic DSP — prefer DeclickTests
# + `pacing-eval --full-chain-render` for those.
#
# Usage:
#   GEMINI_KEY=AQ.… bash scripts/vm-audio-capture.sh
#   OPENAI_KEY=sk-… PROVIDER=openai bash scripts/vm-audio-capture.sh
#
# Env:
#   GEMINI_KEY / OPENAI_KEY   provider key (matches PROVIDER; required)
#   PROVIDER                  gemini (default) | openai
#   WAIT_SECONDS              session run time before capture (default 35)
#   VM_NAME/VM_USER/VM_PASS   defaults: unison-test/admin/admin
#   KEEP_RUNNING=1            leave the VM up afterwards
#
# Output (host):
#   vm-audio-capture/<provider>-output.wav   translated audio (BlackHole path)
#   vm-audio-capture/<provider>-playback.wav  speakers path (usually silent — no peer audio injected)
#   vm-audio-capture/<provider>.log           Unison log
set -euo pipefail

PROVIDER="${PROVIDER:-gemini}"
WAIT_SECONDS="${WAIT_SECONDS:-35}"
VM_NAME="${VM_NAME:-unison-test}"
VM_USER="${VM_USER:-admin}"
VM_PASS="${VM_PASS:-admin}"
KEEP_RUNNING="${KEEP_RUNNING:-0}"
Q_VM_PASS="$(printf '%q' "$VM_PASS")"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR -o PreferredAuthentications=password -o PubkeyAuthentication=no)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$REPO_DIR/build/Unison.app"
TEST_AUDIO="$REPO_DIR/Tests/Fixtures/test_speech_ru.wav"
OUT_DIR="$REPO_DIR/vm-audio-capture"

log() { printf '\033[1;36m[vm-audio]\033[0m %s\n' "$*" >&2; }
warn(){ printf '\033[1;33m[vm-audio]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m[vm-audio]\033[0m %s\n' "$*" >&2; }

# --- Resolve provider key + settings encoding --------------------------------
case "$PROVIDER" in
  gemini) KEY="${GEMINI_KEY:-}"; KEY_ENV="UNISON_GEMINI_API_KEY"; KC_ACCT="gemini-api-key" ;;
  openai) KEY="${OPENAI_KEY:-}"; KEY_ENV="UNISON_API_KEY";        KC_ACCT="openai-api-key" ;;
  *) err "PROVIDER must be gemini or openai (got: $PROVIDER)"; exit 2 ;;
esac
if [ -z "$KEY" ]; then
  err "No key. Set ${PROVIDER^^}_KEY (e.g. GEMINI_KEY=AQ.… bash scripts/vm-audio-capture.sh)."
  exit 2
fi
Q_KEY="$(printf '%q' "$KEY")"

log "Building pacing-eval (for settings encoding)…"
swift build --product pacing-eval >/dev/null 2>&1
SETTINGS_HEX="$("$REPO_DIR/.build/debug/pacing-eval" --emit-settings-hex "$PROVIDER")"
[ -n "$SETTINGS_HEX" ] || { err "empty settings hex"; exit 1; }

if [ ! -x "$APP_PATH/Contents/MacOS/Unison" ]; then
  log "Building Unison.app via scripts/bundle_app.sh…"
  bash "$REPO_DIR/scripts/bundle_app.sh"
fi
mkdir -p "$OUT_DIR"

# --- VM boot + ssh helpers (mirrors vm-integration-test.sh) -------------------
start_vm_if_needed() {
  local state
  state="$(tart list --format json 2>/dev/null \
            | python3 -c 'import json,sys
for vm in json.load(sys.stdin):
    if vm.get("Name")=="'"$VM_NAME"'":
        print(vm.get("State","unknown")); break' 2>/dev/null || echo unknown)"
  if [ "$state" = "running" ] && [ -n "$(tart ip "$VM_NAME" 2>/dev/null || true)" ]; then
    log "VM \"$VM_NAME\" already running"; return 0
  fi
  log "Starting VM \"$VM_NAME\"…"
  nohup tart run "$VM_NAME" >/tmp/vm-audio.log 2>&1 &
  echo $! > /tmp/vm-audio.pid
}
wait_for_ssh() {
  local deadline=$((SECONDS + 90)) ip=""
  while [ $SECONDS -lt $deadline ]; do
    ip="$(tart ip "$VM_NAME" 2>/dev/null || true)"
    if [ -n "$ip" ] && sshpass -p "$VM_PASS" ssh "${SSH_OPTS[@]}" "$VM_USER@$ip" true >/dev/null 2>&1; then
      echo "$ip"; return 0
    fi
    sleep 2
  done
  err "VM never became reachable (last IP: ${ip:-<none>})"; exit 1
}

start_vm_if_needed
log "Waiting for VM SSH (up to 90s)…"
VM_IP="$(wait_for_ssh)"
log "VM reachable at $VM_IP"
ssh_vm()     { sshpass -p "$VM_PASS" ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" "$@"; }
scp_to_vm()  { sshpass -p "$VM_PASS" scp "${SSH_OPTS[@]}" -r "$1" "$VM_USER@$VM_IP:$2"; }
scp_from_vm(){ sshpass -p "$VM_PASS" scp "${SSH_OPTS[@]}" "$VM_USER@$VM_IP:$1" "$2"; }

# --- Stage app + fixture, wipe state -----------------------------------------
log "Staging app + fixture…"
ssh_vm 'pkill -9 Unison 2>/dev/null; true'; sleep 1
ssh_vm "rm -rf /Users/$VM_USER/Unison.app"
scp_to_vm "$APP_PATH" "/Users/$VM_USER/Unison.app"
ssh_vm "codesign --force --sign - /Users/$VM_USER/Unison.app 2>/dev/null || true"
scp_to_vm "$TEST_AUDIO" "/Users/$VM_USER/test_speech_ru.wav"

log "Wiping state + seeding $PROVIDER settings/key…"
ssh_vm 'bash -c "defaults delete com.unison.app >/dev/null 2>&1 || true; rm -rf ~/Library/Logs/Unison /tmp/unison_*.wav 2>/dev/null || true; true"'
# Seed the translation model into UserDefaults (real Codable-encoded blob) so
# the app boots onto the chosen provider, and the key into the keychain.
ssh_vm bash <<EOF
set -e
defaults write com.unison.app com.unison.settings.v1 -data $SETTINGS_HEX
security delete-generic-password -s com.unison.app -a $KC_ACCT /Users/$VM_USER/Library/Keychains/login.keychain-db >/dev/null 2>&1 || true
security unlock-keychain -p $Q_VM_PASS /Users/$VM_USER/Library/Keychains/login.keychain-db >/dev/null
security add-generic-password -A -s com.unison.app -a $KC_ACCT -w $Q_KEY /Users/$VM_USER/Library/Keychains/login.keychain-db
echo "seeded model=$PROVIDER + key"
EOF

# --- Launch a real translation session with playback capture -----------------
log "Launching Unison (start-translation, ${PROVIDER}, dumping playback)…"
ssh_vm "
  rm -f /tmp/unison_output.wav /tmp/unison_playback.wav 2>/dev/null
  nohup env \
    UNISON_DEV_MODE=1 \
    UNISON_FORCE_STATE=start-translation \
    UNISON_TEST_AUDIO=/Users/$VM_USER/test_speech_ru.wav \
    $KEY_ENV=$Q_KEY \
    UNISON_DUMP_OUTPUT_WAV=/tmp/unison_output.wav \
    UNISON_DUMP_PLAYBACK_WAV=/tmp/unison_playback.wav \
    UNISON_MOCK_PERMISSION_GRANTED=microphone \
    /Users/$VM_USER/Unison.app/Contents/MacOS/Unison >/tmp/unison.log 2>&1 &
  disown
  for i in \$(seq 1 10); do pgrep -x Unison >/dev/null && exit 0; sleep 1; done
  exit 1
"
log "Running session for ${WAIT_SECONDS}s…"
sleep "$WAIT_SECONDS"

# SIGINT first so applicationWillTerminate flushes + patches the WAV headers.
log "Stopping Unison (SIGINT flush, then SIGKILL)…"
ssh_vm 'pkill -INT Unison 2>/dev/null; true'; sleep 3
ssh_vm 'pkill -9 Unison 2>/dev/null; true'

# --- Pull artifacts -----------------------------------------------------------
OUT_WAV="$OUT_DIR/$PROVIDER-output.wav"
PB_WAV="$OUT_DIR/$PROVIDER-playback.wav"
LOG_OUT="$OUT_DIR/$PROVIDER.log"
scp_from_vm "/Users/$VM_USER/Library/Logs/Unison/unison.log" "$LOG_OUT" 2>/dev/null \
  || scp_from_vm "/tmp/unison.log" "$LOG_OUT" 2>/dev/null || true
scp_from_vm "/tmp/unison_output.wav" "$OUT_WAV" 2>/dev/null || warn "no output.wav pulled"
scp_from_vm "/tmp/unison_playback.wav" "$PB_WAV" 2>/dev/null || true

if [ "$KEEP_RUNNING" != "1" ]; then
  log "Stopping VM…"; tart stop "$VM_NAME" >/dev/null 2>&1 || true
fi

# --- Analyze ------------------------------------------------------------------
echo "==================== VM AUDIO CAPTURE ANALYSIS ($PROVIDER) ===================="
for w in "$OUT_WAV" "$PB_WAV"; do
  if [ -s "$w" ]; then
    python3 "$REPO_DIR/scripts/analyze_audio.py" "$w" "VM $PROVIDER — $(basename "$w")" || true
  fi
done
echo ""
log "Artifacts in $OUT_DIR/ — log: $LOG_OUT"
grep -iE "apiKey source|model=|WS close|error|underrun|first delta|deltas" "$LOG_OUT" 2>/dev/null | tail -20 || true
