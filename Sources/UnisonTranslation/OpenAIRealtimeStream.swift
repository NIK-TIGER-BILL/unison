import Foundation
import os
import UnisonDomain

public actor OpenAIRealtimeStream: TranslationStream {
    /// `os.Logger` channel for the realtime stream. Every close-code
    /// mapping decision lands here (and in the diagnostic dump) so a
    /// user-reported "networkLost" loop can be traced back to the
    /// actual WS close code + server reason payload.
    private static let log = Logger(subsystem: "com.unison.app", category: "OpenAIRealtimeStream")

    private let apiKey: String
    private let client: any WSClient
    private let clock: any Clock
    private let url: URL
    private let speaker: Speaker

    public nonisolated let transcripts: AsyncStream<TranscriptDelta>
    public nonisolated let output: AsyncStream<AudioFrame>
    public nonisolated let connectionState: AsyncStream<ConnectionState>

    // AsyncStream.Continuation is Sendable; making these `nonisolated let`
    // means the first yield from connect() always finds a non-nil continuation
    // (no actor-hop race between init and the first caller awaiting connect()).
    private nonisolated let transcriptContinuation: AsyncStream<TranscriptDelta>.Continuation
    private nonisolated let outputContinuation: AsyncStream<AudioFrame>.Continuation
    private nonisolated let connectionContinuation: AsyncStream<ConnectionState>.Continuation

    private var receiveTask: Task<Void, Never>?
    private var closeReasonTask: Task<Void, Never>?
    private var currentEntryId = UUID()
    /// Tracks whether the server ever sent us a translated chunk before
    /// closing. A close with `.normalClosure` *before* any data is the
    /// classic OpenAI "your request was rejected on the first message"
    /// pattern (invalid key, account not enabled for realtime, etc.) —
    /// the WS handshake succeeds at TCP/TLS level, then the server
    /// closes immediately. We surface that as `.apiKeyInvalid` instead
    /// of `.networkLost`.
    ///
    /// INVARIANT: This flag is set ONLY when the server delivers an
    /// actual translation chunk — `output_audio.delta` or
    /// `output_transcript.delta`. Handshake/lifecycle events like
    /// `session.*`, `error`, or `conversation.*` MUST NOT flip it,
    /// because the orchestrator's empty-close escalation uses
    /// `receivedAnyData=false` as the signal for "server accepted us
    /// then dropped before translating a byte" — a credential/policy
    /// failure that should terminate the session quickly. If a
    /// non-data event ever toggles this, the user gets stuck in an
    /// endless `.reconnecting` flap.
    private var receivedAnyData = false

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
        self.transcriptContinuation = tc
        self.outputContinuation = oc
        self.connectionContinuation = cc
    }

    public func connect(target: Language) async throws {
        connectionContinuation.yield(.connecting)
        try await client.connect(url: url, headers: [
            "Authorization": "Bearer \(apiKey)",
            "OpenAI-Beta": "realtime=v1",
        ])
        connectionContinuation.yield(.connected)

        let stream = client.receive()
        receiveTask = Task { [weak self] in
            for await msg in stream {
                await self?.handle(message: msg)
            }
        }

        let closeSource = client.closeStream()
        closeReasonTask = Task { [weak self] in
            for await reason in closeSource {
                await self?.handleClose(reason: reason)
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
        closeReasonTask?.cancel()
        await client.close()
        connectionContinuation.yield(.disconnected)
        transcriptContinuation.finish()
        outputContinuation.finish()
        connectionContinuation.finish()
    }

    /// Mirror the close-code/reason payload to the diagnostic logger
    /// **before** picking a `TranslationError`. The mapping decision lives
    /// in `Self.classifyClose(...)` so it can be unit-tested without an
    /// actor.
    private func handleClose(reason: WSCloseReason) {
        let speakerLabel = String(describing: speaker)
        let receivedData = receivedAnyData
        switch reason {
        case .normal:
            // A "normal" close *after* receiving data is a clean shutdown
            // (e.g. server-initiated rotation). A "normal" close *before*
            // any data is OpenAI's auth-rejection pattern — the handshake
            // succeeds, then the server quietly drops us. Treat as auth.
            if receivedData {
                Self.log.info("\(speakerLabel, privacy: .public) WS closed normally after data — surfacing .disconnected")
                connectionContinuation.yield(.disconnected)
            } else {
                Self.log.error("\(speakerLabel, privacy: .public) WS closed normally before any data — likely auth/policy; surfacing .apiKeyInvalid")
                connectionContinuation.yield(.failed(.apiKeyInvalid, receivedAnyData: false))
            }
        case .abnormal(let code, let reasonText):
            let mapped = Self.classifyClose(code: code, reason: reasonText, receivedData: receivedData)
            Self.log.error("\(speakerLabel, privacy: .public) WS abnormal close — code=\(code) reason=\(reasonText ?? "<nil>", privacy: .public) receivedData=\(receivedData) → \(String(describing: mapped), privacy: .public)")
            connectionContinuation.yield(.failed(mapped, receivedAnyData: receivedData))
        case .error(let ns):
            Self.log.error("\(speakerLabel, privacy: .public) WS transport error — domain=\(ns.domain, privacy: .public) code=\(ns.code) receivedData=\(receivedData) → .networkLost")
            connectionContinuation.yield(.failed(.networkLost, receivedAnyData: receivedData))
        }
    }

    /// Pure mapping from a WS close code + optional reason payload to a
    /// `TranslationError`. Extracted to `static` so unit tests can drive
    /// it directly without spinning up a stream.
    ///
    /// Notes on specific codes (RFC 6455 §7.4.1 + OpenAI custom range):
    /// - 1000 normal → handled by caller (treats pre-data as `.apiKeyInvalid`).
    /// - 1001 going away, 1002 protocol error, 1003 unsupported data,
    ///   1005 no status, 1006 abnormal, 1007 invalid frame, 1009 too big,
    ///   1010 mandatory extension, 1011 internal server, 1015 TLS → all
    ///   transport-level, mapped to `.networkLost`.
    /// - 1008 policy violation → typically auth/scope rejection, mapped
    ///   to `.apiKeyInvalid`.
    /// - 1013 try again later → `.rateLimited(retryAfter: 5)`.
    /// - 3000–3999 reserved for application use (OpenAI sometimes uses
    ///   this range for auth/quota signals). Mapped via `reason` text
    ///   inspection; falls back to `.networkLost`.
    /// - 4000–4999 reserved for application use; OpenAI uses 4xxx for
    ///   token/quota errors. Treat any `reason` containing "key",
    ///   "auth", "api" as `.apiKeyInvalid`; "rate", "limit" as
    ///   `.rateLimited`; "quota", "credit", "balance" as
    ///   `.insufficientCredits`; otherwise `.networkLost`.
    static func classifyClose(
        code: Int,
        reason: String?,
        receivedData: Bool
    ) -> TranslationError {
        // Reason-text classifier — runs first because it's the most
        // specific signal we have. OpenAI puts a JSON error blob in
        // the close `reason` payload for any non-1000 close; if we
        // can spot the keyword we don't even need the code.
        if let r = reason?.lowercased(), !r.isEmpty {
            if r.contains("invalid_api_key")
                || r.contains("unauthorized")
                || r.contains("authentication")
                || r.contains("invalid key")
                || r.contains("api key")
                || r.contains("incorrect api key") {
                return .apiKeyInvalid
            }
            if r.contains("insufficient_quota")
                || r.contains("insufficient_credits")
                || r.contains("quota")
                || r.contains("credit")
                || r.contains("balance") {
                return .insufficientCredits
            }
            if r.contains("rate_limit")
                || r.contains("rate limit")
                || r.contains("too many requests") {
                return .rateLimited(retryAfter: 5)
            }
            if r.contains("model_not_found") || r.contains("model not found") {
                return .apiKeyInvalid // surfaces as "ключ отклонён" — closest match in current enum
            }
        }

        switch code {
        case 1008:
            // Policy violation — OpenAI uses this for auth/policy failures.
            return .apiKeyInvalid
        case 1013:
            return .rateLimited(retryAfter: 5)
        case 3000...3999, 4000...4999:
            // App-defined ranges. Without a parseable reason, treat as
            // auth when no data was ever delivered (matches the
            // production log pattern where the server drops us right
            // after the WS upgrade succeeds).
            return receivedData ? .networkLost : .apiKeyInvalid
        default:
            return .networkLost
        }
    }

    private func handle(message: WSMessage) async {
        guard case .text(let str) = message,
              let data = str.data(using: .utf8),
              let event = try? JSONDecoder().decode(RealtimeServerEvent.self, from: data) else { return }
        switch event {
        case .outputAudioDelta(let p):
            guard let pcm = Data(base64Encoded: p.delta) else { return }
            let frame = AudioFrame(pcm: pcm, sampleRate: 24_000, channels: 1, format: .int16)
            receivedAnyData = true
            outputContinuation.yield(frame)
        case .outputTranscriptDelta(let p):
            let delta = TranscriptDelta(
                entryId: currentEntryId, speaker: speaker,
                kind: .translated, text: p.delta, isFinal: false
            )
            receivedAnyData = true
            transcriptContinuation.yield(delta)
        case .sessionClosed:
            connectionContinuation.yield(.disconnected)
        case .error(let e):
            let mapped: TranslationError = {
                switch e.code {
                case "invalid_api_key", "unauthorized": return .apiKeyInvalid
                case "insufficient_quota", "insufficient_credits": return .insufficientCredits
                case "rate_limit_exceeded": return .rateLimited(retryAfter: 5)
                default: return .networkLost
                }
            }()
            Self.log.error("server error event code=\(e.code, privacy: .public) receivedData=\(self.receivedAnyData) → \(String(describing: mapped), privacy: .public)")
            connectionContinuation.yield(.failed(mapped, receivedAnyData: self.receivedAnyData))
        case .unknown:
            break
        }
    }
}
