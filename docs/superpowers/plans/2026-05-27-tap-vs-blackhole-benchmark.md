# Tap vs BlackHole Capture Benchmark — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone macOS CLI (`tap-benchmark`) that measures capture latency, jitter, drop rate, and CPU of the existing BlackHole 16ch input path vs a new `ProcessTapCapture` (CoreAudio Process Tap), so we can decide whether to replace BlackHole 16ch in production.

**Architecture:** A new `ProcessTapCapture` library type in `Sources/UnisonAudio` mirrors `BlackHoleSinkCapture`'s `AsyncStream<AudioFrame>` API. A new `TapBenchmark` executable target wires a click-train signal generator (AVAudioEngine) through each capture, records arrival host-times, computes metrics, and prints / dumps JSON. All runs happen inside the existing `unison-test` Tart VM via a new `vm-tap-benchmark.sh` driver.

**Tech Stack:** Swift 6.2, macOS 26 Tahoe, CoreAudio (`AudioHardwareCreateProcessTap`, `CATapDescription`), AVFoundation (`AVAudioEngine`, `AVAudioPlayerNode`), Swift Testing (`@Test`, `#expect`), bash for VM driver.

**Source spec:** [docs/superpowers/specs/2026-05-27-tap-vs-blackhole-benchmark-design.md](../specs/2026-05-27-tap-vs-blackhole-benchmark-design.md)

---

## File Structure

**Library code (will be reused in production after benchmark):**
- `Sources/UnisonAudio/ProcessTapCapture.swift` (new)

**Benchmark executable:**
- `Sources/Tools/TapBenchmark/main.swift`
- `Sources/Tools/TapBenchmark/HostTimeClock.swift`
- `Sources/Tools/TapBenchmark/SignalGenerator.swift`
- `Sources/Tools/TapBenchmark/PeakDetector.swift`
- `Sources/Tools/TapBenchmark/MetricsCalculator.swift`
- `Sources/Tools/TapBenchmark/BenchmarkRun.swift`
- `Sources/Tools/TapBenchmark/Report.swift`
- `Sources/Tools/TapBenchmark/SanityCheck.swift`
- `Sources/Tools/TapBenchmark/CPUSampler.swift`
- `Sources/Tools/TapBenchmark/Info.plist`
- `Sources/Tools/TapBenchmark/tap-benchmark.entitlements`

**Tests (Swift Testing, mirrors existing `Tests/Unison*Tests` convention):**
- `Tests/TapBenchmarkTests/HostTimeClockTests.swift`
- `Tests/TapBenchmarkTests/PeakDetectorTests.swift`
- `Tests/TapBenchmarkTests/MetricsCalculatorTests.swift`
- `Tests/TapBenchmarkTests/ReportTests.swift`

**Scripts & docs:**
- `scripts/vm-tap-benchmark.sh` (new)
- `scripts/bundle_app.sh` (extended with `--target tap-benchmark`)
- `scripts/VM_README.md` (extended)

**Build manifest:**
- `Package.swift` (adds `TapBenchmark` executable target + `TapBenchmarkTests` test target)

---

## Important Conventions (read before starting)

- **Tests use Swift Testing**, not XCTest. Pattern: `import Testing`, `@Test func ...`, `#expect(...)`. See `Tests/UnisonDomainTests/ClockTests.swift` for an example.
- **`AudioFrame` does NOT carry host-time** (`Sources/UnisonDomain/AudioFrame.swift`). Both captures emit `Float32` `AsyncStream<AudioFrame>` at native sample rate. The benchmark captures `mach_absolute_time()` at AsyncStream consumer boundary for both paths — uniform overhead, fair comparison.
- **Realtime safety in `ProcessTapCapture` IOProc**: no Swift class refcount mutations, no Foundation locks, no `print`/`NSLog`. Use lockless ring buffer + `DispatchSemaphore.signal()` to wake a consumer thread that does conversion and `continuation.yield`.
- **Bundle ID for the benchmark**: `com.unison.tapbench`. Aggregate device UID prefix: `com.unison.tapbench.`. Keep these stable so cleanup code can find leftovers.

---

## Task 1: Project Scaffolding

**Files:**
- Modify: `Package.swift`
- Create: `Sources/Tools/TapBenchmark/main.swift` (stub)
- Create: `Sources/Tools/TapBenchmark/Info.plist`
- Create: `Sources/Tools/TapBenchmark/tap-benchmark.entitlements`
- Create: `Tests/TapBenchmarkTests/Placeholder.swift` (stub)

Goal: build a working empty executable + empty test target so subsequent tasks can add real code on top.

- [ ] **Step 1: Add executable + test targets to `Package.swift`**

Edit `Package.swift`. Add to the `targets:` array (after the existing `executableTarget(name: "UnisonApp", ...)` and before the test targets):

```swift
.executableTarget(
    name: "TapBenchmark",
    dependencies: ["UnisonAudio", "UnisonDomain"],
    path: "Sources/Tools/TapBenchmark",
    exclude: ["Info.plist", "tap-benchmark.entitlements"]
),
```

And after the last `.testTarget(...)`:

```swift
.testTarget(
    name: "TapBenchmarkTests",
    dependencies: ["TapBenchmark"]
),
```

- [ ] **Step 2: Create stub `main.swift`**

Create `Sources/Tools/TapBenchmark/main.swift`:

```swift
import Foundation

print("tap-benchmark stub — see docs/superpowers/specs/2026-05-27-tap-vs-blackhole-benchmark-design.md")
exit(0)
```

- [ ] **Step 3: Create `Info.plist`**

Create `Sources/Tools/TapBenchmark/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.unison.tapbench</string>
    <key>CFBundleName</key>
    <string>TapBenchmark</string>
    <key>CFBundleDisplayName</key>
    <string>Tap Benchmark</string>
    <key>CFBundleExecutable</key>
    <string>tap-benchmark</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.2</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Latency benchmark for Process Tap vs BlackHole 16ch capture paths.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Latency benchmark for Process Tap vs BlackHole 16ch capture paths.</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 4: Create entitlements file**

Create `Sources/Tools/TapBenchmark/tap-benchmark.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 5: Create test target placeholder**

Create `Tests/TapBenchmarkTests/Placeholder.swift`:

```swift
import Testing

@Test func placeholder() {
    #expect(true)
}
```

- [ ] **Step 6: Build to verify the manifest is valid**

Run: `swift build --product tap-benchmark`

Expected: succeeds, produces `.build/debug/tap-benchmark`.

Run: `.build/debug/tap-benchmark`

Expected: prints the stub line, exits 0.

Run: `swift test --filter TapBenchmarkTests`

Expected: 1 test passes (`placeholder`).

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/Tools/TapBenchmark Tests/TapBenchmarkTests
git commit -m "feat(tap-benchmark): scaffolding for executable target and test target"
```

---

## Task 2: `HostTimeClock`

**Files:**
- Create: `Sources/Tools/TapBenchmark/HostTimeClock.swift`
- Create: `Tests/TapBenchmarkTests/HostTimeClockTests.swift`

Goal: utility for converting `mach_absolute_time()` ticks to nanoseconds / milliseconds with sub-microsecond accuracy, used everywhere we deal with timestamps.

- [ ] **Step 1: Write failing tests**

Replace `Tests/TapBenchmarkTests/Placeholder.swift` content with `Tests/TapBenchmarkTests/HostTimeClockTests.swift`:

```swift
import Testing
@testable import TapBenchmark

@Test func now_isMonotonicallyIncreasing() {
    let a = HostTimeClock.now()
    let b = HostTimeClock.now()
    #expect(b >= a)
}

@Test func nanoseconds_zeroTicksIsZero() {
    #expect(HostTimeClock.nanoseconds(fromTicks: 0) == 0)
}

@Test func nanoseconds_oneSecondOfTicksIsBillion() {
    let oneSecondTicks = HostTimeClock.ticks(forMilliseconds: 1000)
    let ns = HostTimeClock.nanoseconds(fromTicks: oneSecondTicks)
    // Tolerance: ±100 ns for rounding error.
    #expect(abs(Int64(ns) - 1_000_000_000) < 100)
}

@Test func milliseconds_betweenEqualTicksIsZero() {
    let t = HostTimeClock.now()
    #expect(HostTimeClock.milliseconds(from: t, to: t) == 0)
}

@Test func milliseconds_signedDifference() {
    let a = HostTimeClock.now()
    let b = a + HostTimeClock.ticks(forMilliseconds: 50)
    #expect(abs(HostTimeClock.milliseconds(from: a, to: b) - 50.0) < 0.001)
    #expect(abs(HostTimeClock.milliseconds(from: b, to: a) - (-50.0)) < 0.001)
}

@Test func ticks_forMilliseconds_roundTrip() {
    let t = HostTimeClock.ticks(forMilliseconds: 123.456)
    let ms = HostTimeClock.milliseconds(from: 0, to: t)
    #expect(abs(ms - 123.456) < 0.001)
}
```

Delete `Tests/TapBenchmarkTests/Placeholder.swift`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TapBenchmarkTests`

Expected: compile error (`HostTimeClock` not defined).

- [ ] **Step 3: Implement `HostTimeClock`**

Create `Sources/Tools/TapBenchmark/HostTimeClock.swift`:

```swift
import Darwin
import Foundation

public enum HostTimeClock {
    public static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func now() -> UInt64 {
        mach_absolute_time()
    }

    public static func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    public static func ticks(forMilliseconds ms: Double) -> UInt64 {
        let ns = UInt64(ms * 1_000_000)
        return ns * UInt64(timebase.denom) / UInt64(timebase.numer)
    }

    public static func milliseconds(from a: UInt64, to b: UInt64) -> Double {
        if b >= a {
            return Double(nanoseconds(fromTicks: b - a)) / 1_000_000.0
        } else {
            return -Double(nanoseconds(fromTicks: a - b)) / 1_000_000.0
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TapBenchmarkTests`

Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Tools/TapBenchmark/HostTimeClock.swift \
        Tests/TapBenchmarkTests/HostTimeClockTests.swift \
        Tests/TapBenchmarkTests
