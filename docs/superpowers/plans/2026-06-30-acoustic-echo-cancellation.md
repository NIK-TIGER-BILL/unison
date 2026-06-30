# Acoustic Echo Cancellation (speaker mode) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cancel the speaker→mic acoustic echo so Unison can run on the built-in MacBook speakers in `.call` and `.test` without the translation feeding back into the outgoing stream.

**Architecture:** A swappable `EchoCanceller` (protocol in `UnisonDomain`) sits on the outgoing mic path, *before* `toWire`. Its far-end reference is a tap on `AVAudioOutputMixer`'s `mainMixerNode` (the real rendered playback). First implementation is `SpeexEchoCanceller` (SpeexDSP MDF echo canceller, vendored as a C target). Two threads: the render thread pushes the reference into a lock-free ring; the mic thread owns the Speex state and cancels. Working rate is 48 kHz F32 mono so a future WebRTC AEC3 swap stays native-rate.

**Tech Stack:** Swift 6.2 toolchain (Swift 5 language mode), SwiftPM, Swift Testing (`import Testing`, `@Test`, `#expect`), `Synchronization.Atomic`, vendored SpeexDSP 1.2.1 (C, revised-BSD).

**Spec:** `docs/superpowers/specs/2026-06-30-acoustic-echo-cancellation-design.md`

**Conventions for every task below:**
- Run tests with `swift test --filter <Name>`; build with `swift build`.
- Commit messages use Conventional Commits (`feat(audio): …`) and **end with the trailer**:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Work happens in the current worktree. Do not push.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `Sources/UnisonAudio/FarReferenceRing.swift` | Lock-free SPSC int16 sample ring (far-end handoff render→mic thread) |
| `Sources/UnisonAudio/Int16Reblocker.swift` | Re-block variable-size input into fixed Speex frames, no sample loss |
| `Sources/UnisonDomain/Protocols/EchoCanceller.swift` | `EchoReferenceSink` + `EchoCanceller` protocols |
| `Sources/CSpeexDSP/**` | Vendored SpeexDSP echo-canceller C sources + module map |
| `Sources/UnisonAudio/SpeexEchoCanceller.swift` | Concrete `EchoCanceller` (ring + reblocker + Speex lifecycle) |
| `Sources/UnisonAudio/EchoMetrics.swift` | Pure ERLE metric (used by tests + eval CLI) |
| `Sources/UnisonDomain/Protocols/AudioOutputMixer.swift` | + `setEchoReference(_:)` |
| `Sources/UnisonAudio/AVAudioOutputMixer.swift` | Install/remove `mainMixerNode` far-tap; teardown-first ordering |
| `Sources/UnisonDomain/TranslationOrchestrator.swift` | Inject canceller; `processNear` before `toWire`; register/clear sink |
| `Sources/UnisonApp/Composition.swift` | Construct the singleton; inject |
| `Sources/Tools/AecEval/**` | Offline ERLE eval harness |
| `Tests/UnisonAudioTests/*`, `Tests/UnisonDomainTests/*` | Unit tests + mocks |
| `Package.swift` | `CSpeexDSP` target, `UnisonAudio` dep, `AecEval` exe |
| `docs/audio-pipeline.md` | Document the AEC stage |

---

## Task 1: FarReferenceRing (lock-free SPSC int16 ring)

**Files:**
- Create: `Sources/UnisonAudio/FarReferenceRing.swift`
- Test: `Tests/UnisonAudioTests/FarReferenceRingTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/UnisonAudioTests/FarReferenceRingTests.swift`:

```swift
import Foundation
import Testing
@testable import UnisonAudio

private func write(_ ring: FarReferenceRing, _ samples: [Int16]) -> Int {
    samples.withUnsafeBufferPointer { ring.write($0) }
}

private func read(_ ring: FarReferenceRing, _ count: Int) -> [Int16] {
    var out = [Int16](repeating: -1, count: count)
    let n = out.withUnsafeMutableBufferPointer { ring.read(into: $0) }
    return Array(out[0..<n])
}

@Test func ring_writeThenRead_returnsSameSamples() {
    let ring = FarReferenceRing(capacity: 8)
    #expect(write(ring, [1, 2, 3]) == 3)
    #expect(read(ring, 3) == [1, 2, 3])
}

@Test func ring_readMoreThanAvailable_returnsOnlyAvailable() {
    let ring = FarReferenceRing(capacity: 8)
    _ = write(ring, [5, 6])
    #expect(read(ring, 4) == [5, 6])   // underrun → caller zero-fills the rest
}

@Test func ring_overflow_dropsExcessAndReportsShortWrite() {
    let ring = FarReferenceRing(capacity: 4)   // holds 4 samples max
    let wrote = write(ring, [1, 2, 3, 4, 5, 6])
    #expect(wrote == 4)                 // newest 2 dropped
    #expect(read(ring, 4) == [1, 2, 3, 4])
}

@Test func ring_wrapsAround() {
    let ring = FarReferenceRing(capacity: 4)
    _ = write(ring, [1, 2, 3])
    #expect(read(ring, 2) == [1, 2])    // head advances
    _ = write(ring, [4, 5, 6])          // wraps past the physical end
    #expect(read(ring, 4) == [3, 4, 5, 6])
}

@Test func ring_clear_emptiesBuffer() {
    let ring = FarReferenceRing(capacity: 8)
    _ = write(ring, [1, 2, 3])
    ring.clear()
    #expect(read(ring, 3) == [])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ring_writeThenRead_returnsSameSamples`
Expected: FAIL — `cannot find 'FarReferenceRing' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/UnisonAudio/FarReferenceRing.swift`:

```swift
import Synchronization

/// Single-producer / single-consumer lock-free ring of `Int16` samples.
///
/// The render thread (`AVAudioOutputMixer`'s `mainMixerNode` tap) is the
/// **only** producer (`write`); the mic thread (the outgoing pipeline's
/// `task1`) is the **only** consumer (`read`). Indices are monotonically
/// increasing `Int`s masked into the backing buffer — the classic Lamport
/// SPSC queue. No locks, no allocation on either path, so `write` is safe
/// to call from a CoreAudio real-time render callback.
///
/// Capacity is rounded up to a power of two. On overflow `write` keeps the
/// oldest samples already queued and drops the newest (returns a short
/// count); on underrun `read` returns fewer than requested and the caller
/// zero-fills (a missing far block means "no echo reference for this block"
/// → that block is simply not cancelled, which is safe).
final class FarReferenceRing: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutableBufferPointer<Int16>
    private let head = Atomic<Int>(0)   // consumer-owned read cursor
    private let tail = Atomic<Int>(0)   // producer-owned write cursor

    init(capacity: Int = 1 << 15) {
        var cap = 1
        while cap < capacity { cap <<= 1 }
        self.capacity = cap
        self.mask = cap - 1
        self.storage = UnsafeMutableBufferPointer<Int16>.allocate(capacity: cap)
        self.storage.initialize(repeating: 0)
    }

    deinit { storage.deallocate() }

    /// Producer. Returns the number of samples actually written (< count on
    /// overflow).
    @discardableResult
    func write(_ src: UnsafeBufferPointer<Int16>) -> Int {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let free = capacity - (t - h)
        let n = min(src.count, free)
        for i in 0..<n { storage[(t &+ i) & mask] = src[i] }
        tail.store(t &+ n, ordering: .releasing)
        return n
    }

    /// Consumer. Returns the number of samples actually read (< count on
    /// underrun).
    @discardableResult
    func read(into dst: UnsafeMutableBufferPointer<Int16>) -> Int {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let avail = t - h
        let n = min(dst.count, avail)
        for i in 0..<n { dst[i] = storage[(h &+ i) & mask] }
        head.store(h &+ n, ordering: .releasing)
        return n
    }

    /// Consumer-side reset. Only call when the producer is quiescent
    /// (session start/stop), which the orchestrator guarantees.
    func clear() {
        head.store(tail.load(ordering: .acquiring), ordering: .releasing)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ring_`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonAudio/FarReferenceRing.swift Tests/UnisonAudioTests/FarReferenceRingTests.swift
