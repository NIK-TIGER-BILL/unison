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

log() { printf '\033[1;36m[vm-shot]\033[0m %s\n' "$*" >&2; }
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

# Single-attempt SSH wrapper for queries where "no output" is a valid
# result. The retrying `ssh_vm` above re-runs on non-zero exit, which
# would hammer the VM with three failed osascript calls when the
# target window isn't visible yet — quiet failure is what we want.
ssh_vm_once() {
  sshpass -p "$VM_PASS" ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" "$@"
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

# Hide every visible app except Unison/Finder and dismiss any system
# notification panels that might still be on screen. The most common
# offender is Terminal.app (the base macOS image opens one Terminal
# window at first login that then sits in the foreground inside the
# VM). We also try to close "Notification Center / App Background
# Activity" panels that appear on a fresh launch.
#
# Notes:
# - Each process is hidden by explicit name; the compound
#   `set visible of (every process whose name is not "Unison")`
#   silently no-ops on macOS 26 / Tahoe and leaves Terminal in front.
# - We do NOT hide Finder — Finder owns the desktop, and hiding it
#   causes macOS to surface whichever app was previously frontmost
#   (Terminal in our case) to take over the focused window slot,
#   undoing the Terminal hide we just performed.
# - Each line is wrapped in `|| true` because some processes (like
#   NotificationCenter) may not be running.
hide_other_apps() {
  ssh_vm '
    osascript -e "tell application \"System Events\" to set visible of process \"Terminal\" to false" 2>/dev/null || true
    osascript -e "tell application \"System Events\" to set visible of process \"NotificationCenter\" to false" 2>/dev/null || true
    # Click the close button on any "Background Activity" / first-run
    # alert owned by UserNotificationCenter so it does not occlude
    # the target window. `button 1` is the default ("OK" / close).
    osascript -e "tell application \"System Events\" to tell process \"UserNotificationCenter\" to if exists window 1 then click button 1 of window 1" 2>/dev/null || true
    true
  '
  sleep 1
}

# Ask AppleScript inside the VM for the bounds of Unison's frontmost
# window (`window 1` of `process "Unison"`). Returns a string of the
# form "x,y,w,h" on success, empty on failure. Stderr from osascript is
# discarded so a "no window" error doesn't pollute logs.
#
# The popover, onboarding, transcript, and settings windows all now
# expose stable internal titles (set in `StatusItemController.swift`,
# `OnboardingWindowController.swift`, `TranscriptWindowController.swift`,
# `SettingsWindowController.swift`), but we don't address them by title
# — we just take whatever is at `window 1`, since the harness only
# brings up a single window per screen.
query_unison_window_bounds() {
  ssh_vm_once '
    osascript <<APPLESCRIPT 2>/dev/null
tell application "System Events"
  tell process "Unison"
    if (count of windows) > 0 then
      set pos to position of window 1
      set sz to size of window 1
      return ((item 1 of pos) as integer as string) & "," & ((item 2 of pos) as integer as string) & "," & ((item 1 of sz) as integer as string) & "," & ((item 2 of sz) as integer as string)
    end if
  end tell
end tell
APPLESCRIPT
  ' 2>/dev/null | tr -d "\r" | tr -d "\n"
}

# Take a screenshot inside the VM and pull it back to the host. Hides
# other apps + dismisses notification dialogs first so the capture
# shows only Unison + the desktop wallpaper.
#
# Behaviour:
# - `menubar`: capture top 30pt strip of the screen (status bar only).
# - all other screens: query Unison's `window 1` bounds via AppleScript
#   and pass them to `screencapture -R x,y,w,h` so the PNG is sized to
#   the window itself. Falls back to full-screen capture if the bounds
#   query returns nothing (e.g. `onboarding-done` shows no window).
#
# Capturing only the window means the downstream multimodal pipeline
# (which downscales reads to ~256px wide) gets the full UI region
# resolved per pixel rather than scaled down with the VM desktop.
capture_screen() {
  local name="$1"
  local remote="/Users/$VM_USER/screen-$name.png"
  local local_path="$SHOTS_DIR/$name.png"
  log "  Capturing $name → $local_path"
  hide_other_apps

  if [ "$name" = "menubar" ]; then
    # Top of the screen only. Query the screen width via AppleScript so
    # we cover the full menubar regardless of the VM's current
    # resolution (1024×768 vs 2560×1600 vs anything else). 30pt covers
    # the standard menubar height.
    local screen_w
    screen_w=$(ssh_vm_once '
      osascript -e "tell application \"Finder\" to get bounds of window of desktop" 2>/dev/null \
        | awk -F", " "{print \$3}"
    ' 2>/dev/null | tr -d "\r" | tr -d "\n")
    if [[ ! "$screen_w" =~ ^[0-9]+$ ]] || [ "$screen_w" -eq 0 ]; then
      # Fallback: derive width from the resolution of the main display.
      screen_w=$(ssh_vm_once "system_profiler SPDisplaysDataType 2>/dev/null | awk '/Resolution:/ {print \$2; exit}'" \
        2>/dev/null | tr -d "\r" | tr -d "\n")
      if [[ ! "$screen_w" =~ ^[0-9]+$ ]] || [ "$screen_w" -eq 0 ]; then
        screen_w=2560
      fi
    fi
    log "    menubar strip: 0,0,${screen_w},30"
    ssh_vm "screencapture -x -R '0,0,${screen_w},30' -t png '$remote'"
  else
    local bounds
    bounds=$(query_unison_window_bounds)
    if [[ "$bounds" =~ ^[0-9]+,[0-9]+,[0-9]+,[0-9]+$ ]]; then
      log "    window region: $bounds"
      ssh_vm "screencapture -x -R '$bounds' -t png '$remote'"
    else
      # No window was reachable via AX. For `popover` try the
      # `popover-frame:` line StatusItemController writes to stderr
      # (/tmp/unison.log) — NSPopover hosts its content in a private
      # panel that the System Events traversal occasionally misses.
      local fallback=""
      if [ "$name" = "popover" ]; then
        fallback=$(ssh_vm_once "grep -m1 '^popover-frame: ' /tmp/unison.log 2>/dev/null | sed -E 's/^popover-frame: //'" 2>/dev/null \
          | tr -d "\r" | tr -d "\n")
      fi
      if [[ "$fallback" =~ ^[0-9]+,[0-9]+,[0-9]+,[0-9]+$ ]]; then
        log "    window region (from log): $fallback"
        ssh_vm "screencapture -x -R '$fallback' -t png '$remote'"
      else
        log "    no window detected, capturing full screen"
        ssh_vm "screencapture -x -t png '$remote'"
      fi
    fi
  fi

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
      # Onboarding gate cleared + popover expanded programmatically via
      # `UNISON_FORCE_STATE=popover-open`. The AppDelegate calls
      # `statusItem.showPopover()` in `applicationDidFinishLaunching`
      # so we avoid the AppleScript menubar-click path entirely
      # (which targets the wrong menu bar — main vs status bar — and
      # needs Accessibility permission anyway).
      reset_app_state
      launch_unison "UNISON_DEV_MODE=1 UNISON_FORCE_STATE=popover-open"
      sleep 3
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
