# Tap-benchmark smoke run — known issues (2026-05-27)

The 13-task prototype is fully built, tested at unit level (21/21 pass),
infrastructure works end-to-end (VM boot → deploy → run → JSON pull).
Signal acquisition does not produce real numbers in the current
architecture. After ~3 hours of follow-up debugging this document is the
complete root-cause analysis.

## Verified findings

### 1. AVAudioEngine output device binding is silently inert

Setting `kAudioOutputUnitProperty_CurrentDevice` on
`AVAudioEngine.outputNode.audioUnit` is accepted (readback confirms the
new device ID) but the engine continues to render into the system
default device. Verified by isolation test
(`/tmp/test-bh-output.swift`): a fresh AVAudioEngine output bound to
BlackHole 16ch + a fresh AVAudioEngine input bound to the same → 0
chunks delivered.

### 2. Default-output swap workaround breaks input format negotiation

If we set the system default output to BlackHole 16ch before creating
the input AVAudioEngine, `inputNode.outputFormat(0)` shifts from
`1ch / 48000 Hz / Float32` to `2ch / 44100 Hz / Float32 deinterleaved`,
which `installTap(format:)` rejects with `Failed to create tap due to
format mismatch`. So this workaround is closed off.

### 3. Raw AUHAL output to a specific device works — when standalone

`AUHALSignalGenerator` (this branch) uses
`kAudioUnitSubType_HALOutput` + `kAudioOutputUnitProperty_CurrentDevice`
+ render callback at the device's native 16-channel non-interleaved
Float32 format. **Standalone**: 187 render callbacks in 2 seconds, full
amplitude, click train visible to an external listener like
`/tmp/test-bh-capture.swift`. **In-process with our AUHAL input on the
same device** (see #5 below): render callback fires exactly once, then
the device clock freezes for the output unit.

### 4. Virtual devices need a "consumer" for their clock to run

BlackHole 16ch is a virtual device with no inherent clock driver. When
nothing in the system is actively reading from it as the default
output, the device clock does not advance, and AUHAL output bound to
it renders once and freezes. Workaround: set it as the system default
output before creating the AU. This works for the standalone case (#3
above) but does not survive the addition of an AUHAL input unit on the
same device in the same process (#5 below).

### 5. Same-process AUHAL output + AUHAL input on the same HAL device conflict

With both an output AU and an input AU bound to BlackHole 16ch in the
same process, the output AU's render callback fires exactly once and
then stops, even with BH 16ch set as system default. We tried:

- Disabling `kAudioOutputUnitProperty_EnableIO` on the input AU's
  output scope — no effect
- Leaving output scope enabled on the input AU — no effect
- Setting default to BH before creating the AUs vs after — no effect

The input AU still captures buffers (76+ chunks at 512 frames each)
but they are silence — because the output side has frozen and BH 16ch
has no upstream data to mirror.

**This is the architectural blocker.** Same-process self-loopback
through BlackHole 16ch is unsupported by CoreAudio on macOS 26 Tahoe;
some shared device state gets clobbered when an input AU is added to a
process that already has an output AU pointed at the same HAL device.

### 6. Process Tap silently denied for ad-hoc bundles

Apple's Process Tap requires a TCC audio-capture grant. From the
system log (`/usr/bin/log show --predicate "subsystem CONTAINS TCC"`):

```
tccd: SecStaticCodeCheckValidity() static code from com.unison.tapbench
    : anchor apple; status: -67050
tccd: For com.unison.tapbench: matches platform requirements: No
…
tccd: ReqResult(Auth Right: Allowed (User Consent), DB Action: None)
```

- "matches platform requirements: No" → ad-hoc signature doesn't
  satisfy "anchor apple"; TCC cannot trust the bundle identity.
- "DB Action: None" → even when the user clicks Allow, the grant is
  not persisted.

`ProcessTapCapture` IOProc fires and delivers chunks at the expected
rate, but every sample is 0.0 — CoreAudio honors the unverified
entitlement enough to deliver buffers but mutes the per-process audio.

Additionally, when the benchmark is launched as a child of Claude Code
(directly or through `osascript`/`open`), TCC traces the responsibility
chain to `com.anthropic.claude-code` and prompts for *Claude Code's*
access rather than the benchmark's.

## What's solid

- `HostTimeClock`, `PeakDetector`, `MetricsCalculator`, `Report` — pure
  logic, 21 unit tests, all pass
- `ProcessTapCapture` — IOProc lifecycle, sample callback delivery; the
  silent samples are a TCC denial, not a code bug
- `CPUSampler`, `BenchmarkRun` scaffold — drive a phase end-to-end
- `AUHALSignalGenerator` — raw AUHAL render to a chosen device,
  verified working standalone with 187 renders/2 s on BlackHole 16ch
- `AUHALInputCapture` — raw AUHAL capture with pre-allocated ring
  buffer, no allocations in the realtime callback
- VM driver, bundle workflow, state-aware tart handling

## What's needed to get real numbers

Both blockers (#5 and #6 above) need architectural changes; tactical
patches won't unstick them.

**For the BlackHole side**, the producer and consumer must live in
different processes:

- Build a tiny separate executable `tap-benchmark-producer` that does
  only AUHAL output of the click train to a chosen device
- The main `tap-benchmark` spawns the producer as a subprocess,
  records its launch timestamp, captures via `AUHALInputCapture` or
  `BlackHoleSinkCapture`, and measures latency from spawn-time to
  click-detected-time

The single-process self-loopback we tried is fundamentally fighting
CoreAudio's HAL-level device sharing rules. Once split into two
processes, the standalone test pattern that worked
(`/tmp/test-bh-capture.swift` with `afplay` as producer) maps directly.

Estimated work: 3–4 hours (new subproject scaffolding, spawn/IPC
plumbing, host-time synchronization between processes via a sentinel
in the audio stream).

**For the Process Tap side**, the bundle needs a Developer ID
signature:

- The user's `DEVELOPER_ID` env var (Apple Developer Program
  membership) signs `TapBenchmark.app` with a trusted anchor
- TCC then persists the grant and the IOProc receives real samples

Estimated work: 10 minutes once the certificate is available.

**Procedural**: launch the .app from Finder by double-click on first
TCC prompt so the responsibility chain doesn't attach to a parent
process like Claude Code.

## Bottom line

The prototype is a complete, working scaffold with a clearly identified
6-step root-cause chain that prevents single-process self-loopback
measurement on this branch. The original architectural question — "Is
Process Tap better than BlackHole 16ch?" — is unanswered by this
measurement attempt, but the remaining obstacles are precisely scoped:
two-process split for the BlackHole side, Developer ID for the Tap
side. Everything else is in place.
