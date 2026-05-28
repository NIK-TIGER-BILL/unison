# Adaptive Playback Pacing v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `PlaybackPacing` v1's timid linear controller with a predictive P+D controller (maxRate=2.5) that keeps the translated-audio player queue ≤ ~200 ms under typical OpenAI Realtime bursts.

**Architecture:** The algorithm is split into two pure static functions (`computeRate(depth:velocity:)` returning `(target, p, d)`, and `smoothed(currentRate:target:)`) so it's unit-testable without an `AVAudioEngine`. The existing `tick()` method composes them and writes to `timePitch.rate`. Constants (target/panic/maxRate/K_d/clamp/attack/release) live as `static let` at the top of the file.

**Tech Stack:** Swift 6 / AVFoundation (`AVAudioPlayerNode`, `AVAudioUnitTimePitch`), Swift Testing framework (`@Test`, `#expect`), single source file — `Sources/UnisonAudio/PlaybackPacing.swift` — plus a new test file.

**Spec:** [docs/superpowers/specs/2026-05-28-adaptive-playback-pacing-design.md](../specs/2026-05-28-adaptive-playback-pacing-design.md)

---

## Files

- Modify: `Sources/UnisonAudio/PlaybackPacing.swift` — rewrite constants, add pure functions, rewrite `tick()`, add `prevDepth` state, update log format
- Create: `Tests/UnisonAudioTests/PlaybackPacingTests.swift` — 10 table-driven cases for the pure functions

No other files change. `AVAudioOutputMixer` and `BlackHole2chPlayer` continue using the same `PlaybackPacing` API (`init`, `start()`, `didSchedule(samples:)`, `reset()`, `stop()`).

---

## Task 1: P-term `computeRate` + v2 constants

**Files:**
- Create: `Tests/UnisonAudioTests/PlaybackPacingTests.swift`
- Modify: `Sources/UnisonAudio/PlaybackPacing.swift` (constants block + new pure function with P-term only)

- [ ] **Step 1: Create the test file with the 4 P-term cases**

Create `Tests/UnisonAudioTests/PlaybackPacingTests.swift` with this exact content:

```swift
import Foundation
import Testing
@testable import UnisonAudio

@Test func pacing_noQueue_targetIsOne() {
    let r = PlaybackPacing.computeRate(depth: 0.0, velocity: 0.0)
    #expect(r.target == 1.0)
    #expect(r.p == 0.0)
    #expect(r.d == 0.0)
}

@Test func pacing_atTarget_targetIsOne() {
    // At exactly the target queue depth, P=0 (no speedup).
    let r = PlaybackPacing.computeRate(depth: 0.2, velocity: 0.0)
    #expect(r.target == 1.0)
    #expect(r.p == 0.0)
}

@Test func pacing_midRange_targetIsApproxOneAndThreeQuarters() {
    // depth=0.85, target=0.2, panic=1.5 → P=(0.85-0.2)/1.3=0.5
    // target = 1.0 + 0.5 * (2.5 - 1.0) = 1.75
    let r = PlaybackPacing.computeRate(depth: 0.85, velocity: 0.0)
    #expect(abs(r.target - 1.75) < 0.0001)
    #expect(abs(r.p - 0.5) < 0.0001)
}

@Test func pacing_atPanic_targetSaturatesAtMax() {
    let r = PlaybackPacing.computeRate(depth: 1.5, velocity: 0.0)
    #expect(r.target == 2.5)
    #expect(r.p == 1.0)
}
```

- [ ] **Step 2: Run tests — verify they fail to compile**

Run:
```bash
swift test --filter PlaybackPacing
```

Expected: Compile error — `'PlaybackPacing' has no member 'computeRate'` (or similar).

- [ ] **Step 3: Update constants and add `RateState` + P-term-only `computeRate` in PlaybackPacing.swift**

Open `Sources/UnisonAudio/PlaybackPacing.swift`.

Replace the existing constants block (the 5 `private static let` lines: `targetQueueSec`, `panicQueueSec`, `maxRate`, `smoothing`, `logHysteresis` — together with their doc comments) with:

