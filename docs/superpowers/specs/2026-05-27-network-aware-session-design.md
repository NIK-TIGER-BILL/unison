# Connectivity-aware session — design

## Problem

Unison currently reacts to network problems with a coarse three-step
machine: while the WebSocket(s) are open it stays in `.translating`,
on a close it flips to `.reconnecting` for at most 15 seconds, then
escalates to terminal `.error(.networkLost)` (or `.apiKeyInvalid`
when no data ever flowed). After a terminal error the user must
click Start manually. There is no signal for "the WebSocket is still
up but deltas are arriving late", no per-stream visibility when one
of the two CALL-mode streams is healthy and the other is not, and no
acknowledgement when network returns after a sustained outage.

User-facing symptoms in real-world flaky-network conditions
(video-conference scenario):

- Brief WS blip (<3 s) → mic audio for those seconds is dropped on
  the floor; user typically doesn't notice the gap themselves and
  has no idea their tool noticed either.
- Sustained slowdown (WS open, deltas late) → Russian transcript
  stops appearing for several seconds, then arrives in a burst; the
  popover shows "translating" the whole time. User cannot tell
  apart "the network is slow" from "the app broke".
- Full WiFi loss (>15 s) → app gives up, lands in `.error`. After
  the network returns, user has to manually press Start. If they
  miss this, translation is silently off for the rest of the call.