git commit -m "feat(audio): lock-free SPSC ring for AEC far-end reference"
```

---

## Task 2: Int16Reblocker (fixed-size framing)

**Files:**
- Create: `Sources/UnisonAudio/Int16Reblocker.swift`
- Test: `Tests/UnisonAudioTests/Int16ReblockerTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/UnisonAudioTests/Int16ReblockerTests.swift`:

```swift
import Testing
@testable import UnisonAudio

@Test func reblocker_emitsFullBlocks_andCarriesRemainder() {
    var rb = Int16Reblocker(blockSize: 480)
    let first = rb.push([Int16](repeating: 1, count: 600))
    #expect(first.count == 1)          // 600 → one 480 block
    #expect(first[0].count == 480)
    #expect(rb.pending == 120)         // 120 carried
    let second = rb.push([Int16](repeating: 2, count: 600))
    #expect(second.count == 1)         // 120 + 600 = 720 → one 480 block
    #expect(rb.pending == 240)
}

@Test func reblocker_smallPushes_accumulateUntilBlock() {
    var rb = Int16Reblocker(blockSize: 4)
    #expect(rb.push([1, 2]).isEmpty)
    #expect(rb.push([3]).isEmpty)
    let blocks = rb.push([4, 5])
    #expect(blocks == [[1, 2, 3, 4]])
    #expect(rb.pending == 1)
}

@Test func reblocker_noSampleLoss_acrossManyPushes() {
    var rb = Int16Reblocker(blockSize: 100)
    var emitted = 0
    for chunk in [37, 200, 1, 99, 63] {
        emitted += rb.push([Int16](repeating: 0, count: chunk)).count * 100
    }
    #expect(emitted + rb.pending == 37 + 200 + 1 + 99 + 63)
}

@Test func reblocker_reset_dropsCarry() {
    var rb = Int16Reblocker(blockSize: 4)
    _ = rb.push([1, 2, 3])
    rb.reset()
    #expect(rb.pending == 0)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter reblocker_emitsFullBlocks_andCarriesRemainder`
Expected: FAIL — `cannot find 'Int16Reblocker' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/UnisonAudio/Int16Reblocker.swift`:

```swift
/// Accumulates a stream of variable-length `Int16` chunks and emits
/// fixed-size blocks, carrying the sub-block remainder to the next `push`.
/// Used on the near (mic) path so SpeexDSP always sees exactly `blockSize`
/// samples per `speex_echo_cancellation` call. Single-threaded — owned by
/// the mic consumer task.
struct Int16Reblocker {
    let blockSize: Int
    private var carry: [Int16] = []

    init(blockSize: Int) { self.blockSize = blockSize }

    /// Append `samples` and return every complete block now available.
    mutating func push(_ samples: [Int16]) -> [[Int16]] {
        carry.append(contentsOf: samples)
        var blocks: [[Int16]] = []
        var offset = 0
        while carry.count - offset >= blockSize {
            blocks.append(Array(carry[offset..<offset + blockSize]))
            offset += blockSize
        }
        if offset > 0 { carry.removeFirst(offset) }
        return blocks
    }

    mutating func reset() { carry.removeAll(keepingCapacity: true) }

    var pending: Int { carry.count }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter reblocker_`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonAudio/Int16Reblocker.swift Tests/UnisonAudioTests/Int16ReblockerTests.swift
git commit -m "feat(audio): fixed-size reblocker for AEC near path"
```

---

## Task 3: EchoCanceller protocols + AudioOutputMixer extension

**Files:**
- Create: `Sources/UnisonDomain/Protocols/EchoCanceller.swift`
- Modify: `Sources/UnisonDomain/Protocols/AudioOutputMixer.swift`
- Modify: `Sources/UnisonAudio/AVAudioOutputMixer.swift` (no-op stub for now)
- Modify: `Tests/UnisonDomainTests/Mocks/MockAudioOutputMixer.swift`

This task is interface scaffolding — verified by a green build + existing
suite, not a new behavioral test. The real tap lands in Task 6.

- [ ] **Step 1: Create the protocols**

Create `Sources/UnisonDomain/Protocols/EchoCanceller.swift`:

```swift
/// Far-end reference sink. The output mixer pushes the audio it renders to
/// the speakers here, from its render thread. Implementations MUST be
/// real-time safe on this call: write into a lock-free buffer only — no
/// locks, no allocation, no syscalls.
public protocol EchoReferenceSink: Sendable {
    func pushFarReference(_ frame: AudioFrame)
}

/// Acoustic echo canceller. The orchestrator runs `processNear` on each mic
/// frame before it is sent to the translation backend.
public protocol EchoCanceller: EchoReferenceSink {
    /// 48 kHz F32 mono in → 48 kHz F32 mono out, with the echo of the
    /// far-end reference removed.
    func processNear(_ frame: AudioFrame) -> AudioFrame
    /// Clear adaptive state + far buffer. Called once per session start.
    func reset()
}
```

- [ ] **Step 2: Extend the mixer protocol**

In `Sources/UnisonDomain/Protocols/AudioOutputMixer.swift`, add one method:

```swift
public protocol AudioOutputMixer: Sendable {
    func start(deviceUID: String?) async throws
    func playTranslated(_ frames: AsyncStream<AudioFrame>) async
    func playOriginal(_ frames: AsyncStream<AudioFrame>) async
    func setOriginalGain(_ gain: Float)
    /// Register (or clear with `nil`) the AEC far-end reference sink. The
    /// mixer forwards its rendered output to the sink while one is set.
    func setEchoReference(_ sink: (any EchoReferenceSink)?)
    func stop()
}
```

- [ ] **Step 3: Stub the real mixer**

In `Sources/UnisonAudio/AVAudioOutputMixer.swift`, add a temporary no-op
(replaced in Task 6) just below `setOriginalGain(_:)`:

```swift
    public func setEchoReference(_ sink: (any EchoReferenceSink)?) {
        // Replaced with the mainMixerNode tap in Task 6.
    }
```

- [ ] **Step 4: Stub the mock mixer**

In `Tests/UnisonDomainTests/Mocks/MockAudioOutputMixer.swift`, add a
recorded property + method (used by Task 7's tests):

```swift
    /// Last sink handed to `setEchoReference`. `.some(nil)` records an
    /// explicit clear; `.none` means it was never called.
    public var echoReference: (any EchoReferenceSink)??
    public func setEchoReference(_ sink: (any EchoReferenceSink)?) {
        echoReference = .some(sink)
    }
```

- [ ] **Step 5: Build + run the existing suite**

Run: `swift build`
Expected: builds clean.
Run: `swift test --filter orchestrator_`
Expected: existing orchestrator tests still PASS (no behavior changed).

- [ ] **Step 6: Commit**

```bash
git add Sources/UnisonDomain/Protocols/EchoCanceller.swift Sources/UnisonDomain/Protocols/AudioOutputMixer.swift Sources/UnisonAudio/AVAudioOutputMixer.swift Tests/UnisonDomainTests/Mocks/MockAudioOutputMixer.swift
git commit -m "feat(domain): EchoCanceller protocols + mixer setEchoReference hook"
```

---

## Task 4: CSpeexDSP vendored C target

**Files:**
- Create: `Sources/CSpeexDSP/include/module.modulemap`
- Create: `Sources/CSpeexDSP/include/config.h`
- Create: `Sources/CSpeexDSP/**` (vendored upstream sources)
- Modify: `Package.swift`
- Test: `Tests/UnisonAudioTests/CSpeexDSPLinkageTests.swift`

> Vendoring autotools C into SwiftPM is the one task that may need a couple
> of iterations on the macro set. The linkage smoke test in Step 6 is the
> success gate — iterate the `config.h` / `cSettings` defines until it links
> and passes.

- [ ] **Step 1: Vendor the upstream sources**

Download SpeexDSP **1.2.1** (`https://github.com/xiph/speexdsp`, tag
`SpeexDSP-1.2.1`). Copy these files into `Sources/CSpeexDSP/` (keep the
upstream `COPYING` alongside them):

Compile units → `Sources/CSpeexDSP/`:
`mdf.c`, `fftwrap.c`, `kiss_fft.c`, `kiss_fftr.c`, `smallft.c`,
`preprocess.c`, `filterbank.c` (from upstream `libspeexdsp/`).

Public headers → `Sources/CSpeexDSP/include/speex/`:
`speex_echo.h`, `speex_preprocess.h`, `speexdsp_types.h`.

Internal headers → `Sources/CSpeexDSP/` (next to the `.c` files):
`arch.h`, `os_support.h`, `fftwrap.h`, `kiss_fft.h`, `_kiss_fft_guts.h`,
`kiss_fftr.h`, `math_approx.h`, `pseudofloat.h`, `smallft.h`,
`filterbank.h`, `fixed_generic.h`, `vorbis_psy.h`, `bfin.h`.

- [ ] **Step 2: Write `config.h`**

Create `Sources/CSpeexDSP/include/config.h`:

```c
#ifndef UNISON_SPEEXDSP_CONFIG_H
#define UNISON_SPEEXDSP_CONFIG_H
/* Minimal hand-written config for the vendored SpeexDSP echo/preprocess
   subset built under SwiftPM (no autotools). Float build + bundled KISS
   FFT; symbols namespaced so they can't collide with a system Speex. */
#define FLOATING_POINT
#define USE_KISS_FFT
#define EXPORT
#define OUTSIDE_SPEEX
#define RANDOM_PREFIX unison_speexdsp
#endif
```

- [ ] **Step 3: Write the module map**

Create `Sources/CSpeexDSP/include/module.modulemap`:

```
module CSpeexDSP {
    header "speex/speex_echo.h"
    header "speex/speex_preprocess.h"
    export *
}
```

- [ ] **Step 4: Wire the target into `Package.swift`**

In `Package.swift`, add the target (after the `UnisonAudio` target) and
make `UnisonAudio` depend on it. The C target carries the build defines and
header search paths so SwiftPM compiles the autotools-free sources:

```swift
        .target(
            name: "CSpeexDSP",
            path: "Sources/CSpeexDSP",
            publicHeadersPath: "include",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("include"),
                .headerSearchPath(".")
            ]
        ),
