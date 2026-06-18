#!/usr/bin/env bash
# vm-cleanup.sh — stop (and optionally delete) the `unison-test` Tart VM.
#
# Usage:
#   bash scripts/vm-cleanup.sh           # stop only
#   bash scripts/vm-cleanup.sh --delete  # stop and delete the VM
set -euo pipefail

VM_NAME="${VM_NAME:-unison-test}"
DELETE_VM=0

for arg in "$@"; do
  case "$arg" in
    --delete) DELETE_VM=1 ;;
    -h|--help)
      cat <<USAGE
Usage: $0 [--delete]

  --delete   Also delete the VM after stopping it.
USAGE
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

log() { printf '\033[1;36m[vm-cleanup]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[vm-cleanup]\033[0m %s\n' "$*" >&2; }

if ! command -v tart >/dev/null 2>&1; then
  err "tart not installed — nothing to do."
  exit 0
fi

# NB: tart's JSON keys are capitalized (`"Name" : "unison-test"`), same
# casing vm-tap-benchmark.sh parses via `vm.get("Name")`.
if ! tart list --format json 2>/dev/null | grep -q "\"Name\"[[:space:]]*:[[:space:]]*\"$VM_NAME\""; then
  log "VM \"$VM_NAME\" not found — nothing to clean up."
  exit 0
fi

# `tart stop` is idempotent — returns nonzero only when the VM doesn't
# exist (we already checked) or if it's mid-shutdown. We swallow errors
# so a stale "already stopped" report doesn't fail the script.
log "Stopping \"$VM_NAME\" (if running)…"
tart stop "$VM_NAME" 2>/dev/null || true

if [ "$DELETE_VM" -eq 1 ]; then
  log "Deleting \"$VM_NAME\"…"
  tart delete "$VM_NAME"
  log "Deleted."
else
  log "VM stopped. Pass --delete to remove it entirely."
fi
