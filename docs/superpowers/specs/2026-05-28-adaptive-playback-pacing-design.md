# Adaptive Playback Pacing v2 — design

**Date:** 2026-05-28
**Status:** Approved, ready for implementation plan
**Supersedes:** `PlaybackPacing` v1 (linear interpolation, maxRate=1.15) introduced in commit `bf3a3cd`.

## Background

OpenAI Realtime returns translated PCM via WebSocket faster than wall-clock when the model is generating a response — typically a 1–2 s burst at the start of an utterance, then near-realtime. Each chunk arrives as a discrete `audio.delta` event; our pipeline resamples it to 48k F32 and schedules it onto `AVAudioPlayerNode` non-blockingly.

The user empirically reproduced the failure mode: translation playback volume gradually quiets as latency accumulates, then snaps back to normal once the queue drains. That observation pinpoints the root cause as **player queue depth**, not source PCM amplitude — drainage restores volume.

The exact downstream mechanism by which a deep `AVAudioPlayerNode` queue produces quieter output is not fully understood (candidates: CoreAudio internal SRC dithering, Bluetooth driver clock compensation, render-thread starvation under buffer pressure). We are not chasing that mechanism. The fix targets the cause: **keep the queue shallow at all times**.

v1's linear interpolation with `maxRate=1.15` and `targetQueueSec=0.4` was too timid — it leaves substantial steady-state latency and cannot drain a 2 s burst within the burst's lifetime.

## Goal

Modulate `AVAudioUnitTimePitch.rate` so the translation playback queue is held at or below ~200 ms under typical OpenAI bursts, and degrades gracefully to a maximum of 2.5× during pathological bursts — without dropping any audio samples (no information loss). The user hears all words; only the tempo adjusts.

Applies identically to both translation audio destinations:
- `AVAudioOutputMixer.translatedPlayer` (what the user hears locally)
- `BlackHole2chPlayer.player` (what the peer hears via the conferencing app)

## Non-goals

- **Silence-region dropping** is deferred. If logs show sustained `rate=2.5` with queue still growing, that signals OpenAI is generating faster than 2.5× realtime — at which point silence-skip becomes the natural next layer. Until that's observed in production, YAGNI.
- **Diagnosing the underlying volume-attenuation mechanism** is out of scope. Treating the symptom (queue depth) at the source eliminates the user-visible problem; the mechanism itself is interesting but doesn't affect product behaviour once the queue stays shallow.
- **Tuning per-output device** (Bluetooth vs wired vs BlackHole). Same algorithm everywhere; the parameters are picked to be reasonable across all routes.

## Algorithm

Every 100 ms tick the controller recomputes target rate from two terms and smooths the current rate toward it.

### Inputs

- `scheduledSamples` — running counter, incremented in `didSchedule(samples:)` after each `scheduleBuffer`
- `playedSamples` — `player.playerTime(forNodeTime: player.lastRenderTime).sampleTime` — samples the player has already pulled (= consumed by `AVAudioUnitTimePitch`)
- `depth` (seconds) — `max(0, (scheduledSamples - playedSamples)) / sampleRate`
- `prevDepth` — stored from previous tick
- `velocity` (s of queue / s of wall-clock) — `(depth - prevDepth) / tickInterval`
  - Positive ⇒ queue growing; negative ⇒ draining
  - We treat the tick interval as the constant 100 ms used in `Task.sleep`. Real OS jitter (±10 ms) is masked by the smoothing pass; no need to measure actual elapsed time.

### Constants

| Name | Value | Purpose |
|---|---|---|
| `targetQueueSec` | 0.2 s | Below this, P-term is 0 (no speedup needed) |
| `panicQueueSec` | 1.5 s | At this depth, P-term saturates to 1.0 |
| `maxRate` | 2.5 | Hard ceiling on `timePitch.rate` |
| `K_d` | 1.5 | Velocity coefficient |
| `derivativeClamp` | ±0.5 | Limit D-term so transient noise doesn't whiplash the rate |
| `attackFactor` | 0.7 | Smoothing when rate is going up |
| `releaseFactor` | 0.15 | Smoothing when rate is going down |
| `tickInterval` | 100 ms | Pacing tick period |

### Rate formula

```
// Proportional: how far above the target queue depth are we?
P = clamp((depth - targetQueueSec) / (panicQueueSec - targetQueueSec), 0.0, 1.0)

// Derivative: is the queue growing or draining? Anticipates trajectory.
D = clamp(velocity * K_d, -derivativeClamp, +derivativeClamp)

// Combined target rate. (P + D) is in [-0.5, 1.5] but typically [0, 1].
targetRate = clamp(1.0 + (P + D) * (maxRate - 1.0), 1.0, maxRate)
```

### Smoothing (asymmetric)

```
factor = (targetRate > currentRate) ? attackFactor : releaseFactor
currentRate = currentRate + (targetRate - currentRate) * factor
timePitch.rate = currentRate
```

