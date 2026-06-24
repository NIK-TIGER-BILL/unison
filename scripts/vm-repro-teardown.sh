#!/usr/bin/env bash
# vm-repro-teardown.sh — A/B the "only selected" Stop wedge inside the
# unison-test Tart VM (fresh coreaudiod, no host pollution).
#
# Runs `tap-benchmark repro-teardown` twice — GLOBAL (.allExcept) then MIXDOWN
# (.onlySelected) — with a coreaudiod restart between, and prints both logs.
# Each run is backgrounded and force-killed after a timeout, so a wedged
# mixer.stop() can't hang the script; the captured [repro] step=… markers show
# exactly which call blocks.
set -uo pipefail

VM_NAME="${VM_NAME:-unison-test}"
VM_USER="${VM_USER:-admin}"
VM_PASS="${VM_PASS:-admin}"
Q_VM_PASS="$(printf '%q' "$VM_PASS")"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR -o PreferredAuthentications=password -o PubkeyAuthentication=no)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$REPO_DIR/build/TapBenchmark.app"
BIN="/Users/$VM_USER/TapBenchmark.app/Contents/MacOS/tap-benchmark"
RUN_SECS="${RUN_SECS:-16}"   # repro itself runs ~3s of audio + the teardown

log(){ printf '\033[1;36m[vm-repro]\033[0m %s\n' "$*" >&2; }

log "Building TapBenchmark.app…"
bash "$REPO_DIR/scripts/bundle_app.sh" --target tap-benchmark >/dev/null

state="$(tart list --format json 2>/dev/null | python3 -c 'import json,sys
for vm in json.load(sys.stdin):
    if vm.get("Name")=="'"$VM_NAME"'": print(vm.get("State","unknown")); break' 2>/dev/null || echo unknown)"
if [ "$state" != "running" ]; then
  log "Booting VM…"; nohup tart run "$VM_NAME" >/tmp/vm-repro.log 2>&1 & sleep 1
fi

log "Waiting for SSH…"
VM_IP=""; deadline=$((SECONDS+120))
while [ $SECONDS -lt $deadline ]; do
  VM_IP="$(tart ip "$VM_NAME" 2>/dev/null || true)"
  [ -n "$VM_IP" ] && sshpass -p "$VM_PASS" ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" true >/dev/null 2>&1 && break
  sleep 2
done
[ -z "$VM_IP" ] && { log "VM unreachable"; exit 1; }
log "VM at $VM_IP"
ssh_vm(){ sshpass -p "$VM_PASS" ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" "$@"; }

log "Staging app + entitlements + TCC…"
ssh_vm "rm -rf /Users/$VM_USER/TapBenchmark.app"
sshpass -p "$VM_PASS" scp "${SSH_OPTS[@]}" -r "$APP_PATH" "$VM_USER@$VM_IP:/Users/$VM_USER/TapBenchmark.app" >/dev/null
ssh_vm "codesign --force --sign - --preserve-metadata=entitlements /Users/$VM_USER/TapBenchmark.app 2>/dev/null || true"
ssh_vm "printf '%s\n' $Q_VM_PASS | sudo -S tccutil reset AudioCapture com.unison.tapbench 2>/dev/null; printf '%s\n' $Q_VM_PASS | sudo -S tccutil reset Microphone com.unison.tapbench 2>/dev/null; true" >/dev/null 2>&1 || true

run_repro(){
  local flag="$1" name="$2"
  local out="/tmp/repro-$name.out"
  log "=== running repro: $name ==="
  ssh_vm "
    printf '%s\n' $Q_VM_PASS | sudo -S launchctl asuser \$(id -u $VM_USER) \
      /bin/sh -c 'pkill tap-benchmark 2>/dev/null; VM_BENCHMARK=1 $BIN repro-teardown $flag > $out 2>&1 &'
    sleep $RUN_SECS
    echo '----- $name output -----'
    cat $out 2>/dev/null || echo '(no output)'
    echo '----- end $name (pkill) -----'
    pkill -9 tap-benchmark 2>/dev/null || true
  "
}

restart_ca(){ log "Restarting coreaudiod in VM…"; ssh_vm "printf '%s\n' $Q_VM_PASS | sudo -S launchctl kickstart -kp system/com.apple.audio.coreaudiod 2>/dev/null || true"; sleep 5; }

# Isolate the wedge: simple graph (player→mixer) vs +timePitch (the node
# AVAudioOutputMixer inserts), both with plain engine.stop(), on a mixdown tap.
run_repro "" "simple-graph"
restart_ca
run_repro "--timepitch" "with-timepitch"
restart_ca
# If timePitch is the culprit, does pause/reset rescue it?
run_repro "--timepitch --teardown pause" "timepitch-pause"
restart_ca
run_repro "--timepitch --teardown reset" "timepitch-reset"

log "Done. (VM left running; stop with: tart stop $VM_NAME)"
