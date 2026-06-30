# Acoustic echo cancellation (speaker mode) — design

## Problem

When the user listens on the **built-in MacBook speakers** instead of
headphones, Unison feeds back on itself:

1. The incoming peer translation is rendered to the speakers by
   `outputMixer.playTranslated(...)` (+ the quiet original via
   `playOriginal`) — `TranslationOrchestrator.wireIncomingPipeline`
   (`Sources/UnisonDomain/TranslationOrchestrator.swift:1631`).
2. The mic pump in `wireOutgoingPipeline` reads every mic frame and
   ships it straight to OpenAI: `transformer.toWire(frame)` →
   `stream.send(wire)` (`TranslationOrchestrator.swift:1500`).
3. On speakers, the mic acoustically re-captures that translation. It is
   indistinguishable from the user's own speech, so it gets re-translated
   and sent to the peer (and pollutes the me-stream transcript).
4. OpenAI's translate endpoint emits continuously, so a single leaked
   phrase spawns a fresh translation that plays out the speaker and is
   re-captured again. The session **sustains a feedback loop** — the
   user's reported "зацикливается".

`.test` mode has the same shape: mic → me-stream → speakers
(`wireOutgoingPipeline` `.speakers` branch). `.listen` mode has no mic,
so it is unaffected.

Headphones break the loop because there is no acoustic path from speaker
to mic — which is exactly why the bug "disappears" with headphones, and
why real-time interpreters always wear a headset.

**OpenAI `noise_reduction: near_field` is not echo cancellation.** It is
single-channel noise suppression + AGC; it cannot remove a correlated
copy of the far-end signal. It will not help here.

## Goals

1. Eliminate the speaker→mic echo loop in `.call` and `.test` so the user
   can run on built-in speakers without feedback.
