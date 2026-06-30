import Foundation
import Synchronization
import CSpeexDSP
import UnisonDomain

/// `EchoCanceller` backed by SpeexDSP's MDF acoustic echo canceller.
///
/// Works internally at 48 kHz F32 mono. Real devices are NOT 48 kHz (a
/// built-in or BT-HFP mic is often 16 kHz; the output device is commonly
/// 44.1 kHz), so both inputs are resampled to 48 kHz before Speex sees them
/// — otherwise a frame mislabeled 48 kHz makes the downstream wire
/// conversion resample from the wrong rate (sped-up / pitch-shifted audio)
/// and Speex can't align the echo. Speex int16 internally.
///
/// Two-thread contract: `pushFarReference` runs on the render thread and
/// only writes the far samples (at their native rate) into the lock-free
/// `FarReferenceRing`; `processNear` runs on the mic task, owns the Speex
/// state, and does the (off-RT) resampling of both near and far to 48 kHz.
/// `reset` is guarded so a session restart can't race an in-flight
/// `processNear`.
public final class SpeexEchoCanceller: EchoCanceller, @unchecked Sendable {
    private static let log = UnisonLog(category: "AEC")

    public struct Config: Sendable {
        public let sampleRate: Int32
        public let frameSize: Int       // samples per speex_echo_cancellation (@ 48 kHz)
        public let filterLength: Int    // echo tail in samples (~100 ms @ 48 kHz)
        public let ringCapacity: Int
        public static let `default` = Config(
            sampleRate: 48_000, frameSize: 480, filterLength: 4_800,
            ringCapacity: 1 << 15)
    }

    private let config: Config
    private let echoState: OpaquePointer
    /// Holds far samples at their NATIVE rate (whatever the output device
    /// runs at); `processNear` resamples them to 48 kHz on the mic thread.
    private let farRing: FarReferenceRing
    private var nearReblocker: Int16Reblocker
    private var farReblocker: Int16Reblocker
    /// Output-device sample rate of the far reference, published by the
    /// render thread (`pushFarReference`) and read by the mic thread.
    private let farNativeRate = Atomic<Int>(48_000)
    /// Mic-thread-only (under `stateLock`): fractional accumulator so the
    /// per-frame "native far samples to consume" has no rounding drift.
    private var farReadAccum: Double = 0
    /// Guards `echoState` + the reblockers + `farReadAccum` between
    /// `processNear` (mic task) and `reset`. The render thread never touches
    /// them — it only writes the ring — so this lock is off the RT path.
    private let stateLock = NSLock()
    /// Render-thread-only scratch for F32→int16 conversion. Single producer,
    /// so no synchronization needed.
    private var farScratch: [Int16]
    /// Far-reference loss counters — observability for the render/mic
    /// clock-drift risk flagged as the AEC design's #1 open question. A
    /// *constant* lead/lag is harmless (Speex's adaptive filter absorbs a
    /// fixed delay within its tail); *growing* counters mean the reference
    /// is mis-paced and cancellation is silently degrading. `farDropped`
    /// (render thread) counts samples dropped on ring overflow; `farUnderrun`
    /// (mic thread) counts samples zero-filled when no reference was queued.
    private let farDroppedSamples = Atomic<Int>(0)
    private let farUnderrunSamples = Atomic<Int>(0)
    /// Read-only diagnostic snapshots (also logged internally when growing).
    public var droppedFarSamples: Int { farDroppedSamples.load(ordering: .relaxed) }
    public var underrunFarSamples: Int { farUnderrunSamples.load(ordering: .relaxed) }
    /// Mic-thread-only (touched under `stateLock`): log-cadence counter +
    /// last-logged loss total, so we emit a diagnostic only when far-loss
    /// actually grows rather than every check.
    private var processCallCount = 0
    private var lastLoggedFarLoss = 0

