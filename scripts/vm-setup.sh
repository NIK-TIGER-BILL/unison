#!/usr/bin/env bash
# vm-setup.sh — one-time provisioning of the `unison-test` Tart VM.
#
# Clones the pre-built macOS 26 Tahoe base image from cirruslabs,
# bumps it to 4 vCPU / 8 GiB RAM / 60 GiB disk, and prints info.
# Subsequent invocations are no-ops (the clone step is skipped if
# the VM already exists).
set -euo pipefail

VM_NAME="${VM_NAME:-unison-test}"
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/cirruslabs/macos-tahoe-base:latest}"
VM_CPU="${VM_CPU:-4}"
VM_MEMORY_MB="${VM_MEMORY_MB:-8192}"
VM_DISK_GB="${VM_DISK_GB:-60}"

log() { printf '\033[1;36m[vm-setup]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[vm-setup]\033[0m %s\n' "$*" >&2; }

ensure_tool() {
  local name="$1" install_hint="$2"
  if ! command -v "$name" >/dev/null 2>&1; then
    err "missing required tool: $name"
    err "install with: $install_hint"
    exit 1
  fi
}

log "Checking host prerequisites…"
ensure_tool tart    "brew install cirruslabs/cli/tart"
ensure_tool sshpass "brew install hudochenkov/sshpass/sshpass"

# `tart list` exits 0 even if VM is missing — match the name explicitly.
# NB: tart's JSON keys are capitalized (`"Name" : "unison-test"`), same
# casing vm-tap-benchmark.sh parses via `vm.get("Name")`.
if tart list --format json 2>/dev/null | grep -q "\"Name\"[[:space:]]*:[[:space:]]*\"$VM_NAME\""; then
  log "VM \"$VM_NAME\" already exists — skipping clone."
else
  log "Pulling and cloning base image: $BASE_IMAGE"
  log "(first run downloads ~30 GiB; this may take a while)"
  tart clone "$BASE_IMAGE" "$VM_NAME"
fi

log "Configuring \"$VM_NAME\": ${VM_CPU} vCPU, ${VM_MEMORY_MB} MiB RAM, ${VM_DISK_GB} GB disk…"
tart set "$VM_NAME" \
  --cpu "$VM_CPU" \
  --memory "$VM_MEMORY_MB" \
  --disk-size "$VM_DISK_GB"

log "VM info:"
tart get "$VM_NAME" || true

log "Done. Next step: bash scripts/vm-screenshot.sh"