```

and change the `UnisonAudio` target dependency line to:

```swift
        .target(name: "UnisonAudio", dependencies: ["UnisonDomain", "CSpeexDSP"], swiftSettings: langModeV5),
```

Also add `#include "config.h"` handling: SpeexDSP sources already do
`#ifdef HAVE_CONFIG_H` `#include "config.h"`, satisfied by the `-DHAVE_CONFIG_H`
define + the `include` header search path above.

- [ ] **Step 5: Write the linkage smoke test**

Create `Tests/UnisonAudioTests/CSpeexDSPLinkageTests.swift`:

```swift
import Testing
import CSpeexDSP

@Test func cspeexdsp_echoState_initAndDestroy_links() {
    // Proves the vendored C target compiles, links, and is callable from
    // Swift. 64-sample frame, 1024-sample tail — values irrelevant here.
    let st = speex_echo_state_init(64, 1024)
    #expect(st != nil)
    speex_echo_state_destroy(st)
}
```

- [ ] **Step 6: Build + run the linkage test**

Run: `swift build`
Expected: `CSpeexDSP` compiles. If it fails, adjust `config.h` defines
(common culprits: missing `FLOATING_POINT`, FFT backend) until clean.
Run: `swift test --filter cspeexdsp_echoState_initAndDestroy_links`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/CSpeexDSP Package.swift Tests/UnisonAudioTests/CSpeexDSPLinkageTests.swift
git commit -m "build(audio): vendor SpeexDSP echo canceller as CSpeexDSP target"
```

---

## Task 5: SpeexEchoCanceller

**Files:**
- Create: `Sources/UnisonAudio/SpeexEchoCanceller.swift`
- Test: `Tests/UnisonAudioTests/SpeexEchoCancellerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/UnisonAudioTests/SpeexEchoCancellerTests.swift`:

```swift
import Foundation
import Testing
@testable import UnisonAudio
import UnisonDomain

// Deterministic noise so the convergence assertions never flake.
private struct LCG {
    var state: UInt64
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
    }
}

private func f32Frame(_ samples: [Float]) -> AudioFrame {
    var data = Data(count: samples.count * 4)
    data.withUnsafeMutableBytes { raw in
        let p = raw.bindMemory(to: Float.self)
        for i in samples.indices { p[i] = samples[i] }
    }
    return AudioFrame(pcm: data, sampleRate: 48_000, channels: 1, format: .float32)
}

private func samples(_ frame: AudioFrame) -> [Float] {
    var out = [Float](repeating: 0, count: frame.sampleCount)
    frame.pcm.withUnsafeBytes { raw in
        let p = raw.bindMemory(to: Float.self)
        for i in out.indices { out[i] = p[i] }
    }
    return out
}