    public init(config: Config = .default) {
        precondition(config.frameSize > 0, "frameSize must be positive")
        precondition(config.filterLength % config.frameSize == 0,
                     "filterLength must be a multiple of frameSize for the MDF block decomposition")
        self.config = config
        self.echoState = speex_echo_state_init(Int32(config.frameSize),
                                               Int32(config.filterLength))
        self.farRing = FarReferenceRing(capacity: config.ringCapacity)
        self.nearReblocker = Int16Reblocker(blockSize: config.frameSize)
        self.farReblocker = Int16Reblocker(blockSize: config.frameSize)
        self.farScratch = [Int16](repeating: 0, count: 8192)
        var rate = config.sampleRate
        speex_echo_ctl(echoState, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
    }

    deinit { speex_echo_state_destroy(echoState) }

    // MARK: EchoReferenceSink (render thread)

    public func pushFarReference(_ frame: AudioFrame) {
        guard frame.format == .float32 else { return }
        // Publish the far's native rate so the mic thread knows how to
        // resample it. The ring carries native-rate samples — resampling
        // here would mean an AVAudioConverter on the render thread.
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

    /// Echo-cancel one mic frame. The input is resampled to 48 kHz mono
    /// first (device mics are rarely 48 kHz), so the returned frame is
    /// 48 kHz with the SAME duration as the input. Because the near path is
    /// reblocked to `frameSize`, the returned frame may have **0 samples**
    /// when the input only adds to the pending remainder — callers must
    /// tolerate an empty (but valid) frame rather than treating it as
    /// end-of-stream.
    public func processNear(_ frame: AudioFrame) -> AudioFrame {
        // Near → 48 kHz F32 mono (proper resample, off the RT path). Without
        // this a non-48k mic is mislabeled 48k and `toWire` resamples from the
        // wrong rate → sped-up / pitch-shifted audio to the backend.
        let near48 = Resampler.resampleToMonoF32(frame, targetSampleRate: 48_000)
        let nearInt16 = Self.int16Samples(near48)
        let m = nearInt16.count

        stateLock.lock()
        defer { stateLock.unlock() }

        let farInt16 = pullFar48(matchingNearSamples: m)

        var out = [Int16]()
        out.reserveCapacity(m)
        var outBlock = [Int16](repeating: 0, count: config.frameSize)
        let nearBlocks = nearReblocker.push(nearInt16)
        let farBlocks = farReblocker.push(farInt16)
        // near and far are pushed in equal-length arrays every call, so the
        // reblockers stay length-synced; `min` is belt-and-braces.
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
                          sampleRate: 48_000, channels: 1, format: .float32)
    }

    /// Pull `m` samples of far reference at 48 kHz, aligned with the near
    /// frame. The ring holds far at the output device's native rate; we
    /// consume a proportional number of native samples and resample them.
    /// Zero-fills (and counts) any ring underrun.
    private func pullFar48(matchingNearSamples m: Int) -> [Int16] {
        guard m > 0 else { return [] }
        let farRate = farNativeRate.load(ordering: .relaxed)
        if farRate == 48_000 {
            return readFarFromRing(count: m)
        }
        // Fractional accumulator avoids rounding drift across calls.
        farReadAccum += Double(m) * Double(farRate) / 48_000.0
        let nativeNeeded = Int(farReadAccum)
        farReadAccum -= Double(nativeNeeded)
        guard nativeNeeded > 0 else { return [Int16](repeating: 0, count: m) }
        let nativeFar = readFarFromRing(count: nativeNeeded)
        let nativeFrame = AudioFrame(pcm: Self.data(fromInt16: nativeFar),
                                     sampleRate: farRate, channels: 1, format: .int16)
        let far48 = Resampler.resampleToMonoF32(nativeFrame, targetSampleRate: 48_000)
        return Self.int16Samples(far48, padOrTruncateTo: m)
    }

    private func readFarFromRing(count: Int) -> [Int16] {
        guard count > 0 else { return [] }
        var buf = [Int16](repeating: 0, count: count)
        let got = buf.withUnsafeMutableBufferPointer { farRing.read(into: $0) }
        if got < count {
            _ = farUnderrunSamples.wrappingAdd(count - got, ordering: .relaxed)
            // tail already zero-filled by the `repeating: 0` init
        }
        return buf
    }

    private func logFarLossIfGrowing() {
        // Drift observability (spec open-question #1): emit only when the
        // cumulative far-loss grows, throttled to every 500th call, so a
        // healthy session stays quiet and a render/mic clock drift shows up
        // as a growing dropped/underrun count in the diagnostic log.
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
        speex_echo_state_reset(echoState)
        farRing.clear()
        nearReblocker.reset()
        farReblocker.reset()
        farReadAccum = 0
    }

    // MARK: Conversion

    // Deliberate asymmetry: encode ×32767 (so +1.0 → Int16.max, no overflow),
    // decode ÷32768 (symmetric full-scale, output can't exceed 1.0). Sibling
    // `Resampler` decodes ÷32767; the round-trip error here is ~3e-5.
    private static func toInt16(_ f: Float) -> Int16 {
        Int16(max(-1.0, min(1.0, f)) * 32_767.0)
    }
    private static func toFloat(_ i: Int16) -> Float {
        Float(i) / 32_768.0
    }

    /// Float32 `AudioFrame` → `[Int16]`.
    private static func int16Samples(_ frame: AudioFrame) -> [Int16] {
        frame.pcm.withUnsafeBytes { raw -> [Int16] in
            let src = raw.bindMemory(to: Float.self)
            return (0..<src.count).map { toInt16(src[$0]) }
        }
    }

    private static func int16Samples(_ frame: AudioFrame, padOrTruncateTo m: Int) -> [Int16] {
        var s = int16Samples(frame)
        if s.count > m {
            s.removeLast(s.count - m)
        } else if s.count < m {
            s.append(contentsOf: repeatElement(0, count: m - s.count))
        }
        return s
    }

    private static func data(fromInt16 s: [Int16]) -> Data {
        s.withUnsafeBufferPointer { Data(buffer: $0) }
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
