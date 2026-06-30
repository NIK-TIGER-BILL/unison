import Foundation
import Synchronization
import CSpeexDSP
import UnisonDomain

/// `EchoCanceller` backed by SpeexDSP's MDF acoustic echo canceller.
///
/// **Runs at the microphone's native rate.** Real devices are rarely 48 kHz
/// (a built-in or BT-HFP mic is often 16 kHz; the output device is commonly
/// 44.1 kHz). Two things must hold for the canceller to both not corrupt the
/// outgoing audio AND actually cancel:
///   1. The near (mic) signal is left at its native rate and the cleaned frame
///      is tagged with THAT rate, so the downstream wire conversion resamples
///      from the correct rate (a mislabel = sped-up / pitch-shifted audio).
///   2. The far (speaker) reference is resampled DOWN to the mic rate. This
///      band-limits it to the mic's bandwidth — crucial: if far carried energy
///      above the mic's Nyquist (e.g. a 48 kHz far vs a 16 kHz mic), that
///      out-of-band energy has no near counterpart and dilutes Speex's
///      adaptive normalization, collapsing cancellation to ~0 dB. Measured:
///      band-limited far → ~34 dB, full-band far → ~0 dB at 16 k/44.1 k.
///
/// The Speex state is (re)created for the current mic rate (`frameSize` =
/// `frameMs` of it; `filterLength` = `tailMs`). A stateful `StreamingResampler`
/// brings the far from its device rate to the mic rate (LTI; a per-chunk-reset
/// resampler injects boundary transients that also defeat cancellation).
///
/// Two-thread contract: `pushFarReference` runs on the render thread and only
/// writes far samples (at their native rate) into the lock-free
/// `FarReferenceRing`; `processNear` runs on the mic task, owns the Speex
/// state, and does all (off-RT) resampling. `reset` is guarded.
public final class SpeexEchoCanceller: EchoCanceller, @unchecked Sendable {
    private static let log = UnisonLog(category: "AEC")

    public struct Config: Sendable {
        public let frameMs: Int     // Speex frame = this many ms of the mic rate (10)
        public let tailMs: Int      // echo tail length in ms (100); multiple of frameMs
        public let ringCapacity: Int
        public static let `default` = Config(frameMs: 10, tailMs: 100, ringCapacity: 1 << 15)
    }

    private let config: Config
    private var echoState: OpaquePointer?   // created for `currentRate`
    private var currentRate = 0             // mic rate Speex is configured for (0 = none)
    private var frameSize = 0               // samples per speex_echo_cancellation @ currentRate
    private let farRing: FarReferenceRing
    private var nearReblocker = Int16Reblocker(blockSize: 1)   // re-created per rate
    private var farReblocker = Int16Reblocker(blockSize: 1)
    /// Far→mic-rate resampler (LTI), created lazily / recreated on rate change.
    private var farResampler: StreamingResampler?
    /// Far samples (at the MIC rate) produced ahead of the matching near;
    /// carried so far stays continuous and aligned without lossy truncation.
    private var farCarry: [Int16] = []
    /// Native output-device rate of the far reference (0 until first push).
    private let farNativeRate = Atomic<Int>(0)
    /// Mic-thread-only: fractional accumulator so the per-frame native-far
    /// consumption has no rounding drift.
    private var farReadAccum: Double = 0
    private let stateLock = NSLock()
    /// Render-thread-only scratch for F32→int16 conversion.
    private var farScratch: [Int16]
    /// Far-reference loss counters — observability for the render/mic clock-
    /// drift open question. Growing = the reference is mis-paced.
    private let farDroppedSamples = Atomic<Int>(0)
    private let farUnderrunSamples = Atomic<Int>(0)
    public var droppedFarSamples: Int { farDroppedSamples.load(ordering: .relaxed) }
    public var underrunFarSamples: Int { farUnderrunSamples.load(ordering: .relaxed) }
    private var processCallCount = 0
    private var lastLoggedFarLoss = 0

