#!/usr/bin/env bash
# vm-verify-fix.sh — confirm the production AVAudioOutputMixer.stop() (reset-based)
# no longer wedges Stop after a mixdown ("only selected") process tap.
#
# Methodology mirrors the A/B that found the bug: FRESH-BOOT the VM before each
# rep (the wedge is deterministic only from a clean coreaudiod), then run the
# production mixer path `tap-benchmark repro-teardown --mixer`. Each run is
# backgrounded and force-killed after a timeout, so a (regressed) wedge can't
# hang the script. Pass = every rep prints "NO WEDGE (mixer)".
#
# Usage: scripts/vm-verify-fix.sh [REPS]   (default 3)
set -uo pipefail

REPS="${1:-3}"
VM_NAME="${VM_NAME:-unison-test}"
VM_USER="${VM_USER:-admin}"
VM_PASS="${VM_PASS:-admin}"
Q_VM_PASS="$(printf '%q' "$VM_PASS")"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR -o PreferredAuthentications=password -o PubkeyAuthentication=no)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$REPO_DIR/build/TapBenchmark.app"
BIN="/Users/$VM_USER/TapBenchmark.app/Contents/MacOS/tap-benchmark"
RUN_SECS="${RUN_SECS:-16}"

log(){ printf '\033[1;36m[vm-verify]\033[0m %s\n' "$*" >&2; }

log "Building TapBenchmark.app…"
bash "$REPO_DIR/scripts/bundle_app.sh" --target tap-benchmark >/dev/null

vm_state(){ tart list --format json 2>/dev/null | python3 -c 'import json,sys
for vm in json.load(sys.stdin):
    if vm.get("Name")=="'"$VM_NAME"'": print(vm.get("State","unknown")); break' 2>/dev/null || echo unknown; }

fresh_boot(){
  log "Fresh boot (stop + run)…"
  tart stop "$VM_NAME" >/dev/null 2>&1 || true
  # wait until actually stopped
  for _ in $(seq 1 30); do [ "$(vm_state)" != "running" ] && break; sleep 1; done
  nohup tart run "$VM_NAME" >/tmp/vm-verify-boot.log 2>&1 &
  sleep 2
}

wait_ssh(){
  VM_IP=""; local deadline=$((SECONDS+150))
  while [ $SECONDS -lt $deadline ]; do
    VM_IP="$(tart ip "$VM_NAME" 2>/dev/null || true)"
    [ -n "$VM_IP" ] && sshpass -p "$VM_PASS" ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" true >/dev/null 2>&1 && return 0
    sleep 2
  done
  log "VM unreachable"; return 1
}
ssh_vm(){ for _ in 1 2 3; do sshpass -p "$VM_PASS" ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" "$@" && return 0; sleep 1; done; return 1; }

stage_app(){
  log "Staging app + entitlements + TCC…"
  ssh_vm "rm -rf /Users/$VM_USER/TapBenchmark.app" >/dev/null 2>&1
  sshpass -p "$VM_PASS" scp "${SSH_OPTS[@]}" -r "$APP_PATH" "$VM_USER@$VM_IP:/Users/$VM_USER/TapBenchmark.app" >/dev/null 2>&1
  ssh_vm "codesign --force --sign - --preserve-metadata=entitlements /Users/$VM_USER/TapBenchmark.app 2>/dev/null || true" >/dev/null 2>&1
  ssh_vm "printf '%s\n' $Q_VM_PASS | sudo -S tccutil reset AudioCapture com.unison.tapbench 2>/dev/null; true" >/dev/null 2>&1 || true
}

run_mixer(){
  local out="/tmp/verify-mixer.out"
  ssh_vm "
    printf '%s\n' $Q_VM_PASS | sudo -S launchctl asuser \$(id -u $VM_USER) \
      /bin/sh -c 'pkill tap-benchmark 2>/dev/null; VM_BENCHMARK=1 $BIN repro-teardown --mixer > $out 2>&1 &'
    sleep $RUN_SECS
    echo '----- mixer output -----'
    cat $out 2>/dev/null || echo '(no output)'
    echo '----- end mixer -----'
    pkill -9 tap-benchmark 2>/dev/null || true
  "
}

PASS=0; FAIL=0
for rep in $(seq 1 "$REPS"); do
  log "================= REP $rep / $REPS ================="
  fresh_boot
  wait_ssh || { log "rep $rep: SSH failed"; FAIL=$((FAIL+1)); continue; }
  log "VM at $VM_IP"
  stage_app
  result="$(run_mixer)"
  echo "$result"
  if echo "$result" | grep -q "NO WEDGE (mixer)"; then
    log "rep $rep: ✅ OK (no wedge)"; PASS=$((PASS+1))
  else
    log "rep $rep: ❌ WEDGED (mixer.stop did not return)"; FAIL=$((FAIL+1))
  fi
done

log "================= SUMMARY ================="
log "PASS=$PASS  FAIL=$FAIL  (of $REPS reps)"
[ "$FAIL" -eq 0 ] && { log "✅ FIX VERIFIED — production mixer.stop() never wedged"; exit 0; } || { log "❌ regression — mixer.stop() still wedges"; exit 1; }