private func rms(_ s: [Float]) -> Float {
    guard !s.isEmpty else { return 0 }
    return (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
}

@Test func speex_silentFar_preservesNear() {
    let aec = SpeexEchoCanceller()
    var lcg = LCG(state: 1)
    let block = 480
    let near = (0..<block).map { _ in lcg.next() * 0.3 }
    // Far is silence → nothing correlated to remove → near passes through.
    aec.pushFarReference(f32Frame([Float](repeating: 0, count: block)))
    let out = samples(aec.processNear(f32Frame(near)))
    #expect(out.count == block)
    #expect(abs(rms(out) - rms(near)) < 0.05)
}

@Test func speex_cancelsCorrelatedEcho() {
    let aec = SpeexEchoCanceller()
    var lcg = LCG(state: 42)
    let block = 480
    var inRMS: Float = 0, outRMS: Float = 0
    // Echo-only scenario: mic hears exactly what was played. After the
    // filter converges, the residual should be a fraction of the input.
    for i in 0..<400 {
        let far = (0..<block).map { _ in lcg.next() * 0.3 }
        aec.pushFarReference(f32Frame(far))
        let out = samples(aec.processNear(f32Frame(far)))   // near == far
        if i >= 350 { inRMS += rms(far); outRMS += rms(out) }
    }
    // ≥ ~6 dB echo return loss enhancement after convergence.
    #expect(outRMS < inRMS * 0.5)
}

@Test func speex_doubleTalk_preservesNearVoice() {
    let aec = SpeexEchoCanceller()
    var farGen = LCG(state: 7), nearGen = LCG(state: 99)
    let block = 480
    var nearVoiceRMS: Float = 0, outRMS: Float = 0
    for i in 0..<400 {
        let far = (0..<block).map { _ in farGen.next() * 0.3 }
        let voice = (0..<block).map { _ in nearGen.next() * 0.2 }
        let mic = zip(voice, far).map(+)         // user voice + acoustic echo
        aec.pushFarReference(f32Frame(far))
        let out = samples(aec.processNear(f32Frame(mic)))
        if i >= 350 { nearVoiceRMS += rms(voice); outRMS += rms(out) }
    }
    // Output should track the near voice (echo removed), not be crushed to
    // silence and not still carry the full echo.
    #expect(outRMS > nearVoiceRMS * 0.5)
    #expect(outRMS < nearVoiceRMS * 1.8)
}

@Test func speex_reset_restoresPassthrough() {
    let aec = SpeexEchoCanceller()
    var lcg = LCG(state: 3)
    let block = 480
    for _ in 0..<100 {
        let far = (0..<block).map { _ in lcg.next() * 0.3 }
        aec.pushFarReference(f32Frame(far))
        _ = aec.processNear(f32Frame(far))
    }
    aec.reset()
    let near = (0..<block).map { _ in lcg.next() * 0.3 }
    aec.pushFarReference(f32Frame([Float](repeating: 0, count: block)))
    let out = samples(aec.processNear(f32Frame(near)))
    #expect(abs(rms(out) - rms(near)) < 0.08)
}

@Test func speex_reblocks_oddSizedFrames() {
    let aec = SpeexEchoCanceller()
    // 500-sample near with no full pending → 480 out, 20 carried.
    aec.pushFarReference(f32Frame([Float](repeating: 0, count: 500)))
    let out = aec.processNear(f32Frame([Float](repeating: 0.1, count: 500)))
    #expect(out.sampleCount == 480)
    #expect(out.sampleRate == 48_000)
    #expect(out.format == .float32)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter speex_silentFar_preservesNear`
Expected: FAIL — `cannot find 'SpeexEchoCanceller' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/UnisonAudio/SpeexEchoCanceller.swift`:

```swift
import Foundation
import CSpeexDSP
import UnisonDomain

/// `EchoCanceller` backed by SpeexDSP's MDF acoustic echo canceller.
///
/// Works at 48 kHz F32 mono (the native mic + mainMixer rate, and AEC3's
/// native rate for a future swap). Internally converts to int16 for Speex.
/// Two-thread contract: `pushFarReference` runs on the render thread and
/// only writes into the lock-free `FarReferenceRing`; `processNear` runs on
/// the mic task and owns the Speex state. `reset` is guarded so a session
/// restart can't race an in-flight `processNear`.
public final class SpeexEchoCanceller: EchoCanceller, @unchecked Sendable {
    public struct Config: Sendable {
        public let sampleRate: Int32
        public let frameSize: Int       // samples per speex_echo_cancellation
        public let filterLength: Int    // echo tail in samples (~100 ms)
        public let ringCapacity: Int
        public static let `default` = Config(
            sampleRate: 48_000, frameSize: 480, filterLength: 4_800,
            ringCapacity: 1 << 15)
    }

    private let config: Config
    private let echoState: OpaquePointer
    private let farRing: FarReferenceRing
    private var nearReblocker: Int16Reblocker
    /// Guards `echoState` + `nearReblocker` between `processNear` (mic task)
    /// and `reset` (orchestrator/main). The render thread never touches
    /// them — it only writes the ring — so this lock is off the RT path.
    private let stateLock = NSLock()
    /// Render-thread-only scratch for F32→int16 conversion. Single producer,
    /// so no synchronization needed.
    private var farScratch: [Int16]

    public init(config: Config = .default) {
        self.config = config
        self.echoState = speex_echo_state_init(Int32(config.frameSize),
                                               Int32(config.filterLength))
        self.farRing = FarReferenceRing(capacity: config.ringCapacity)
        self.nearReblocker = Int16Reblocker(blockSize: config.frameSize)
        self.farScratch = [Int16](repeating: 0, count: 8192)
        var rate = config.sampleRate
        speex_echo_ctl(echoState, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
    }

    deinit { speex_echo_state_destroy(echoState) }

    // MARK: EchoReferenceSink (render thread)

    public func pushFarReference(_ frame: AudioFrame) {
        guard frame.format == .float32 else { return }
        frame.pcm.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Float.self)
            var i = 0
            while i < src.count {
                let chunk = min(farScratch.count, src.count - i)
                for j in 0..<chunk { farScratch[j] = Self.toInt16(src[i + j]) }
                farScratch.withUnsafeBufferPointer {
                    _ = farRing.write(UnsafeBufferPointer(start: $0.baseAddress, count: chunk))
                }
                i += chunk
            }
        }
    }

    // MARK: EchoCanceller (mic task)

    public func processNear(_ frame: AudioFrame) -> AudioFrame {
        guard frame.format == .float32 else { return frame }
        let nearF32 = frame.pcm.withUnsafeBytes { raw -> [Int16] in
            let src = raw.bindMemory(to: Float.self)
            return (0..<src.count).map { Self.toInt16(src[$0]) }
        }

        stateLock.lock()
        defer { stateLock.unlock() }

        var out = [Int16]()
        var farBlock = [Int16](repeating: 0, count: config.frameSize)
        var outBlock = [Int16](repeating: 0, count: config.frameSize)
        for block in nearReblocker.push(nearF32) {
            // Pull an aligned far block; zero-fill any underrun (missing
            // reference for this block → cancel against silence = no-op).
            let got = farBlock.withUnsafeMutableBufferPointer { farRing.read(into: $0) }
            if got < config.frameSize {
                for k in got..<config.frameSize { farBlock[k] = 0 }
            }
            block.withUnsafeBufferPointer { near in
                farBlock.withUnsafeBufferPointer { far in
                    outBlock.withUnsafeMutableBufferPointer { o in
                        speex_echo_cancellation(echoState, near.baseAddress,
                                                far.baseAddress, o.baseAddress)
                    }
                }
            }
            out.append(contentsOf: outBlock)
        }

        var data = Data(count: out.count * 4)
        data.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: Float.self)
            for i in out.indices { dst[i] = Self.toFloat(out[i]) }
        }
        return AudioFrame(pcm: data, sampleRate: 48_000, channels: 1, format: .float32)
    }

    public func reset() {
        stateLock.lock()
        defer { stateLock.unlock() }
        speex_echo_state_reset(echoState)
        farRing.clear()
        nearReblocker.reset()
    }

    // MARK: Conversion

    private static func toInt16(_ f: Float) -> Int16 {
        Int16(max(-1.0, min(1.0, f)) * 32_767.0)
    }
    private static func toFloat(_ i: Int16) -> Float {
        Float(i) / 32_768.0
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter speex_`
Expected: PASS (6 tests). If `speex_cancelsCorrelatedEcho` is marginal,
raise the convergence window (`i >= 350` → more frames) — do NOT loosen the
0.5 ratio.

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonAudio/SpeexEchoCanceller.swift Tests/UnisonAudioTests/SpeexEchoCancellerTests.swift
git commit -m "feat(audio): SpeexEchoCanceller — MDF AEC with far-reference ring"
```

---

## Task 6: AVAudioOutputMixer far-reference tap + teardown ordering

**Files:**
- Modify: `Sources/UnisonAudio/AVAudioOutputMixer.swift`
- Test: `Tests/UnisonAudioTests/AVAudioOutputMixerEchoTapTests.swift`

- [ ] **Step 1: Write the failing test (conversion helper)**

The `installTap` lifecycle is integration/VM-verified; the unit-testable
part is the buffer→`AudioFrame` conversion the tap callback performs.

Create `Tests/UnisonAudioTests/AVAudioOutputMixerEchoTapTests.swift`:

```swift
import AVFoundation
import Testing
@testable import UnisonAudio
import UnisonDomain

@Test func echoFrame_fromFloatBuffer_isMono48kF32() throws {
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                            sampleRate: 48_000, channels: 1, interleaved: false)!
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4)!
    buf.frameLength = 4
    for i in 0..<4 { buf.floatChannelData![0][i] = Float(i) * 0.1 }

    let frame = try #require(AVAudioOutputMixer.echoFrame(from: buf))
    #expect(frame.sampleRate == 48_000)
    #expect(frame.channels == 1)
    #expect(frame.format == .float32)
    #expect(frame.sampleCount == 4)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter echoFrame_fromFloatBuffer_isMono48kF32`
Expected: FAIL — `type 'AVAudioOutputMixer' has no member 'echoFrame'`.

- [ ] **Step 3: Implement the tap + helper**

In `Sources/UnisonAudio/AVAudioOutputMixer.swift`:

(a) Add a stored sink property near the other private vars (e.g. after
`private let agc = CompensatingAGCRunner()`):

```swift
    /// AEC far-end reference sink. Set per session by the orchestrator in
    /// mic modes. While non-nil, a tap on `mainMixerNode` forwards every
    /// rendered block here so the echo canceller knows what is on the
    /// speakers. Render-thread access; the sink itself is RT-safe.
    private var echoSink: (any EchoReferenceSink)?
```

(b) Replace the Task-3 no-op `setEchoReference(_:)` with the real one:

```swift
    public func setEchoReference(_ sink: (any EchoReferenceSink)?) {
        echoSink = sink
        if sink != nil {
            installEchoReferenceTap()
        } else {
            removeEchoReferenceTap()
        }
    }

    private func installEchoReferenceTap() {
        // Tap the post-mix output (translated post-timePitch/AGC + original)
        // — exactly what reaches the speaker. Mono 48k (playerFormat). A
        // second tap alongside the optional UNISON_DUMP_PLAYBACK_WAV tap
        // (which is on `timePitch`, a different node) is fine.
        mixer.removeTap(onBus: 0)   // idempotent re-install on stop-restart
        let fmt = mixer.outputFormat(forBus: 0)
        mixer.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buffer, _ in
            guard let self, let sink = self.echoSink,
                  let frame = Self.echoFrame(from: buffer) else { return }
            sink.pushFarReference(frame)
        }
    }

    private func removeEchoReferenceTap() {
        mixer.removeTap(onBus: 0)
    }

    /// Convert a rendered mono float buffer into a 48 kHz F32 mono
    /// `AudioFrame`. Returns nil for a non-float or empty buffer.
    static func echoFrame(from buffer: AVAudioPCMBuffer) -> AudioFrame? {
        let n = Int(buffer.frameLength)
        guard n > 0, let ch = buffer.floatChannelData?[0] else { return nil }
        let data = Data(bytes: ch, count: n * MemoryLayout<Float>.size)
        return AudioFrame(pcm: data, sampleRate: 48_000, channels: 1, format: .float32)
    }
```

(c) In `stop()`, remove the echo tap FIRST — before the player `reset()`s
and `engine.stop()`, mirroring `closePlaybackDumpIfNeeded()`. Change the
body to:

```swift
    public func stop() {
        pacing?.stop()
        closePlaybackDumpIfNeeded()
        // Remove the AEC tap before any player/engine teardown so no
        // pushFarReference runs on the render thread mid-teardown (the
        // Process-Tap Stop-hang class of bug). removeTap drains pending
        // render callbacks before returning.
        removeEchoReferenceTap()
        echoSink = nil
        translatedPlayer.reset()
        originalPlayer.reset()
        engine.stop()
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter echoFrame_fromFloatBuffer_isMono48kF32`
Expected: PASS.
Run: `swift build`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonAudio/AVAudioOutputMixer.swift Tests/UnisonAudioTests/AVAudioOutputMixerEchoTapTests.swift
git commit -m "feat(audio): mainMixerNode far-reference tap with teardown-first removal"
```

---

## Task 7: Orchestrator wiring

**Files:**
- Modify: `Sources/UnisonDomain/TranslationOrchestrator.swift`
- Create: `Tests/UnisonDomainTests/Mocks/MockEchoCanceller.swift`
- Modify: `Tests/UnisonDomainTests/TranslationOrchestratorTests.swift`

- [ ] **Step 1: Add the mock canceller**

Create `Tests/UnisonDomainTests/Mocks/MockEchoCanceller.swift`:

```swift
import Foundation
@testable import UnisonDomain

public final class MockEchoCanceller: EchoCanceller, @unchecked Sendable {
    public private(set) var processNearCalls = 0
    public private(set) var resetCalls = 0
    public private(set) var farPushes = 0
    private let lock = NSLock()

    public init() {}

    public func pushFarReference(_ frame: AudioFrame) {
        lock.lock(); farPushes += 1; lock.unlock()
    }
    public func processNear(_ frame: AudioFrame) -> AudioFrame {
        lock.lock(); processNearCalls += 1; lock.unlock()
        return frame   // passthrough; we only assert it was invoked
    }
    public func reset() {
        lock.lock(); resetCalls += 1; lock.unlock()
    }
    public var processNearCount: Int { lock.lock(); defer { lock.unlock() }; return processNearCalls }
}
```

- [ ] **Step 2: Write the failing orchestrator tests**

In `Tests/UnisonDomainTests/TranslationOrchestratorTests.swift`, first add
an `echoCanceller` parameter to the `makeOrchestrator` helper:

```swift
private func makeOrchestrator(
    mic: MockMicrophoneCapture = .init(),
    peer: MockPeerAudioCapture = .init(),
    mixer: MockAudioOutputMixer = .init(),
    bhPlayer: MockAudioPlayer = .init(),
    factory: MockTranslationStreamFactory = .init(),
    perms: MockPermissionsService? = nil,
    registry: MockAudioDeviceRegistry? = nil,
    clock: any Clock = SystemClock(),
    transformer: any AudioFormatTransformer = MockAudioFormatTransformer(),
    networkMonitor: any NetworkPathMonitoring = MockNetworkPathMonitor(initial: .satisfied),
    echoCanceller: (any EchoCanceller)? = nil
) -> TranslationOrchestrator {
    let resolvedRegistry = registry ?? defaultRegistry()
    let resolvedPerms = perms ?? defaultPerms()
    return TranslationOrchestrator(
        micCapture: mic, peerCapture: peer, outputMixer: mixer,
        virtualMicPlayer: bhPlayer, translationFactory: factory,
        permissions: resolvedPerms, deviceRegistry: resolvedRegistry, clock: clock,
        transformer: transformer,
        networkMonitor: networkMonitor,
        echoCanceller: echoCanceller
    )
}
```

Then add the tests (append to the file):

```swift
@Test @MainActor func orchestrator_callMode_registersEchoReferenceAndResets() async {
    let mixer = MockAudioOutputMixer()
    let aec = MockEchoCanceller()
    let o = makeOrchestrator(mixer: mixer, echoCanceller: aec)
    await o.start(mode: .call, languages: .default)
    // Far sink registered (non-nil) and adaptive state reset on start.
    if case .some(.some) = mixer.echoReference {} else {
        Issue.record("expected setEchoReference(non-nil) in call mode")
    }
    #expect(aec.resetCalls == 1)
}

@Test @MainActor func orchestrator_listenMode_doesNotRegisterEchoReference() async {
    let mixer = MockAudioOutputMixer()
    let aec = MockEchoCanceller()
    let o = makeOrchestrator(mixer: mixer, echoCanceller: aec)
    await o.start(mode: .listen, languages: .default)
    // Listen has no mic → no far sink, no reset.
    if case .some(.some) = mixer.echoReference {
        Issue.record("listen mode must not register an echo reference")
    }
    #expect(aec.resetCalls == 0)
}

@Test @MainActor func orchestrator_stop_clearsEchoReference() async {
    let mixer = MockAudioOutputMixer()
    let aec = MockEchoCanceller()
    let o = makeOrchestrator(mixer: mixer, echoCanceller: aec)
    await o.start(mode: .call, languages: .default)
    await o.stop()
    // After stop the sink was explicitly cleared (.some(nil)).
    if case .some(.none) = mixer.echoReference {} else {
        Issue.record("expected setEchoReference(nil) on stop")
    }
}

@Test @MainActor func orchestrator_callMode_runsMicFramesThroughCanceller() async {
    let mic = MockMicrophoneCapture()
    let aec = MockEchoCanceller()
    let o = makeOrchestrator(mic: mic, echoCanceller: aec)
    await o.start(mode: .call, languages: .default)
    let frame = AudioFrame(pcm: Data(count: 960 * 4), sampleRate: 48_000,
                           channels: 1, format: .float32)
    mic.emit(frame)
    // The mic pump hops through MainActor; yield until processNear is seen.
    for _ in 0..<200 where aec.processNearCount == 0 { await Task.yield() }
    #expect(aec.processNearCount >= 1)
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter orchestrator_callMode_registersEchoReferenceAndResets`
Expected: FAIL — `TranslationOrchestrator` has no `echoCanceller:` parameter.

- [ ] **Step 4: Implement the orchestrator changes**

(a) Add the stored dependency. Next to the other `private let` deps (after
`private let transformer: any AudioFormatTransformer`):

```swift
    /// Optional acoustic echo canceller. Present in production for the
    /// speaker-mode echo loop; nil in tests/tools that don't need it.
    private let echoCanceller: (any EchoCanceller)?
```

(b) Add it to `init`. Append a parameter (with a default so existing
callers keep compiling) and assign it:

```swift
        networkMonitor: any NetworkPathMonitoring,
        echoCanceller: (any EchoCanceller)? = nil
    ) {
        ...
        self.networkMonitor = networkMonitor
        self.echoCanceller = echoCanceller
    }
```

(c) Register the far sink + reset in `start()`, in mic modes only, right
after the output mixer starts. Find:

```swift
            try await outputMixer.start(deviceUID: settings.outputDeviceUID)
            outputMixer.setOriginalGain(settings.originalMixVolume)
```

and add immediately below it (inside the same `do` block):

```swift
            if mode.requiresMicrophone {
                echoCanceller?.reset()
                outputMixer.setEchoReference(echoCanceller)
            }
```

(d) Run mic frames through the canceller in `wireOutgoingPipeline`. Capture
the canceller as a local before `task1` (next to `let transformer = self.transformer`):

```swift
        let transformer = self.transformer
        let echoCanceller = self.echoCanceller
```

and inside `task1`, change the send line from:

```swift
                let wire = transformer.toWire(frame)
```

to:

```swift
                let near = echoCanceller?.processNear(frame) ?? frame
                let wire = transformer.toWire(near)
```

(e) Clear the sink on teardown. In `stopAllStreams()` the real mixer
teardown (`mixer.stop()`) runs inside a **detached** task, so clear the sink
synchronously on the MainActor *before* that — right after
`stopSlowDetectionLoop()`, near the top of the method:

```swift
        // Remove the AEC far-reference (tap off) before the detached HAL
        // teardown tears the engine down. Idempotent with the mixer's own
        // stop()-time tap removal; also clears the mock's recorded sink.
        outputMixer.setEchoReference(nil)
```

This places the `mainMixerNode` tap removal ahead of `engine.stop()` (the
desired teardown ordering) and gives the mock mixer the `.some(nil)` the
stop test asserts.

(f) Re-reset on network resume. In `resumeStreams(...)`, inside the
`if mode == .call || mode == .test {` branch (the me-stream re-wire), add at
the top of that branch:

```swift
            echoCanceller?.reset()
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter orchestrator_`
Expected: PASS (existing + 4 new).

- [ ] **Step 6: Commit**

```bash
git add Sources/UnisonDomain/TranslationOrchestrator.swift Tests/UnisonDomainTests/Mocks/MockEchoCanceller.swift Tests/UnisonDomainTests/TranslationOrchestratorTests.swift
git commit -m "feat(domain): wire EchoCanceller into the outgoing mic pipeline"
```

---

## Task 8: Composition wiring

**Files:**
- Modify: `Sources/UnisonApp/Composition.swift`

Pure wiring — verified by build + full suite.

- [ ] **Step 1: Construct + inject the singleton**

In `Sources/UnisonApp/Composition.swift`, after `let mixer = AVAudioOutputMixer()`:

```swift
        let mixer = AVAudioOutputMixer()
        // One persistent echo canceller, reused across sessions (reset per
        // start). Never destroyed mid-teardown — keeps Speex alloc/dealloc
        // off the Stop path. See the AEC design + audio-pipeline.md.
        let echoCanceller = SpeexEchoCanceller()
```

and add it to the orchestrator construction:

```swift
        self.orchestrator = TranslationOrchestrator(
            micCapture: mic,
            peerCapture: peerCap,
            outputMixer: mixer,
            virtualMicPlayer: bhPlayer,
            translationFactory: factory,
            permissions: permissions,
            deviceRegistry: registry,
            clock: SystemClock(),
            transformer: ResamplerAdapter(),
            networkMonitor: NetworkMonitor(),
            echoCanceller: echoCanceller
        )
```

- [ ] **Step 2: Build + full suite**

Run: `swift build`
Expected: clean.
Run: `swift test`
Expected: entire suite PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/UnisonApp/Composition.swift
git commit -m "feat(app): inject SpeexEchoCanceller in the composition root"
```

---

## Task 9: ERLE metric + aec-eval harness

**Files:**
- Create: `Sources/UnisonAudio/EchoMetrics.swift`
- Test: `Tests/UnisonAudioTests/EchoMetricsTests.swift`
- Create: `Sources/Tools/AecEval/main.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Write the failing metric test**

Create `Tests/UnisonAudioTests/EchoMetricsTests.swift`:

```swift
import Testing
@testable import UnisonAudio

@Test func erle_halfAmplitudeResidual_isAboutSixDB() {
    let near = [Float](repeating: 0.4, count: 1000)
    let residual = [Float](repeating: 0.2, count: 1000)   // half → ~6.02 dB
    let erle = EchoMetrics.erleDB(reference: near, residual: residual)
    #expect(abs(erle - 6.02) < 0.1)
}

@Test func erle_silentResidual_isLargePositive() {
    let near = [Float](repeating: 0.4, count: 1000)
    let residual = [Float](repeating: 0, count: 1000)
    #expect(EchoMetrics.erleDB(reference: near, residual: residual) > 60)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter erle_halfAmplitudeResidual_isAboutSixDB`
Expected: FAIL — `cannot find 'EchoMetrics' in scope`.

- [ ] **Step 3: Implement the metric**

Create `Sources/UnisonAudio/EchoMetrics.swift`:

```swift
import Foundation

/// Echo-cancellation quality metrics, shared by tests and the aec-eval CLI.
public enum EchoMetrics {
    /// Echo Return Loss Enhancement in dB: how much the residual is below
    /// the reference, in RMS terms. Higher is better. A silent residual is
    /// clamped to a large finite value so callers don't get +inf.
    public static func erleDB(reference: [Float], residual: [Float]) -> Double {
        let refRMS = rms(reference)
        let resRMS = rms(residual)
        guard refRMS > 1e-9 else { return 0 }
        guard resRMS > 1e-9 else { return 120 }
        return 20.0 * log10(Double(refRMS) / Double(resRMS))
    }

    public static func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        return (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter erle_`
Expected: PASS (2 tests).

- [ ] **Step 5: Add the eval CLI**

Create `Sources/Tools/AecEval/main.swift`:

```swift
import Foundation
import UnisonAudio
import UnisonDomain

// aec-eval — offline ERLE harness.
//
//   swift run aec-eval --near <near.wav> --far <far.wav> [--delay-ms 25] [--echo-gain 0.5]
//
// Synthesizes a mic signal = near + echo-gain · delay(far), runs it through
// SpeexEchoCanceller (with `far` as the reference), and reports ERLE per
// second + overall. This is the gate for deciding whether the AEC3 upgrade
// is worth it: run the same inputs through a future AEC3 implementation and
// compare. WAVs are 48 kHz mono float32 (matching Tests/Fixtures/audio).

func arg(_ name: String, _ def: String? = nil) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return def
}

guard let nearPath = arg("--near"), let farPath = arg("--far") else {
    FileHandle.standardError.write(Data("usage: aec-eval --near <wav> --far <wav> [--delay-ms N] [--echo-gain G]\n".utf8))
    exit(2)
}
let delayMs = Int(arg("--delay-ms", "25")!) ?? 25
let echoGain = Float(arg("--echo-gain", "0.5")!) ?? 0.5

let near = WavIO.readMonoF32(path: nearPath)
let far = WavIO.readMonoF32(path: farPath)
let delaySamples = delayMs * 48
let n = min(near.count, far.count)

// mic = near + echo-gain · delay(far)
var mic = [Float](repeating: 0, count: n)
for i in 0..<n {
    let d = i - delaySamples
    let echo = d >= 0 && d < far.count ? far[d] * echoGain : 0
    mic[i] = near[i] + echo
}

let aec = SpeexEchoCanceller()
let block = 480
var residual = [Float]()
residual.reserveCapacity(n)
var i = 0
while i + block <= n {
    aec.pushFarReference(WavIO.frame(Array(far[i..<i+block])))
    let out = WavIO.samples(aec.processNear(WavIO.frame(Array(mic[i..<i+block]))))
    residual.append(contentsOf: out)
    i += block
}

// Per-second ERLE (compare residual vs the near+echo mic it came from).
let micPrefix = Array(mic[0..<residual.count])
print("delay=\(delayMs)ms echoGain=\(echoGain)")
let perSec = 48_000
var s = 0
while s + perSec <= residual.count {
    let e = EchoMetrics.erleDB(reference: Array(micPrefix[s..<s+perSec]),
                               residual: Array(residual[s..<s+perSec]))
    print(String(format: "  t=%2ds  ERLE=%.1f dB", s / perSec, e))
    s += perSec
}
let overall = EchoMetrics.erleDB(reference: micPrefix, residual: residual)
print(String(format: "overall ERLE = %.1f dB", overall))
```

Create `Sources/Tools/AecEval/WavIO.swift` (minimal 48 kHz mono float32 WAV
reader + AudioFrame helpers):

```swift
import Foundation
import UnisonDomain

enum WavIO {
    /// Reads a 48 kHz mono float32 WAV's `data` chunk into [Float].
    /// Assumes the canonical 44-byte header produced by
    /// Tests/Fixtures/audio/generate.sh.
    static func readMonoF32(path: String) -> [Float] {
        guard let d = FileManager.default.contents(atPath: path), d.count > 44 else { return [] }
        let body = d.subdata(in: 44..<d.count)
        let count = body.count / 4
        var out = [Float](repeating: 0, count: count)
        body.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            for i in 0..<count { out[i] = p[i] }
        }
        return out
    }

    static func frame(_ s: [Float]) -> AudioFrame {
        var data = Data(count: s.count * 4)
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            for i in s.indices { p[i] = s[i] }
        }
        return AudioFrame(pcm: data, sampleRate: 48_000, channels: 1, format: .float32)
    }

    static func samples(_ frame: AudioFrame) -> [Float] {
        var out = [Float](repeating: 0, count: frame.sampleCount)
        frame.pcm.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            for i in out.indices { out[i] = p[i] }
        }
        return out
    }
}
```

- [ ] **Step 6: Register the executable target**

In `Package.swift`, add to `products`:

```swift
        .executable(name: "aec-eval", targets: ["AecEval"]),
```

and to `targets` (mirroring the `PacingEval` tool target):

```swift
        .executableTarget(
            name: "AecEval",
            dependencies: ["UnisonAudio", "UnisonDomain"],
            path: "Sources/Tools/AecEval",
            swiftSettings: langModeV5
        ),
```

- [ ] **Step 7: Build + run on a fixture**

Run: `swift build`
Expected: clean.
Run: `swift run aec-eval --near Tests/Fixtures/audio/en-monologue-normal.wav --far Tests/Fixtures/audio/ru-monologue-normal.wav`
Expected: prints per-second ERLE lines and an `overall ERLE = … dB` line
with a positive overall value (echo is being reduced).

- [ ] **Step 8: Commit**

```bash
git add Sources/UnisonAudio/EchoMetrics.swift Tests/UnisonAudioTests/EchoMetricsTests.swift Sources/Tools/AecEval Package.swift
git commit -m "feat(tools): aec-eval offline ERLE harness + EchoMetrics"
```

---

## Task 10: Far-reference fixture

**Files:**
- Modify: `Tests/Fixtures/audio/generate.sh`

- [ ] **Step 1: Add a translation-like far fixture**

`Tests/Fixtures/audio/*.wav` are synthesized with `say` + `afconvert`. Add a
far/translation monologue alongside the existing ones. Append a generation
line following the file's existing pattern (match the existing `afconvert`
flags exactly — 48 kHz mono float32). Add, adapting to the script's helper:

```bash
# Far-end reference fixture for aec-eval (a "translation" monologue, a
# different voice from the near fixtures so double-talk is realistic).
say -v Daniel -o /tmp/aec-far.aiff "The quarterly results exceeded expectations across every region we operate in."
afconvert -f WAVE -d LEF32@48000 -c 1 /tmp/aec-far.aiff "$DIR/far-monologue-normal.wav"
```

(If `generate.sh` defines a `$DIR`/output-dir variable or a helper function,
use that instead of the literal path — match the surrounding lines.)

- [ ] **Step 2: Regenerate + verify**

Run: `bash Tests/Fixtures/audio/generate.sh`
Expected: `Tests/Fixtures/audio/far-monologue-normal.wav` exists, 48 kHz
mono float32.
Run: `swift run aec-eval --near Tests/Fixtures/audio/en-monologue-normal.wav --far Tests/Fixtures/audio/far-monologue-normal.wav`
Expected: prints ERLE report.

- [ ] **Step 3: Commit**

```bash
git add Tests/Fixtures/audio/generate.sh Tests/Fixtures/audio/far-monologue-normal.wav
git commit -m "test(audio): far-reference fixture for aec-eval"
```

---

## Task 11: Document the AEC stage

**Files:**
- Modify: `docs/audio-pipeline.md`

- [ ] **Step 1: Add the AEC section**

In `docs/audio-pipeline.md`, after the `## Наша цепочка — компоненты`
component list (before the `## Process Tap scope` section), add:

```markdown
### `SpeexEchoCanceller` (Sources/UnisonAudio/SpeexEchoCanceller.swift)
Acoustic echo cancellation for **speaker mode** — без него перевод,
играющий из динамиков, переловится микрофоном и уйдёт в outgoing-перевод
(loop). С наушниками проблемы нет (нет акустического пути динамик→микрофон).

- **Где:** в `wireOutgoingPipeline` `task1`, `processNear(frame)` **до**
  `toWire`. Применяется в `.call` и `.test` (есть микрофон); `.listen` —
  нет.
- **Far-reference:** tap на `AVAudioOutputMixer.mainMixerNode` — реальный
  рендер (translated post-timePitch/AGC + original), а не запланированные
  кадры.
- **Рейт:** 48 kHz F32 mono (нативный far + mic; AEC3-апгрейд native-rate).
  Внутри Speex — int16.
- **Два потока:** render-поток только пишет far в lock-free `FarReferenceRing`
  (RT-safe), mic-поток владеет Speex-стейтом и зовёт
  `speex_echo_cancellation`.
- **`noise_reduction: near_field` ≠ AEC** — это шумодав, эхо не убирает.
- **Teardown:** `AVAudioOutputMixer.stop()` снимает mainMixer-tap **первым**
  (до `reset()`/`engine.stop()`), как `closePlaybackDumpIfNeeded`. Canceller
  — singleton, `reset()` на старте, не уничтожается в teardown (Speex
  alloc/dealloc вне Stop-пути).
- **Eval:** `swift run aec-eval --near <wav> --far <wav>` — ERLE/сек на
  синтезированном миксе. Это gate для апгрейда на AEC3.
- **Движок swappable** за `EchoCanceller`-протоколом (UnisonDomain) — AEC3
  меняется без правок call-site.
```

- [ ] **Step 2: Commit**

```bash
git add docs/audio-pipeline.md
git commit -m "docs(audio): document the AEC stage"
```

---

## Final verification

- [ ] Run the whole suite + lint:

```bash
swift test
swiftlint
```

Expected: all tests PASS; SwiftLint clean (the orchestrator already carries
`// swiftlint:disable file_length` — keep additions within the other rules).

- [ ] Offline eval sanity:

```bash
swift run aec-eval --near Tests/Fixtures/audio/en-monologue-normal.wav --far Tests/Fixtures/audio/far-monologue-normal.wav
```

Expected: overall ERLE positive (echo reduced); inspect per-second
convergence.

- [ ] **VM real-call check** (per project testing discipline — only after the
  above are green): build the app, run a `.call` session on **built-in
  speakers** in the Tart VM with `UNISON_DUMP_SENT_WAV=/tmp/sent.wav`, have
  the peer speak, and confirm `/tmp/sent.wav` no longer contains the
  re-captured translation (compare against a pre-change capture). This is
  the in-the-wild ERLE confirmation the unit tests + offline eval can't give.

---

## Self-Review notes (for the executor)

- **Spec coverage:** ring + reblocker (Task 1–2), protocols (Task 3),
  vendored Speex (Task 4), canceller (Task 5), mainMixer tap + teardown
  ordering (Task 6), orchestrator `processNear`/register/clear + mode gating
  (Task 7), Composition singleton (Task 8), eval harness + ERLE (Task 9),
  fixtures (Task 10), docs (Task 11). Non-goals (no toggle, no AEC3, no NS,
  no virtual-mic tap) are respected — none are implemented.
- **Type consistency:** `EchoCanceller.processNear/reset`,
  `EchoReferenceSink.pushFarReference`, `AudioOutputMixer.setEchoReference`,
  `FarReferenceRing.write/read/clear`, `Int16Reblocker.push/reset/pending`,
  `SpeexEchoCanceller.Config.{frameSize,filterLength}`,
  `EchoMetrics.erleDB(reference:residual:)`,
  `AVAudioOutputMixer.echoFrame(from:)` — names are used identically across
  tasks.
- **Open risk carried from the spec:** mic/output clock drift over long
  sessions. The VM check + `aec-eval` on a long fixture are where it would
  surface; mitigation (consumer-side ring trim / AEC3 delay estimator) is
  out of scope for v1 and noted in the spec's Risks section.
```