```swift
    /// Below this queue depth the P-term is 0 (no speedup).
    static let targetQueueSec: Double = 0.2
    /// At or above this queue depth the P-term saturates to 1.0.
    static let panicQueueSec: Double = 1.5
    /// Hard ceiling on `timePitch.rate`. AVAudioUnitTimePitch supports
    /// much higher but speech becomes unintelligible past ~3x.
    static let maxRate: Double = 2.5
    /// Velocity coefficient. `D = clamp(velocity * kDerivative, ±derivativeClamp)`.
    static let kDerivative: Double = 1.5
    /// Hard limit on the D-term so a noisy velocity spike doesn't
    /// whiplash the rate.
    static let derivativeClamp: Double = 0.5
    /// Smoothing factor when the new target is higher than current —
    /// fast attack so bursts get caught quickly.
    static let attackFactor: Double = 0.7
    /// Smoothing factor when the new target is lower than current —
    /// slow release so we keep eating buffered audio before easing off.
    static let releaseFactor: Double = 0.15
    /// Polling interval for `tick()`. Velocity is computed as
    /// `(depth - prevDepth) / tickIntervalSec` assuming the constant
    /// — Task.sleep jitter (±10ms) is masked by the smoothing pass.
    static let tickIntervalSec: Double = 0.1
    /// Re-log when rate or queue has moved beyond this delta. Keeps
    /// the diagnostic noise bounded.
    static let logHysteresis: Double = 0.03
```

Then add the `RateState` struct and `computeRate` static function just above the `public init` line:

```swift
    /// Result of one pacing calculation. Decomposed so the diagnostic
    /// log can show why the rate is what it is (which term dominated).
    struct RateState: Equatable {
        let target: Double
        let p: Double
        let d: Double
    }

    /// Pure rate-target computation. Combines a proportional term
    /// (how far above `targetQueueSec` we are) with a derivative term
    /// (how fast the queue is growing or draining), clamps the result
    /// into `[1.0, maxRate]`. Returns the raw unsmoothed target — the
    /// caller applies asymmetric smoothing via `smoothed(currentRate:target:)`.
    ///
    /// At this task's checkpoint the D-term is hardcoded to 0; Task 2
    /// fills it in.
    static func computeRate(depth: Double, velocity: Double) -> RateState {
        let pNum = max(0.0, depth - targetQueueSec)
        let p = min(1.0, pNum / (panicQueueSec - targetQueueSec))
        let d = 0.0
        let raw = 1.0 + (p + d) * (maxRate - 1.0)
        let target = min(maxRate, max(1.0, raw))
        return RateState(target: target, p: p, d: d)
    }
```

- [ ] **Step 4: Run tests — verify they pass**

Run:
```bash
swift test --filter PlaybackPacing
```

Expected: 4 tests pass.

- [ ] **Step 5: Run full test suite — verify nothing else broke**

Run:
```bash
swift test 2>&1 | tail -3
```

Expected: `Test run with N tests in M suites passed`.

- [ ] **Step 6: Commit**

```bash
git add Tests/UnisonAudioTests/PlaybackPacingTests.swift Sources/UnisonAudio/PlaybackPacing.swift
git commit -m "$(cat <<'EOF'
feat(audio): pacing v2 — P-term + new constants

First slice of the v2 pacing controller. Adds the pure-function entry
point computeRate(depth:velocity:) returning a RateState struct (target,
p, d). At this commit the D-term is still hardcoded to 0; following
commits add the derivative anticipation and asymmetric smoothing.

Constants updated to v2 spec values (target 0.2s, panic 1.5s, maxRate
2.5). Old v1 values (target 0.4s, panic 1.0s, maxRate 1.15, smoothing
0.5) and the v1 tick body are still in place — the tick rewrite happens
in Task 4 once all pure functions are tested.
EOF
)"
```

---

## Task 2: D-term in `computeRate`

**Files:**
- Modify: `Tests/UnisonAudioTests/PlaybackPacingTests.swift` (append 3 D-term tests)
- Modify: `Sources/UnisonAudio/PlaybackPacing.swift` (extend `computeRate` with non-zero D)

- [ ] **Step 1: Append 3 D-term tests to the end of PlaybackPacingTests.swift**

Add these tests at the end of the file:

