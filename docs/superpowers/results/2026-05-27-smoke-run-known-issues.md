# Tap-benchmark smoke run — known issues (2026-05-27)

The 13-task prototype is fully built, tested at unit level (21/21 pass),
and the infrastructure works end-to-end:

- VM boots via Tart and is reachable over SSH
- TapBenchmark.app builds, signs (ad-hoc with audio-input entitlement),
  and deploys into the VM
- TCC pre-grant succeeds for both Microphone and AudioCapture services
- The binary runs to completion inside the VM's GUI user session
  (launched via `launchctl asuser`)
- Both phases (BlackHole, Tap) execute and emit a report and JSON

What does **not** work yet — signal acquisition. Across host runs and VM
runs:

| Phase     | Symptom                                                           |
| --------- | ----------------------------------------------------------------- |
| BlackHole | `BlackHoleSinkCapture` emits **0 chunks** — its installTap never fires |
| Tap       | `ProcessTapCapture` emits chunks at the expected rate (~512 samples per chunk, ~98 chunks/s) but **every sample is 0.0** |

Both phases report 100% drop rate as a consequence.

## What was tried during diagnosis

1. Gain — raised from `-40 dB` (~0.007 amplitude, below the 0.3 PeakDetector
   threshold) to `0 dB` (full 0.7 amplitude). No change in behavior.
2. Click buffer content — verified non-zero samples in the buffer.
3. `engine.isRunning` and `player.isPlaying` — both `true` after `engine.start()`.
4. Output node format — `2 ch, 44100 Hz, Float32, deinterleaved`. Mono 48 kHz
   buffer connects via AVAudioEngine's auto-conversion.
5. Skipped `setOutputDevice()` for the Tap phase to verify the engine
   could route to the default output device. Tap still captured silence.
6. Switched scheduling to `scheduleBuffer(at: nil)` (immediate) in case
   `AVAudioTime(hostTime:)` with a future tick was being interpreted
   wrong. Same result.

## Hypotheses

- **BlackHole 0 chunks**: `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)`
  on `engine.outputNode.audioUnit` returns `noErr` but doesn't actually
  rebind the output. The engine continues to render into the default
  device. BlackHole 16ch receives nothing → installTap on its input fires
  zero callbacks. Worth exploring: `AVAudioFormat`-based output unit
  rebinding, or bypass AVAudioEngine entirely with AUHAL.
- **Tap silent chunks**: AVAudioEngine on macOS may push to a private
  audio path that Process Tap does not monitor at the per-process level.
  This contradicts the documented behavior of `CATapDescription
  (monoMixdownOfProcesses:)`, so worth verifying with a CATap on a known-emitting
  process (e.g. `afplay`) before assuming the API is at fault.

## Next steps for a follow-up session

1. Verify Process Tap mechanics independently: spawn `afplay` of a known
   WAV, tap that PID, capture, compute RMS — expect > 0.
2. If (1) works, the issue is AVAudioEngine ↔ ProcessTap interaction.
   Replace `SignalGenerator`'s AVAudioEngine usage with raw AUHAL (or
   `AudioQueue`) writing samples directly to the chosen output device.
3. If (1) fails, debug ProcessTapCapture: log `mNumberChannels` and
   `mDataByteSize` in the IOProc, check `kAudioTapPropertyFormat`
   for the actual stream format, verify the aggregate device's stream
   description matches the capture buffer format.
4. For BlackHole binding: read back
   `AudioUnitGetProperty(kAudioOutputUnitProperty_CurrentDevice)` after the
   set call to confirm it stuck. If not, try setting before `engine.start()`
   via the device's HAL audio unit directly.

## What is solid in the prototype

Everything outside signal acquisition is verified working:

- `HostTimeClock`, `PeakDetector`, `MetricsCalculator`, `Report` — pure
  logic, 21 unit tests, all pass
- `ProcessTapCapture` lifecycle — IOProc installs, fires, tears down
  cleanly. The TCC entitlement survives the in-VM `codesign --preserve-metadata`.
- `CPUSampler` — produces sensible CPU% (1–4% in idle phases).
- VM driver script — boots VM, deploys, runs, collects JSON, stops VM.
  State-aware so it correctly distinguishes "VM stopped" from
  "VM with stale IP cached".
- Bundle workflow — `bundle_app.sh --target tap-benchmark` produces a
  signed .app with the right entitlements.

This is a working scaffold ready for the signal-acquisition issue to be
solved in a follow-up. The decision on "Tap vs BlackHole" can't be made
from this run, but the path to make it is clear.