- One stream of two flaps (one speaker's WebSocket dies, the
  other's stays healthy) → half the conversation is silently
  untranslated. Detectable only in logs.

## Goals

1. Auto-resume translation when the network returns after a
   sustained outage — no manual click required.
2. Make degraded but functioning state (`.slow`) visible in the UI
   so the user can distinguish "network is bad" from "the app is
   broken".
3. Recover transparently from blips short enough to be invisible to
   the user (≤3 s) by buffering mic audio and replaying it on
   reconnect.
4. Mark mid-phrase translation losses in the transcript so the user
   sees what was missed instead of an empty bubble.
5. Surface per-stream asymmetry (me-stream slow, peer-stream
   healthy or vice-versa) via the existing diagnostic dialog — main
   UI aggregates per-stream into one overall health.

## Non-goals

- Buffering audio across **long** outages (>3 s). Replaying minutes-old
  mic audio onto a fresh WebSocket session means translations arrive
  long after the live conversation moved on — that's worse than no
  translation. The threshold is a deliberate UX tradeoff.
- Per-stream UI prominence in popover / control pill. CALL mode has
  two streams; surfacing both as separate top-level indicators
  doubles the UI surface for marginal everyday value. Aggregate
  into one indicator; route the per-stream detail to the Diagnostic
  window for the rare cases the user wants it.
- Menubar status-item icon colour changes for `.slow`. The menubar
  is global and persistent; flickering it on every brief slowdown
  is intrusive. Reserve menubar colour changes for true `.paused`
  / `.error`, *not* for soft degradation. (Decision: even on
  `.paused`, keep menubar colour as-is — `.paused` is visible in
  popover + pill, that's enough.)
- macOS notifications. Same rationale — too intrusive for an event
  that's already shown in two places.

## State model

Two orthogonal axes.

### Axis 1 — `SessionState` (existing, one new case)

```swift
public enum SessionState: Sendable, Equatable {
    case idle
    case connecting(mode: SessionMode)
    case translating(mode: SessionMode, startedAt: Date)
    case paused(mode: SessionMode, since: Date, startedAt: Date, reason: PauseReason)  // NEW
    case reconnecting(mode: SessionMode, since: Date, startedAt: Date)
    case error(TranslationError)
}

public enum PauseReason: Sendable, Equatable {
    /// `NWPathMonitor` reported `unsatisfied` — system has no network
    /// path at all (WiFi off, ethernet unplugged, airplane mode).
    case networkLost
    /// Network came back, we're re-establishing streams. Brief
    /// transitional state visible to the UI as "Возобновляем…".
    case awaitingNetwork
}
```

`.reconnecting` keeps its current meaning — a WS-level flap *while*
the network is otherwise healthy. NWPath-driven outages flip
straight to `.paused`. The orchestrator's reconnect loop and
`reconnectWatchdog` continue to handle the WS-level case unchanged.

`startedAt` is preserved across `.translating ↔ .paused ↔ .translating`
so the popover timer keeps ticking from the user's original Start
click.

### Axis 2 — `ConnectivityHealth` (new, orthogonal)

```swift
public enum ConnectivityHealth: Sendable, Equatable {
    /// Baseline. Deltas are flowing, no concerns.
    case healthy
    /// User is speaking (mic RMS > 0.001 in the last 1 s) but the
    /// server hasn't returned any delta in ≥3 s. WS is still open.
    case slow
    /// Stream just reconnected. UI shows a "Связь восстановлена"
    /// flash for 2 s, then returns to `.healthy` on the next delta
    /// (or the 2 s timer, whichever comes first).
    case recovering
}
```

Only meaningful when `SessionState == .translating`. In `.paused` /
`.reconnecting` / `.error` the UI reads from the SessionState alone.

`ConnectivityHealth` is computed independently per stream
(me/peer) and aggregated for the main UI: if either is `.slow`,
overall is `.slow`. Diagnostic dialog shows per-stream.

## Detection

| Signal | Source | Trigger |
|---|---|---|
| `NWPathMonitor` → `.unsatisfied` | new `NetworkMonitor` actor in `UnisonSystem` | `.translating → .paused(.networkLost)`. Close WSes gracefully, stop mic + peer captures. |
| `NWPathMonitor` → `.satisfied` while in `.paused` | same | `.paused(.networkLost) → .paused(.awaitingNetwork) → .connecting`. Re-establish streams via the existing connect path. |
| WS close (`.normalClosure`, `.abnormalClosure(networkLost)`) while in `.paused` | `OpenAIRealtimeStream.handleClose` | Ignored — we're already paused. |
| Mic RMS > 0.001 for 1 s **AND** no delta from this speaker's stream for 3 s | new counter on the orchestrator's per-stream pipeline task | `health[speaker] = .slow` |
| Any delta arrives (input/output transcript or audio) | existing `stream.transcripts` / `stream.output` consumers | `health[speaker] = .healthy` |
| Stream reconnect succeeds (existing reconnect loop) | `handleStreamFailure` success branch | `health[speaker] = .recovering` for 2 s, then natural transition to `.healthy` on next delta or timer expiry |

The "mic audible AND no delta" gate prevents the false-positive case
where the user is simply listening to the other side and not speaking
themselves — in that case mic frames have RMS ≈ 0 and we don't flag
`.slow`. (This is the same RMS threshold already used by the
no-data watchdog in `markMicFrameReceived`.)

## Mic audio ring buffer (brief-blip recovery)

For blips short enough that NWPathMonitor never reports unsatisfied
(typically WS-level flap, 0–3 s), we want translation to recover
**without visible UI changes** — the user shouldn't even know it
happened.

Implementation:

- 3-second ring buffer of mic frames per outgoing stream
  (`UnisonAudio/AudioRingBuffer.swift`, new). Wire format is OpenAI's
  24 kHz int16 PCM, so 3 s × 24 000 samples × 2 bytes = 144 KB per
  stream. Negligible memory.
- In `wireOutgoingPipeline`'s `task1` (mic-frame → wire-format →
  `stream.send`), copy each post-transformer frame into the ring
  buffer *before* sending. If `stream.send` succeeds the buffer
  entry is effectively redundant; if it fails (WS closed
  underneath) the buffer holds the frames that didn't make it.
- On stream reconnect (`handleStreamFailure` success branch),
  *before* wiring the new stream's pipeline, flush the buffer to
  `newStream.send(...)` in order. Then clear the buffer. The new
  WS session sees a small audio burst, treats it as fresh input,
  starts emitting deltas — and with the existing 2 s time-gap
  rotation, the deltas usually land in the same bubble (gap is
  typically <2 s for blips this short).
- The buffer is **cleared and disabled** the moment the
  orchestrator enters `.paused`. After the threshold (3 s outage)
  there's no point trying to splice in old audio — by then the
  conversation has moved on. This is the deliberate "drop is more
  honest than late translation" tradeoff.

Why 3 s as the threshold: empirically, a person speaks ~3 words per
second; a 3 s window covers ~9 words. A WS blip lasting <3 s and
followed by a buffer replay means the user lost at most one
sentence-fragment from their own speech — the translation usually
catches up within the same phrase. Beyond 3 s the speaker is past
the previous sentence and translating stale audio actively confuses
the listener.

## UI

Single status indicator across two surfaces — popover and transcript
control pill. No menubar changes.

| State / health | Status dot colour | Popover text | Pill text |
|---|---|---|---|
| `.translating` + `.healthy` | cyan (existing) | timer only | — |
| `.translating` + `.slow` | yellow | "Медленная сеть" | — |
| `.translating` + `.recovering` (2 s flash) | cyan with brief brightness pulse | "Связь восстановлена" | — |
| `.paused(.networkLost)` | grey | "Нет интернета. Ждём…" | "Пауза" |
| `.paused(.awaitingNetwork)` | cyan (returning) | "Возобновляем…" | "Возобновляем…" |
| `.reconnecting` | yellow (existing) | "Переподключение…" | "Переподключение…" |
| `.error(.networkLost)` | red | "Связь потеряна. Нажмите Старт" | — |

`StatusDot` already supports `.ready/.active/.warn` — we extend with
`.paused` (grey) and `.recovering` (cyan with subtle pulse). Colours
follow `UnisonColors` (`cyan/yellow/grey/red/coral`).

Text under the timer in the popover already exists as a "secondary
text" slot; we extend its source from a single state-derived string
to one that incorporates both `SessionState` and `ConnectivityHealth`.

## Lost-translation bubbles

When a phrase's `entryId` exists with non-empty `originalText` but
`translatedText` stays empty for ≥10 s **AND** the orchestrator
transitioned through `.paused` / `.reconnecting` during that window,
the bubble is permanently marked as having lost its translation.

Implementation:

- `TranscriptStore` tracks per-entry "in-flight" timestamps. A
  background watcher on the orchestrator's `state` transitions
  flags entries that were active during a pause / reconnect.
- After the orchestrator returns to `.translating` (or to `.idle`),
  any entry that's still missing `translatedText` past the 10 s
  cutoff gets a `translatedText = ""` → placeholder shape:
  `BubbleViewModel` renders a grey italic line "*Перевод не получен —
  нестабильная сеть*" with a leading `exclamationmark.bubble` SF
  Symbol where the translation would be. Original text stays as-is.

Why 10 s: long enough that we don't mark live in-progress phrases
as lost; short enough that the user sees the marker before the
session moves on.

Note: this is purely a render-time concern, not a data mutation.
The empty `translatedText` field stays empty in `TranscriptEntry`;
the bubble view derives the placeholder. This way, if a delayed
delta does arrive later, it overwrites the placeholder cleanly.

## Watchdog timing changes

Two watchdogs in the orchestrator need re-tuning to match the new
model:

- `reconnectWatchdogSeconds` (currently 15) →
  - **WS-level reconnect (no NWPath unsatisfied):** keep 15 s. If
    we can't reconnect inside that window without a global network
    drop, something's structurally wrong (auth, model removed, etc).
  - **`.paused(.networkLost)` → recovery attempt:** 60 s. Allow a
    full minute for the network to come back before escalating to
    terminal `.error(.networkLost)`. After 60 s show "Связь
    потеряна. Нажмите Старт" and stop trying.
- `noDataWatchdogSeconds` (currently 20) → unchanged. The mic-frame
  latch already correctly distinguishes "user silent" (don't fire)
  from "mic dead" (fire).
- `emptyCloseTerminalThreshold` (currently 1) → unchanged. This
  defends against authentication failures, not network. NWPathMonitor
  + the new `.paused` path is the network defence; empty close still
  means "WS accepted then dropped before delivering data" which is
  classic auth/policy.

## Component changes

| Component | Change |
|---|---|
| `Sources/UnisonDomain/SessionState.swift` | Add `.paused(...)` case + `PauseReason` enum. Update `isActive` to include `.paused` (yes — pause is part of an active session). Update `activeMode`, `sessionStartedAt`. |
| `Sources/UnisonDomain/ConnectivityHealth.swift` (new) | `ConnectivityHealth` enum + per-stream → aggregate logic. |
| `Sources/UnisonSystem/NetworkMonitor.swift` (new) | Actor wrapping `NWPathMonitor`. Exposes `AsyncStream<NWPath.Status>` for the orchestrator to subscribe to. |
| `Sources/UnisonAudio/AudioRingBuffer.swift` (new) | Thread-safe ring buffer of `AudioFrame`, drops oldest when full. Used per-outgoing-stream. |
| `Sources/UnisonDomain/TranslationOrchestrator.swift` | Subscribe to `NetworkMonitor`. Wire ring buffer into outgoing pipeline. Track per-stream health. Flush buffer on reconnect. Mark in-flight entries during pause. Re-tune watchdog for the new 60 s pause-recovery window. |
| `Sources/UnisonDomain/TranscriptStore.swift` | Track per-entry in-flight timestamp. Add helper to derive "translation lost" for the view. |
| `Sources/UnisonUI/ViewModels/PopoverViewModel.swift` | Surface aggregate `ConnectivityHealth` + extend status text computation. |
| `Sources/UnisonUI/ViewModels/TranscriptViewModel.swift` | Same for the control pill. |
| `Sources/UnisonUI/BubbleViewModel.swift` | `.translationLost` boolean derived from entry's empty `translatedText` + recent pause/reconnect transit. |
| `Sources/UnisonUI/Components/Bubble.swift` | Render placeholder for `.translationLost` case. |
| `Sources/UnisonUI/Components/StatusDot.swift` | Add `.paused` (grey) and `.recovering` (pulsing cyan) cases. |
| `Sources/UnisonApp/DiagnosticCollector.swift` | Add per-stream health to the snapshot so the diagnostic dialog surfaces "me healthy, peer slow" type asymmetry for support. |

## Testing

Unit tests at the domain layer (no network needed):

- `TranslationOrchestratorTests`:
  - NWPath `.unsatisfied` while `.translating` → `.paused(.networkLost)`; mic + peer captures stopped.
  - NWPath `.satisfied` while `.paused` → `.paused(.awaitingNetwork)` → `.translating`.
  - Pause >60 s without recovery → `.error(.networkLost)`.
  - Mic RMS > 0.001 + no delta for 3 s → `health = .slow`. First delta → `health = .healthy`.
  - Per-stream health: me-slow + peer-healthy → aggregate slow.
- `AudioRingBufferTests`:
  - Ring fills, oldest dropped on overflow.
  - Flush in FIFO order.
  - Clear on `.paused`.
- `TranscriptStoreTests`:
  - Entry with empty `translatedText` + transition through `.paused` for >10 s → `BubbleViewModel.translationLost == true`.
  - Late-arriving delta clears the lost flag.

Snapshot tests for the new UI states:

- `PopoverViewSnapshotTests`:
  - `popover_translatingSlow`
  - `popover_pausedNetworkLost`
  - `popover_pausedAwaitingNetwork`
  - `popover_recoveringFlash`
- `TranscriptViewSnapshotTests`:
  - `transcript_bubbleWithLostTranslation`

End-to-end (via existing `UNISON_FORCE_STATE` harness, no real
network needed): a new `network-flap` force state that emits a fake
NWPath flap sequence over 5 s to verify the full pause→recover
cycle UI-side. (Optional — feasible but not blocking.)

## Open questions / future work

- Should the user be able to manually pause translation via a UI
  control (separate from the network-driven pause)? Out of scope for
  this design — it's a feature request, not a bug fix.
- Should we offer "retry translation for this phrase" on a bubble
  marked `translationLost`? Technically possible (resend the audio
  if we have it in the ring buffer) but adds significant UX
  complexity. Defer.
- Should `.paused` survive across `Stop` → restart? Currently
  `.paused` is a sub-state of an active session; pressing Stop
  exits it cleanly. No change needed.