```swift
@Test func pacing_anticipatesGrowth_targetRisesEvenAtShallowQueue() {
    // depth=0.3 → P=(0.3-0.2)/1.3 ≈ 0.0769
    // velocity=+0.5 → D = clamp(0.5*1.5, ±0.5) = 0.5 (clamped)
    // target = 1.0 + (0.0769 + 0.5) * 1.5 ≈ 1.865
    let r = PlaybackPacing.computeRate(depth: 0.3, velocity: 0.5)
    #expect(r.target > 1.5)
    #expect(r.target < 2.0)
    #expect(r.d == 0.5)
}

@Test func pacing_drainingQueue_reducesTargetBelowPureProportional() {
    // depth=1.0, velocity=-0.5
    // P=(1.0-0.2)/1.3 ≈ 0.615
    // D = clamp(-0.5*1.5, ±0.5) = -0.5
    // target = 1.0 + (0.615 - 0.5) * 1.5 ≈ 1.173
    let withDrain = PlaybackPacing.computeRate(depth: 1.0, velocity: -0.5)
    let noDrain = PlaybackPacing.computeRate(depth: 1.0, velocity: 0.0)
    #expect(withDrain.target < noDrain.target)
    #expect(abs(withDrain.target - 1.173) < 0.01)
    #expect(withDrain.d == -0.5)
}

@Test func pacing_derivativeIsClamped_extremeVelocityDoesNotExplodeRate() {
    // velocity=10 is absurd. D should clamp to 0.5 not 15.
    // depth=0.2 (P=0). target = 1.0 + 0.5 * 1.5 = 1.75
    let r = PlaybackPacing.computeRate(depth: 0.2, velocity: 10.0)
    #expect(abs(r.target - 1.75) < 0.0001)
    #expect(r.d == 0.5)
}
```

- [ ] **Step 2: Run new tests — verify they fail**

Run:
```bash
swift test --filter PlaybackPacing
```

Expected: 4 prior tests pass, 3 new tests fail (the new ones expect non-zero `r.d` but the function still hardcodes `d = 0.0`).

- [ ] **Step 3: Replace the hardcoded `d = 0.0` with the real derivative term**

In `Sources/UnisonAudio/PlaybackPacing.swift`, find this line inside `computeRate`:

```swift
        let d = 0.0
```

Replace with:

```swift
        let d = max(-derivativeClamp, min(derivativeClamp, velocity * kDerivative))
```

- [ ] **Step 4: Run tests — verify all 7 pass**

Run:
```bash
swift test --filter PlaybackPacing
```

Expected: all 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Tests/UnisonAudioTests/PlaybackPacingTests.swift Sources/UnisonAudio/PlaybackPacing.swift
git commit -m "$(cat <<'EOF'
feat(audio): pacing v2 — D-term anticipates queue growth

Adds the derivative contribution to computeRate. Positive velocity
(queue growing) pulls the rate up before depth alone would warrant
it; negative velocity (draining) pulls the rate down before depth
alone would. Clamped to ±derivativeClamp so a one-tick velocity
spike from clock jitter can't whiplash the rate beyond 0.5 of the
1.0→maxRate span.
EOF
)"
```

---

## Task 3: `smoothed(currentRate:target:)` with asymmetric attack/release

**Files:**
- Modify: `Tests/UnisonAudioTests/PlaybackPacingTests.swift` (append 3 smoothing tests)
- Modify: `Sources/UnisonAudio/PlaybackPacing.swift` (add `smoothed` static func)

- [ ] **Step 1: Append smoothing tests**

Add at the end of `PlaybackPacingTests.swift`:

```swift
@Test func pacing_attack_movesSeventyPercentTowardTarget() {
    // currentRate=1.0, target=2.5 → next = 1.0 + (2.5-1.0)*0.7 = 2.05
    let next = PlaybackPacing.smoothed(currentRate: 1.0, target: 2.5)
    #expect(abs(next - 2.05) < 0.0001)
}

@Test func pacing_release_movesFifteenPercentTowardTarget() {
    // currentRate=2.5, target=1.0 → next = 2.5 + (1.0-2.5)*0.15 = 2.275
    let next = PlaybackPacing.smoothed(currentRate: 2.5, target: 1.0)
    #expect(abs(next - 2.275) < 0.0001)
}