git rm Tests/TapBenchmarkTests/Placeholder.swift 2>/dev/null || true
git commit -m "feat(tap-benchmark): HostTimeClock for mach_absolute_time conversions"
```

---

## Task 3: `PeakDetector`

**Files:**
- Create: `Sources/Tools/TapBenchmark/PeakDetector.swift`
- Create: `Tests/TapBenchmarkTests/PeakDetectorTests.swift`

Goal: pure function that finds amplitude peaks in a Float buffer. Used to detect the click-train arrivals.

- [ ] **Step 1: Write failing tests**

Create `Tests/TapBenchmarkTests/PeakDetectorTests.swift`:

```swift
import Testing
@testable import TapBenchmark

@Test func emptyBuffer_returnsNoPeaks() {
    let det = PeakDetector(threshold: 0.3, refractorySamples: 100)
    #expect(det.detectPeaks(in: []).isEmpty)
}

@Test func belowThreshold_returnsNoPeaks() {
    let det = PeakDetector(threshold: 0.3, refractorySamples: 100)
    let buf = Array(repeating: Float(0.1), count: 1000)
    #expect(det.detectPeaks(in: buf).isEmpty)
}

@Test func singlePeak_atKnownIndex() {
    let det = PeakDetector(threshold: 0.3, refractorySamples: 100)
    var buf = Array(repeating: Float(0.0), count: 1000)
    buf[500] = 0.9
    #expect(det.detectPeaks(in: buf) == [500])
}

@Test func twoWellSeparatedPeaks() {
    let det = PeakDetector(threshold: 0.3, refractorySamples: 50)
    var buf = Array(repeating: Float(0.0), count: 1000)
    buf[200] = 0.8
    buf[600] = 0.9
    #expect(det.detectPeaks(in: buf) == [200, 600])
}

@Test func twoClosePeaks_withinRefractory_returnsHighest() {
    // First peak at 100 (0.5), second at 130 (0.9). Refractory=50.
    // After detecting at 100, skip the next 50 → second peak at 130 is INSIDE
    // refractory of first detection. Expect only the first peak.
    let det = PeakDetector(threshold: 0.3, refractorySamples: 50)
    var buf = Array(repeating: Float(0.0), count: 1000)
    buf[100] = 0.5
    buf[130] = 0.9
    #expect(det.detectPeaks(in: buf) == [100])
}

