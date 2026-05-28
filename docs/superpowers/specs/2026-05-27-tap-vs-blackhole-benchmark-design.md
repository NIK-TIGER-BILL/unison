# Process Tap vs BlackHole 16ch capture benchmark — design

Status: draft  •  Author: nvzamuldinov  •  Date: 2026-05-27

## Context

Unison currently captures the meeting-side audio (the other person on Zoom/Meet)
by routing the conferencing app's output into **BlackHole 16ch** and reading
that virtual device via `AVAudioEngine.inputNode`. This works on any
conferencing app, but it forces the user to:

1. Install BlackHole 16ch via the bundled `.pkg`
2. Manually switch Zoom's *speaker output* to BlackHole 16ch
3. Lose the ability to also hear the meeting through real speakers
   without an extra multi-output device

macOS 14.2+ exposes **CoreAudio Process Tap** (`AudioHardwareCreateProcessTap`),
a first-class API for capturing the audio output of a specific process
without any virtual device. On macOS 26 Tahoe (Unison's target OS) the API
is fully available.

Hypothesis: Process Tap can replace BlackHole 16ch for the input path with
comparable or better latency, no installer step, and no Zoom output
re-routing. The outbound path (user mic → translation → virtual microphone
into Zoom) still requires BlackHole 2ch — Apple does not expose a way to
publish a virtual microphone without a HAL plug-in.

This document specifies a **standalone benchmark** that measures latency,
jitter, drop rate, and CPU of both capture paths under the same controlled
signal, plus a sanity check against a real Zoom call. The benchmark output
gives a go/no-go decision for a separate production-integration task.

## Goals

- Measure capture-entry latency (signal generated → bytes available in our
  callback) for both paths under identical conditions
- Measure jitter (latency stddev), drop rate, and CPU usage for both paths
- Verify that Tap works on a system **without** BlackHole installed
- Verify Tap captures audio from a real third-party process (Zoom)
- Produce numbers that decide: replace BlackHole 16ch with Tap, or stay
- All testing in an isolated Tart VM (macOS 26 Tahoe), not on the host

## Non-goals

- Production integration in `TranslationOrchestrator` / `Composition` — a
  separate brainstorming + plan after this prototype's results are in
- ScreenCaptureKit comparison — separate investigation if Tap is rejected
- Multi-process tap (e.g. Zoom + Meet simultaneously)
- UX for granting TCC audio-capture permission in production
- Replacing BlackHole 2ch (outbound path) — out of scope, still required

## Architecture & file layout

New files:

```
Sources/
  UnisonAudio/
    ProcessTapCapture.swift           # library: Process Tap → AudioFrame
  Tools/
    TapBenchmark/
      main.swift                      # CLI entry, flag parsing, phase driver
      SignalGenerator.swift           # click-train player + ground-truth log
      BenchmarkRun.swift              # one phase end-to-end, returns metrics
      Report.swift                    # stdout table + JSON file
      HostTimeClock.swift             # mach_absolute_time helpers
      Info.plist                      # NSAudioCaptureUsageDescription, bundle ID
      tap-benchmark.entitlements      # com.apple.security.device.audio-input
scripts/
  vm-tap-benchmark.sh                 # boot Tart VM, deploy, run, collect
```

Changes:

- `Package.swift` gains `.executableTarget(name: "TapBenchmark", path:
  "Sources/Tools/TapBenchmark", dependencies: ["UnisonAudio"])`
- `scripts/bundle_app.sh` extended with `--target tap-benchmark` mode that
  produces `build/TapBenchmark.app` (minimal bundle, ad-hoc signed)
- `scripts/VM_README.md` extended with a "Tap vs BlackHole benchmark"
  section

`ProcessTapCapture` lives in `UnisonAudio` (next to `BlackHoleSinkCapture`)
because it is reusable production code — if the benchmark passes, the same
type is consumed from `TranslationOrchestrator` in the follow-up task. No
production code paths are modified by this prototype.

## Methodology

### Test signal

A click-train: a 2 ms white-noise burst at amplitude 0.7, repeated every
200 ms for the run duration (default 30 s ≈ 150 clicks). Short impulses are
easy to localise via amplitude threshold; 200 ms between clicks tolerates
±50 ms jitter without ambiguity.

### Ground truth

`SignalGenerator` plays the click-train through an `AVAudioEngine` with an
`AVAudioPlayerNode`. For each click, the player computes an exact
`AVAudioTime(hostTime: ...)`, schedules the buffer at that time, and
records `(clickIndex, expectedHostTime)` into a log. `hostTime` is
`mach_absolute_time()` ticks; `HostTimeClock` converts to nanoseconds via
`mach_timebase_info`.

### Phase routing

| Phase           | Engine output device         | Capture                          |
| --------------- | ---------------------------- | -------------------------------- |
| `blackhole`     | BlackHole 16ch (forced)      | `BlackHoleSinkCapture` (as-is)   |
| `tap`           | Default system output (-40 dB) or `--silent` (Null Aggregate) | `ProcessTapCapture(targetPID: getpid())` |

The output device for the engine is set by binding
`AVAudioEngine.outputNode`'s audio unit to a specific `AudioDeviceID` via
`AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)`.

### Per-callback recording

Each capture's audio callback records:

- `arrivalHostTime` — from `AudioTimeStamp.mHostTime` if present and
  monotonic, otherwise `mach_absolute_time()` taken at callback entry
- raw float PCM buffer (interleaved or planar, normalised to mono)

Buffers are appended to a phase-scoped recording. No real-time processing
during the run — analysis is offline after the phase ends.

### Offline analysis

After a phase completes:

1. **Peak detection** — sliding window over the recorded PCM; mark any
   sample whose absolute amplitude exceeds 0.3 and is a local maximum
   within a 10 ms window. Each peak gets a host-time via
   `arrivalHostTime + sampleOffset / sampleRate`.
2. **Click matching** — for each expected click, find the nearest detected
   peak within ±100 ms. No peak → drop.
3. **Metrics**:
   - `latency_ms_median`, `latency_ms_p95` — median and p95 of
     `(detectedHostTime − expectedHostTime)` in milliseconds
   - `jitter_ms_stddev` — sample standard deviation of the same array
   - `drop_rate` — `1 − matched_clicks / 150`
   - `cpu_mean_pct` — background thread samples `task_info` every 100 ms;
     report mean CPU% of the benchmark process during the phase

All host-times stay in `mach_absolute_time` ticks until the final ms
conversion, giving sub-microsecond resolution.

### Phase sequencing

CLI runs phases sequentially with a 2 s quiescent pause between them so
CoreAudio buffers drain. Order is `blackhole` then `tap` by default; flags:

```
tap-benchmark --duration 30 --phase {blackhole,tap,both} --silent
              --json-out path.json
tap-benchmark sanity-check
```

## Capture implementations

### `ProcessTapCapture` (new)

Public API mirrors `BlackHoleSinkCapture`:

```swift
public final class ProcessTapCapture {
    public init(targetPID: pid_t) throws
    public func start(onFrame: @escaping (AudioFrame) -> Void) throws
    public func stop()
}
```

Internally, the lifecycle is:

1. **Resolve target process** —
   `AudioObjectGetPropertyData(kAudioObjectSystemObject,
   kAudioHardwarePropertyTranslatePIDToProcessObject, &pid, &processObjectID)`
2. **Build tap description** — `CATapDescription(monoMixdownOfProcesses:
   [processObjectID])`, with `isPrivate = true` (other processes do not see
   the tap), `muteBehavior = .unmuted` (the original audio still plays to
   its destination)
3. **Create tap** —
   `AudioHardwareCreateProcessTap(tapDescription, &tapObjectID)`. Read
   `kAudioTapPropertyUID` for the tap's CFString UID.
4. **Wrap in aggregate device** —
   `AudioHardwareCreateAggregateDevice(dict, &aggregateID)` with:

   ```
   kAudioAggregateDeviceNameKey:      "UnisonTapBenchmark"
   kAudioAggregateDeviceUIDKey:       "com.unison.tapbench.<uuid>"
   kAudioAggregateDeviceTapListKey:   [[kAudioSubTapUIDKey: tapUID]]
   kAudioAggregateDeviceIsPrivateKey: true
   ```

5. **Install IOProc** — `AudioDeviceCreateIOProcID(aggregateID, callback,
   refcon, &procID)`, then `AudioDeviceStart(aggregateID, procID)`
6. **Realtime callback** (CoreAudio realtime thread, no allocations / no
   Swift retain-release / no locks):
   - Record `inInputTime.pointee.mHostTime`
   - Copy `inInputData.pointee.mBuffers[0]` floats into a lockless
     single-producer / single-consumer ring buffer
   - `DispatchSemaphore.signal()` to wake the consumer
7. **Consumer thread** — dequeues buffers, drives an `AVAudioConverter`
   from the tap's native format (likely 48 kHz float) to 24 kHz Int16
   mono, emits `AudioFrame` with the preserved host-time
8. **Cleanup** (idempotent, callable on SIGINT or normal exit):
   `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` →
   `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`

Refcon passed to the IOProc is
`Unmanaged.passUnretained(self).toOpaque()`; the class is guaranteed alive
because `AudioDeviceStop` is synchronous and returns only after the last
callback completes.

Reference for the API chain: Apple sample "Capturing system audio with
Core Audio taps" (WWDC 2023/2024). We adopt only the
Tap + Aggregate + IOProc pattern; the rest is bespoke.

### `BlackHoleSinkCapture` (existing)

Used unmodified. The benchmark instantiates it in the `blackhole` phase
and subscribes to its existing `AudioFrame` callback. To extract
`arrivalHostTime` for parity with Tap, the benchmark either reads the
host-time off the emitted `AudioFrame` (if the type already carries one)
or wraps the callback with `mach_absolute_time()` at entry. No changes to
production code.

### Shared helpers

- `HostTimeClock` — `now() -> UInt64`, `nanoseconds(from:)`,
  `milliseconds(between:and:)`. Caches `mach_timebase_info`.

## Permissions & errors

### TCC for Process Tap

A bare CLI binary built by `swift run` is not bundled and frequently does
not get the audio-capture TCC prompt. To make Process Tap work reliably,
`scripts/bundle_app.sh --target tap-benchmark` produces a minimal `.app`:

```
build/TapBenchmark.app/
  Contents/
    Info.plist            # CFBundleIdentifier=com.unison.tapbench,
                          # NSAudioCaptureUsageDescription="Latency benchmark vs BlackHole"
    MacOS/tap-benchmark   # the swift-built executable
    _CodeSignature/
```

The app is ad-hoc signed (`codesign --force --sign -`) with
`tap-benchmark.entitlements` containing
`com.apple.security.device.audio-input`. Launch via
`open build/TapBenchmark.app --args --duration 30`; the first run triggers
the TCC prompt. If the user declines, the next run prints an actionable
error pointing to *System Settings → Privacy & Security → Microphone →
tap-benchmark*.

### Missing BlackHole 16ch

Before the `blackhole` phase, the benchmark queries CoreAudio for the
BlackHole 16ch device UID. If absent, the phase is **skipped** and the
report shows `(skipped: BlackHole 16ch not installed)`. The `tap` phase
has no such dependency. The skip is also the "setup-friendly check": if
the `tap` phase succeeds while BlackHole is absent, the check is **PASS**;
if BlackHole is present, the check is **SKIPPED** (cannot verify absence
of dependency without uninstalling).

### CoreAudio OSStatus mapping

All `AudioHardware*` and `AudioDevice*` calls are wrapped:

```swift
func checkCAStatus(_ status: OSStatus, _ call: String) throws {
    guard status == noErr else {
        throw CoreAudioError(call: call, status: status, fourCC: fourCC(status))
    }
}
```

`fourCC(status)` decodes the OSStatus as a 4-char code (e.g. `'!obj'`,
`'who?'`). A small table maps known codes to human descriptions. Errors
abort the phase with a clear diagnostic.

### macOS availability

Project is macOS 26 Tahoe only; Process Tap is macOS 14.2+. The Tap code
is wrapped in `if #available(macOS 14.2, *)` for explicitness, although
always true on the target OS.

### Cleanup & SIGINT

Aggregate devices and taps persist in `coreaudiod` across process crashes
until reboot. Mitigations:

- `SIGINT` handler triggers `BenchmarkRun.teardown()` (idempotent)
- `defer { teardown() }` in `main()` for normal exit
- On startup, scan existing aggregate devices for UIDs matching
  `com.unison.tapbench.*` and remove them (handles a previous crashed
  run)

### Realtime safety

The IOProc callback runs on a CoreAudio realtime thread. Constraints:

- No `print`, no `NSLog`
- No Swift allocations / no class refcount mutations
- No `os_unfair_lock` / no Foundation locks
- Permitted: pointer copies, ring-buffer push, `DispatchSemaphore.signal()`
- The consumer thread (regular GCD) does conversion and `AudioFrame`
  emission

### Audio safety in the tap phase

The `tap` phase plays the click-train into the default output device, so
the user will hear it. Mitigations:

- Default gain is **-40 dB** (about 10× quieter than typical)
- `--silent` flag routes the engine output to a Null Audio Device (a
  fresh aggregate with empty sub-device list); zero audible output

## Report format

stdout (also mirrored to a JSON file `tap-benchmark-results-<ts>.json`):

```
Tap vs BlackHole capture benchmark
duration: 30s  •  clicks: 150  •  signal: 2ms burst @ 200ms

                 BlackHole 16ch   Process Tap
─────────────────────────────────────────────
median latency       XX.X ms        XX.X ms
p95 latency          XX.X ms        XX.X ms
jitter (stddev)       X.X ms         X.X ms
drop rate             X.X %          X.X %
mean CPU              X.X %          X.X %
─────────────────────────────────────────────
verdict: Process Tap is XX ms <faster|slower> (median), XX% <more|less> CPU

Setup-friendly check: <PASS|FAIL|SKIPPED>
```

JSON schema:

```json
{
  "timestamp": "2026-05-27T10:30:00Z",
  "duration_s": 30,
  "click_count": 150,
  "blackhole": { "median_ms": ..., "p95_ms": ..., "jitter_ms": ...,
                 "drop_rate": ..., "cpu_pct": ..., "skipped": false },
  "tap":       { "median_ms": ..., "p95_ms": ..., "jitter_ms": ...,
                 "drop_rate": ..., "cpu_pct": ..., "skipped": false },
  "setup_friendly_check": "PASS|FAIL|SKIPPED",
  "verdict": { "tap_faster_by_ms": ..., "tap_cpu_delta_pct": ... },
  "environment": { "host": "vm-tahoe-26.4", "vm": true, "blackhole_present": false }
}
```

## Sanity check (Variant C — real Zoom)

A separate subcommand, no ground-truth signal:

```
tap-benchmark sanity-check
```

Flow:

1. Iterate `NSWorkspace.shared.runningApplications`, find bundle
   `us.zoom.xos` → `pid`
2. If not found: print `Start Zoom and join a test call at zoom.us/test,
   then re-run`
3. Build `ProcessTapCapture(targetPID: zoomPID)`, capture for 10 s
4. Compute RMS amplitude of the captured buffer
5. Print:

   ```
   Zoom PID: 12345
   Captured: 480000 frames (10.0 s @ 48 kHz)
   RMS amplitude: 0.042
   Verdict: <Tap is receiving Zoom audio | Tap returned silence — Zoom may be muted>
   ```

The user runs this with a Zoom test call active; non-trivial RMS means Tap
is functional on a foreign process.

## Success criteria

The benchmark gives a green light for production integration if **all**
of the following hold across at least 3 separate VM runs:

| Metric             | Threshold                                       |
| ------------------ | ----------------------------------------------- |
| Median latency     | `tap ≤ blackhole + 5 ms`                        |
| p95 latency        | `tap ≤ blackhole + 10 ms`                       |
| Jitter (stddev)    | `tap ≤ blackhole × 1.5`                         |
| Drop rate          | 0% in both phases                               |
| CPU                | `tap ≤ blackhole + 2 percentage points`         |
| Setup-friendly     | PASS                                            |
| Sanity on Zoom     | RMS > 0.001 during an active Zoom test call     |

If **all** criteria pass: a follow-up brainstorming + plan covers
production integration (replacing `BlackHoleSinkCapture` in
`TranslationOrchestrator` with `ProcessTapCapture`, removing BlackHole
16ch from `BundledBlackHoleInstaller`, updating onboarding copy).

If **any** criterion fails: results are archived as justification for
staying on BlackHole, and the next investigation may evaluate
ScreenCaptureKit.

## VM testing (Tart)

All measurement runs happen inside the `unison-test` Tart VM (macOS 26
Tahoe base, 4 vCPU / 8 GiB RAM), provisioned by the existing
`scripts/vm-setup.sh`. Rationale:

- **CoreAudio isolation** — leaked aggregate devices and taps stay inside
  the VM; a `tart stop` + restart resets them
- **BlackHole presence control** — the host typically has BlackHole 16ch
  installed; the VM lets us run the `without-blackhole` scenario
- **Reproducibility** — identical OS / vCPU / memory across runs
- **TCC isolation** — audio-capture grant lives in the VM, not on the
  host

### New script: `scripts/vm-tap-benchmark.sh`

Modelled on `scripts/vm-integration-test.sh`. Outline:

1. Boot the VM (`tart run --no-graphics unison-test` in background); poll
   `tart ip` and SSH for readiness (90 s deadline, 2 s interval)
2. On the host, run `bash scripts/bundle_app.sh --target tap-benchmark`;
   produces `build/TapBenchmark.app`
3. `scp -r build/TapBenchmark.app admin@$VM_IP:~/`
4. Depending on `--scenario`, optionally install BlackHole 16ch inside
   the VM via the same flow `BundledBlackHoleInstaller` uses
5. Pre-grant TCC audio capture for `com.unison.tapbench` via `tccutil` /
   `sqlite3 TCC.db`; fallback: AppleScript "Allow" on the prompt
6. Run the benchmark over SSH:
   `ssh -t admin@$VM_IP "/Users/admin/TapBenchmark.app/Contents/MacOS/tap-benchmark
   --duration 30 --phase both --json-out ~/results.json --silent"`
7. `scp` `results.json` back to `vm-tap-benchmark/<unix-ts>.json` on the
   host
8. `tart stop unison-test` unless `--keep-running` was passed

### Scenarios (`--scenario` flag)

| Scenario             | BlackHole 16ch in VM | Phases run               |
| -------------------- | -------------------- | ------------------------ |
| `with-blackhole`     | installed            | both (full A/B)          |
| `without-blackhole`  | not installed        | tap only (setup-friendly)|
| `sanity-zoom`        | irrelevant           | sanity-check on Zoom     |

Default: `with-blackhole`. The benchmark requires at least one
`with-blackhole` run and one `without-blackhole` run to compute the
verdict.

### Absolute-numbers caveat

The VM uses a virtio audio device; absolute latency may differ from
bare-metal hardware by 1–3 ms. The benchmark measures **relative**
Tap-vs-BlackHole differences within the same environment, so the verdict
is valid; absolute production latency may be slightly better than the
reported numbers.

### Documentation

`scripts/VM_README.md` gains a section "Tap vs BlackHole benchmark"
documenting `vm-tap-benchmark.sh` invocations and the three scenarios.

## Out of scope

- Any change to `TranslationOrchestrator`, `Composition`,
  `BundledBlackHoleInstaller`, onboarding UI, or other production code
- A user-facing UX for granting Process Tap permission in production
- Selection of Zoom / Meet / Teams via UI — sanity-check is hard-coded
  to `us.zoom.xos`
- Tapping multiple processes at once
- ScreenCaptureKit comparison (separate spike if Tap fails)
- Replacing BlackHole 2ch on the outbound (virtual microphone) path —
  still required, no public API replacement exists

## Open questions

- Does `BlackHoleSinkCapture` already emit a host-time on its
  `AudioFrame`, or does the benchmark need to capture
  `mach_absolute_time()` at the callback boundary? Decide by reading the
  type when implementing.
- Does `tccutil` / direct `TCC.db` write work for pre-granting audio
  capture on macOS 26 Tahoe in Tart VMs? If not, AppleScript click on
  the system prompt is the fallback.