@Test func pacing_atTarget_smoothingIsIdentity() {
    // No change requested — output equals input regardless of which
    // factor would have applied.
    let next = PlaybackPacing.smoothed(currentRate: 1.5, target: 1.5)
    #expect(next == 1.5)
}
```

- [ ] **Step 2: Run new tests — verify they fail**

Run:
```bash
swift test --filter PlaybackPacing
```

Expected: 7 prior tests pass; 3 new tests fail with `'PlaybackPacing' has no member 'smoothed'`.

- [ ] **Step 3: Add `smoothed` static function**

In `Sources/UnisonAudio/PlaybackPacing.swift`, add this directly below the `computeRate` function:

```swift
    /// One-tick smoothing step. Pulls `currentRate` toward `target`
    /// using `attackFactor` when ramping up (we want to catch bursts
    /// quickly) and `releaseFactor` when ramping down (we want to
    /// hold the elevated rate briefly so any residual buffered audio
    /// finishes draining before we let off).
    static func smoothed(currentRate: Double, target: Double) -> Double {
        let factor = target > currentRate ? attackFactor : releaseFactor
        return currentRate + (target - currentRate) * factor
    }
```

- [ ] **Step 4: Run tests — verify all 10 pass**

Run:
```bash
swift test --filter PlaybackPacing
```

Expected: all 10 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Tests/UnisonAudioTests/PlaybackPacingTests.swift Sources/UnisonAudio/PlaybackPacing.swift
git commit -m "$(cat <<'EOF'
feat(audio): pacing v2 — asymmetric smoothing (fast attack, slow release)

Adds the smoothed(currentRate:target:) pure function. Attack factor
0.7 catches a sudden burst within 2-3 ticks (~250ms); release factor
0.15 holds the elevated rate for ~1s before easing to 1.0, which
keeps any residual buffered audio draining instead of letting it
re-accumulate.
EOF
)"
```

---

## Task 4: Wire pure functions into `tick()` + add `prevDepth` + new log format

**Files:**
- Modify: `Sources/UnisonAudio/PlaybackPacing.swift` (replace `tick()` body, add stored property, update `reset()`, fix `lastLoggedRate` type)

- [ ] **Step 1: Replace `lastLoggedRate` type from Float to Double**

In `Sources/UnisonAudio/PlaybackPacing.swift`, find:

```swift
    private var lastLoggedRate: Float = 1.0
```

Replace with:

```swift
    private var lastLoggedRate: Double = 1.0
```

- [ ] **Step 2: Add `prevDepth` stored property**

In the same file, find the line `private var scheduledSamples: AVAudioFramePosition = 0` and add `prevDepth` immediately below it:

```swift
    private var scheduledSamples: AVAudioFramePosition = 0
    /// Last tick's queue depth in seconds — used to compute velocity.
    /// Reset to 0 in `reset()` so a stop-restart cycle doesn't carry
    /// a stale value into the first tick.
    private var prevDepth: Double = 0
```

- [ ] **Step 3: Update `reset()` to clear `prevDepth`**

Find the `reset()` body. It currently looks like:

```swift
    public func reset() {
        lock.lock()
        scheduledSamples = 0
        lock.unlock()
        timePitch.rate = 1.0
        lastLoggedRate = 1.0
        lastLoggedQueueSec = 0
    }
```

Replace with:

```swift
    public func reset() {
        lock.lock()
        scheduledSamples = 0
        prevDepth = 0
        lock.unlock()
        timePitch.rate = 1.0
        lastLoggedRate = 1.0
        lastLoggedQueueSec = 0
    }
```

- [ ] **Step 4: Replace the `tick()` body**

Find the entire `private func tick()` method (the whole `if queueSec >= Self.panicQueueSec / else if / else` branch + the smoothing + the log line). Replace the method's body with:

```swift
    private func tick() {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return }
        lock.lock()
        let queuedSamples = max(0, scheduledSamples - playerTime.sampleTime)
        let depth = Double(queuedSamples) / sampleRate
        let velocity = (depth - prevDepth) / Self.tickIntervalSec
        prevDepth = depth
        lock.unlock()

        let state = Self.computeRate(depth: depth, velocity: velocity)
        let currentRate = Double(timePitch.rate)
        let newRate = Self.smoothed(currentRate: currentRate, target: state.target)
        timePitch.rate = Float(newRate)

        if abs(newRate - lastLoggedRate) >= Self.logHysteresis ||
            abs(depth - lastLoggedQueueSec) >= 0.5 {
            log.debug("[\(label)] pacing — queue=\(String(format: "%.2fs", depth)) velocity=\(String(format: "%+.2fs/s", velocity)) rate=\(String(format: "%.3f", newRate)) (P=\(String(format: "%.2f", state.p)) D=\(String(format: "%+.2f", state.d)))")
            lastLoggedRate = newRate
            lastLoggedQueueSec = depth
        }
    }
```

- [ ] **Step 5: Build — verify the project compiles**

Run:
```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!` (no errors).

If there are unused warnings about the old constants (`smoothing`, etc.) — those were removed in Task 1, so no warnings expected. If the compiler complains about a type mismatch on `lastLoggedRate` or `lastLoggedQueueSec` — re-check Steps 1 and 4 (both must be `Double`).

- [ ] **Step 6: Run full test suite — verify nothing broke**

Run:
```bash
swift test 2>&1 | tail -3
```

Expected: All tests pass (10 pacing tests + the rest of the suite).

- [ ] **Step 7: Commit**

```bash
git add Sources/UnisonAudio/PlaybackPacing.swift
git commit -m "$(cat <<'EOF'
feat(audio): pacing v2 — integrate P+D + smoothing into tick()

Replaces the v1 linear-interpolation tick body with a call to the new
computeRate + smoothed pure functions. Adds prevDepth stored property
(reset on `reset()`) so velocity can be derived between ticks. Log
line now shows queue depth, velocity, smoothed rate, plus the raw P
and D contributions — when the diagnostic dump shows rate=2.5 you can
tell whether it was depth-driven (large P) or growth-driven (large D).
EOF
)"
```

---

## Task 5: Manual smoke test on host

**Files:** none — verification only.

- [ ] **Step 1: Stop any running Unison + rebuild bundle**

Run:
```bash
killall Unison 2>/dev/null
bash scripts/bundle_app.sh 2>&1 | tail -3
```

Expected: `Bundle ready: build/Unison.app`.

- [ ] **Step 2: Install fresh bundle**

Run:
```bash
cp -R build/Unison.app /Applications/
```

Expected: no output, exit 0.

- [ ] **Step 3: Launch Unison via the start-translation force state**

Run:
```bash
UNISON_FORCE_STATE=start-translation open -a /Applications/Unison.app
```

Expected: Unison auto-starts a translation session after ~2s.

- [ ] **Step 4: Play audio source for ~30 seconds**

Open any audio source (YouTube, Spotify, ChatGPT voice, `say "..."` in Terminal — anything that emits system audio that isn't Unison itself). Let it play for 30s.

- [ ] **Step 5: Inspect the log for new pacing lines**

Run:
```bash
grep -E "pacing — queue=" ~/Library/Logs/Unison/unison.log | tail -30
```

Expected: lines like
```
[speakers] pacing — queue=0.35s velocity=+0.20s/s rate=1.272 (P=0.12 D=+0.30)
[blackhole2ch] pacing — queue=0.18s velocity=-0.05s/s rate=1.000 (P=0.00 D=-0.07)
```

The exact numbers will vary. Validate:
- `rate` values are inside `[1.000, 2.500]`
- `queue` typically stays below `0.5s` during normal playback
- When `queue` spikes (e.g. start of a long OpenAI response), `rate` rises within 1-2 lines and `queue` falls back

If `queue` keeps growing for 5+ seconds with `rate=2.500`, that's the saturation signal — out of scope for this plan; record the symptom and stop here.

- [ ] **Step 6: Stop Unison**

Run:
```bash
killall Unison
```

Expected: clean shutdown line in the log (`applicationWillTerminate — graceful shutdown`).

- [ ] **Step 7: No-op commit marker (optional)**

If smoke passed and the implementer wants a "verified locally" marker, they can amend the previous commit message or add a verification note in the PR description. No code commit needed for this step.
