import Foundation
import CryptoKit
import IOKit
import UnisonDomain

public actor OpenAIRealtimeStream: TranslationStream {
    /// Diagnostic logger for the realtime stream. Every close-code
    /// mapping decision lands here (and in the diagnostic dump) so a
    /// user-reported "networkLost" loop can be traced back to the
    /// actual WS close code + server reason payload. Mirrors to
    /// `~/Library/Logs/Unison/unison.log` — see `UnisonLog`.
    private static let log = UnisonLog(category: "OpenAIRealtimeStream")

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
    /// One UUID per *utterance* (turn). Rotated on
    /// `session.{input,output}_transcript.done` so each thing the
    /// speaker says lands in its own bubble. The old behaviour kept
    /// the same id forever, so every fragment of every sentence got
    /// appended to a single ever-growing bubble.
    private var currentEntryId = UUID()
    /// Wall-clock timestamp of the most recent **input** transcript
    /// delta (source-language fragment of what the speaker said).
    /// Used as the turn-boundary signal in the absence of reliable
    /// `output_transcript.done` events: when a fresh input delta
    /// arrives after a gap of `Self.turnGapSeconds` since the previous
    /// input delta, that's a new utterance from the speaker and we
    /// rotate `currentEntryId`.
    ///
    /// **Why ONLY input deltas, not "any delta":**
    /// Empirical evidence from production logs showed OpenAI's
    /// translation pipeline can take 5+ seconds to start streaming
    /// the output transcript for an utterance — that's a normal
    /// IN→OUT gap inside a single turn, not a boundary. The earlier
    /// "any-delta gap" heuristic rotated on those, dropping the
    /// translation into a fresh bubble while the source text stayed
    /// in the previous one (one phrase rendered as two mismatched
    /// bubbles). Input-to-input is the speaker-side rhythm that
    /// genuinely marks "started a new utterance"; output deltas in
    /// between don't reset the clock.
    private var lastInputDeltaAt: Date?
    /// Wall-clock of the previous audio chunk — for the arrival-gap
    /// diagnostic (model/network gap vs our playback pipeline as the
    /// source of audible micropauses).
    private var lastAudioAt: Date?
    /// Pause threshold between consecutive input transcript deltas
    /// to count as a new utterance. 5 s is comfortably longer than
    /// a natural mid-sentence pause (typically <2 s) while still
    /// being shorter than the typical inter-utterance gap in a
    /// conversation (5–30 s). Combined with `output_transcript.done`
    /// rotation when the server does emit it, this gives a robust
    /// boundary signal even with the GA endpoint's irregular event
    /// emission.
    private static let turnGapSeconds: TimeInterval = 5.0
    /// Signal raised when `session.closed` arrives from the server.
    /// `close()` awaits this (with a short timeout) so any audio the
    /// server flushes between our `session.close` and the actual close
    /// is still delivered downstream. Per OpenAI cookbook: "send
    /// `session.close`, then continue reading events until
    /// `session.closed` confirmation — system flushes pending audio."
    private var sessionClosedContinuation: CheckedContinuation<Void, Never>?
    private var sawSessionClosed = false
    /// Makes `close()` idempotent. The orchestrator can race two
    /// `close()` calls onto the same stream (failure handling vs. a
    /// user Stop landing in the same 0.5 s grace window); without this
    /// guard the second call overwrites `sessionClosedContinuation`
    /// while the first is parked on it — the first caller then hangs
    /// forever on a leaked CheckedContinuation.
    private var closeStarted = false
    /// Tracks whether the server ever sent us a translated chunk before
    /// closing. A close with `.normalClosure` *before* any data is the
    /// classic OpenAI "your request was rejected on the first message"
    /// pattern (invalid key, account not enabled for realtime, etc.) —
    /// the WS handshake succeeds at TCP/TLS level, then the server
    /// closes immediately. We surface that as `.apiKeyInvalid` instead
    /// of `.networkLost`.
    ///
    /// INVARIANT: This flag is set ONLY when the server delivers an
    /// actual translation chunk — `session.output_audio.delta` or
    /// `session.output_transcript.delta` (GA event names). Handshake/
    /// lifecycle events like `session.created`, `session.updated`,
    /// `error`, etc. MUST NOT flip it, because the orchestrator's
    /// empty-close escalation uses `receivedAnyData=false` as the
    /// signal for "server accepted us then dropped before translating
    /// a byte" — a credential/policy failure that should terminate the
    /// session quickly. If a non-data event ever toggles this, the
    /// user gets stuck in an endless `.reconnecting` flap.
    private var receivedAnyData = false
    /// First-audio-delta latch — fires `Logger.info` exactly once per
    /// stream so the diagnostic dump can confirm that the server
    /// actually delivered translated audio. The per-delta hot path
    /// stays log-free after that.
    private var loggedFirstAudioDelta = false
    /// First-transcript-delta latch — same idea, but for the
    /// target-language transcript. Helps tell apart "server is silent"
    /// vs "audio path broken but transcript landed".
    private var loggedFirstTranscriptDelta = false
    /// First source-language transcript-delta latch. Catching the input
    /// transcript path separately matters because it's the .me bubble's
    /// *primary* text — if input transcripts never arrive, the bubble
    /// looks blank even when the translated side is fine.
    private var loggedFirstInputTranscriptDelta = false
    /// Sticky classification of *why* the WS / server failed. Set by
    /// `handleClose` and the server `error` event handler — the first
    /// classification wins so later transport-level noise (POSIX 89
    /// "Operation canceled" raised by an in-flight `client.send` once
    /// the socket has already shut down) can't overwrite the real
    /// reason. `connect()` uses this to substitute a meaningful
    /// `TranslationError` for whatever generic NSError the transport
    /// happens to throw at the same moment.
    private var lastClassifiedError: TranslationError?

    public init(
        apiKey: String,
        client: any WSClient,
        clock: any Clock,
        speaker: Speaker = .peer,
        // Canonical GA URL per OpenAI cookbook:
        //   wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate
        // The translation-specific endpoint sets `session.type: "translation"`
        // server-side, which is the documented best-practice path. The
        // generic `/v1/realtime` endpoint still works but produces
        // `session.type: "realtime"` — fine in practice but not the
        // canonical shape.
        url: URL = URL(string: "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate")!
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
        // GA Realtime API — no `OpenAI-Beta` header. The Beta endpoint
        // (`OpenAI-Beta: realtime=v1`) was retired and now returns
        // `beta_api_shape_disabled`. The GA endpoint authenticates with
        // a plain Bearer token. We also send `OpenAI-Safety-Identifier`
        // (recommended per docs) so OpenAI can rate-limit per-install
        // without us shipping PII — the value is a SHA-256 hash of the
        // bundle ID + host UUID and is stable across launches.
        var headers: [String: String] = [
            "Authorization": "Bearer \(apiKey)"
        ]
        if let safetyId = Self.safetyIdentifier() {
            headers["OpenAI-Safety-Identifier"] = safetyId
        }
        try await client.connect(url: url, headers: headers)
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
        do {
            try await client.send(.text(String(data: data, encoding: .utf8) ?? ""))
        } catch {
            // The send may race with a server-initiated close: the WS
            // is already shut down by the time URLSession marshals our
            // outbound frame, surfacing as a generic `POSIX 89
            // "Operation canceled"` NSError. If `handleClose` or the
            // server `error` event already classified the failure
            // (e.g. `.apiKeyInvalid` from a reason payload), propagate
            // *that* — the transport-level noise hides the real cause.
            if let classified = lastClassifiedError {
                Self.log.error("connect — send(session.update) failed but close already classified as \(String(describing: classified)); propagating classified error instead of POSIX")
                throw classified
            }
            // Give the close-monitor task a tiny grace window in case
            // the classification is in-flight on a separate task and
            // simply hasn't landed yet.
            try? await Task.sleep(nanoseconds: 50_000_000)
            if let classified = lastClassifiedError {
                Self.log.error("connect — send(session.update) failed; classified error arrived in grace window: \(String(describing: classified))")
                throw classified
            }
            throw error
        }
    }

    /// First-write-wins setter for the sticky classification. Both the
    /// WS-close path and the server `error` event funnel through here.
    private func setClassifiedError(_ error: TranslationError) {
        if lastClassifiedError == nil {
            lastClassifiedError = error
        }
    }

    /// Rotate `currentEntryId` when the gap since the previous
    /// **input** delta exceeds `turnGapSeconds`. Called ONLY from the
    /// input-delta handler BEFORE building the `TranscriptDelta` —
    /// output deltas don't reset the clock because a slow translation
    /// response inside the same utterance is normal (5+ seconds is
    /// observed in production).
    private func rotateOnInputGap() {
        let now = clock.now()
        if let prev = lastInputDeltaAt, now.timeIntervalSince(prev) >= Self.turnGapSeconds {
            Self.log.info("[\(speaker)] input gap \(String(format: "%.2f", now.timeIntervalSince(prev)))s ≥ \(Self.turnGapSeconds)s → rotating entryId")
            currentEntryId = UUID()
        }
        lastInputDeltaAt = now
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
        guard !closeStarted else { return }
        closeStarted = true
        if let data = try? JSONEncoder().encode(RealtimeClientEvent.sessionClose),
           let str = String(data: data, encoding: .utf8) {
            try? await client.send(.text(str))
        }
        // Graceful close per cookbook: wait briefly for `session.closed`
        // so the server has a chance to flush in-flight translated audio
        // before we yank the socket. If the server doesn't confirm within
        // the grace window we proceed anyway — the alternative is hanging
        // the UI on stop. The grace is short (max ~500ms) because by the
        // time the user clicked Stop, any worthwhile audio is already
        // queued on the network.
        if !sawSessionClosed {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                sessionClosedContinuation = cont
                Task {
                    try? await clock.sleep(for: 0.5)
                    self.fireSessionClosedWaiterIfPending()
                }
            }
        }
        receiveTask?.cancel()
        closeReasonTask?.cancel()
        await client.close()
        connectionContinuation.yield(.disconnected)
        transcriptContinuation.finish()
        outputContinuation.finish()
        connectionContinuation.finish()
    }

    /// Resume the `close()` waiter if it's still parked. Called from
    /// both the receive path (when `session.closed` arrives) and the
    /// timeout path. Either branch resumes at most once.
    private func fireSessionClosedWaiterIfPending() {
        guard let cont = sessionClosedContinuation else { return }
        sessionClosedContinuation = nil
        cont.resume()
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
                Self.log.info("\(speakerLabel) WS closed normally after data — surfacing .disconnected")
                connectionContinuation.yield(.disconnected)
            } else {
                Self.log.error("\(speakerLabel) WS closed normally before any data — likely auth/policy; surfacing .apiKeyInvalid")
                setClassifiedError(.apiKeyInvalid)
                connectionContinuation.yield(.failed(.apiKeyInvalid, receivedAnyData: false))
            }
        case .abnormal(let code, let reasonText):
            let mapped = Self.classifyClose(code: code, reason: reasonText, receivedData: receivedData)
            Self.log.error("\(speakerLabel) WS abnormal close — code=\(code) reason=\(reasonText ?? "<nil>") receivedData=\(receivedData) → \(String(describing: mapped))")
            setClassifiedError(mapped)
            connectionContinuation.yield(.failed(mapped, receivedAnyData: receivedData))
        case .error(let ns):
            Self.log.error("\(speakerLabel) WS transport error — domain=\(ns.domain) code=\(ns.code) receivedData=\(receivedData) → .networkLost")
            setClassifiedError(.networkLost)
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
            let nowAt = clock.now()
            let gapMs = lastAudioAt.map { nowAt.timeIntervalSince($0) * 1000 } ?? 0
            lastAudioAt = nowAt
            Self.log.debug("[audio-rx \(speaker)] +\(Int(gapMs))ms gap, \(pcm.count)B (~\(pcm.count / 48)ms audio)")
            receivedAnyData = true
            if !loggedFirstAudioDelta {
                loggedFirstAudioDelta = true
                let speakerLabel = String(describing: speaker)
                Self.log.info("\(speakerLabel) first session.output_audio.delta received — \(pcm.count) bytes (24kHz int16 PCM, ~\(pcm.count / 48)ms)")
            }
            outputContinuation.yield(frame)
        case .outputTranscriptDelta(let p):
            // No rotation logic here — output deltas inside an
            // utterance can arrive 5+ seconds after the last input
            // delta (slow translation latency). Rotating on
            // "any-delta gap" used to drop the translation into a
            // fresh bubble while the source text stayed in the
            // previous one. Turn-boundary detection lives in the
            // input-delta handler instead.
            let delta = TranscriptDelta(
                entryId: currentEntryId, speaker: speaker,
                kind: .translated, text: p.delta, isFinal: false
            )
            receivedAnyData = true
            if !loggedFirstTranscriptDelta {
                loggedFirstTranscriptDelta = true
                let speakerLabel = String(describing: speaker)
                Self.log.info("\(speakerLabel) first session.output_transcript.delta received — \(p.delta.count) chars")
            }
            transcriptContinuation.yield(delta)
        case .inputTranscriptDelta(let p):
            // Source-language fragment of what the speaker said. Tagged
            // as `.original` so `TranscriptStore.apply` writes it into
            // `entry.originalText` — the bubble's primary text for
            // `.me` (and secondary for `.peer`).
            //
            // Turn boundary: input-to-input gap (see `rotateOnInputGap`).
            // OpenAI interleaves IN+OUT deltas continuously inside one
            // utterance; only the input rhythm reliably marks a new
            // speaker utterance.
            rotateOnInputGap()
            let delta = TranscriptDelta(
                entryId: currentEntryId, speaker: speaker,
                kind: .original, text: p.delta, isFinal: false
            )
            receivedAnyData = true
            if !loggedFirstInputTranscriptDelta {
                loggedFirstInputTranscriptDelta = true
                let speakerLabel = String(describing: speaker)
                Self.log.info("\(speakerLabel) first session.input_transcript.delta received — \(p.delta.count) chars")
            }
            transcriptContinuation.yield(delta)
        case .outputTranscriptDone:
            // Authoritative turn boundary when the server DOES emit
            // it. The GA `gpt-realtime-translate` flow only sometimes
            // emits this between turns (and not at all for many
            // observed utterances), so we can't rely on it alone —
            // `rotateOnInputGap` carries the rest. When the server
            // does emit it, rotate immediately so the next delta
            // starts a fresh bubble even if there's no audible pause.
            currentEntryId = UUID()
            lastInputDeltaAt = nil
        case .inputTranscriptDone:
            // Informational only — marks the end of the source
            // transcription phase, but the turn continues with the
            // translation. Don't rotate here.
            break
        case .sessionClosed:
            // Server confirmed it has flushed any pending output. Wake
            // `close()` if it is parked on the grace continuation so we
            // exit immediately instead of riding out the timeout.
            sawSessionClosed = true
            fireSessionClosedWaiterIfPending()
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
            Self.log.error("server error event code=\(e.code) receivedData=\(self.receivedAnyData) → \(String(describing: mapped))")
            setClassifiedError(mapped)
            connectionContinuation.yield(.failed(mapped, receivedAnyData: self.receivedAnyData))
        case .unknown:
            break
        }
    }

    /// Build the `OpenAI-Safety-Identifier` header value.
    ///
    /// **Privacy contract — read this before touching the implementation:**
    ///
    /// - Input ingredients are limited to (a) the app's bundle identifier
    ///   (a constant compiled into the binary) and (b) the macOS
    ///   `IOPlatformUUID` from IORegistry. Neither is user-supplied PII.
    /// - The two values are concatenated and SHA-256-hashed. We send only
    ///   the lowercase hex digest to OpenAI — the raw UUID never leaves
    ///   the device.
    /// - The result is stable across launches on the same machine
    ///   (so OpenAI can rate-limit / fingerprint abuse per install)
    ///   but cannot be reversed to a Mac or a user.
    /// - If `IOPlatformUUID` is unavailable (sandboxed Swift Package
    ///   tests, virtualized CI, etc.) we return `nil` and skip the
    ///   header rather than fabricate or persist anything.
    static func safetyIdentifier() -> String? {
        guard let uuid = platformUUID() else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.unison.app"
        let composite = bundleID + "|" + uuid
        let digest = SHA256.hash(data: Data(composite.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Read the IOPlatformUUID from IORegistry.
    /// Returns `nil` outside macOS or when the platform expert is
    /// inaccessible (sandbox, hypervisor without DMG passthrough).
    private static func platformUUID() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        let prop = IORegistryEntryCreateCFProperty(
            entry,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault,
            0
        )
        return prop?.takeRetainedValue() as? String
    }
}