2. Preserve the near-end (the user's own voice) during **double-talk**
   (user speaking while the translation plays) — i.e. cancel the echo, do
   not gate the mic.
3. Keep the AEC engine **swappable behind a protocol**. Ship a SpeexDSP
   implementation first; leave WebRTC AEC3 as a drop-in upgrade with no
   call-site changes.
4. Make cancellation **offline-measurable** through an eval harness, the
   same way `pacing-eval` makes playback pacing measurable.
5. Add **zero risk** to the documented Stop/teardown path (see the
   Stop-hang saga in `docs/audio-pipeline.md`).

## Non-goals

- WebRTC AEC3 itself in v1. The protocol seam and eval harness exist
  precisely so the upgrade is a later, measured decision.
- Noise suppression / AGC on the mic. OpenAI `near_field` owns near-end
  NR; we do echo cancellation only and avoid double-processing.
- Auto-detecting headphones vs. speakers. The canceller runs always-on in
  mic modes; with headphones there is no correlated echo, so it converges
  to a near-passthrough at negligible CPU cost. No device sniffing.
- A user-facing Settings toggle (YAGNI for v1 — add only if real-world
  near-end degradation is observed).
- Cancelling echo on the BlackHole / virtual-mic path. That audio goes to
  the peer's conferencing app, is never played on the user's speakers,
  and therefore is not part of the acoustic reference.

## Background — why this is the tractable case

Unlike a generic conferencing app, Unison is in a privileged position:

- **Perfect digital reference.** We own the exact samples we render to the
  speakers; a normal app must loopback-capture its own output.
- **Fixed geometry.** The built-in speaker↔mic acoustic path on a laptop
  is short and stationary — the easy case for an adaptive filter.
- **Mono both sides.** Mic capture and playback are already mono, so no
  channel-mapping ambiguity.

## Architecture

```
.call — what plays on the speakers is what the mic re-captures
                              ┌─────────────── outputMixer (AVAudioEngine) ──────────────┐
 peer translation (incoming) ► playTranslated ─┐                                          │
 original (quiet, 0.2) ───────► playOriginal ──┼─► mainMixerNode ─► outputNode ─► 🔊      │
                                               │        │ installTap (48k F32)            │
                                               └────────┼─────────────────────────────────┘
                                                        ▼ pushFarReference  (render thread, RT-safe)
                                                 ┌──────────────┐
 🎤 mic (48k F32) ─►[task1]─► processNear(f) ──►│ EchoCanceller │─► clean 48k F32 ─► toWire ─► me-stream ─► 🌐 OpenAI ─► BlackHole ─► peer
                                                │ far ring +    │
                                                │ Speex MDF AEC │
                                                └──────────────┘
```

In `.test` the far-reference on `mainMixerNode` is the user's own
translation (rendered by the outgoing `.speakers` branch). The wiring is
identical; only the source of the rendered audio differs.

### Protocols (UnisonDomain), beside `AudioFormatTransformer`

```swift
/// What the output mixer pushes from its render thread. Real-time safe:
/// the implementation must only write into a lock-free buffer — no locks,
/// no allocation, no syscalls on this call.
public protocol EchoReferenceSink: Sendable {
    func pushFarReference(_ frame: AudioFrame)
}

/// What the orchestrator uses on the mic path.
public protocol EchoCanceller: EchoReferenceSink {
    /// 48 kHz F32 mono in → 48 kHz F32 mono out, echo removed.
    func processNear(_ frame: AudioFrame) -> AudioFrame
    /// Clear adaptive state + far buffer. Called once per session start.
    func reset()
}
```

One concrete object conforms to both and is handed to the mixer (as the
far-end sink) and to the orchestrator (as the near-end processor).

### `SpeexEchoCanceller` (UnisonAudio, `@unchecked Sendable`)

- **far ring** — single-producer/single-consumer lock-free ring of int16
  reference samples. `pushFarReference` converts F32→int16 and writes
  here; the only thing that runs on the render thread.
- **near re-blocker** — accumulates incoming mic samples into fixed Speex
  frame-size blocks.
- **Speex state** — `SpeexEchoState`, owned exclusively by the mic thread.
- `processNear`: for each full near block, pull the matching far block
  from the ring, call `speex_echo_cancellation(near_i16, far_i16,
  out_i16)`, convert `out`→F32, reassemble, return a 48 kHz F32 mono
  `AudioFrame`. **Echo cancellation only** — no Speex NS/AGC (OpenAI does
  NR).
- `reset`: drain the ring + `speex_echo_state_reset`.
- **Lifecycle: persistent singleton.** Created once in `Composition`,
  `reset()` at each session start, **never destroyed** during teardown —
  so no Speex alloc/dealloc lands on the hot Stop path (see Teardown
  safety).

### `CSpeexDSP` — new SPM C target

Vendor the minimal SpeexDSP echo-canceller source subset (`mdf.c`,
`fftwrap.c`, `kiss_fft.c`, `kiss_fftr.c`, `smallft.c`, plus headers; add
`preprocess.c` + `filterbank.c` only if the optional residual suppressor
is enabled) with a module map. **Compiled from source as a plain C
target** — no prebuilt binary, no abseil, no change to notarization.
SpeexDSP is under the Xiph revised-BSD license; vendoring requires keeping
the upstream `COPYING`/notice.

## Signal format & rate

- **Working rate: 48 kHz F32 mono**, exposed by the `EchoCanceller`
  protocol. Rationale:
  - the far reference is captured natively at 48 kHz on `mainMixerNode`
    (no resample),
  - the near signal is native 48 kHz at the mic, processed *before*
    `toWire`,
  - a future **AEC3 swap stays native-rate** (AEC3 supports 16/32/48 kHz;
    it does **not** support 24 kHz).
- Running at the 24 kHz wire rate was rejected precisely because it would
  make the AEC3 drop-in impossible without resampling gymnastics.
- Speex's API is int16; the implementation converts F32↔int16 internally.
  The cleaned 48 kHz F32 frame flows into the existing `toWire`
  (→ 24 kHz int16) unchanged.

## Reference source — tap the real render, not the schedule

The far reference is a tap installed on `AVAudioOutputMixer`'s
`mainMixerNode`. That captures the **actual rendered mix** — translated
(post-`timePitch` rate, post-`CompensatingAGC`) **plus** original — i.e.
exactly what reaches the speaker. Reconstructing the reference from the
frames we *scheduled* would miss both the pacing time-stretch and the AGC
gain baked into the played samples, so the filter would adapt against the
wrong signal.

(The mixer already runs a separate `timePitch` tap for the
`UNISON_DUMP_PLAYBACK_WAV` diagnostic; a second tap on a different node is
fine.)

## Threading & real-time safety

The two-thread split is the pattern WebRTC's APM is designed around, and
maps cleanly onto SpeexDSP here:

- **Render thread** (the `mainMixerNode` tap callback) only calls
  `pushFarReference` → F32→int16 → lock-free ring write. No locks, no
  allocation, no logging on this path.
- **Mic thread** (`wireOutgoingPipeline` `task1`) owns the Speex state
  exclusively: it pulls aligned far blocks from the ring and runs the
  cancellation. Single-threaded state access; the ring is the only
  cross-thread handoff.
- **Re-blocking.** `AVCaptureSession` delivers variable mic chunk sizes
  and the mixer tap delivers its own block size; the canceller internally
  re-blocks both to the Speex frame size, so no samples are lost or
  duplicated.
- **Delay budget.** The fixed output→input round-trip latency (~20–40 ms
  on macOS) plus room reverb is absorbed by the adaptive filter tail
  (~150–250 ms, tunable). The eval harness validates the budget; if a
  device exceeds it, a coarse fixed pre-alignment can be added before the
  ring. AEC3 later replaces this with its own delay estimator.

## Wiring

- **`Composition`** constructs one `SpeexEchoCanceller`, injects it into
  the orchestrator via a new optional parameter
  `echoCanceller: (any EchoCanceller)? = nil`, and the orchestrator hands
  it to the mixer per session.
- **`TranslationOrchestrator`**:
  - In `wireOutgoingPipeline` `task1`, when a canceller is present:
    `let cleaned = echoCanceller.processNear(frame)` **before**
    `transformer.toWire(cleaned)`.
  - At session start, for mic modes only (`mode.requiresMicrophone` →
    `.call` / `.test`), register the far sink:
    `outputMixer.setEchoReference(echoCanceller)` and call
    `echoCanceller.reset()`. `.listen` skips registration.
  - During `stopAllStreams()`, `outputMixer.setEchoReference(nil)`.
- **`AudioOutputMixer` protocol** gains
  `func setEchoReference(_ sink: (any EchoReferenceSink)?)`.
  `AVAudioOutputMixer` installs/removes the `mainMixerNode` tap in that
  method; test mocks implement a no-op.

## Teardown safety (critical — respects the Stop-hang history)

`docs/audio-pipeline.md` documents a deterministic Stop wedge: with a
Process Tap active, `AVAudioPlayerNode.stop()`'s completion-handler flush
never returns, hanging teardown. The AEC additions must not reintroduce a
hang:

1. **Remove the `mainMixerNode` tap FIRST** in `AVAudioOutputMixer.stop()`
   — before `translatedPlayer.reset()` / `originalPlayer.reset()` /
   `engine.stop()` — mirroring how `closePlaybackDumpIfNeeded` removes its
   tap first. `removeTap` drains pending render callbacks before
   returning, so no `pushFarReference` runs after teardown begins.
2. **Ordering:** `setEchoReference(nil)` → mixer removes the tap → no more
   far pushes → the sink reference is safe to drop.
3. **No Speex alloc/dealloc on the Stop path.** The canceller is a
   persistent singleton (`reset()` per session, destroyed only at process
   exit), so teardown never touches Speex allocation.
4. `processNear` is pure DSP that returns promptly; cancelling `task1`
   mid-frame is safe (no blocking I/O, no completion handlers).

This is exercised by the existing `start-stop-start` integration forcing
state and the stop-restart unit path, plus a VM real-call check.

## Scope & configuration

- **Modes:** `.call` and `.test` only (mic present). `.listen` untouched.
- **Always-on** within those modes; no headphone/speaker detection, no
  Settings toggle in v1.
- **Speex config:** echo cancellation only. `frame_size` and
  `filter_length` (tail ≈ 150–250 ms) are tunable constants validated by
  the eval harness. The optional residual-echo preprocessor stays off by
  default (kept mild if ever enabled). No Speex NS/AGC.

## Testing & evaluation

- **Unit (`SpeexEchoCancellerTests`, in `UnisonAudioTests`):**
  - *Passthrough:* far = silence, near = speech → output ≈ near (no
    near-end distortion).
  - *Cancellation:* near = silence, far = tone/speech → output → ~0 after
    convergence (high ERLE).
  - *Double-talk:* near = speech A, far = delayed speech B → B suppressed,
    A preserved.
  - *Re-blocking:* feed variable chunk sizes → sample-exact output length,
    no loss/duplication.
  - *Reset:* `reset()` clears adaptive state + far ring.
- **`aec-eval` CLI (`Sources/Tools/AecEval`),** analogous to `pacing-eval`:
  synthesize a mic signal = near + α·delay(far) [+ optional room IR],
  run it through the canceller, and report **ERLE (dB) per second** plus a
  near-end preservation metric. Sweeps delay / α / tail length. This is
  the **Speex-vs-AEC3 comparison gate** — the harness, not a guess,
  decides whether the AEC3 upgrade is warranted.
- **Fixtures:** reuse `Tests/Fixtures/audio/{ru,en}-monologue-*.wav` as
  near-end; add a translation-like far fixture; extend
  `Tests/Fixtures/audio/generate.sh`.
- **VM verification** (per project testing discipline — exhaust autotests
  before manual): full Swift Testing suite + SwiftLint + green offline
  eval first; then a Tart VM real-call on built-in speakers, comparing the
  me-stream `UNISON_DUMP_SENT_WAV` dump before/after the change to confirm
  the leaked translation is gone (ERLE in the wild).

## Package / module changes

- New **`CSpeexDSP`** C target (vendored BSD sources + module map +
  upstream notice).
- **`UnisonAudio`** depends on `CSpeexDSP`.
- New **`AecEval`** executable target (deps: `UnisonAudio`,
  `UnisonDomain`).
- New protocols `EchoReferenceSink` / `EchoCanceller` in `UnisonDomain`.

## Risks & open questions

- **Clock drift.** Mic capture (`AVCaptureSession`) and playback
  (`AVAudioEngine`) run on different clocks; over a long session the
  far/near alignment can drift beyond the filter tail. Mitigation: a
  generous tail + long-run eval; if it bites, periodic re-sync or the
  AEC3 delay estimator. **Open: confirm drift magnitude over a 30-min eval
  run.**
- **Built-in-speaker nonlinearity at high volume** can exceed Speex's
  linear-filter + mild-residual capacity. The eval harness quantifies the
  residual; a poor result is the trigger to spend the AEC3 integration.
- **Tap × Process-Tap teardown.** Low risk (mirrors the existing dump
  tap), but explicitly covered by the teardown ordering above and the
  stop-restart + VM checks.
- **Licensing.** SpeexDSP revised-BSD — compatible; keep the upstream
  notice in `CSpeexDSP`.

## File-by-file change list

- `Sources/UnisonDomain/Protocols/EchoCanceller.swift` — **new**
  (`EchoReferenceSink`, `EchoCanceller`).
- `Sources/UnisonDomain/Protocols/AudioOutputMixer.swift` — add
  `setEchoReference(_:)`.
- `Sources/UnisonDomain/TranslationOrchestrator.swift` — new optional
  `echoCanceller` dependency; `processNear` before `toWire` in
  `wireOutgoingPipeline`; register/unregister far sink at start/stop;
  gate on `mode.requiresMicrophone`.
- `Sources/CSpeexDSP/**` — **new** vendored SpeexDSP subset + module map +
  notice.
- `Sources/UnisonAudio/SpeexEchoCanceller.swift` — **new** concrete
  implementation (ring, re-blocker, F32↔int16, Speex lifecycle).
- `Sources/UnisonAudio/AVAudioOutputMixer.swift` — `setEchoReference(_:)`
  installs/removes the `mainMixerNode` tap; `stop()` removes it first.
- `Sources/UnisonApp/Composition.swift` — construct the singleton; inject
  into the orchestrator.
- `Sources/Tools/AecEval/**` — **new** eval CLI.
- `Tests/UnisonAudioTests/SpeexEchoCancellerTests.swift` — **new** unit
  tests.
- `Tests/Fixtures/audio/generate.sh` — add the far/translation fixture.
- `Package.swift` — `CSpeexDSP` target, `UnisonAudio` dependency, `AecEval`
  executable target.
- `docs/audio-pipeline.md` — document the AEC stage, the
  `mainMixerNode`-tap reference, and the teardown ordering.
```

*Last updated: 2026-06-30*
