#!/usr/bin/env bash
# vm-screenshot.sh — capture Unison.app UI surfaces inside a Tart VM.
#
# Boots the `unison-test` VM in graphics mode, SCPs the locally-built
# .app bundle inside, then launches it once per requested screen with
# the appropriate UNISON_FORCE_STATE / UNISON_DEV_MODE env vars and
# pulls back a PNG via `screencapture`.
#
# Usage:
#   bash scripts/vm-screenshot.sh                          # capture all screens
#   bash scripts/vm-screenshot.sh popover settings         # capture a subset
#   bash scripts/vm-screenshot.sh --keep-running popover   # leave VM up afterwards
#
# Output:
#   vm-screenshots/<name>.png on the host.
#
# Recognised screen names: popover, onboarding-pending, onboarding-done,
# settings, transcript, menubar.

set -euo pipefail

VM_NAME="${VM_NAME:-unison-test}"
VM_USER="${VM_USER:-admin}"
VM_PASS="${VM_PASS:-admin}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$REPO_DIR/build/Unison.app"
SHOTS_DIR="$REPO_DIR/vm-screenshots"
VM_PID_FILE="$SHOTS_DIR/.vm.pid"
VM_LOG_FILE="$SHOTS_DIR/.vm.log"

ALL_SCREENS=(popover onboarding-pending onboarding-done settings transcript menubar)
KEEP_RUNNING=0

log() { printf '\033[1;36m[vm-shot]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[vm-shot]\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m[vm-shot]\033[0m %s\n' "$*" >&2; }

# Parse args. `--keep-running` is the only flag; everything else is a screen name.
SCREENS=()
for arg in "$@"; do
  case "$arg" in
    --keep-running) KEEP_RUNNING=1 ;;
    -h|--help)
      grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --*)
      err "unknown flag: $arg"
      exit 2
      ;;
    *)  SCREENS+=("$arg") ;;
  esac