    public init(config: Config = .default) {
        precondition(config.frameMs > 0, "frameMs must be positive")
        precondition(config.tailMs % config.frameMs == 0,
                     "tailMs must be a multiple of frameMs for the MDF block decomposition")
        self.config = config
        self.farRing = FarReferenceRing(capacity: config.ringCapacity)
        self.farScratch = [Int16](repeating: 0, count: 8192)
    }

    deinit { if let echoState { speex_echo_state_destroy(echoState) } }

    // MARK: EchoReferenceSink (render thread)

    public func pushFarReference(_ frame: AudioFrame) {
        guard frame.format == .float32 else { return }
        farNativeRate.store(frame.sampleRate, ordering: .relaxed)
        frame.pcm.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Float.self)
            var i = 0
            while i < src.count {
                let chunk = min(farScratch.count, src.count - i)
                for j in 0..<chunk { farScratch[j] = Self.toInt16(src[i + j]) }
                let written = farScratch.withUnsafeBufferPointer {
                    farRing.write(UnsafeBufferPointer(start: $0.baseAddress, count: chunk))
                }
                if written < chunk {
                    _ = farDroppedSamples.wrappingAdd(chunk - written, ordering: .relaxed)
                }
                i += chunk
            }
        }
    }

    // MARK: EchoCanceller (mic task)

    /// Echo-cancel one mic frame. Output is at the **mic's rate** with the same
    /// duration as the input. Because the path is reblocked to `frameSize`, the
    /// returned frame may have **0 samples** when the input only adds to the
    /// pending remainder — callers must tolerate an empty (but valid) frame.
    public func processNear(_ frame: AudioFrame) -> AudioFrame {
        let micRate = frame.sampleRate
        // Normalize to mono F32 at the native rate (handles int16 / multi-
        // channel mics). No resampling of the near/voice signal.
        let nearMono = Self.floats(Resampler.resampleToMonoF32(frame, targetSampleRate: micRate))

        stateLock.lock()
        defer { stateLock.unlock() }

        guard micRate > 0, configureForRate(micRate), let echoState else {
            return AudioFrame(pcm: Data(), sampleRate: micRate, channels: 1, format: .float32)
        }

        let nearInt16 = nearMono.map { Self.toInt16($0) }
        let m = nearInt16.count
        let farInt16 = pullFar(matchingNear: m, micRate: micRate)

        var out = [Int16]()
        out.reserveCapacity(m)
        var outBlock = [Int16](repeating: 0, count: frameSize)
        let nearBlocks = nearReblocker.push(nearInt16)
        let farBlocks = farReblocker.push(farInt16)
        for k in 0..<min(nearBlocks.count, farBlocks.count) {
            nearBlocks[k].withUnsafeBufferPointer { near in
                farBlocks[k].withUnsafeBufferPointer { far in
                    outBlock.withUnsafeMutableBufferPointer { o in
                        speex_echo_cancellation(echoState, near.baseAddress,
                                                far.baseAddress, o.baseAddress)
                    }
                }
            }
            out.append(contentsOf: outBlock)
        }

        logFarLossIfGrowing()
        return AudioFrame(pcm: Self.f32Data(fromInt16: out),
                          sampleRate: micRate, channels: 1, format: .float32)
    }

    /// (Re)create the Speex state + reblockers for `rate` if it changed.
    /// Returns false if the Speex state couldn't be created. Caller holds the
    /// lock.
    private func configureForRate(_ rate: Int) -> Bool {
        if rate == currentRate, echoState != nil { return true }
        if let old = echoState { speex_echo_state_destroy(old); echoState = nil }
        let fSize = max(1, Int((Double(rate) * Double(config.frameMs) / 1000.0).rounded()))
        let blocksPerTail = config.tailMs / config.frameMs
        let filterLength = fSize * blocksPerTail
        guard let state = speex_echo_state_init(Int32(fSize), Int32(filterLength)) else { return false }
        var r = Int32(rate)
        speex_echo_ctl(state, SPEEX_ECHO_SET_SAMPLING_RATE, &r)
        echoState = state
        frameSize = fSize
        currentRate = rate
        nearReblocker = Int16Reblocker(blockSize: fSize)
        farReblocker = Int16Reblocker(blockSize: fSize)
        farResampler = nil
        farCarry.removeAll(keepingCapacity: true)
        farReadAccum = 0
        return true
    }

    /// Produce exactly `m` samples of far reference at the mic rate, aligned
    /// with the near frame. Far is stored at the device's native rate; we
    /// consume a proportional (drift-free) count and resample DOWN to the mic
    /// rate (band-limiting it), serving `m` from a carry buffer.
    private func pullFar(matchingNear m: Int, micRate: Int) -> [Int16] {
        guard m > 0 else { return [] }
        let stored = farNativeRate.load(ordering: .relaxed)
        let farRate = stored == 0 ? micRate : stored   // no far yet → count underruns at mic rate
        let nativeNeeded: Int
        if farRate == micRate {
            nativeNeeded = m
        } else {
            farReadAccum += Double(m) * Double(farRate) / Double(micRate)
            nativeNeeded = Int(farReadAccum)
            farReadAccum -= Double(nativeNeeded)
        }
        if nativeNeeded > 0 {
            let nativeFar = readFarFromRing(count: nativeNeeded)   // zero-filled + counted on underrun
            let atMic = resampleFar(nativeFar.map { Self.toFloat($0) }, srcRate: farRate, dstRate: micRate)
            farCarry.append(contentsOf: atMic.map { Self.toInt16($0) })
        }
        let take = min(m, farCarry.count)
        var block = Array(farCarry[0..<take])
        if take > 0 { farCarry.removeFirst(take) }
        if take < m { block.append(contentsOf: repeatElement(0, count: m - take)) }
        return block
    }

    private func resampleFar(_ x: [Float], srcRate: Int, dstRate: Int) -> [Float] {
        if srcRate == dstRate { return x }
        if farResampler?.srcRate != srcRate || farResampler?.dstRate != dstRate {
            farResampler = StreamingResampler(srcRate: srcRate, dstRate: dstRate)
        }
        return farResampler?.resample(x) ?? x
    }

    private func readFarFromRing(count: Int) -> [Int16] {
        guard count > 0 else { return [] }
        var buf = [Int16](repeating: 0, count: count)
        let got = buf.withUnsafeMutableBufferPointer { farRing.read(into: $0) }
        if got < count {
            _ = farUnderrunSamples.wrappingAdd(count - got, ordering: .relaxed)
        }
        return buf
    }

    private func logFarLossIfGrowing() {
        processCallCount += 1
        guard processCallCount % 500 == 0 else { return }
        let dropped = farDroppedSamples.load(ordering: .relaxed)
        let underrun = farUnderrunSamples.load(ordering: .relaxed)
        if dropped + underrun > lastLoggedFarLoss {
            Self.log.debug("far-reference loss growing — dropped=\(dropped) underrun=\(underrun) samples (render/mic drift?)")
            lastLoggedFarLoss = dropped + underrun
        }
    }

    public func reset() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let echoState { speex_echo_state_reset(echoState) }
        farRing.clear()
        nearReblocker.reset()
        farReblocker.reset()
        farResampler?.reset()
        farCarry.removeAll(keepingCapacity: true)
        farReadAccum = 0
    }

    // MARK: Conversion

    // Encode ×32767 (so +1.0 → Int16.max, no overflow), decode ÷32768
    // (symmetric full-scale). Round-trip error ~3e-5.
    private static func toInt16(_ f: Float) -> Int16 {
        Int16(max(-1.0, min(1.0, f)) * 32_767.0)
    }
    private static func toFloat(_ i: Int16) -> Float {
        Float(i) / 32_768.0
    }

    /// Float32 `AudioFrame` → `[Float]` (empty frame → empty array).
    private static func floats(_ frame: AudioFrame) -> [Float] {
        frame.pcm.withUnsafeBytes { raw -> [Float] in
            let p = raw.bindMemory(to: Float.self)
            guard let base = p.baseAddress, p.count > 0 else { return [] }
            return Array(UnsafeBufferPointer(start: base, count: p.count))
        }
    }

    private static func f32Data(fromInt16 s: [Int16]) -> Data {
        var d = Data(count: s.count * 4)
        d.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: Float.self)
            for i in s.indices { dst[i] = toFloat(s[i]) }
        }
        return d
    }
}
