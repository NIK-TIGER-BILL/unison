#!/usr/bin/env bash
# vm-repro-devicechange.sh — does a default-output-device change (what
# connecting BT headphones does) kill the production AVAudioOutputMixer engine?
# Runs `tap-benchmark repro-devicechange` in the unison-test Tart VM.
#
# Usage: scripts/vm-repro-devicechange.sh [--fresh]   (--fresh = reboot the VM first)
set -uo pipefail

FRESH=0; [ "${1:-}" = "--fresh" ] && FRESH=1
VM_NAME="${VM_NAME:-unison-test}"
VM_USER="${VM_USER:-admin}"
VM_PASS="${VM_PASS:-admin}"
Q_VM_PASS="$(printf '%q' "$VM_PASS")"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR -o PreferredAuthentications=password -o PubkeyAuthentication=no)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$REPO_DIR/build/TapBenchmark.app"
BIN="/Users/$VM_USER/TapBenchmark.app/Contents/MacOS/tap-benchmark"
RUN_SECS="${RUN_SECS:-18}"

log(){ printf '\033[1;36m[vm-devrepro]\033[0m %s\n' "$*" >&2; }

log "Building TapBenchmark.app…"
bash "$REPO_DIR/scripts/bundle_app.sh" --target tap-benchmark >/dev/null

vm_state(){ tart list --format json 2>/dev/null | python3 -c 'import json,sys
for vm in json.load(sys.stdin):
    if vm.get("Name")=="'"$VM_NAME"'": print(vm.get("State","unknown")); break' 2>/dev/null || echo unknown; }

if [ "$FRESH" = "1" ]; then
  log "Fresh boot…"; tart stop "$VM_NAME" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do [ "$(vm_state)" != "running" ] && break; sleep 1; done
fi
if [ "$(vm_state)" != "running" ]; then
  log "Booting VM…"; nohup tart run "$VM_NAME" >/tmp/vm-devrepro-boot.log 2>&1 & sleep 2
fi

log "Waiting for SSH…"
VM_IP=""; deadline=$((SECONDS+150))
while [ $SECONDS -lt $deadline ]; do
  VM_IP="$(tart ip "$VM_NAME" 2>/dev/null || true)"
  [ -n "$VM_IP" ] && sshpass -p "$VM_PASS" ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" true >/dev/null 2>&1 && break
  sleep 2
done
[ -z "$VM_IP" ] && { log "VM unreachable"; exit 1; }
log "VM at $VM_IP"
ssh_vm(){ for _ in 1 2 3; do sshpass -p "$VM_PASS" ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" "$@" && return 0; sleep 1; done; return 1; }

log "Staging app…"
ssh_vm "rm -rf /Users/$VM_USER/TapBenchmark.app" >/dev/null 2>&1
sshpass -p "$VM_PASS" scp "${SSH_OPTS[@]}" -r "$APP_PATH" "$VM_USER@$VM_IP:/Users/$VM_USER/TapBenchmark.app" >/dev/null 2>&1
ssh_vm "codesign --force --sign - --preserve-metadata=entitlements /Users/$VM_USER/TapBenchmark.app 2>/dev/null || true" >/dev/null 2>&1

log "Running repro-devicechange…"
out="/tmp/devrepro.out"
ssh_vm "
  printf '%s\n' $Q_VM_PASS | sudo -S launchctl asuser \$(id -u $VM_USER) \
    /bin/sh -c 'pkill tap-benchmark 2>/dev/null; VM_BENCHMARK=1 $BIN repro-devicechange > $out 2>&1 &'
  sleep $RUN_SECS
  echo '----- repro-devicechange output -----'
  cat $out 2>/dev/null || echo '(no output)'
  echo '----- end -----'
  pkill -9 tap-benchmark 2>/dev/null || true
"
