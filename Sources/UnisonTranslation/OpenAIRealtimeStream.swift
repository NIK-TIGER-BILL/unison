import Foundation
import UnisonDomain

public actor OpenAIRealtimeStream: TranslationStream {
    private let apiKey: String
    private let client: any WSClient
    private let clock: any Clock
    private let url: URL
    private let speaker: Speaker

    private var transcriptContinuation: AsyncStream<TranscriptDelta>.Continuation?
    private var outputContinuation: AsyncStream<AudioFrame>.Continuation?
    private var connectionContinuation: AsyncStream<ConnectionState>.Continuation?

    public nonisolated let transcripts: AsyncStream<TranscriptDelta>
    public nonisolated let output: AsyncStream<AudioFrame>
    public nonisolated let connectionState: AsyncStream<ConnectionState>

    private var receiveTask: Task<Void, Never>?
    private var currentEntryId = UUID()

    public init(
        apiKey: String,
        client: any WSClient,
        clock: any Clock,
        speaker: Speaker = .peer,
        url: URL = URL(string: "wss://api.openai.com/v1/realtime/translations")!
    ) {
        self.apiKey = apiKey
        self.client = client
        self.clock = clock
        self.speaker = speaker
        self.url = url

        var tc: AsyncStream<TranscriptDelta>.Continuation!
        var oc: AsyncStream<AudioFrame>.Continuation!
        var cc: AsyncStream<ConnectionState>.Continuation!
        self.transcripts = AsyncStream { tc = $0 }
        self.output = AsyncStream { oc = $0 }
        self.connectionState = AsyncStream { cc = $0 }

        Task { [weak self] in
            await self?.setContinuations(tc: tc, oc: oc, cc: cc)
        }
    }

    private func setContinuations(
        tc: AsyncStream<TranscriptDelta>.Continuation,
        oc: AsyncStream<AudioFrame>.Continuation,
        cc: AsyncStream<ConnectionState>.Continuation
    ) {
        self.transcriptContinuation = tc
        self.outputContinuation = oc
        self.connectionContinuation = cc
    }

    public func connect(target: Language) async throws {
        connectionContinuation?.yield(.connecting)
        try await client.connect(url: url, headers: [
            "Authorization": "Bearer \(apiKey)",
            "OpenAI-Beta": "realtime=v1",
        ])
        connectionContinuation?.yield(.connected)

        let stream = client.receive()
        receiveTask = Task { [weak self] in
            for await msg in stream {
                await self?.handle(message: msg)
            }
        }

        let evt = RealtimeClientEvent.sessionUpdate(.init(targetLanguage: target.rawValue))
        let data = try JSONEncoder().encode(evt)
        try await client.send(.text(String(data: data, encoding: .utf8) ?? ""))
    }

    public func send(_ frame: AudioFrame) async {
        let evt = RealtimeClientEvent.inputAudioBufferAppend(
            .init(audio: frame.pcm.base64EncodedString())
        )
        guard let data = try? JSONEncoder().encode(evt),
              let str = String(data: data, encoding: .utf8) else { return }
        try? await client.send(.text(str))
    }

    public func close() async {
        if let data = try? JSONEncoder().encode(RealtimeClientEvent.sessionClose),
           let str = String(data: data, encoding: .utf8) {
            try? await client.send(.text(str))
        }
        receiveTask?.cancel()
        await client.close()
        connectionContinuation?.yield(.disconnected)
        transcriptContinuation?.finish()
        outputContinuation?.finish()
        connectionContinuation?.finish()
    }

    private func handle(message: WSMessage) async {
        guard case .text(let str) = message,
              let data = str.data(using: .utf8),
              let event = try? JSONDecoder().decode(RealtimeServerEvent.self, from: data) else { return }
        switch event {
        case .outputAudioDelta(let p):
            guard let pcm = Data(base64Encoded: p.delta) else { return }
            let frame = AudioFrame(pcm: pcm, sampleRate: 24_000, channels: 1, format: .int16)
            outputContinuation?.yield(frame)
        case .outputTranscriptDelta(let p):
            let delta = TranscriptDelta(
                entryId: currentEntryId, speaker: speaker,
                kind: .translated, text: p.delta, isFinal: false
            )
            transcriptContinuation?.yield(delta)
        case .sessionClosed:
            connectionContinuation?.yield(.disconnected)
        case .error(let e):
            let mapped: TranslationError = {
                switch e.code {
                case "invalid_api_key", "unauthorized": return .apiKeyInvalid
                case "insufficient_quota", "insufficient_credits": return .insufficientCredits
                case "rate_limit_exceeded": return .rateLimited(retryAfter: 5)
                default: return .networkLost
                }
            }()
            connectionContinuation?.yield(.failed(mapped))
        case .unknown:
            break
        }
    }
}
