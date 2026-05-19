public enum ConnectionState: Sendable, Equatable {
    case disconnected, connecting, connected, reconnecting, failed(TranslationError)
}

public protocol TranslationStream: Sendable {
    var transcripts: AsyncStream<TranscriptDelta> { get }
    var output: AsyncStream<AudioFrame> { get }
    var connectionState: AsyncStream<ConnectionState> { get }

    func connect(target: Language) async throws
    func send(_ frame: AudioFrame) async
    func close() async
}

public protocol TranslationStreamFactory: Sendable {
    func make(speaker: Speaker) -> any TranslationStream
}
