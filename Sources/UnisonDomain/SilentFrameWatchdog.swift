import Foundation

/// Detects prolonged all-zero amplitude on the peer audio stream and
/// fires a callback so the orchestrator can flip state to `.error`.
///
/// Production safety net for the case where macOS Process Tap delivers
/// silent buffers due to a TCC audio-capture denial — the call to
/// `AudioHardwareCreateProcessTap` itself succeeds, but the IOProc's
/// samples are all zero. We can't query TCC state from public API, so
/// observing the data is the only reliable detection.
public final class SilentFrameWatchdog: @unchecked Sendable {
    private let thresholdSeconds: TimeInterval
    private let onTriggered: @Sendable () -> Void
    private let queue = DispatchQueue(label: "unison.silent-frame-watchdog")
    private var firstSilentAt: Date?
    private var triggered = false
    private var running = false

    public init(thresholdSeconds: TimeInterval = 10,
                onTriggered: @escaping @Sendable () -> Void) {
        self.thresholdSeconds = thresholdSeconds
        self.onTriggered = onTriggered
    }

    public func start() {
        queue.sync {
            running = true
            triggered = false
            firstSilentAt = nil
        }
    }

    public func stop() {
        queue.sync {
            running = false
            firstSilentAt = nil
        }
    }

    /// Observe a chunk of PCM Float32 samples (the AudioFrame's `pcm`).
    /// Non-zero amplitude resets the silence timer; all-zero accumulates
    /// elapsed silence and triggers the callback once the threshold is
    /// crossed.
    public func observe(_ pcm: Data) {
        queue.sync {
            guard running, !triggered else { return }
            let isAllZero = pcmIsAllZero(pcm)
            let now = Date()
            if isAllZero {
                if firstSilentAt == nil { firstSilentAt = now }
                if let start = firstSilentAt,
                   now.timeIntervalSince(start) >= thresholdSeconds {
                    triggered = true
                    onTriggered()
                }
            } else {
                firstSilentAt = nil
            }
        }
    }

    private func pcmIsAllZero(_ data: Data) -> Bool {
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: Float.self).baseAddress else { return true }
            let count = data.count / MemoryLayout<Float>.size
            for i in 0..<count where base[i] != 0 {
                return false
            }
            return true
        }
    }
}
