# Tart VM screenshot harness

Three scripts that run `Unison.app` inside an isolated macOS 26 Tahoe Tart
VM and pull back PNGs of every major UI surface. Used by Claude to verify
visual changes without polluting the host's Keychain, UserDefaults, or
audio device list.

## One-time setup

```bash
brew install cirruslabs/cli/tart       # if not installed
brew install hudochenkov/sshpass/sshpass

bash scripts/vm-setup.sh
```

`vm-setup.sh` clones `ghcr.io/cirruslabs/macos-tahoe-base:latest` into a
local VM named `unison-test`, then configures it with 4 vCPU / 8 GiB RAM /
60 GiB disk. The first clone downloads ~30 GiB and takes a while; later
invocations are no-ops.

Override the defaults with env vars: `VM_NAME`, `BASE_IMAGE`, `VM_CPU`,
`VM_MEMORY_MB`, `VM_DISK_GB`.

## Capturing screens

```bash
# Capture every surface (default).
bash scripts/vm-screenshot.sh

# Capture a subset by name.
bash scripts/vm-screenshot.sh popover settings

# Leave the VM running so the next call doesn't pay the boot cost.
bash scripts/vm-screenshot.sh --keep-running popover

# Add a margin (in points) around each captured window — includes the
# window's drop shadow + breathing room, nicer for docs/README hero
# shots. Default 0 = tight to the window bounds. No effect on `menubar`.
UNISON_SHOT_PADDING=64 bash scripts/vm-screenshot.sh transcript
```

Outputs land in `vm-screenshots/<name>.png` (gitignored).

### Available screens

| Name                  | What it shows                                                 |
|-----------------------|---------------------------------------------------------------|
| `popover`             | Menubar popover after onboarding cleared (default `idle`)     |
| `onboarding-pending`  | First-launch onboarding window, all three steps pending       |
| `onboarding-done`     | Post-onboarding state (window auto-closes, status icon idle)  |
| `settings`            | Settings window opened via `Cmd+,` equivalent                 |
| `transcript`          | Transcript window seeded with demo bubbles                    |
| `menubar`             | Bare menubar with the status item                             |

### How it works

`vm-screenshot.sh` does the following for each requested screen:

1. Builds `build/Unison.app` if it's missing (calls `scripts/bundle_app.sh`).
2. Boots the VM in background graphics mode (`nohup tart run …`).
3. Polls `tart ip` + SSH until reachable (90 s timeout, 2 s interval).
4. SCPs `build/Unison.app` into the guest's home directory.
5. For each screen:
   - Kills any running `Unison` process.
   - Resets state (`defaults delete com.unison.app`, deletes the
     Keychain entry) so each run starts pristine.
   - Launches Unison with the right env vars (see "Debug env vars" below).
   - Triggers the appropriate UI state via AppleScript (e.g. click the
     menubar item to open the popover).
   - Runs `screencapture -x -t png ~/screen-<name>.png` inside the VM.
   - SCPs the PNG back to `vm-screenshots/<name>.png`.
6. Stops the VM unless `--keep-running` was passed.

Credentials default to `admin / admin` (Cirrus base image default). Override
with `VM_USER` / `VM_PASS` env vars.

## Debug env vars (read by the app)

These exist purely so the harness can land on a specific surface without
driving the UI manually. Production launches never set them.

| Env var                | Effect                                                                 |
|------------------------|------------------------------------------------------------------------|
| `UNISON_DEV_MODE=1`    | Swap the real BlackHole installer for an in-process mock.              |
| `UNISON_FORCE_STATE=onboarding-done` | Mark all 3 onboarding steps satisfied at boot.            |
| `UNISON_FORCE_STATE=transcript-demo` | Seed `TranscriptStore` with demo bubbles + open window.   |
| `UNISON_FORCE_STATE=history-demo`    | Seed the archive with demo meetings (in-memory) + open the History window. |
| `UNISON_FORCE_STATE=settings-open`   | Open the Settings window immediately after launch.        |
| `UNISON_FORCE_STATE=popover-open`    | Clear onboarding + show the menubar popover programmatically (avoids fragile AppleScript clicks). |

Implementation lives in `Sources/UnisonApp/Composition.swift` (factories
+ `seedTranscriptDemo`) and `Sources/UnisonApp/AppDelegate.swift`
(`applyForceStateOverrides`).

## Process Tap latency benchmark

`scripts/vm-tap-benchmark.sh` runs the `tap-benchmark` CLI inside the same
`unison-test` VM to measure Process Tap audio capture latency. The script
can optionally include BlackHole 16ch for comparative baseline testing.
Output: a JSON file in `vm-tap-benchmark/`.

```bash
# Default — both phases, with BlackHole present in the VM.
bash scripts/vm-tap-benchmark.sh

# Setup-friendly check — Tap phase only, BlackHole removed first.
bash scripts/vm-tap-benchmark.sh --scenario without-blackhole

# Sanity check on real Zoom (requires Zoom installed + a test call active).
bash scripts/vm-tap-benchmark.sh --scenario sanity-zoom

# Longer duration, keep the VM running afterward.
bash scripts/vm-tap-benchmark.sh --duration 60 --keep-running
```

The script:

1. Boots the VM (or attaches to a running one)
2. Builds `build/TapBenchmark.app` on the host via `bundle_app.sh --target tap-benchmark`
3. Pushes the bundle into the VM
4. Configures the scenario: `without-blackhole` removes the BlackHole 16ch
   driver (then kickstarts coreaudiod); `with-blackhole` only warns if the
   driver is missing — the script never installs it (the benchmark then
   skips the BlackHole phase)
5. Resets TCC Microphone / AudioCapture decisions for `com.unison.tapbench`
   so the capture prompt state is clean
6. Runs the benchmark over SSH inside the console user's session
   (`launchctl asuser`), output captured to a log file — the click train
   is audible in the VM
7. Pulls the JSON report back to `vm-tap-benchmark/results-<unix-ts>.json`

VM uses a virtio audio device; absolute latency may differ from host
metal by 1–3 ms. The verdict (Tap faster or slower) is valid within the
VM environment.

## Cleanup

```bash
bash scripts/vm-cleanup.sh             # stop the VM (keep the image)
bash scripts/vm-cleanup.sh --delete    # stop and delete the VM entirely
```

## Troubleshooting

- **VM never becomes reachable** — check `vm-screenshots/.vm.log` for tart
  output. The most common cause is the base image still downloading; let
  `vm-setup.sh` finish first.
- **`tart ip` returns empty** — the VM hasn't acquired a DHCP lease yet.
  The script waits up to 90 s; bump the deadline if your host is slow.
- **Screencapture returns a black PNG** — the VM needs to be running with
  `--graphics` (default). If you previously launched it with
  `--no-graphics`, stop and restart it.
- **Onboarding-done shows the onboarding window** — make sure
  `UNISON_FORCE_STATE=onboarding-done` reaches the launched process. The
  script uses `env VAR=value /path/to/binary` which is bash-portable.