done
if [ ${#SCREENS[@]} -eq 0 ]; then
  SCREENS=("${ALL_SCREENS[@]}")
fi

# Validate screen names.
for name in "${SCREENS[@]}"; do
  match=0
  for valid in "${ALL_SCREENS[@]}"; do
    [ "$name" = "$valid" ] && match=1 && break
  done
  if [ $match -eq 0 ]; then
    err "unknown screen: $name"
    err "valid: ${ALL_SCREENS[*]}"
    exit 2
  fi
done

mkdir -p "$SHOTS_DIR"

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
  # Background run lets us SSH into the VM while it owns its own
  # native window for screencapture to grab. `nohup` detaches it from
  # the shell so it survives this script exiting.
  nohup tart run "$VM_NAME" >"$VM_LOG_FILE" 2>&1 &
  echo $! > "$VM_PID_FILE"
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
  err "Check $VM_LOG_FILE for tart output."
  exit 1
}

start_vm_if_needed
VM_IP="$(wait_for_ssh)"

# --- helpers ------------------------------------------------------------------
ssh_vm() {
  # Retry SSH up to 3 times for transient drops while the app is launching.
  local attempt=1
  while [ $attempt -le 3 ]; do
    if sshpass -p "$VM_PASS" ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" "$@"; then
      return 0
    fi
    warn "ssh attempt $attempt/3 failed; retrying in 2s…"
    sleep 2
    attempt=$((attempt + 1))
  done
  err "ssh failed after 3 attempts: $*"
  return 1
}

scp_to_vm() {
  sshpass -p "$VM_PASS" scp "${SSH_OPTS[@]}" -r "$1" "$VM_USER@$VM_IP:$2"
}

scp_from_vm() {
  sshpass -p "$VM_PASS" scp "${SSH_OPTS[@]}" "$VM_USER@$VM_IP:$1" "$2"
}

# Quit any running Unison instance; ignore failures (process may not exist).
quit_unison() {
  ssh_vm 'osascript -e "tell application \"Unison\" to quit" 2>/dev/null; pkill -9 Unison 2>/dev/null; true'
  sleep 1
}

# Clear UserDefaults + Keychain entries so onboarding-pending starts clean.
reset_app_state() {
  ssh_vm '
    defaults delete com.unison.app 2>/dev/null
    security delete-generic-password -s com.unison.app -a openai-api-key 2>/dev/null
    true
  '
}

# Launch Unison.app with the given env vars (key=value pairs). The app
# uses LSUIElement=true so we don't get a Dock icon — the menubar item
# is the only visible chrome. Returns once the binary has actually
# spawned (poll pgrep up to 10s).
launch_unison() {
  local env_line="$1"
  ssh_vm "
    nohup env $env_line /Users/$VM_USER/Unison.app/Contents/MacOS/Unison >/tmp/unison.log 2>&1 &
    disown
    for i in \$(seq 1 10); do
      if pgrep -x Unison >/dev/null; then exit 0; fi
      sleep 1
    done
    exit 1
  "
}

# Take a screenshot inside the VM and pull it back to the host.
capture_screen() {
  local name="$1"
  local remote="/Users/$VM_USER/screen-$name.png"
  local local_path="$SHOTS_DIR/$name.png"
  log "  Capturing $name → $local_path"
  ssh_vm "screencapture -x -t png '$remote'"
  scp_from_vm "$remote" "$local_path"
  ssh_vm "rm -f '$remote'" || true
}

# --- 3. Push the .app bundle into the VM --------------------------------------
log "Copying Unison.app into VM ($VM_IP)…"
ssh_vm "rm -rf /Users/$VM_USER/Unison.app"
scp_to_vm "$APP_PATH" "/Users/$VM_USER/Unison.app"
# Re-sign ad-hoc inside the VM in case codesign metadata was stripped by SCP.
ssh_vm "codesign --force --sign - /Users/$VM_USER/Unison.app 2>/dev/null || true"

# --- 4. Capture each requested screen -----------------------------------------
# Each block: quit any running app → reset state if needed → launch with
# the right env → wait a beat for the UI to settle → trigger the
# desired screen via AppleScript → screencapture → pull PNG → quit.

for screen in "${SCREENS[@]}"; do
  log "=== $screen ==="
  quit_unison

  case "$screen" in
    popover)
      # Onboarding gate cleared via FORCE_STATE so the popover is usable.
      reset_app_state
      launch_unison "UNISON_DEV_MODE=1 UNISON_FORCE_STATE=onboarding-done"
      sleep 2
      # Left-click the menubar item to expand the popover. AppKit
      # registers the status item as menu-bar item 1 (Unison) for the
      # System Events process named "Unison".
      ssh_vm 'osascript -e '"'"'tell application "System Events" to tell process "Unison" to click menu bar item 1 of menu bar 1'"'"' || true'
      sleep 2
      capture_screen popover
      ;;

    onboarding-pending)
      # Wipe all persisted state so the onboarding window opens fresh.
      # UNISON_DEV_MODE swaps in the mock BlackHole installer so we
      # don't need a real .pkg payload inside the VM.
      reset_app_state
      launch_unison "UNISON_DEV_MODE=1"
      sleep 3
      capture_screen onboarding-pending
      ;;

    onboarding-done)
      # All three steps satisfied at boot → the onboarding window
      # auto-closes via OnboardingViewModel.onCompleted. We capture
      # what the user sees on the very first frame after the gate
      # clears — a bare menubar (the popover hasn't been opened yet).
      # TODO: if/when the design ships a "welcome / ready" surface
      # distinct from the popover, replace this with a screencap of
      # that surface. For now this mirrors the production launch
      # behaviour for a returning user.
      reset_app_state
      launch_unison "UNISON_DEV_MODE=1 UNISON_FORCE_STATE=onboarding-done"
      sleep 3
      capture_screen onboarding-done
      ;;

    settings)
      reset_app_state
      launch_unison "UNISON_DEV_MODE=1 UNISON_FORCE_STATE=settings-open"
      # The AppDelegate opens the Settings window in
      # applicationDidFinishLaunching, but the window controller calls
      # `NSApp.activate(ignoringOtherApps:)` which only works when the
      # app is the frontmost. Nudge it forward with AppleScript.
      sleep 2
      ssh_vm 'osascript -e '"'"'tell application "System Events" to set frontmost of process "Unison" to true'"'"' || true'
      sleep 1
      capture_screen settings
      ;;

    transcript)
      # `transcript-demo` seeds the TranscriptStore with sample bubbles
      # and pre-installs BlackHole / mic / API key so onboarding stays
      # out of the way. The AppDelegate then shows the transcript
      # window from `applyForceStateOverrides()`.
      reset_app_state
      launch_unison "UNISON_DEV_MODE=1 UNISON_FORCE_STATE=transcript-demo"
      sleep 2
      ssh_vm 'osascript -e '"'"'tell application "System Events" to set frontmost of process "Unison" to true'"'"' || true'
      sleep 1
      capture_screen transcript
      ;;

    menubar)
      # No UI interaction — just snap the top of the screen so the
      # status item is visible. We launch the app in the cleared
      # state so the idle icon is shown.
      reset_app_state
      launch_unison "UNISON_DEV_MODE=1 UNISON_FORCE_STATE=onboarding-done"
      sleep 2
      capture_screen menubar
      ;;
  esac

  quit_unison
done

# --- 5. Tear down (or keep running for next call) -----------------------------
if [ $KEEP_RUNNING -eq 1 ]; then
  log "Leaving VM running (--keep-running)."
else
  log "Stopping VM…"
  tart stop "$VM_NAME" 2>/dev/null || true
  rm -f "$VM_PID_FILE"
fi

log "Done. Screenshots in: $SHOTS_DIR"
ls -lh "$SHOTS_DIR"/*.png 2>/dev/null || true
