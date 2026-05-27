# Tap-benchmark smoke run — known issues (2026-05-27)

The 13-task prototype is fully built, tested at unit level (21/21 pass),
and the infrastructure works end-to-end:

- VM boots via Tart and is reachable over SSH
- TapBenchmark.app builds, signs (ad-hoc with audio-input entitlement),
  and deploys into the VM
- TCC pre-grant resets succeed for both Microphone and AudioCapture
- The binary runs to completion inside the VM's GUI user session
  (launched via `launchctl asuser`)
- Both phases (BlackHole, Tap) execute and emit a report and JSON

What does **not** work yet — signal acquisition produces zero usable
clicks across all configurations tried.

## Findings from the debugging session

### 1. AVAudioEngine output device binding is broken

Setting `kAudioOutputUnitProperty_CurrentDevice` on
`AVAudioEngine.outputNode.audioUnit` is accepted (readback confirms the
new device ID) but the engine renders into the system default device,
not the bound one. **Verified by isolation test**
(`/tmp/test-bh-output.swift`): a fresh AVAudioEngine output bound to
BlackHole 16ch + a fresh AVAudioEngine input bound to the same → 0
chunks delivered.

Default-output-swap workaround introduces a second regression: with BH
16ch as default, `engine.inputNode.outputFormat(0)` shifts from
`1ch / 48000 Hz / Float32` to `2ch / 44100 Hz / Float32 deinterleaved`,
which `installTap(format:)` rejects with `Failed to create tap due to
format mismatch`.

### 2. Raw AUHAL output to a specific device works

`AUHALSignalGenerator` (in this branch) uses
`kAudioUnitSubType_HALOutput` + `kAudioOutputUnitProperty_CurrentDevice`
+ render callback. **Render callback fires reliably** (verified at 512
frames per callback). This is the path production code would use for
per-device output.

### 3. Raw AUHAL input also works, with caveats

`AUHALInputCapture` (in this branch) sets up an AUHAL input scope, binds
to BlackHole 16ch, and pulls samples through `AudioUnitRender` in the
input callback. Callbacks **do fire**, but two caveats observed:

- **Throughput is partial**: ~80 chunks of 512 samples each over 4.5s
  of capture, total ~0.85s of audio. The remaining time is dropped.
  Root cause: the input callback runs on the realtime audio thread, and
  we allocate a `[Float]` and append to a locked array per callback —
  realtime-unsafe, the OS aborts or skips work to keep the audio
  schedule. A production-quality fix uses a lockless ring buffer
  pre-allocated up-front and a separate consumer thread.
- **Loopback amplitude is attenuated**: BH 16ch round-trip peak was
  ~0.09 from a 0.7-amplitude click train. Suspicion: BlackHole 16ch's
  internal channel routing/mixing reduces per-channel amplitude when
  the source is mono but the device exposes 16 channels — the click
  energy spreads or attenuates. Easiest fix: write a full 16-channel
  click (replicate the mono sample across all channels) or accept the
  amplitude and lower the PeakDetector threshold.

### 4. Process Tap silently denied for ad-hoc bundles

Apple's Process Tap requires a TCC audio-capture grant. From the
system log (`/usr/bin/log show --predicate "subsystem CONTAINS TCC"`):

```
tccd: SecStaticCodeCheckValidity() static code from com.unison.tapbench
    : anchor apple; status: -67050
tccd: For com.unison.tapbench: matches platform requirements: No
…
tccd: ReqResult(Auth Right: Allowed (User Consent), DB Action: None)
```

- `matches platform requirements: No` — the ad-hoc signature does not
  satisfy "anchor apple"; TCC cannot trust the bundle identity.
- `DB Action: None` — even when the user clicks Allow, the grant is
  not persisted. Next launch re-prompts.

Result: `ProcessTapCapture` IOProc fires and delivers chunks at the
expected rate, but every sample is 0.0 — CoreAudio honors the
unverified entitlement enough to deliver buffers but mutes the per-
process audio.

Additionally, when the benchmark is launched as a child of Claude Code
(directly or through `osascript`/`open`), TCC traces the responsibility
chain to `com.anthropic.claude-code` and prompts for *Claude Code's*
access rather than the benchmark's. Cleanest reproduction is launching
the .app from Finder by double-click.

## What's solid

- `HostTimeClock`, `PeakDetector`, `MetricsCalculator`, `Report` — pure
  logic, 21 unit tests, all pass
- `ProcessTapCapture` lifecycle — IOProc installs, fires, tears down
  cleanly (silent samples are a TCC denial, not a code bug)
- `CPUSampler` — produces sensible CPU%
- `AUHALSignalGenerator` — raw AUHAL render, fires reliably
- `AUHALInputCapture` — raw AUHAL capture, fires (modulo realtime-
  unsafe allocator dropping chunks)
- VM driver script — boots VM, deploys, runs, collects JSON, stops VM;
  state-aware (handles stale `tart ip` after the VM stopped)
- Bundle workflow — `bundle_app.sh --target tap-benchmark` produces a
  signed .app with the right entitlements, survives the in-VM re-sign
  with `--preserve-metadata=entitlements`

## What's needed to get real numbers

1. **Lockless ring buffer in `AUHALInputCapture`** — replace the
   per-callback `Array.append` with a pre-allocated `UnsafeMutableBufferPointer`
   ring written from the audio thread and drained from a consumer task.
   Closes the partial-throughput gap.

2. **16-channel click in `AUHALSignalGenerator`** — emit identical
   samples on all 16 channels of BH 16ch rather than mono. Verify
   loopback amplitude reaches ~0.7. Or measure the attenuation
   coefficient empirically and adjust the PeakDetector threshold.

3. **Developer ID signing for the .app bundle** — set `DEVELOPER_ID`
   env var before `bundle_app.sh --target tap-benchmark`. Without it,
   Process Tap captures silence regardless of the source. Until this
   is in place, the Tap phase can't be measured at all.

4. **Direct Finder launch (or proper TCC seed)** in the VM, so the
   responsibility chain doesn't lead back to Claude Code.

Items 1+2 unblock BlackHole measurement on the host (in 1-2 hours of
careful CoreAudio work). Item 3 unblocks Tap measurement (Developer ID
certificate availability is the bottleneck). Item 4 is procedural.

## Bottom line

The prototype is a complete, working scaffold that didn't reach signal
acquisition in the time available. The original architectural question
— "Is Process Tap better than BlackHole 16ch?" — is unanswered by this
measurement attempt, but the unanswered-ness is now well-bounded: every
remaining obstacle is identified and has a known fix.
