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

What does **not** work yet — signal acquisition. Across host runs and VM
runs:

| Phase     | Symptom                                                           |
| --------- | ----------------------------------------------------------------- |
| BlackHole | `BlackHoleSinkCapture` emits **0 chunks** — its installTap never fires |
| Tap       | `ProcessTapCapture` emits chunks at the expected rate (~98/s) but **every sample is 0.0** |

Both phases report 100% drop rate as a consequence.

## Root causes (verified during follow-up debugging session)

### 1. BlackHole side — AVAudioEngine doesn't push to a manually-bound device

Setting `kAudioOutputUnitProperty_CurrentDevice` on
`AVAudioEngine.outputNode.audioUnit` is accepted (readback confirms the
new device ID) but the engine renders into the system default device,
not the bound one. **Verified by isolation test**: a fresh AVAudioEngine
output bound to BlackHole 16ch + a fresh AVAudioEngine input bound to
BlackHole 16ch → 0 chunks (`/tmp/test-bh-output.swift`).

The default-output swap workaround (set the system default to BlackHole
16ch for the BlackHole phase) introduces a second regression: with BH
16ch as default, `engine.inputNode.outputFormat(0)` shifts from
`1ch / 48000 Hz / Float32` to `2ch / 44100 Hz / Float32 deinterleaved`,
which `installTap(format:)` rejects with `'Failed to create tap due to
format mismatch'`.

**Replacing the AVAudioEngine-based output with raw AUHAL works** for
writing to BlackHole 16ch (`AUHALSignalGenerator` in this branch, render
callback fires at 512 frames/chunk). But BlackHoleSinkCapture still
captures 0 chunks when AUHAL is the source.

Hypothesis: a single process with **both** an AUHAL output unit and an
AVAudioEngine.inputNode bound to the same HAL device causes CoreAudio
to silently fail one of them. Production usage is safe because the
producer (Zoom) and the consumer (Unison) are different processes; the
benchmark's same-process test is the unsupported case.

### 2. Tap side — ad-hoc bundles don't get a persistent TCC grant

Apple's Process Tap requires a TCC audio-capture grant. Verified via
the system log:

```
tccd: [com.apple.TCC:access] -[TCCDAccessIdentity matchesCodeRequirement:]
    SecStaticCodeCheckValidity() static code from com.unison.tapbench :
    anchor apple; status: -67050
tccd: For com.unison.tapbench: matches platform requirements: No
…
tccd: ReqResult(Auth Right: Allowed (User Consent), DB Action: None)
```

Two pieces of bad news:

- `matches platform requirements: No` — the ad-hoc signature does not
  satisfy "anchor apple", so TCC cannot trust the bundle's identity.
- `DB Action: None` — even if the user clicks Allow on the prompt, the
  grant is not persisted to the TCC database, so the next run prompts
  again.

Result: ProcessTap captures chunks but every sample is silence —
CoreAudio honors the unverified entitlement enough to deliver buffers
but the per-process audio is muted on the tap path.

This is **not fixable in the prototype** without one of:

- Signing the bundle with a real Apple Developer ID (then TCC trusts
  the identity and the grant persists). Requires the user's Developer
  ID Application certificate.
- Manually inserting into `TCC.db` with Full Disk Access, which the
  agent does not have.
- Running with TCC enforcement disabled in Recovery / DEBUG mode.

A related complication when running from inside Claude Code: TCC
attributes the responsibility chain back to `com.anthropic.claude-code`
as the "responsible" parent, even when the child binary is launched
through `osascript` / `open`. This means the prompt shown to the user
is for Claude Code's access, not the benchmark's.

## What's solid in the prototype

- `HostTimeClock`, `PeakDetector`, `MetricsCalculator`, `Report` — pure
  logic, 21 unit tests, all pass
- `ProcessTapCapture` lifecycle — IOProc installs, fires, tears down
  cleanly (silent samples are a TCC denial, not a code bug)
- `CPUSampler` — produces sensible CPU% (1–4% in idle phases)
- `AUHALSignalGenerator` — raw AUHAL render to a chosen device, render
  callback fires; demonstrates per-device output works
- VM driver script — boots VM, deploys, runs, collects JSON, stops VM;
  state-aware (handles stale `tart ip` after the VM stopped)
- Bundle workflow — `bundle_app.sh --target tap-benchmark` produces a
  signed .app with the right entitlements, survives the in-VM re-sign
  with `--preserve-metadata=entitlements`

## What's left to actually measure

The infrastructure is ready; signal acquisition needs ~1–2 days of
focused work along one of these axes:

1. **Replace `BlackHoleSinkCapture` for the benchmark** with a raw AUHAL
   input reader that reads from BlackHole 16ch (mirroring
   `AUHALSignalGenerator`'s approach for output). This removes the
   AVAudioEngine in-process conflict and gives a clean BlackHole
   latency measurement. Production `BlackHoleSinkCapture` stays
   unchanged — the benchmark reads through its own path.

2. **Sign with Developer ID** to unblock the Tap side. Set
   `DEVELOPER_ID` env var when running `bundle_app.sh --target
   tap-benchmark`. The Tap chunks should then contain real audio.

Once both are done, the benchmark produces real numbers and the
prototype's success criteria (median latency, jitter, drop rate, CPU,
setup-friendly check, Zoom sanity) become measurable.

Until then: the prototype's value is the **infrastructure** (build,
deploy, isolate, measure surface, report) and the **negative results**
documented here. The original architectural question — "Is Process Tap
faster/easier than BlackHole?" — is **not yet answered** by this
measurement attempt, but the question's tractability is unchanged: once
the signal path is fixed, the same scaffolding will produce verdict
numbers in minutes.
