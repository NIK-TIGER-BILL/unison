import Foundation
import UnisonDomain

/// Bridge between the domain `AudioFormatTransformer` protocol and the
/// concrete `Resampler` helpers in this module.
///
/// Logs the first conversion in each direction so the diagnostic dump
/// can confirm the pipeline really is converting `Int16 @ 24kHz ↔
/// Float32 @ 48kHz` (the silent-no-audio bug class is "wire format
/// reached `BlackHole2chPlayer.schedule` unconverted and was dropped
/// by the `.float32` guard"). The per-frame hot path stays log-free —
/// `loggedX` flags latch on first crossing.
public final class ResamplerAdapter: AudioFormatTransformer, @unchecked Sendable {
    private static let log = UnisonLog(category: "Resampler")
    private let lock = NSLock()
    private var loggedToWire = false
    private var loggedFromWire = false

    public init() {}

    public func toWire(_ frame: AudioFrame, sampleRate: Int) -> AudioFrame {
        let out = Resampler.toWire(frame, targetSampleRate: sampleRate)
        lock.lock(); let shouldLog = !loggedToWire; if shouldLog { loggedToWire = true }; lock.unlock()
        if shouldLog {
            Self.log.info("toWire — first call: in=\(frame.sampleRate)Hz \(String(describing: frame.format)) → out=\(out.sampleRate)Hz \(String(describing: out.format))")
        }
        return out
    }

    public func fromWire(_ frame: AudioFrame, targetSampleRate: Int) -> AudioFrame {
        let out = Resampler.fromWire(frame, targetSampleRate: targetSampleRate)
        lock.lock(); let shouldLog = !loggedFromWire; if shouldLog { loggedFromWire = true }; lock.unlock()
        if shouldLog {
            Self.log.info("fromWire — first call: in=\(frame.sampleRate)Hz \(String(describing: frame.format)) → out=\(out.sampleRate)Hz \(String(describing: out.format))")
        }
        return out
    }
}
