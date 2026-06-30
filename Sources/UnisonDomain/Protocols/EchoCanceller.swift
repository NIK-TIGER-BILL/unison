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
