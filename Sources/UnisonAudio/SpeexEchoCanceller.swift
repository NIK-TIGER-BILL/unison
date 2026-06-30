import Foundation
import Synchronization
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
    private static let log = UnisonLog(category: "AEC")

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

    /// Echo-cancel one mic frame. Because the near path is reblocked to
    /// `frameSize`, the returned frame may have **0 samples** when the input
    /// only adds to the pending remainder — callers must tolerate an empty
    /// (but valid) frame rather than treating it as end-of-stream.
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
            // Dequeue the next far block (FIFO). A fixed lead/lag is fine —
            // Speex's adaptive filter absorbs a constant delay within its
            // tail. Underrun (consumer ahead of producer) zero-fills, so the
            // block is cancelled against silence (a no-op) and counted.
            let got = farBlock.withUnsafeMutableBufferPointer { farRing.read(into: $0) }
            if got < config.frameSize {
                _ = farUnderrunSamples.wrappingAdd(config.frameSize - got, ordering: .relaxed)
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

        // Drift observability (spec open-question #1): emit only when the
        // cumulative far-loss grows, throttled to every 500th call, so a
        // healthy session stays quiet and a render/mic clock drift shows up
        // as a growing dropped/underrun count in the diagnostic log.
        processCallCount += 1
        if processCallCount % 500 == 0 {
            let dropped = farDroppedSamples.load(ordering: .relaxed)
            let underrun = farUnderrunSamples.load(ordering: .relaxed)
            if dropped + underrun > lastLoggedFarLoss {
                Self.log.debug("far-reference loss growing — dropped=\(dropped) underrun=\(underrun) samples (render/mic drift?)")
                lastLoggedFarLoss = dropped + underrun
            }
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

    // Deliberate asymmetry: encode ×32767 (so +1.0 → Int16.max, no overflow),
    // decode ÷32768 (symmetric full-scale, output can't exceed 1.0). Sibling
    // `Resampler` decodes ÷32767; the round-trip error here is ~3e-5.
    private static func toInt16(_ f: Float) -> Int16 {
        Int16(max(-1.0, min(1.0, f)) * 32_767.0)
    }
    private static func toFloat(_ i: Int16) -> Float {
        Float(i) / 32_768.0
    }
}
