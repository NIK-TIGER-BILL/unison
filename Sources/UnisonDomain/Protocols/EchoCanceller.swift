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
    /// Mono float32 in at the mic's native rate → mono float32 out at that
    /// SAME rate, with the echo of the far reference removed. May return a
    /// 0-sample frame (the internal reblocking remainder); callers must
    /// tolerate it. (Do NOT assume a fixed rate — a literal 48 kHz contract is
    /// exactly the mislabel that ships sped-up audio on a non-48 kHz mic.)
    func processNear(_ frame: AudioFrame) -> AudioFrame
    /// Clear adaptive state + far buffer. Called once per session start.
    func reset()
}