Fast attack means a sudden burst pushes rate up within ~2-3 ticks (≈ 250 ms). Slow release means once we've drained, we hold the elevated rate briefly to keep eating any residual buffered audio, then ease back to 1.0 over ~1 s.

## Component layout

No new files. The existing `Sources/UnisonAudio/PlaybackPacing.swift` is rewritten:

- Algorithm body in `tick()` replaced with the P+D formula
- One new stored property: `prevDepth`
- Constants updated and extended (`K_d`, `derivativeClamp`, `attackFactor`, `releaseFactor`)
- Log line extended: `[label] pacing — queue=0.65s velocity=+0.30s/s rate=1.80 (P=0.35 D=0.45)`

Callers (`AVAudioOutputMixer`, `BlackHole2chPlayer`) are unchanged — same `init`, `start()`, `didSchedule(samples:)`, `reset()`, `stop()` API.

## Data flow

```
OpenAI Realtime audio.delta
    │
    ▼
Resampler.fromOpenAIWire (24k int16 → 48k F32)
    │
    ▼
AVAudioPlayerNode.scheduleBuffer  ──► didSchedule(samples: buf.frameLength)
                                          │
                                          ▼
                                    scheduledSamples += samples
    │
    ▼
AVAudioUnitTimePitch  ◄─── timePitch.rate = newRate
    │                          ▲
    ▼                          │
mainMixerNode → output     PlaybackPacing.tick() every 100 ms
                               │
                               └── reads player.playerTime(forNodeTime:).sampleTime
                                   computes P, D, smooths, writes rate
```

## Edge cases / error handling

- **Cold start, `lastRenderTime == nil`**: tick returns early. No rate change until the engine has produced at least one render cycle.
- **`playerTime` returns nil** (rare engine-stop race): same — return early, keep current rate.
- **Negative depth** (clock-skew or wrap edge case): clamped to 0 via `max(0, ...)`. P stays at 0.
- **Velocity spike on the first tick after `reset()`** (where `prevDepth` is 0 but depth jumped to whatever was buffered): suppressed by the derivativeClamp. After one tick `prevDepth` catches up.
- **stop-restart cycle**: `reset()` zeroes `scheduledSamples`, `prevDepth`, and sets `rate = 1.0`. The next `start()` begins polling fresh.
- **Player not yet `play()`-ing**: `lastRenderTime` is nil → tick no-ops. Safe.

## Testing strategy

`PlaybackPacing` is unit-testable without a real `AVAudioEngine` if we extract the algorithm into a pure function that takes `(depth, velocity, currentRate, dt)` and returns `newRate`. That function gets table-driven tests for:

1. **No queue** — depth=0, velocity=0 → rate stays at 1.0
2. **Target boundary** — depth=0.2 → rate=1.0 (P=0)
3. **Mid-range** — depth=0.85, velocity=0 → rate ≈ 1.75 (linear P, no D)
4. **Saturated P** — depth=1.5, velocity=0 → rate=2.5 (P=1.0 at panic)
5. **Anticipation (D term up)** — depth=0.3, velocity=+0.5 → rate > 1.0 even though P is small
6. **Anticipation (D term down)** — depth=1.0, velocity=-0.5 → rate < pure-P case (D negative)
7. **Derivative clamp** — depth=0.2, velocity=+10.0 → D contribution capped at 0.5, not unbounded
8. **Asymmetric smoothing** — rate=1.0, target=2.5 → next tick rate=1.0 + (2.5-1.0)*0.7 = 2.05 (attack)
9. **Asymmetric smoothing release** — rate=2.5, target=1.0 → next tick rate=2.5 - (2.5-1.0)*0.15 = 2.275 (release)

The `tick()` wrapper that does the AVAudioPlayerNode I/O stays untested at unit level (covered by manual smoke testing against the real engine).

## Implementation order

1. **Refactor `PlaybackPacing.swift`** — extract pure-function `computeNextRate(depth:velocity:currentRate:dt:)` for testability; rewrite `tick()` to use it
2. **Add `Tests/UnisonAudioTests/PlaybackPacingTests.swift`** — the 9 cases above
3. **Verify build + tests** — `swift test --filter PlaybackPacing`
4. **Build app + install + manual smoke** — run a translation session, watch logs for the new `(P=… D=…)` annotation, confirm queue stays ≤ 0.5 s under typical use and rate stays in [1.0, 2.5]

## Success criteria

A 5-minute conversation produces:
- No reports of audio quieting over time (the user-visible bug)
- Log shows `queue` value consistently ≤ 0.5 s, peaks ≤ 1.5 s
- Log shows `rate` typically in [1.0, 1.5], peaks at 2.5 only during real bursts (not steady-state)

If we observe sustained `rate=2.5` with `queue` still growing, that's the signal to layer silence-skip on top (not in scope for this spec).
