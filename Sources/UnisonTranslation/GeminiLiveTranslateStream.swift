import Foundation
import UnisonDomain

public actor GeminiLiveTranslateStream: TranslationStream {
    private static let log = UnisonLog(category: "GeminiLiveTranslateStream")
    private static let base =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    private let apiKey: String
    private let client: any WSClient
    private let clock: any Clock
    private let speaker: Speaker

    public nonisolated let transcripts: AsyncStream<TranscriptDelta>
    public nonisolated let output: AsyncStream<AudioFrame>
    public nonisolated let connectionState: AsyncStream<ConnectionState>
    private nonisolated let transcriptContinuation: AsyncStream<TranscriptDelta>.Continuation
    private nonisolated let outputContinuation: AsyncStream<AudioFrame>.Continuation
    private nonisolated let connectionContinuation: AsyncStream<ConnectionState>.Continuation

    // Gemini expects 16 kHz input (output is 24 kHz like OpenAI).
    public nonisolated var inputWireSampleRate: Int { 16_000 }

    private var receiveTask: Task<Void, Never>?
    private var closeReasonTask: Task<Void, Never>?
    private var currentEntryId = UUID()
    private var lastInputDeltaAt: Date?
    /// Wall-clock of the previous audio chunk from the model — for the
    /// arrival-gap diagnostic (distinguishes model/network gaps from our
    /// playback pipeline as the source of audible micropauses).
    private var lastAudioAt: Date?
    private static let turnGapSeconds: TimeInterval = 5.0
    private var receivedAnyData = false
    private var closeStarted = false

    public init(apiKey: String, client: any WSClient, clock: any Clock, speaker: Speaker = .peer) {
        self.apiKey = apiKey
        self.client = client
        self.clock = clock
        self.speaker = speaker
        var tc: AsyncStream<TranscriptDelta>.Continuation!
        var oc: AsyncStream<AudioFrame>.Continuation!
        var cc: AsyncStream<ConnectionState>.Continuation!
        self.transcripts = AsyncStream { tc = $0 }
        self.output = AsyncStream { oc = $0 }
        self.connectionState = AsyncStream { cc = $0 }
        self.transcriptContinuation = tc
        self.outputContinuation = oc
        self.connectionContinuation = cc
    }

    public func connect(target: Language) async throws {
        connectionContinuation.yield(.connecting)
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: allowed) ?? apiKey
        guard let url = URL(string: "\(Self.base)?key=\(encodedKey)") else {
            throw TranslationError.networkLost
        }
        try await client.connect(url: url, headers: [:])
        connectionContinuation.yield(.connected)

        let stream = client.receive()
        receiveTask = Task { [weak self] in
            for await msg in stream { await self?.handle(message: msg) }
        }
        let closeSource = client.closeStream()
        closeReasonTask = Task { [weak self] in
            for await reason in closeSource { await self?.handleClose(reason: reason) }
        }

        let evt = GeminiClientEvent.setup(.init(targetLanguage: target.rawValue))
        let data = try JSONEncoder().encode(evt)
        try await client.send(.text(String(data: data, encoding: .utf8) ?? ""))
    }

    public func send(_ frame: AudioFrame) async {
        let evt = GeminiClientEvent.realtimeAudio(base64: frame.pcm.base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(evt),
              let str = String(data: data, encoding: .utf8) else { return }
        try? await client.send(.text(str))
    }

    public func close() async {
        guard !closeStarted else { return }
        closeStarted = true
        receiveTask?.cancel()
        closeReasonTask?.cancel()
        await client.close()
        connectionContinuation.yield(.disconnected)
        transcriptContinuation.finish()
        outputContinuation.finish()
        connectionContinuation.finish()
    }

    private func rotateOnInputGap() {
        let now = clock.now()
        if let prev = lastInputDeltaAt, now.timeIntervalSince(prev) >= Self.turnGapSeconds {
            currentEntryId = UUID()
        }
        lastInputDeltaAt = now
    }

    private func handle(message: WSMessage) async {
        // Gemini delivers serverContent as BINARY WebSocket frames (unlike
        // OpenAI's text frames), so accept both.
        let data: Data
        switch message {
        case .text(let str): data = Data(str.utf8)
        case .data(let d): data = d
        }
        guard let event = try? JSONDecoder().decode(GeminiServerEvent.self, from: data) else { return }
        switch event {
        case .setupComplete:
            break
        case .audio(let b64):
            guard let pcm = Data(base64Encoded: b64) else { return }
            let nowAt = clock.now()
            let gapMs = lastAudioAt.map { nowAt.timeIntervalSince($0) * 1000 } ?? 0
            lastAudioAt = nowAt
            Self.log.debug("[audio-rx \(speaker)] +\(Int(gapMs))ms gap, \(pcm.count)B (~\(pcm.count / 48)ms audio)")
            receivedAnyData = true
            outputContinuation.yield(AudioFrame(pcm: pcm, sampleRate: 24_000, channels: 1, format: .int16))
        case .inputTranscript(let text):
            rotateOnInputGap()
            receivedAnyData = true
            transcriptContinuation.yield(TranscriptDelta(
                entryId: currentEntryId, speaker: speaker, kind: .original, text: text, isFinal: false))
        case .outputTranscript(let text):
            receivedAnyData = true
            transcriptContinuation.yield(TranscriptDelta(
                entryId: currentEntryId, speaker: speaker, kind: .translated, text: text, isFinal: false))
        case .turnComplete:
            // Turn boundary — the model finished a turn and pauses until it
            // decides the next turn started (governed by the VAD
            // `silenceDurationMs`). Logged so a big `[audio-rx]` gap can be
            // attributed to a turn boundary (VAD wait) vs. a mid-turn stall.
            let sinceAudio = lastAudioAt.map { Int(clock.now().timeIntervalSince($0) * 1000) }
            Self.log.debug("[turn \(speaker)] turnComplete (\(sinceAudio.map { "\($0)ms since last audio" } ?? "no audio yet"))")
            currentEntryId = UUID()
            lastInputDeltaAt = nil
        case .goAway:
            Self.log.info("\(String(describing: speaker)) goAway — server will close soon")
        case .unknown:
            break
        }
    }

    private func handleClose(reason: WSCloseReason) {
        let receivedData = receivedAnyData
        switch reason {
        case .normal:
            if receivedData {
                connectionContinuation.yield(.disconnected)
            } else {
                connectionContinuation.yield(.failed(.apiKeyInvalid, receivedAnyData: false))
            }
        case .abnormal(let code, let reasonText):
            let mapped = Self.classifyClose(code: code, reason: reasonText, receivedData: receivedData)
            connectionContinuation.yield(.failed(mapped, receivedAnyData: receivedData))
        case .error:
            connectionContinuation.yield(.failed(.networkLost, receivedAnyData: receivedData))
        }
    }

    /// Map a WS close code / reason to a TranslationError. Gemini puts
    /// HTTP-style auth failures (401/403) into the close payload; quota → 429.
    /// Pre-data close ⇒ auth (handshake ok, then dropped).
    static func classifyClose(code: Int, reason: String?, receivedData: Bool) -> TranslationError {
        if let r = reason?.lowercased(), !r.isEmpty {
            if r.contains("api key") || r.contains("api_key") || r.contains("unauthenticated")
                || r.contains("permission") || r.contains("401") || r.contains("403") {
                return .apiKeyInvalid
            }
            if r.contains("quota") || r.contains("resource_exhausted") || r.contains("billing") {
                return .insufficientCredits
            }
            if r.contains("rate") || r.contains("429") { return .rateLimited(retryAfter: 5) }
        }
        switch code {
        case 1008: return .apiKeyInvalid
        case 1011: return receivedData ? .networkLost : .apiKeyInvalid
        default:   return .networkLost
        }
    }
}
