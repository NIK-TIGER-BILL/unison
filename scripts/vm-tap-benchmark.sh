#!/usr/bin/env bash
# vm-tap-benchmark.sh — runs tap-benchmark inside the `unison-test`
# Tart VM and pulls back results.json.
#
# Usage:
#   bash scripts/vm-tap-benchmark.sh                          # with-blackhole, 30s duration
#   bash scripts/vm-tap-benchmark.sh --scenario without-blackhole --duration 60
#   bash scripts/vm-tap-benchmark.sh --keep-running            # leave VM up afterwards
#
# Options:
#   --scenario {with-blackhole|without-blackhole|sanity-zoom}  default: with-blackhole
#   --duration N                                                default: 30
#   --keep-running                                              don't stop the VM at the end
#
# Env vars:
#   VM_NAME, VM_USER, VM_PASS                                   defaults: unison-test/admin/admin
#
# Output:
#   vm-tap-benchmark/<timestamp>.json on the host.

set -euo pipefail

VM_NAME="${VM_NAME:-unison-test}"
VM_USER="${VM_USER:-admin}"
VM_PASS="${VM_PASS:-admin}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$REPO_DIR/build/TapBenchmark.app"
OUT_DIR="$REPO_DIR/vm-tap-benchmark"

SCENARIO="with-blackhole"
DURATION="30"
KEEP_RUNNING=0

log() { printf '\033[1;36m[vm-tap-bench]\033[0m %s\n' "$*" >&2; }
warn(){ printf '\033[1;33m[vm-tap-bench]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m[vm-tap-bench]\033[0m %s\n' "$*" >&2; }

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario)
      SCENARIO="$2"
      shift 2
      ;;
    --duration)
      DURATION="$2"
      shift 2
      ;;
    --keep-running)
      KEEP_RUNNING=1
      shift
      ;;
    -h|--help)
      cat <<'USAGE'
Usage: vm-tap-benchmark.sh [options]

Options:
  --scenario {with-blackhole|without-blackhole|sanity-zoom}  default: with-blackhole
  --duration N                                                default: 30
  --keep-running                                              don't stop the VM at the end

Env vars:
  VM_NAME, VM_USER, VM_PASS                                   defaults: unison-test/admin/admin
USAGE
      exit 0
      ;;
    *)
      err "Unknown arg: $1"
      exit 1
      ;;
  esac
done

# Validate scenario
case "$SCENARIO" in
  with-blackhole|without-blackhole|sanity-zoom)
    ;;
  *)
    err "Invalid scenario: $SCENARIO"
    err "Valid: with-blackhole, without-blackhole, sanity-zoom"
    exit 2
    ;;
esac

# Cleanup trap
cleanup() {
  if [ "$KEEP_RUNNING" = "0" ]; then
    log "Stopping VM..."
    tart stop "$VM_NAME" 2>/dev/null || true
  fi
}
trap cleanup EXIT

mkdir -p "$OUT_DIR"

# --- 1. Build TapBenchmark.app if missing ----------------------------------------
if [ ! -d "$APP_PATH" ] || [ ! -x "$APP_PATH/Contents/MacOS/tap-benchmark" ]; then
  log "Building TapBenchmark.app via scripts/bundle_app.sh…"
  bash "$REPO_DIR/scripts/bundle_app.sh" --target tap-benchmark
fi

# --- 2. Boot the VM if not already running ---------------------------------------
start_vm_if_needed() {
  if tart_ip="$(tart ip "$VM_NAME" 2>/dev/null)" && [ -n "${tart_ip:-}" ]; then
    log "VM \"$VM_NAME\" already running at $tart_ip"
    return 0
  fi
  log "Starting VM \"$VM_NAME\" in background…"
  nohup tart run "$VM_NAME" >"$OUT_DIR/.vm.log" 2>&1 &
  echo $! >"$OUT_DIR/.vm.pid"
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

# --- 3. Stage app in the VM ------------------------------------------------------
log "Copying TapBenchmark.app into VM…"
ssh_vm "rm -rf /Users/$VM_USER/TapBenchmark.app"
scp_to_vm "$APP_PATH" "/Users/$VM_USER/TapBenchmark.app"
ssh_vm "codesign --force --sign - /Users/$VM_USER/TapBenchmark.app 2>/dev/null || true"

# --- 4. Configure scenario (BlackHole presence) -----------------------------------
case "$SCENARIO" in
  with-blackhole)
    log "Ensuring BlackHole 16ch is installed in the VM…"
    ssh_vm "
      if [ ! -d /Library/Audio/Plug-Ins/HAL/BlackHole16ch.driver ]; then
        echo 'BlackHole 16ch not found in VM — benchmark will skip BlackHole phase'
      fi
    " || true
    ;;
  without-blackhole)
    log "Removing BlackHole 16ch from VM (if present)…"
    ssh_vm "
      echo $VM_PASS | sudo -S rm -rf /Library/Audio/Plug-Ins/HAL/BlackHole16ch.driver 2>/dev/null || true
      echo $VM_PASS | sudo -S launchctl kickstart -kp system/com.apple.audio.coreaudiod 2>/dev/null || true
    " || true
    ;;
  sanity-zoom)
    log "(sanity-zoom requires Zoom installed and running in VM — manual step)"
    ;;
esac

# --- 5. Pre-grant TCC audio capture permission ------------------------------------
log "Pre-granting TCC audio capture…"
ssh_vm "
  echo $VM_PASS | sudo -S tccutil reset Microphone com.unison.tapbench 2>/dev/null || true
" || true

# --- 6. Run the benchmark --------------------------------------------------------
RESULT_FILE="results-$(date +%s).json"
log "Running benchmark inside VM (scenario=$SCENARIO duration=${DURATION}s)…"

if [ "$SCENARIO" = "sanity-zoom" ]; then
  ssh_vm "
    VM_BENCHMARK=1 /Users/$VM_USER/TapBenchmark.app/Contents/MacOS/tap-benchmark sanity-check
  " || true
else
  ssh_vm "
    VM_BENCHMARK=1 /Users/$VM_USER/TapBenchmark.app/Contents/MacOS/tap-benchmark \
      --duration $DURATION --phase both --silent --json-out ~/$RESULT_FILE
  " || true

  # Pull results back
  if ssh_vm "[ -f ~/$RESULT_FILE ]" >/dev/null 2>&1; then
    scp_from_vm "~/$RESULT_FILE" "$OUT_DIR/$RESULT_FILE"
    log "Results saved to $OUT_DIR/$RESULT_FILE"
  else
    warn "Benchmark did not produce results file (may have crashed or timed out)"
  fi
fi
