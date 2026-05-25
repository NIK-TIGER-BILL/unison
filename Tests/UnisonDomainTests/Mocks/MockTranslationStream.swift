import Foundation
@testable import UnisonDomain

public final class MockTranslationStream: TranslationStream, @unchecked Sendable {
    public let speaker: Speaker
    public var connectedTo: Language?
    public var sentFrames: [AudioFrame] = []
    public var closeCalls = 0
    /// If set, `connect(...)` throws this error instead of succeeding.
    /// Used by tests that need to keep the orchestrator in
    /// `.reconnecting` across the retry loop (e.g. watchdog tests).
    public var connectError: Error?

    private var transcriptContinuation: AsyncStream<TranscriptDelta>.Continuation?
    private var outputContinuation: AsyncStream<AudioFrame>.Continuation?
    private var connectionContinuation: AsyncStream<ConnectionState>.Continuation?

    public let transcripts: AsyncStream<TranscriptDelta>
    public let output: AsyncStream<AudioFrame>
    public let connectionState: AsyncStream<ConnectionState>

    public init(speaker: Speaker = .peer) {
        self.speaker = speaker
        var tc: AsyncStream<TranscriptDelta>.Continuation!
        var oc: AsyncStream<AudioFrame>.Continuation!
        var cc: AsyncStream<ConnectionState>.Continuation!
        transcripts = AsyncStream { tc = $0 }
        output = AsyncStream { oc = $0 }
        connectionState = AsyncStream { cc = $0 }
        transcriptContinuation = tc
        outputContinuation = oc
        connectionContinuation = cc
    }

    public func connect(target: Language) async throws {
        if let err = connectError { throw err }
        connectedTo = target
        connectionContinuation?.yield(.connected)
    }
    public func send(_ frame: AudioFrame) async { sentFrames.append(frame) }
    public func close() async {
        closeCalls += 1
        connectionContinuation?.yield(.disconnected)
        transcriptContinuation?.finish()
        outputContinuation?.finish()
        connectionContinuation?.finish()
    }

    public func emitTranscript(_ d: TranscriptDelta) { transcriptContinuation?.yield(d) }
    public func emitOutput(_ f: AudioFrame) { outputContinuation?.yield(f) }
    public func emitConnectionState(_ s: ConnectionState) { connectionContinuation?.yield(s) }
}

public final class MockTranslationStreamFactory: TranslationStreamFactory, @unchecked Sendable {
    public var streams: [Speaker: MockTranslationStream] = [:]
    /// If non-nil, every stream produced after `make(...)` will throw
    /// `nextConnectError` from `connect()`. Set this before triggering
    /// the reconnect path to keep the orchestrator stuck in the retry
    /// loop (useful for watchdog tests).
    public var nextConnectError: Error?
    public init() {}
    public func make(speaker: Speaker) -> any TranslationStream {
        let s = MockTranslationStream(speaker: speaker)
        s.connectError = nextConnectError
        streams[speaker] = s
        return s
    }
}
