import Foundation

/// Fixed-capacity FIFO of `AudioFrame`s with drop-oldest overflow.
///
/// Used by the orchestrator's outgoing pipeline to retain a short
/// (~3 s) window of mic audio that can be replayed onto a fresh WS
/// session after a brief flap. The buffer is cleared (and not
/// refilled) once the orchestrator enters `.paused` — beyond a
/// few-second outage, replaying stale audio creates more confusion
/// than it solves (see the design note in
/// `docs/superpowers/specs/2026-05-27-network-aware-session-design.md`).
///
/// Thread-safety: backed by `NSLock`. Append/drain/clear can be
/// called from any thread; one writer (the mic-frame pipeline task)
/// plus one reader (the reconnect flush) is the only pattern used in
/// practice.
public final class AudioRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [AudioFrame] = []
    private let maxFrames: Int

    /// `maxFrames` is in *frame count*, not samples or seconds. With
    /// the pipeline's ~100 ms-per-frame cadence, 30 frames ≈ 3 s.
    public init(maxFrames: Int) {
        self.maxFrames = maxFrames
        self.frames.reserveCapacity(maxFrames)
    }

    /// Append a new frame. If the buffer is full, the oldest frame
    /// is silently dropped — by the time we'd consider replaying
    /// audio that old, it's already too stale to be useful.
    public func append(_ frame: AudioFrame) {
        lock.lock()
        defer { lock.unlock() }
        frames.append(frame)
        if frames.count > maxFrames {
            frames.removeFirst(frames.count - maxFrames)
        }
    }

    /// Return all currently-buffered frames in FIFO order and reset
    /// the buffer. Used on stream reconnect to replay the audio that
    /// was being captured while the old WS was dying.
    public func drain() -> [AudioFrame] {
        lock.lock()
        defer { lock.unlock() }
        let out = frames
        frames.removeAll(keepingCapacity: true)
        return out
    }

    /// Discard buffered frames without returning them. Called when
    /// the orchestrator enters `.paused` — audio captured during a
    /// long outage is stale, and replaying it would land the
    /// translation after the live conversation moved on.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        frames.removeAll(keepingCapacity: true)
    }
}
