public enum ConnectionState: Sendable, Equatable {
    case disconnected, connecting, connected, reconnecting
    /// Stream failed with `error`. `receivedAnyData` is `true` when the
    /// server delivered at least one translated chunk (audio or
    /// transcript) before failing — used by the orchestrator to
    /// distinguish a transient mid-session drop from an immediate
    /// post-handshake close. Two consecutive empty closes on the same
    /// speaker is the strongest signal of bad credentials or a
    /// disabled account, so the orchestrator stops retrying.
    case failed(TranslationError, receivedAnyData: Bool = false)
}

public protocol TranslationStream: Sendable {
    var transcripts: AsyncStream<TranscriptDelta> { get }
    var output: AsyncStream<AudioFrame> { get }
    var connectionState: AsyncStream<ConnectionState> { get }

    /// PCM sample rate the engine expects in `send(_:)`. Default 24 kHz
    /// (OpenAI). Gemini overrides to 16 kHz.
    var inputWireSampleRate: Int { get }

    func connect(target: Language) async throws
    func send(_ frame: AudioFrame) async
    func close() async
}

public extension TranslationStream {
    // Conformers that expect a non-24 kHz input wire (e.g. Gemini 16 kHz) MUST override.
    var inputWireSampleRate: Int { 24_000 }
}

public protocol TranslationStreamFactory: Sendable {
    func make(speaker: Speaker) -> any TranslationStream
}