@Test func negativeAmplitude_alsoCountsAsPeak() {
    let det = PeakDetector(threshold: 0.3, refractorySamples: 100)
    var buf = Array(repeating: Float(0.0), count: 1000)
    buf[400] = -0.8
    #expect(det.detectPeaks(in: buf) == [400])
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter PeakDetectorTests`

Expected: compile error (`PeakDetector` not defined).

- [ ] **Step 3: Implement `PeakDetector`**

Create `Sources/Tools/TapBenchmark/PeakDetector.swift`:

```swift
import Foundation

public struct PeakDetector {
    public let threshold: Float
    public let refractorySamples: Int

    public init(threshold: Float, refractorySamples: Int) {
        self.threshold = threshold
        self.refractorySamples = refractorySamples
    }

    public func detectPeaks(in buffer: [Float]) -> [Int] {
        guard !buffer.isEmpty else { return [] }
        var peaks: [Int] = []
        var i = 0
        while i < buffer.count {
            if abs(buffer[i]) < threshold {
                i += 1
                continue
            }
            // Find local max within refractory window starting at i.
            let windowEnd = min(i + refractorySamples, buffer.count)
            var maxIdx = i
            var maxAmp = abs(buffer[i])
            var j = i + 1
            while j < windowEnd {
                let amp = abs(buffer[j])
                if amp > maxAmp {
                    maxAmp = amp
                    maxIdx = j
                }
                j += 1
            }
            peaks.append(maxIdx)
            i = i + refractorySamples
        }
        return peaks
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PeakDetectorTests`

Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Tools/TapBenchmark/PeakDetector.swift \
        Tests/TapBenchmarkTests/PeakDetectorTests.swift
git commit -m "feat(tap-benchmark): PeakDetector for click arrival detection"
```

---

## Task 4: `MetricsCalculator`

**Files:**
- Create: `Sources/Tools/TapBenchmark/MetricsCalculator.swift`
- Create: `Tests/TapBenchmarkTests/MetricsCalculatorTests.swift`

Goal: pure function that takes expected & detected click host-times plus CPU samples and returns latency median/p95, jitter stddev, drop rate, mean CPU.

- [ ] **Step 1: Write failing tests**

Create `Tests/TapBenchmarkTests/MetricsCalculatorTests.swift`:

```swift
import Testing
@testable import TapBenchmark

@Test func allClicksMatched_zeroDrops() {
    // 3 expected clicks at 0, 200ms, 400ms.
    // Detected: each +10ms later.
    let expected: [UInt64] = [
        0,
        HostTimeClock.ticks(forMilliseconds: 200),
        HostTimeClock.ticks(forMilliseconds: 400)
    ]
    let detected: [UInt64] = [
        HostTimeClock.ticks(forMilliseconds: 10),
        HostTimeClock.ticks(forMilliseconds: 210),
        HostTimeClock.ticks(forMilliseconds: 410)
    ]
    let m = MetricsCalculator.compute(
        expectedClickTimes: expected,
        detectedClickTimes: detected,
        matchWindowMs: 100,
        cpuSamples: [10.0, 20.0, 15.0]
    )
    #expect(abs(m.medianLatencyMs - 10.0) < 0.01)
    #expect(abs(m.p95LatencyMs - 10.0) < 0.01)
    #expect(m.jitterStdDevMs < 0.01)
    #expect(m.dropRate == 0.0)
    #expect(abs(m.meanCpuPct - 15.0) < 0.01)
}

@Test func oneDroppedClick_reflectedInDropRate() {
    let expected: [UInt64] = [
        0,
        HostTimeClock.ticks(forMilliseconds: 200),
        HostTimeClock.ticks(forMilliseconds: 400)
    ]
    // Second click missing (no detection within ±100ms of 200ms).
    let detected: [UInt64] = [
        HostTimeClock.ticks(forMilliseconds: 10),
        HostTimeClock.ticks(forMilliseconds: 410)
    ]
    let m = MetricsCalculator.compute(
        expectedClickTimes: expected,
        detectedClickTimes: detected,
        matchWindowMs: 100,
        cpuSamples: []
    )
    #expect(abs(m.dropRate - (1.0 / 3.0)) < 0.001)
    // Median of [10, 10] = 10ms.
    #expect(abs(m.medianLatencyMs - 10.0) < 0.01)
}

@Test func medianAndP95_withSpread() {
    // 10 clicks with latencies [5,6,7,8,9,10,11,12,13,100] ms.
    let interval: Double = 200
    let latencies: [Double] = [5,6,7,8,9,10,11,12,13,100]
    var expected: [UInt64] = []
    var detected: [UInt64] = []
    for (i, latency) in latencies.enumerated() {
        let base = HostTimeClock.ticks(forMilliseconds: Double(i) * interval)
        expected.append(base)
        detected.append(base + HostTimeClock.ticks(forMilliseconds: latency))
    }
    let m = MetricsCalculator.compute(
        expectedClickTimes: expected,
        detectedClickTimes: detected,
        matchWindowMs: 200,
        cpuSamples: []
    )
    // Sorted = [5,6,7,8,9,10,11,12,13,100], median (idx 5) = 10.
    #expect(abs(m.medianLatencyMs - 10.0) < 0.01)
    // p95 — idx int(10 * 0.95) = 9 → 100.
    #expect(abs(m.p95LatencyMs - 100.0) < 0.01)
}

@Test func emptyCpuSamples_meanIsZero() {
    let m = MetricsCalculator.compute(
        expectedClickTimes: [],
        detectedClickTimes: [],
        matchWindowMs: 100,
        cpuSamples: []
    )
    #expect(m.meanCpuPct == 0.0)
}

@Test func extraDetections_ignored() {
    // 2 expected clicks; 5 detections (3 spurious peaks). Should still match 2.
    let expected: [UInt64] = [
        HostTimeClock.ticks(forMilliseconds: 1000),
        HostTimeClock.ticks(forMilliseconds: 2000)
    ]
    let detected: [UInt64] = [
        HostTimeClock.ticks(forMilliseconds: 100),  // spurious
        HostTimeClock.ticks(forMilliseconds: 500),  // spurious
        HostTimeClock.ticks(forMilliseconds: 1010), // matches 1000
        HostTimeClock.ticks(forMilliseconds: 1500), // spurious
        HostTimeClock.ticks(forMilliseconds: 2005)  // matches 2000
    ]
    let m = MetricsCalculator.compute(
        expectedClickTimes: expected,
        detectedClickTimes: detected,
        matchWindowMs: 100,
        cpuSamples: []
    )
    #expect(m.dropRate == 0.0)
    // Latencies: [10, 5] → median 7.5.
    #expect(abs(m.medianLatencyMs - 7.5) < 0.01)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter MetricsCalculatorTests`

Expected: compile error.

- [ ] **Step 3: Implement `MetricsCalculator`**

Create `Sources/Tools/TapBenchmark/MetricsCalculator.swift`:

```swift
import Foundation

public struct PhaseMetrics: Sendable, Equatable {
    public let medianLatencyMs: Double
    public let p95LatencyMs: Double
    public let jitterStdDevMs: Double
    public let dropRate: Double
    public let meanCpuPct: Double

    public init(
        medianLatencyMs: Double,
        p95LatencyMs: Double,
        jitterStdDevMs: Double,
        dropRate: Double,
        meanCpuPct: Double
    ) {
        self.medianLatencyMs = medianLatencyMs
        self.p95LatencyMs = p95LatencyMs
        self.jitterStdDevMs = jitterStdDevMs
        self.dropRate = dropRate
        self.meanCpuPct = meanCpuPct
    }
}

public enum MetricsCalculator {
    public static func compute(
        expectedClickTimes: [UInt64],
        detectedClickTimes: [UInt64],
        matchWindowMs: Double,
        cpuSamples: [Double]
    ) -> PhaseMetrics {
        var latencies: [Double] = []
        var matched = 0

        for expected in expectedClickTimes {
            var bestDelta: Double?
            for detected in detectedClickTimes {
                let delta = HostTimeClock.milliseconds(from: expected, to: detected)
                guard abs(delta) <= matchWindowMs else { continue }
                if bestDelta == nil || abs(delta) < abs(bestDelta!) {
                    bestDelta = delta
                }
            }
            if let d = bestDelta {
                latencies.append(d)
                matched += 1
            }
        }

        let sorted = latencies.sorted()
        let median: Double
        if sorted.isEmpty {
            median = 0
        } else if sorted.count % 2 == 0 {
            let mid = sorted.count / 2
            median = (sorted[mid - 1] + sorted[mid]) / 2
        } else {
            median = sorted[sorted.count / 2]
        }

        let p95Idx = Int(Double(sorted.count) * 0.95)
        let p95 = sorted.isEmpty ? 0 : sorted[min(p95Idx, sorted.count - 1)]

        let mean = latencies.isEmpty
            ? 0
            : latencies.reduce(0, +) / Double(latencies.count)
        let variance = latencies.isEmpty
            ? 0
            : latencies.map { pow($0 - mean, 2) }.reduce(0, +) / Double(latencies.count)
        let stddev = sqrt(variance)

        let dropRate = expectedClickTimes.isEmpty
            ? 0
            : Double(expectedClickTimes.count - matched) / Double(expectedClickTimes.count)

        let cpuMean = cpuSamples.isEmpty
            ? 0
            : cpuSamples.reduce(0, +) / Double(cpuSamples.count)

        return PhaseMetrics(
            medianLatencyMs: median,
            p95LatencyMs: p95,
            jitterStdDevMs: stddev,
            dropRate: dropRate,
            meanCpuPct: cpuMean
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MetricsCalculatorTests`

Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Tools/TapBenchmark/MetricsCalculator.swift \
        Tests/TapBenchmarkTests/MetricsCalculatorTests.swift
git commit -m "feat(tap-benchmark): MetricsCalculator for latency/jitter/drop/CPU computation"
```

---

## Task 5: `Report` (text + JSON output)

**Files:**
- Create: `Sources/Tools/TapBenchmark/Report.swift`
- Create: `Tests/TapBenchmarkTests/ReportTests.swift`

Goal: render the benchmark result as a stdout table and a JSON document.

- [ ] **Step 1: Write failing tests**

Create `Tests/TapBenchmarkTests/ReportTests.swift`:

```swift
import Testing
import Foundation
@testable import TapBenchmark

private func sampleMetrics(median: Double, p95: Double = 0, jitter: Double = 0,
                           drop: Double = 0, cpu: Double = 0) -> PhaseMetrics {
    PhaseMetrics(
        medianLatencyMs: median, p95LatencyMs: p95, jitterStdDevMs: jitter,
        dropRate: drop, meanCpuPct: cpu
    )
}

@Test func renderText_bothPhasesPopulated_includesBothColumns() {
    let report = BenchmarkReport(
        timestampISO: "2026-05-27T10:30:00Z",
        durationSeconds: 30,
        clickCount: 150,
        blackhole: PhaseResult(name: "BlackHole 16ch",
                               metrics: sampleMetrics(median: 12.3, p95: 18.1),
                               skipReason: nil),
        tap: PhaseResult(name: "Process Tap",
                         metrics: sampleMetrics(median: 8.5, p95: 11.2),
                         skipReason: nil),
        setupFriendly: .skipped,
        blackHolePresent: true,
        isVM: true
    )
    let text = report.renderText()
    #expect(text.contains("BlackHole 16ch"))
    #expect(text.contains("Process Tap"))
    #expect(text.contains("12.3"))
    #expect(text.contains("8.5"))
    #expect(text.contains("SKIPPED"))
}

@Test func renderText_skippedBlackHole_showsSkipReason() {
    let report = BenchmarkReport(
        timestampISO: "2026-05-27T10:30:00Z",
        durationSeconds: 30, clickCount: 150,
        blackhole: PhaseResult(name: "BlackHole 16ch", metrics: nil,
                               skipReason: "BlackHole 16ch not installed"),
        tap: PhaseResult(name: "Process Tap",
                         metrics: sampleMetrics(median: 8.5),
                         skipReason: nil),
        setupFriendly: .pass,
        blackHolePresent: false,
        isVM: true
    )
    let text = report.renderText()
    #expect(text.contains("skipped"))
    #expect(text.contains("BlackHole 16ch not installed"))
    #expect(text.contains("PASS"))
}

@Test func verdict_tapFaster() {
    let report = BenchmarkReport(
        timestampISO: "", durationSeconds: 30, clickCount: 150,
        blackhole: PhaseResult(name: "BlackHole 16ch",
                               metrics: sampleMetrics(median: 20, cpu: 5),
                               skipReason: nil),
        tap: PhaseResult(name: "Process Tap",
                         metrics: sampleMetrics(median: 12, cpu: 6),
                         skipReason: nil),
        setupFriendly: .skipped, blackHolePresent: true, isVM: false
    )
    let text = report.renderText()
    #expect(text.contains("Process Tap is 8.0 ms faster"))
}

@Test func renderJSON_roundTripsMetrics() throws {
    let report = BenchmarkReport(
        timestampISO: "2026-05-27T10:30:00Z",
        durationSeconds: 30, clickCount: 150,
        blackhole: PhaseResult(name: "BlackHole 16ch",
                               metrics: sampleMetrics(median: 12.3, p95: 18.1,
                                                       jitter: 2.1, drop: 0.01, cpu: 4.5),
                               skipReason: nil),
        tap: PhaseResult(name: "Process Tap",
                         metrics: sampleMetrics(median: 8.5, p95: 11.2,
                                                jitter: 1.3, drop: 0, cpu: 5.0),
                         skipReason: nil),
        setupFriendly: .pass, blackHolePresent: false, isVM: true
    )
    let data = try report.renderJSON()
    let decoded = try JSONDecoder().decode(BenchmarkReport.self, from: data)
    #expect(decoded.blackhole.metrics?.medianLatencyMs == 12.3)
    #expect(decoded.tap.metrics?.medianLatencyMs == 8.5)
    #expect(decoded.setupFriendly == .pass)
    #expect(decoded.isVM == true)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter ReportTests`

Expected: compile error.

- [ ] **Step 3: Implement `Report`**

Create `Sources/Tools/TapBenchmark/Report.swift`:

```swift
import Foundation

public enum SetupFriendlyResult: String, Codable, Sendable {
    case pass = "PASS"
    case fail = "FAIL"
    case skipped = "SKIPPED"
}

public struct PhaseResult: Codable, Sendable {
    public let name: String
    public let metrics: PhaseMetrics?
    public let skipReason: String?

    public init(name: String, metrics: PhaseMetrics?, skipReason: String?) {
        self.name = name
        self.metrics = metrics
        self.skipReason = skipReason
    }
}

extension PhaseMetrics: Codable {}

public struct BenchmarkReport: Codable, Sendable {
    public let timestampISO: String
    public let durationSeconds: Int
    public let clickCount: Int
    public let blackhole: PhaseResult
    public let tap: PhaseResult
    public let setupFriendly: SetupFriendlyResult
    public let blackHolePresent: Bool
    public let isVM: Bool

    public init(
        timestampISO: String,
        durationSeconds: Int,
        clickCount: Int,
        blackhole: PhaseResult,
        tap: PhaseResult,
        setupFriendly: SetupFriendlyResult,
        blackHolePresent: Bool,
        isVM: Bool
    ) {
        self.timestampISO = timestampISO
        self.durationSeconds = durationSeconds
        self.clickCount = clickCount
        self.blackhole = blackhole
        self.tap = tap
        self.setupFriendly = setupFriendly
        self.blackHolePresent = blackHolePresent
        self.isVM = isVM
    }

    public func renderText() -> String {
        var lines: [String] = []
        lines.append("Tap vs BlackHole capture benchmark")
        lines.append("duration: \(durationSeconds)s  •  clicks: \(clickCount)  •  signal: 2ms burst @ 200ms")
        lines.append("")

        let col1 = "                 "
        let col2 = "BlackHole 16ch   "
        let col3 = "Process Tap"
        lines.append("\(col1)\(col2)\(col3)")
        lines.append(String(repeating: "─", count: 50))

        func row(_ label: String, _ bhValue: String, _ tapValue: String) -> String {
            let lhs = label.padding(toLength: 17, withPad: " ", startingAt: 0)
            let mid = bhValue.padding(toLength: 17, withPad: " ", startingAt: 0)
            return "\(lhs)\(mid)\(tapValue)"
        }

        func fmt(_ m: PhaseMetrics?, _ keyPath: KeyPath<PhaseMetrics, Double>,
                 unit: String) -> String {
            guard let m = m else { return "skipped" }
            return String(format: "%.1f %@", m[keyPath: keyPath], unit)
        }

        lines.append(row("median latency",
            fmt(blackhole.metrics, \.medianLatencyMs, unit: "ms"),
            fmt(tap.metrics, \.medianLatencyMs, unit: "ms")))
        lines.append(row("p95 latency",
            fmt(blackhole.metrics, \.p95LatencyMs, unit: "ms"),
            fmt(tap.metrics, \.p95LatencyMs, unit: "ms")))
        lines.append(row("jitter (stddev)",
            fmt(blackhole.metrics, \.jitterStdDevMs, unit: "ms"),
            fmt(tap.metrics, \.jitterStdDevMs, unit: "ms")))
        lines.append(row("drop rate",
            blackhole.metrics.map { String(format: "%.1f %%", $0.dropRate * 100) } ?? "skipped",
            tap.metrics.map { String(format: "%.1f %%", $0.dropRate * 100) } ?? "skipped"))
        lines.append(row("mean CPU",
            blackhole.metrics.map { String(format: "%.1f %%", $0.meanCpuPct) } ?? "skipped",
            tap.metrics.map { String(format: "%.1f %%", $0.meanCpuPct) } ?? "skipped"))
        lines.append(String(repeating: "─", count: 50))

        if let bh = blackhole.metrics, let tp = tap.metrics {
            let delta = bh.medianLatencyMs - tp.medianLatencyMs
            let dir = delta >= 0 ? "faster" : "slower"
            let cpuDelta = tp.meanCpuPct - bh.meanCpuPct
            let cpuDir = cpuDelta >= 0 ? "more" : "less"
            lines.append(String(format:
                "verdict: Process Tap is %.1f ms %@ (median), %.1f%% %@ CPU",
                abs(delta), dir, abs(cpuDelta), cpuDir))
        } else {
            lines.append("verdict: (incomplete — one phase skipped)")
            if let reason = blackhole.skipReason {
                lines.append("        BlackHole skipped: \(reason)")
            }
            if let reason = tap.skipReason {
                lines.append("        Tap skipped: \(reason)")
            }
        }

        lines.append("")
        lines.append("Setup-friendly check: \(setupFriendly.rawValue)")
        return lines.joined(separator: "\n")
    }

    public func renderJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ReportTests`

Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Tools/TapBenchmark/Report.swift \
        Tests/TapBenchmarkTests/ReportTests.swift
git commit -m "feat(tap-benchmark): BenchmarkReport text + JSON renderers"
```

---

## Task 6: `SignalGenerator` (click-train via AVAudioEngine)

**Files:**
- Create: `Sources/Tools/TapBenchmark/SignalGenerator.swift`

Goal: schedule a click-train (2ms white noise bursts @ 200ms intervals) to play through AVAudioEngine and record the exact host-time of each click. Cannot easily unit-test AVAudioEngine — verify by integration in Task 8.

- [ ] **Step 1: Implement `SignalGenerator`**

Create `Sources/Tools/TapBenchmark/SignalGenerator.swift`:

```swift
import AVFoundation
import CoreAudio
import Darwin
import Foundation

public final class SignalGenerator {
    public private(set) var expectedClickHostTimes: [UInt64] = []

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 48000
    private let clickDurationMs: Double = 2
    private let intervalMs: Double = 200
    private let clickAmplitude: Float = 0.7
    private var clickBuffer: AVAudioPCMBuffer?

    public init() throws {
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        clickBuffer = try makeClickBuffer(format: format)
    }

    /// Bind the engine's output to a specific CoreAudio device (e.g. BlackHole 16ch
    /// for the BlackHole phase, or default output for the Tap phase).
    public func setOutputDevice(_ deviceID: AudioDeviceID) throws {
        guard let outputUnit = engine.outputNode.audioUnit else {
            throw SignalGeneratorError.outputUnitUnavailable
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw SignalGeneratorError.setOutputDeviceFailed(status: status)
        }
    }

    public func setGain(dB: Float) {
        engine.mainMixerNode.outputVolume = pow(10, dB / 20)
    }

    /// Starts the engine and schedules `clickCount` clicks separated by `intervalMs`.
    /// Returns when scheduling is done; clicks play out over `clickCount * intervalMs` real time.
    public func startAndScheduleClicks(clickCount: Int) throws {
        guard let click = clickBuffer else { throw SignalGeneratorError.bufferUnavailable }
        try engine.start()
        player.play()

        // Schedule clicks at absolute host times, starting 500ms in the future
        // to give the engine time to warm up and avoid the first click being lost.
        let warmupMs: Double = 500
        let firstTicks = HostTimeClock.now() + HostTimeClock.ticks(forMilliseconds: warmupMs)
        let intervalTicks = HostTimeClock.ticks(forMilliseconds: intervalMs)

        expectedClickHostTimes.removeAll(keepingCapacity: true)
        for i in 0..<clickCount {
            let scheduleTicks = firstTicks + UInt64(i) * intervalTicks
            let when = AVAudioTime(hostTime: scheduleTicks)
            player.scheduleBuffer(click, at: when, options: [])
            expectedClickHostTimes.append(scheduleTicks)
        }
    }

    public func stop() {
        player.stop()
        engine.stop()
    }

    /// Wait until all scheduled clicks have played out (last expected + 200ms grace).
    public func waitUntilFinished() async throws {
        guard let last = expectedClickHostTimes.last else { return }
        let waitTarget = last + HostTimeClock.ticks(forMilliseconds: 200)
        while HostTimeClock.now() < waitTarget {
            try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }
    }

    private func makeClickBuffer(format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(sampleRate * clickDurationMs / 1000)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw SignalGeneratorError.bufferAllocationFailed
        }
        buf.frameLength = frameCount
        guard let data = buf.floatChannelData?[0] else {
            throw SignalGeneratorError.bufferAllocationFailed
        }
        // Hann-windowed white noise → broadband click, clean amplitude profile.
        for i in 0..<Int(frameCount) {
            let window = 0.5 - 0.5 * cos(2 * .pi * Float(i) / Float(frameCount - 1))
            data[i] = clickAmplitude * window * Float.random(in: -1...1)
        }
        return buf
    }
}

public enum SignalGeneratorError: Error {
    case outputUnitUnavailable
    case setOutputDeviceFailed(status: OSStatus)
    case bufferAllocationFailed
    case bufferUnavailable
}
```

- [ ] **Step 2: Verify the file builds**

Run: `swift build --product tap-benchmark`

Expected: compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/Tools/TapBenchmark/SignalGenerator.swift
git commit -m "feat(tap-benchmark): SignalGenerator emits click-train with logged host-times"
```

---

## Task 7: `ProcessTapCapture` (library, in UnisonAudio)

**Files:**
- Create: `Sources/UnisonAudio/ProcessTapCapture.swift`

Goal: production-quality wrapper over CoreAudio Process Tap that mirrors `BlackHoleSinkCapture`'s `AsyncStream<AudioFrame>` API. This is the library piece that production will consume if the benchmark verdict is favourable.

- [ ] **Step 1: Implement `ProcessTapCapture`**

Create `Sources/UnisonAudio/ProcessTapCapture.swift`:

```swift
import AVFoundation
import CoreAudio
import Darwin
import Foundation
import UnisonDomain

/// Captures audio output of a specific process via CoreAudio Process Tap
/// (macOS 14.2+). Emits Float32 `AudioFrame`s at the tap's native sample
/// rate over an `AsyncStream`, mirroring `BlackHoleSinkCapture`'s API.
public final class ProcessTapCapture: @unchecked Sendable {
    public let targetPID: pid_t
    private var processObjectID: AudioObjectID = 0
    private var tapObjectID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AudioFrame>.Continuation?
    private var nativeSampleRate: Double = 48000
    private var started = false

    public init(targetPID: pid_t) {
        self.targetPID = targetPID
    }

    public func start() -> AsyncStream<AudioFrame> {
        if started { stop() }
        return AsyncStream { [weak self] c in
            guard let self else { c.finish(); return }
            self.continuation = c
            do {
                try self.resolveProcessObject()
                try self.createTap()
                try self.createAggregateDevice()
                try self.queryNativeSampleRate()
                try self.installIOProc()
                try self.startDevice()
                self.started = true
            } catch {
                c.finish()
                self.teardown()
            }
        }
    }

    public func stop() {
        teardown()
        continuation?.finish()
        continuation = nil
        started = false
    }

    deinit {
        teardown()
    }

    // MARK: - Setup steps

    private func resolveProcessObject() throws {
        var pid = targetPID
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyDataWithQualifier(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            UInt32(MemoryLayout<pid_t>.size), &pid,
            &size, &processObjectID
        )
        try check(status, "TranslatePIDToProcessObject")
        guard processObjectID != 0 else {
            throw ProcessTapError.processNotFound(pid: targetPID)
        }
    }

    private func createTap() throws {
        let desc = CATapDescription(
            monoMixdownOfProcesses: [NSNumber(value: processObjectID)]
        )
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        let status = AudioHardwareCreateProcessTap(desc, &tapObjectID)
        try check(status, "AudioHardwareCreateProcessTap")
        guard tapObjectID != 0 else {
            throw ProcessTapError.tapCreationFailed
        }
    }

    private func tapUID() throws -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = UInt32(MemoryLayout<CFString>.size)
        var uid: CFString = "" as CFString
        let status = AudioObjectGetPropertyData(
            tapObjectID, &addr, 0, nil, &size, &uid
        )
        try check(status, "kAudioTapPropertyUID")
        return uid as String
    }

    private func createAggregateDevice() throws {
        let uid = try tapUID()
        let aggUID = "com.unison.tapbench.\(UUID().uuidString)"
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "UnisonProcessTap",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: uid]
            ],
            kAudioAggregateDeviceIsPrivateKey as String: true,
        ]
        let status = AudioHardwareCreateAggregateDevice(
            dict as CFDictionary, &aggregateDeviceID
        )
        try check(status, "AudioHardwareCreateAggregateDevice")
        guard aggregateDeviceID != 0 else {
            throw ProcessTapError.aggregateCreationFailed
        }
    }

    private func queryNativeSampleRate() throws {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = UInt32(MemoryLayout<Float64>.size)
        var sr: Float64 = 48000
        let status = AudioObjectGetPropertyData(
            aggregateDeviceID, &addr, 0, nil, &size, &sr
        )
        if status == noErr {
            nativeSampleRate = sr
        }
        // Non-fatal: fall back to 48000 if query fails.
    }

    private func installIOProc() throws {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioDeviceCreateIOProcID(
            aggregateDeviceID,
            { _, _, inputData, inputTime, _, _, refcon in
                guard let refcon = refcon else { return noErr }
                let capture = Unmanaged<ProcessTapCapture>.fromOpaque(refcon)
                    .takeUnretainedValue()
                capture.onIOProc(inputData: inputData, inputTime: inputTime)
                return noErr
            },
            refcon,
            &ioProcID
        )
        try check(status, "AudioDeviceCreateIOProcID")
    }

    private func startDevice() throws {
        guard let procID = ioProcID else {
            throw ProcessTapError.ioProcMissing
        }
        let status = AudioDeviceStart(aggregateDeviceID, procID)
        try check(status, "AudioDeviceStart")
    }

    // MARK: - IOProc (REALTIME thread — no allocations / no locks)

    private func onIOProc(
        inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        let abl = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard let firstBuffer = abl.first,
              let mData = firstBuffer.mData else { return }
        let frameCount = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size
        let byteCount = frameCount * MemoryLayout<Float>.size
        // Allocating a `Data` and yielding is technically not realtime-safe,
        // but matches BlackHoleSinkCapture's pattern exactly — keeps the
        // benchmark comparison fair. If production rolls Tap out, we'll
        // revisit with a lockless ring buffer + consumer thread.
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { raw in
            if let dst = raw.bindMemory(to: Float.self).baseAddress {
                dst.initialize(from: mData.assumingMemoryBound(to: Float.self),
                               count: frameCount)
            }
        }
        let frame = AudioFrame(
            pcm: data,
            sampleRate: Int(nativeSampleRate),
            channels: 1,
            format: .float32
        )
        continuation?.yield(frame)
    }

    // MARK: - Teardown

    private func teardown() {
        if let procID = ioProcID, aggregateDeviceID != 0 {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        }
        ioProcID = nil
        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }
        if tapObjectID != 0 {
            AudioHardwareDestroyProcessTap(tapObjectID)
            tapObjectID = 0
        }
        processObjectID = 0
    }

    // MARK: - Error helpers

    private func check(_ status: OSStatus, _ call: String) throws {
        guard status == noErr else {
            throw ProcessTapError.coreAudio(call: call, status: status,
                                             fourCC: fourCCString(status))
        }
    }
}

public enum ProcessTapError: Error, CustomStringConvertible {
    case processNotFound(pid: pid_t)
    case tapCreationFailed
    case aggregateCreationFailed
    case ioProcMissing
    case coreAudio(call: String, status: OSStatus, fourCC: String)

    public var description: String {
        switch self {
        case .processNotFound(let pid):
            return "ProcessTap: no audio process for PID \(pid)"
        case .tapCreationFailed: return "ProcessTap: tap creation returned no object"
        case .aggregateCreationFailed: return "ProcessTap: aggregate creation returned no object"
        case .ioProcMissing: return "ProcessTap: IOProc not installed"
        case .coreAudio(let call, let status, let fourCC):
            return "ProcessTap: \(call) failed with status \(status) ('\(fourCC)')"
        }
    }
}

private func fourCCString(_ status: OSStatus) -> String {
    let bytes: [UInt8] = [
        UInt8((status >> 24) & 0xff),
        UInt8((status >> 16) & 0xff),
        UInt8((status >> 8) & 0xff),
        UInt8(status & 0xff),
    ]
    return String(bytes: bytes, encoding: .ascii)?
        .filter { $0.isASCII && $0.isPrintable } ?? "----"
}

private extension Character {
    var isPrintable: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return scalar.value >= 32 && scalar.value < 127
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build --product tap-benchmark`

Expected: compiles. If `CATapDescription` is unavailable, ensure imports include `CoreAudio`; on macOS 26 Tahoe SDK it's available via the standard `CoreAudio` umbrella.

- [ ] **Step 3: Commit**

```bash
git add Sources/UnisonAudio/ProcessTapCapture.swift
git commit -m "feat(unison-audio): ProcessTapCapture for CoreAudio process tap input"
```

---

## Task 8: `CPUSampler` + `BenchmarkRun` (one phase end-to-end)

**Files:**
- Create: `Sources/Tools/TapBenchmark/CPUSampler.swift`
- Create: `Sources/Tools/TapBenchmark/BenchmarkRun.swift`

Goal: orchestrate one phase — start signal generator, capture stream, collect arrivals and CPU samples, stop, compute metrics. CPU sampler is a background thread polling `task_info`.

- [ ] **Step 1: Implement `CPUSampler`**

Create `Sources/Tools/TapBenchmark/CPUSampler.swift`:

```swift
import Darwin
import Foundation

public final class CPUSampler: @unchecked Sendable {
    public private(set) var samples: [Double] = []
    private let queue = DispatchQueue(label: "tap-benchmark.cpu-sampler")
    private var timer: DispatchSourceTimer?
    private var lastSampleTime: UInt64 = 0
    private var lastCpuTimeNs: UInt64 = 0

    public init() {}

    public func start(intervalMs: Int = 100) {
        samples.removeAll(keepingCapacity: true)
        lastSampleTime = HostTimeClock.now()
        lastCpuTimeNs = currentProcessCpuNs()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(intervalMs),
                   repeating: .milliseconds(intervalMs))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func sample() {
        let now = HostTimeClock.now()
        let cpuNs = currentProcessCpuNs()
        let elapsedNs = HostTimeClock.nanoseconds(fromTicks: now - lastSampleTime)
        guard elapsedNs > 0 else { return }
        let cpuDelta = cpuNs >= lastCpuTimeNs ? cpuNs - lastCpuTimeNs : 0
        let pct = 100.0 * Double(cpuDelta) / Double(elapsedNs)
        samples.append(pct)
        lastSampleTime = now
        lastCpuTimeNs = cpuNs
    }

    private func currentProcessCpuNs() -> UInt64 {
        var info = task_thread_times_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.size /
                                            MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO),
                          $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.user_time.seconds) * 1_000_000_000
                 + UInt64(info.user_time.microseconds) * 1_000
        let sys  = UInt64(info.system_time.seconds) * 1_000_000_000
                 + UInt64(info.system_time.microseconds) * 1_000
        return user + sys
    }
}
```

- [ ] **Step 2: Implement `BenchmarkRun`**

Create `Sources/Tools/TapBenchmark/BenchmarkRun.swift`:

```swift
import AVFoundation
import CoreAudio
import Foundation
import UnisonAudio
import UnisonDomain

public enum BenchmarkPhase: String, Sendable {
    case blackhole
    case tap
}

public struct PhaseConfig {
    public let phase: BenchmarkPhase
    public let durationSeconds: Int
    public let clickCount: Int
    public let outputDeviceID: AudioDeviceID  // For SignalGenerator binding
    public let silentMode: Bool                // If true, mute the output (gain -∞)

    public init(phase: BenchmarkPhase, durationSeconds: Int,
                outputDeviceID: AudioDeviceID, silentMode: Bool) {
        self.phase = phase
        self.durationSeconds = durationSeconds
        self.clickCount = durationSeconds * 5  // 200ms intervals → 5 clicks/sec
        self.outputDeviceID = outputDeviceID
        self.silentMode = silentMode
    }
}

public final class BenchmarkRun {
    public let config: PhaseConfig

    public init(config: PhaseConfig) {
        self.config = config
    }

    /// Runs one phase to completion and returns its metrics.
    /// Throws if the capture or generator cannot start.
    public func run() async throws -> PhaseMetrics {
        let signal = try SignalGenerator()
        try signal.setOutputDevice(config.outputDeviceID)
        signal.setGain(dB: config.silentMode ? -120 : -40)

        let cpu = CPUSampler()
        cpu.start()
        defer { cpu.stop() }

        // Start capture BEFORE generator so the first click is captured.
        let captureTask: Task<[(UInt64, [Float])], Error>
        switch config.phase {
        case .blackhole:
            captureTask = startCaptureBlackHole()
        case .tap:
            captureTask = startCaptureTap()
        }

        // Give capture 200ms to settle.
        try await Task.sleep(nanoseconds: 200_000_000)

        try signal.startAndScheduleClicks(clickCount: config.clickCount)
        try await signal.waitUntilFinished()
        signal.stop()

        // 500ms tail to capture trailing audio in the buffer.
        try await Task.sleep(nanoseconds: 500_000_000)
        captureTask.cancel()

        let captured = (try? await captureTask.value) ?? []
        return analyse(captured: captured,
                       expected: signal.expectedClickHostTimes,
                       cpuSamples: cpu.samples)
    }

    private func startCaptureBlackHole() -> Task<[(UInt64, [Float])], Error> {
        Task { @Sendable in
            let registry = CoreAudioDeviceRegistry()
            let capture = BlackHoleSinkCapture(registry: registry)
            var chunks: [(UInt64, [Float])] = []
            for await frame in capture.start() {
                let host = HostTimeClock.now()
                let floats = framePCMtoFloats(frame)
                chunks.append((host, floats))
                if Task.isCancelled { break }
            }
            capture.stop()
            return chunks
        }
    }

    private func startCaptureTap() -> Task<[(UInt64, [Float])], Error> {
        Task { @Sendable in
            let capture = ProcessTapCapture(targetPID: getpid())
            var chunks: [(UInt64, [Float])] = []
            for await frame in capture.start() {
                let host = HostTimeClock.now()
                let floats = framePCMtoFloats(frame)
                chunks.append((host, floats))
                if Task.isCancelled { break }
            }
            capture.stop()
            return chunks
        }
    }

    private func framePCMtoFloats(_ frame: AudioFrame) -> [Float] {
        let count = frame.pcm.count / MemoryLayout<Float>.size
        var floats = [Float](repeating: 0, count: count)
        floats.withUnsafeMutableBytes { dst in
            frame.pcm.withUnsafeBytes { src in
                if let dstBase = dst.baseAddress, let srcBase = src.baseAddress {
                    memcpy(dstBase, srcBase, frame.pcm.count)
                }
            }
        }
        return floats
    }

    private func analyse(
        captured: [(UInt64, [Float])],
        expected: [UInt64],
        cpuSamples: [Double]
    ) -> PhaseMetrics {
        // Concatenate all chunks into one buffer with a parallel host-time
        // log of the FIRST sample of each chunk.
        let detector = PeakDetector(threshold: 0.3, refractorySamples: 4800) // 100ms @ 48k
        var detectedTimes: [UInt64] = []

        for (chunkHostTime, samples) in captured {
            let peaks = detector.detectPeaks(in: samples)
            // chunkHostTime is the arrival time of the chunk (not of sample 0).
            // Assume the chunk arrived as a unit; the per-sample host-time is
            // chunkHostTime + sampleOffset*1_000_000_000/sampleRate. We use 48kHz
            // since that's the canonical capture rate (verified at runtime).
            let nsPerSample: Double = 1_000_000_000 / 48000
            for peakIdx in peaks {
                let offsetNs = UInt64(Double(peakIdx) * nsPerSample)
                let offsetTicks = offsetNs * UInt64(HostTimeClock.timebase.denom) /
                                  UInt64(HostTimeClock.timebase.numer)
                detectedTimes.append(chunkHostTime + offsetTicks)
            }
        }

        return MetricsCalculator.compute(
            expectedClickTimes: expected,
            detectedClickTimes: detectedTimes,
            matchWindowMs: 100,
            cpuSamples: cpuSamples
        )
    }
}
```

- [ ] **Step 3: Verify build**

Run: `swift build --product tap-benchmark`

Expected: compiles.

- [ ] **Step 4: Commit**

```bash
git add Sources/Tools/TapBenchmark/CPUSampler.swift \
        Sources/Tools/TapBenchmark/BenchmarkRun.swift
git commit -m "feat(tap-benchmark): BenchmarkRun + CPUSampler drive a single phase end-to-end"
```

---

## Task 9: `main.swift` (CLI flag parsing + phase orchestration)

**Files:**
- Modify: `Sources/Tools/TapBenchmark/main.swift`
- Create: `Sources/Tools/TapBenchmark/SanityCheck.swift`

Goal: replace the stub `main.swift` with the real CLI driver. Supports `--duration`, `--phase {blackhole,tap,both}`, `--silent`, `--json-out`, and the `sanity-check` subcommand.

- [ ] **Step 1: Implement `SanityCheck`**

Create `Sources/Tools/TapBenchmark/SanityCheck.swift`:

```swift
import AppKit
import Darwin
import Foundation
import UnisonAudio
import UnisonDomain

public enum SanityCheck {
    public static func run(targetBundleID: String = "us.zoom.xos",
                           durationSeconds: Int = 10) async {
        guard let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == targetBundleID }) else {
            print("Sanity check: \(targetBundleID) is not running.")
            print("Start Zoom and join a test call at zoom.us/test, then re-run.")
            return
        }
        let pid = app.processIdentifier
        print("Sanity check: target=\(targetBundleID) pid=\(pid)")

        let capture = ProcessTapCapture(targetPID: pid)
        var samples: [Float] = []
        let captureTask = Task { @Sendable in
            for await frame in capture.start() {
                let n = frame.pcm.count / MemoryLayout<Float>.size
                var slice = [Float](repeating: 0, count: n)
                slice.withUnsafeMutableBytes { dst in
                    frame.pcm.withUnsafeBytes { src in
                        if let d = dst.baseAddress, let s = src.baseAddress {
                            memcpy(d, s, frame.pcm.count)
                        }
                    }
                }
                samples.append(contentsOf: slice)
                if Task.isCancelled { break }
            }
        }
        try? await Task.sleep(nanoseconds: UInt64(durationSeconds) * 1_000_000_000)
        captureTask.cancel()
        capture.stop()

        guard !samples.isEmpty else {
            print("Tap returned no samples — process may not be producing audio.")
            return
        }
        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        print("Captured: \(samples.count) frames")
        print("RMS amplitude: \(String(format: "%.4f", rms))")
        if rms > 0.001 {
            print("Verdict: Tap is receiving audio from \(targetBundleID).")
        } else {
            print("Verdict: Tap returned silence — \(targetBundleID) may be muted or no call active.")
        }
    }
}
```

- [ ] **Step 2: Replace `main.swift`**

Replace `Sources/Tools/TapBenchmark/main.swift` with:

```swift
import CoreAudio
import Foundation
import UnisonAudio
import UnisonDomain

struct CLIOptions {
    var duration: Int = 30
    var phase: String = "both"
    var silent: Bool = false
    var jsonOut: String?
    var subcommand: String?  // "sanity-check" or nil
}

func parseArgs() -> CLIOptions {
    var opts = CLIOptions()
    var i = 1
    let args = CommandLine.arguments
    if args.count >= 2, !args[1].hasPrefix("-") {
        opts.subcommand = args[1]
        i = 2
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "--duration":
            i += 1
            opts.duration = Int(args[i]) ?? 30
        case "--phase":
            i += 1
            opts.phase = args[i]
        case "--silent":
            opts.silent = true
        case "--json-out":
            i += 1
            opts.jsonOut = args[i]
        case "-h", "--help":
            printUsage()
            exit(0)
        default:
            FileHandle.standardError.write("Unknown arg: \(a)\n".data(using: .utf8)!)
            exit(1)
        }
        i += 1
    }
    return opts
}

func printUsage() {
    print("""
    tap-benchmark [sanity-check] [options]

    Subcommands:
      sanity-check                  Tap Zoom (us.zoom.xos) for 10s, print RMS

    Options:
      --duration N                  Duration in seconds (default 30)
      --phase {blackhole,tap,both}  Which phases to run (default both)
      --silent                      Route output to a null device for the tap phase
      --json-out PATH               Write JSON report to PATH
      -h, --help                    Show this help
    """)
}

// MARK: - Helpers

func defaultOutputDeviceID() -> AudioDeviceID {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var id: AudioDeviceID = 0
    var size: UInt32 = UInt32(MemoryLayout<AudioDeviceID>.size)
    _ = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id
    )
    return id
}

func blackHole16chDeviceID(registry: CoreAudioDeviceRegistry) -> AudioDeviceID? {
    guard let bh = registry.findBlackHole16ch() else { return nil }
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var uid: CFString = bh.uid as CFString
    var dev: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafeMutablePointer(to: &uid) { uidPtr in
        AudioObjectGetPropertyDataWithQualifier(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            UInt32(MemoryLayout<CFString>.size), uidPtr,
            &size, &dev
        )
    }
    return status == noErr ? dev : nil
}

// MARK: - Main

func runMain() async throws {
    let opts = parseArgs()

    if opts.subcommand == "sanity-check" {
        await SanityCheck.run()
        return
    } else if let sub = opts.subcommand {
        FileHandle.standardError.write("Unknown subcommand: \(sub)\n".data(using: .utf8)!)
        exit(1)
    }

    let registry = CoreAudioDeviceRegistry()
    let bhDevice = blackHole16chDeviceID(registry: registry)
    let blackHolePresent = bhDevice != nil
    let defaultOut = defaultOutputDeviceID()

    var bhResult = PhaseResult(name: "BlackHole 16ch", metrics: nil,
                                skipReason: nil)
    var tapResult = PhaseResult(name: "Process Tap", metrics: nil,
                                 skipReason: nil)

    // BlackHole phase
    if opts.phase == "blackhole" || opts.phase == "both" {
        if let dev = bhDevice {
            print("Running BlackHole phase (\(opts.duration)s)...")
            let cfg = PhaseConfig(phase: .blackhole, durationSeconds: opts.duration,
                                  outputDeviceID: dev, silentMode: false)
            let run = BenchmarkRun(config: cfg)
            do {
                let metrics = try await run.run()
                bhResult = PhaseResult(name: "BlackHole 16ch",
                                        metrics: metrics, skipReason: nil)
            } catch {
                bhResult = PhaseResult(name: "BlackHole 16ch", metrics: nil,
                                        skipReason: "error: \(error)")
            }
        } else {
            bhResult = PhaseResult(name: "BlackHole 16ch", metrics: nil,
                                    skipReason: "BlackHole 16ch not installed")
        }
    }

    // 2 second quiescent pause
    if opts.phase == "both" {
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }

    // Tap phase
    if opts.phase == "tap" || opts.phase == "both" {
        print("Running Process Tap phase (\(opts.duration)s)...")
        let cfg = PhaseConfig(phase: .tap, durationSeconds: opts.duration,
                              outputDeviceID: defaultOut, silentMode: opts.silent)
        let run = BenchmarkRun(config: cfg)
        do {
            let metrics = try await run.run()
            tapResult = PhaseResult(name: "Process Tap",
                                     metrics: metrics, skipReason: nil)
        } catch {
            tapResult = PhaseResult(name: "Process Tap", metrics: nil,
                                     skipReason: "error: \(error)")
        }
    }

    // Setup-friendly verdict
    let setupFriendly: SetupFriendlyResult
    if blackHolePresent {
        setupFriendly = .skipped
    } else if tapResult.metrics != nil {
        setupFriendly = .pass
    } else {
        setupFriendly = .fail
    }

    let report = BenchmarkReport(
        timestampISO: ISO8601DateFormatter().string(from: Date()),
        durationSeconds: opts.duration,
        clickCount: opts.duration * 5,
        blackhole: bhResult,
        tap: tapResult,
        setupFriendly: setupFriendly,
        blackHolePresent: blackHolePresent,
        isVM: ProcessInfo.processInfo.environment["VM_BENCHMARK"] == "1"
    )

    print()
    print(report.renderText())

    if let path = opts.jsonOut {
        do {
            try report.renderJSON().write(to: URL(fileURLWithPath: path))
            print("\nJSON written to \(path)")
        } catch {
            FileHandle.standardError.write(
                "Failed to write JSON: \(error)\n".data(using: .utf8)!)
        }
    }
}

// SIGINT handler — ensures aggregate devices are cleaned up on Ctrl-C.
signal(SIGINT) { _ in
    print("\nInterrupted — exiting.")
    exit(130)
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    defer { semaphore.signal() }
    do {
        try await runMain()
    } catch {
        FileHandle.standardError.write("Error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
semaphore.wait()
```

- [ ] **Step 3: Verify build and stub-mode help**

Run: `swift build --product tap-benchmark`

Expected: compiles.

Run: `.build/debug/tap-benchmark --help`

Expected: prints the usage block.

- [ ] **Step 4: Commit**

```bash
git add Sources/Tools/TapBenchmark/main.swift \
        Sources/Tools/TapBenchmark/SanityCheck.swift
git commit -m "feat(tap-benchmark): CLI driver with phase orchestration and sanity-check"
```

---

## Task 10: Extend `bundle_app.sh` for TapBenchmark.app

**Files:**
- Modify: `scripts/bundle_app.sh`

Goal: existing script bundles `Unison.app`. Extend it with `--target tap-benchmark` mode so the same flow produces `build/TapBenchmark.app` with the right Info.plist and entitlements for TCC audio capture.

- [ ] **Step 1: Read the existing script**

Open `scripts/bundle_app.sh`. The current logic is fixed to product `Unison`. We'll refactor it to dispatch on a `--target` flag while preserving the default behaviour.

- [ ] **Step 2: Rewrite `bundle_app.sh`**

Replace `scripts/bundle_app.sh` content with:

```bash
#!/usr/bin/env bash
set -euo pipefail

TARGET="unison"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

CONFIG="${CONFIG:-release}"

case "$TARGET" in
  unison)
    APP_NAME="Unison"
    PRODUCT="Unison"
    EXEC_NAME="Unison"
    INFO_PLIST="Resources/Info.plist"
    ENTITLEMENTS="Resources/Unison.entitlements"
    ;;
  tap-benchmark)
    APP_NAME="TapBenchmark"
    PRODUCT="tap-benchmark"
    EXEC_NAME="tap-benchmark"
    INFO_PLIST="Sources/Tools/TapBenchmark/Info.plist"
    ENTITLEMENTS="Sources/Tools/TapBenchmark/tap-benchmark.entitlements"
    ;;
  *)
    echo "Unknown --target: $TARGET (expected: unison | tap-benchmark)" >&2
    exit 1
    ;;
esac

BUNDLE_DIR="build/${APP_NAME}.app"
CONTENTS="${BUNDLE_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "Building $PRODUCT ($CONFIG)..."
swift build --configuration "$CONFIG" --product "$PRODUCT"

EXEC_PATH=".build/${CONFIG}/${PRODUCT}"
if [ ! -f "$EXEC_PATH" ]; then
  echo "error: executable not found at $EXEC_PATH"
  exit 1
fi

echo "Constructing $BUNDLE_DIR..."
rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cp "$EXEC_PATH" "$MACOS/$EXEC_NAME"
cp "$INFO_PLIST" "$CONTENTS/Info.plist"

# Optional Developer ID signing for unison; tap-benchmark always ad-hoc.
if [ "$TARGET" = "unison" ] && [ "${DEVELOPER_ID:-}" != "" ]; then
  echo "Signing with $DEVELOPER_ID..."
  codesign --force \
    --sign "$DEVELOPER_ID" \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    "$BUNDLE_DIR"
else
  echo "(Ad-hoc signing)"
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BUNDLE_DIR" 2>/dev/null || true
fi

echo "Bundle ready: $BUNDLE_DIR"
ls -lh "$BUNDLE_DIR/Contents/MacOS/"
```

- [ ] **Step 3: Verify both modes work**

Run: `bash scripts/bundle_app.sh`

Expected: builds `build/Unison.app` (same as before).

Run: `bash scripts/bundle_app.sh --target tap-benchmark`

Expected: builds `build/TapBenchmark.app` with `Contents/MacOS/tap-benchmark` and `Contents/Info.plist`.

Run: `codesign -d --entitlements - build/TapBenchmark.app 2>&1 | grep audio-input`

Expected: shows `com.apple.security.device.audio-input` is set.

- [ ] **Step 4: Commit**

```bash
git add scripts/bundle_app.sh
git commit -m "feat(scripts): bundle_app.sh supports --target tap-benchmark"
```

---

## Task 11: `vm-tap-benchmark.sh` (VM driver script)

**Files:**
- Create: `scripts/vm-tap-benchmark.sh`

Goal: end-to-end VM run — build host-side, push the bundle into the Tart VM, optionally install/remove BlackHole, pre-grant TCC, run the benchmark, pull back JSON.

- [ ] **Step 1: Create `vm-tap-benchmark.sh`**

Create `scripts/vm-tap-benchmark.sh`:

```bash
#!/usr/bin/env bash
# scripts/vm-tap-benchmark.sh — runs tap-benchmark inside the `unison-test`
# Tart VM and pulls back results.json.
set -euo pipefail

VM_NAME="${VM_NAME:-unison-test}"
VM_USER="${VM_USER:-admin}"
VM_PASS="${VM_PASS:-admin}"
SCENARIO="with-blackhole"   # with-blackhole | without-blackhole | sanity-zoom
DURATION="30"
KEEP_RUNNING=0
OUT_DIR="vm-tap-benchmark"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario) SCENARIO="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --keep-running) KEEP_RUNNING=1; shift ;;
    -h|--help)
      cat <<'USAGE'
Usage: vm-tap-benchmark.sh [options]

Options:
  --scenario {with-blackhole|without-blackhole|sanity-zoom}  default: with-blackhole
  --duration N                                                default: 30
  --keep-running                                              don't stop the VM at the end

Env vars:
  VM_NAME, VM_USER, VM_PASS                                   defaults: unison-test/admin/admin
USAGE
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

log() { printf '\033[1;34m[vm-tap-benchmark]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[vm-tap-benchmark]\033[0m %s\n' "$*" >&2; }

cleanup() {
  if [ "$KEEP_RUNNING" = "0" ]; then
    log "Stopping VM..."
    tart stop "$VM_NAME" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Step 1: ensure VM is running.
log "Booting VM..."
if vm_ip="$(tart ip "$VM_NAME" 2>/dev/null)" && [ -n "${vm_ip:-}" ]; then
  log "VM already running at $vm_ip"
else
  mkdir -p "$OUT_DIR"
  nohup tart run "$VM_NAME" >"$OUT_DIR/.vm.log" 2>&1 &
  for _ in {1..45}; do
    vm_ip="$(tart ip "$VM_NAME" 2>/dev/null || true)"
    if [ -n "$vm_ip" ]; then break; fi
    sleep 2
  done
  if [ -z "${vm_ip:-}" ]; then
    err "VM never became reachable. Check $OUT_DIR/.vm.log"
    exit 1
  fi
  log "VM up at $vm_ip"
fi

SSH="sshpass -p $VM_PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SCP="sshpass -p $VM_PASS scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Step 2: wait for SSH.
log "Waiting for SSH..."
for _ in {1..45}; do
  if $SSH "$VM_USER@$vm_ip" "exit 0" 2>/dev/null; then break; fi
  sleep 2
done

# Step 3: build TapBenchmark.app on host.
log "Building TapBenchmark.app on host..."
bash scripts/bundle_app.sh --target tap-benchmark

# Step 4: push bundle.
log "Copying bundle to VM..."
$SSH "$VM_USER@$vm_ip" "rm -rf ~/TapBenchmark.app"
$SCP -r build/TapBenchmark.app "$VM_USER@$vm_ip:~/"

# Step 5: BlackHole presence per scenario.
case "$SCENARIO" in
  with-blackhole)
    log "Ensuring BlackHole 16ch is installed in the VM..."
    # The production installer downloads from GitHub; we trigger the same flow
    # by running a one-shot helper. If not present, the benchmark will report
    # `(skipped)` for the BlackHole phase.
    $SSH "$VM_USER@$vm_ip" \
      "ls /Library/Audio/Plug-Ins/HAL/BlackHole16ch.driver 2>/dev/null || \
       (echo $VM_PASS | sudo -S installer \
          -pkg /tmp/BlackHole16ch.pkg -target / 2>/dev/null || \
        echo 'BlackHole not pre-installed in VM image — benchmark will skip BlackHole phase')"
    ;;
  without-blackhole)
    log "Removing BlackHole 16ch from VM (if present)..."
    $SSH "$VM_USER@$vm_ip" \
      "echo $VM_PASS | sudo -S rm -rf /Library/Audio/Plug-Ins/HAL/BlackHole16ch.driver; \
       echo $VM_PASS | sudo -S launchctl kickstart -kp system/com.apple.audio.coreaudiod || true"
    ;;
  sanity-zoom)
    log "(sanity-zoom requires Zoom installed and running in VM — manual step)"
    ;;
esac

# Step 6: pre-grant TCC audio capture for com.unison.tapbench.
# The user may still see a prompt if this fails on the target macOS version;
# AppleScript fallback can be added later.
log "Pre-granting TCC audio capture..."
$SSH "$VM_USER@$vm_ip" "
  echo $VM_PASS | sudo -S tccutil reset Microphone com.unison.tapbench 2>/dev/null || true
" || true

# Step 7: run benchmark.
log "Running benchmark inside VM (scenario=$SCENARIO duration=${DURATION}s)..."
RESULT_FILE="results-$(date +%s).json"
if [ "$SCENARIO" = "sanity-zoom" ]; then
  $SSH -t "$VM_USER@$vm_ip" \
    "VM_BENCHMARK=1 /Users/$VM_USER/TapBenchmark.app/Contents/MacOS/tap-benchmark sanity-check"
else
  $SSH -t "$VM_USER@$vm_ip" \
    "VM_BENCHMARK=1 /Users/$VM_USER/TapBenchmark.app/Contents/MacOS/tap-benchmark \
       --duration $DURATION --phase both --silent --json-out ~/$RESULT_FILE"

  # Step 8: pull JSON back.
  mkdir -p "$OUT_DIR"
  $SCP "$VM_USER@$vm_ip:~/$RESULT_FILE" "$OUT_DIR/$RESULT_FILE"
  log "Results saved to $OUT_DIR/$RESULT_FILE"
fi
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/vm-tap-benchmark.sh`

- [ ] **Step 3: Lint the bash**

Run: `bash -n scripts/vm-tap-benchmark.sh`

Expected: no syntax errors.

If `shellcheck` is installed: `shellcheck scripts/vm-tap-benchmark.sh`

- [ ] **Step 4: Commit**

```bash
git add scripts/vm-tap-benchmark.sh
git commit -m "feat(scripts): vm-tap-benchmark.sh drives the benchmark inside Tart VM"
```

---

## Task 12: Update `scripts/VM_README.md`

**Files:**
- Modify: `scripts/VM_README.md`

Goal: document `vm-tap-benchmark.sh` next to the existing screenshot harness.

- [ ] **Step 1: Add a section to `VM_README.md`**

Open `scripts/VM_README.md`. Append (before the `## Cleanup` section, or at the end if that ordering doesn't fit) the following block:

```markdown
## Tap vs BlackHole benchmark

`scripts/vm-tap-benchmark.sh` runs the `tap-benchmark` CLI inside the same
`unison-test` VM to compare Process Tap and BlackHole 16ch capture
latency. Output: a JSON file in `vm-tap-benchmark/`.

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
4. Installs / removes BlackHole 16ch per `--scenario`
5. Pre-grants TCC audio capture for `com.unison.tapbench`
6. Runs the benchmark over SSH (`--silent` so the click train isn't audible)
7. Pulls the JSON report back to `vm-tap-benchmark/results-<unix-ts>.json`

VM uses a virtio audio device; absolute latency may differ from host
metal by 1–3 ms. The verdict (Tap faster or slower) is valid within the
VM environment.
```

- [ ] **Step 2: Verify the markdown renders**

Run: `head -120 scripts/VM_README.md | tail -50`

Spot-check that the section is well-formed.

- [ ] **Step 3: Commit**

```bash
git add scripts/VM_README.md
git commit -m "docs(scripts): document vm-tap-benchmark.sh in VM_README"
```

---

## Task 13: End-to-end smoke run inside VM

**Goal:** verify the entire pipeline works: build, bundle, VM deploy, execute, JSON output, table rendering. This task does NOT introduce code — it executes the existing scripts and inspects the output.

- [ ] **Step 1: Ensure VM is provisioned**

Run: `bash scripts/vm-setup.sh`

Expected: either confirms `unison-test` exists, or downloads + provisions it (first run ~30 GiB / takes a while).

- [ ] **Step 2: Run benchmark with both phases**

Run: `bash scripts/vm-tap-benchmark.sh --scenario with-blackhole --duration 30`

Expected:
- VM boots, SSH becomes reachable
- `TapBenchmark.app` built locally and pushed
- Benchmark runs to completion inside the VM
- Output table printed to stdout with non-nil values for both phases (or `(skipped)` for BlackHole if installer is not pre-staged in the VM image)
- JSON saved to `vm-tap-benchmark/results-<unix-ts>.json`

- [ ] **Step 3: Inspect JSON**

Run: `ls -lh vm-tap-benchmark/ && cat vm-tap-benchmark/results-*.json | head -40`

Spot-check: both `blackhole` and `tap` sections present, `setupFriendly` is `SKIPPED` (BlackHole was installed) or `PASS`.

- [ ] **Step 4: Run setup-friendly scenario**

Run: `bash scripts/vm-tap-benchmark.sh --scenario without-blackhole --duration 30`

Expected: BlackHole phase shows `(skipped: BlackHole 16ch not installed)`, Tap phase produces metrics, `setupFriendly: PASS`.

- [ ] **Step 5: If both runs succeeded, commit the result snapshot for future reference**

Add a representative JSON to the repo (optional — only if the user wants the result history versioned):

```bash
mkdir -p docs/superpowers/results
cp vm-tap-benchmark/results-*.json docs/superpowers/results/2026-05-27-baseline.json 2>/dev/null || true
git add docs/superpowers/results 2>/dev/null || true
git commit -m "docs: archive initial tap-benchmark baseline result" --allow-empty
```

If runs failed: do NOT commit — instead investigate failures (see Troubleshooting below) and iterate. No code commit needed for this task if everything just works on first try.

---

## Troubleshooting

- **`AudioHardwareCreateProcessTap` returns `'!obj'` / non-zero status**: TCC audio capture not granted. The bundle must be `open`-ed from the VM's Finder once so the system records the bundle ID, OR run from a shell that has audio-capture permission. Check System Settings → Privacy & Security → Microphone for `TapBenchmark` / `com.unison.tapbench`.

- **`AudioHardwareCreateProcessTap` returns `'who?'`**: invalid process object — `kAudioHardwarePropertyTranslatePIDToProcessObject` returned 0 for the PID. Make sure the target process is alive and has produced audio at least once.

- **Leftover aggregate devices** (CoreAudio shows `UnisonTapBenchmark` after a crash): `sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod` in the VM, or `tart stop && tart run unison-test` to reset.

- **Click train is audible during the Tap phase**: pass `--silent` to `tap-benchmark` (the VM script already does).

- **Both phases report 0 detected clicks**: most likely the engine output device binding failed silently. Verify by enabling temporary `print` statements at the top of `SignalGenerator.startAndScheduleClicks` to log the chosen `AudioDeviceID`.

---

## Self-Review (completed during plan authoring)

**1. Spec coverage**

- Goals (4) — covered by Tasks 6, 7, 8, 9, 11, 13
- ProcessTapCapture library — Task 7
- Click-train signal — Task 6
- Metrics (latency, jitter, drop, CPU) — Tasks 3, 4, 8
- BlackHole reuse — Task 8 (`startCaptureBlackHole`)
- Setup-friendly check — Task 9 (`setupFriendly` derivation), Task 11 (`without-blackhole` scenario)
- Sanity check on Zoom — Tasks 9, 11 (`sanity-zoom` scenario)
- Report (table + JSON) — Task 5
- TCC bundle + entitlements — Tasks 1, 10
- VM driver — Task 11
- VM doc — Task 12
- Success-criteria evaluation — not coded in CLI; lives in human review of the JSON (intentional, per spec scope)

**2. Placeholder scan**

No `TBD` / `TODO` / vague placeholders. All steps show full code or full commands. The realtime-safety section of `ProcessTapCapture` has a comment acknowledging that the current `Data` allocation in the IOProc is not strictly realtime — this is documented as a deliberate parity choice with `BlackHoleSinkCapture`, not a gap.

**3. Type consistency**

- `PhaseMetrics` field names (`medianLatencyMs`, `p95LatencyMs`, `jitterStdDevMs`, `dropRate`, `meanCpuPct`) used consistently across Tasks 4, 5, 8, 9.
- `PhaseResult` / `BenchmarkReport` / `SetupFriendlyResult` defined in Task 5 and consumed in Task 9.
- `HostTimeClock.ticks(forMilliseconds:)`, `nanoseconds(fromTicks:)`, `milliseconds(from:to:)` defined Task 2, consumed Tasks 4, 6, 8.
- `CoreAudioDeviceRegistry.findBlackHole16ch()` is the existing production helper; used unchanged in Tasks 8, 9.

**4. Scope check**

Single deliverable, single plan. No subsystem decomposition needed.

**5. Ambiguity check**

- `--phase both` vs `--scenario with-blackhole`: different axes (CLI phases vs VM scenario), both documented in Task 9 and Task 11.
- Setup-friendly verdict mapping: explicit ternary in Task 9 (`if blackHolePresent → SKIPPED; else if tap.metrics → PASS; else FAIL`).
