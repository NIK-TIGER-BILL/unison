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

    // MARK: Original ↔ translation pairing (two tracks + FIFO)
    //
    // One shared entry id used to pair bubbles off-by-one: the translation
    // lags the original, so the NEXT utterance's input transcription lands
    // BEFORE the previous turn's `turnComplete` — and glued into the
    // previous bubble (field screenshot 2026-07-02: every bubble held
    // translated(N) + original(N+1)). Now the two directions ride separate
    // tracks:
    //  • INPUT (original) deltas write to `inputEntryId`, which rotates on
    //    a real speech pause: an input-to-input gap ≥
    //    `interUtteranceGapSeconds` IS a VAD turn boundary by construction
    //    (the server VAD closes a turn after ~0.3 s of silence — see
    //    `UNISON_VAD_SILENCE_MS`), gated on the current turn's output
    //    having started so transcription *delivery* jitter inside one turn
    //    can't split a bubble.
    //  • OUTPUT (translated) deltas write to the FIFO head of
    //    `pendingTurnEntries` — utterances in speech order awaiting their
    //    translation — and `turnComplete` pops the head.
    // A missed input boundary degrades to the previous behavior (merge,
    // then rotate at `turnComplete`); it can no longer SHIFT the pairing.

    /// Entry receiving the ORIGINAL (input transcription) right now.
    private var inputEntryId = UUID()
    /// Utterance entries in speech order, awaiting/receiving translation.
    /// `turnComplete` pops the head. Bounded by `maxPendingTurnEntries`.
    private var pendingTurnEntries: [UUID] = []
    /// True once the CURRENT input entry's own translation started (an
    /// output delta arrived while the FIFO head was this entry) — the arm
    /// condition for gap-splitting the input side. Cleared on rotation.
    private var sawOutputForCurrentInput = false
    private var lastInputDeltaAt: Date?
    /// Coarse same-speaker fallback (pre-existing behavior): a ≥5 s input
    /// gap always starts a new utterance, armed or not.
    private static let turnGapSeconds: TimeInterval = 5.0
    /// Speech-pause boundary: above the server VAD's ~0.3 s close threshold
    /// with headroom for transcription delivery jitter.
    private static let interUtteranceGapSeconds: TimeInterval = 0.6
    /// Drift cap: if `turnComplete`s stop arriving (or translation falls
    /// hopelessly behind), drop the oldest pending utterance rather than
    /// pin every future translation to an ancient bubble.
    private static let maxPendingTurnEntries = 3

    /// Wall-clock of the previous audio chunk from the model — for the
    /// arrival-gap diagnostic (distinguishes model/network gaps from our
    /// playback pipeline as the source of audible micropauses).
    private var lastAudioAt: Date?
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

    /// Input-side utterance segmentation — see the pairing note above.
    /// Rotates `inputEntryId` when the input gap marks a new utterance:
    /// either the fine speech-pause boundary (armed once this entry's own
    /// translation started, or once the input has already run a turn ahead
    /// of the translation), or the coarse ≥5 s fallback unconditionally.
    private func rotateInputEntryIfNewUtterance() {
        let now = clock.now()
        defer { lastInputDeltaAt = now }
        guard let prev = lastInputDeltaAt else { return }
        let gap = now.timeIntervalSince(prev)
        let inputRanAhead = pendingTurnEntries.first.map { $0 != inputEntryId } ?? false
        let speechPauseBoundary = gap >= Self.interUtteranceGapSeconds
            && (sawOutputForCurrentInput || inputRanAhead)
        guard speechPauseBoundary || gap >= Self.turnGapSeconds else { return }
        Self.log.debug("[pairing \(speaker)] input gap \(Int(gap * 1000))ms ≥ boundary → new utterance entry"
            + " (pending=\(pendingTurnEntries.count))")
        inputEntryId = UUID()
        sawOutputForCurrentInput = false
    }

    private func handle(message: WSMessage) async {
        // Gemini delivers serverContent as BINARY WebSocket frames (unlike
        // OpenAI's text frames), so accept both.
        let data: Data
        switch message {
        case .text(let str): data = Data(str.utf8)
        case .data(let d): data = d
        }
        // A serverContent frame can bundle several signals (e.g. the final
        // outputTranscription AND turnComplete); process each in order so the
        // turn boundary is never dropped — dropping it stalled the pairing FIFO.
        guard let frame = try? JSONDecoder().decode(GeminiServerFrame.self, from: data) else { return }
        for event in frame.events { apply(event: event) }
    }

    private func apply(event: GeminiServerEvent) {
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
            // Translation audio counts as "this turn's output started" for
            // the input-side splitter (audio often precedes the transcript).
            markOutputStartedForCurrentTurn()
            outputContinuation.yield(AudioFrame(pcm: pcm, sampleRate: 24_000, channels: 1, format: .int16))
        case .inputTranscript(let text):
            rotateInputEntryIfNewUtterance()
            receivedAnyData = true
            // First original of a fresh entry enqueues it for translation
            // routing (FIFO in speech order).
            if !pendingTurnEntries.contains(inputEntryId) {
                pendingTurnEntries.append(inputEntryId)
                if pendingTurnEntries.count > Self.maxPendingTurnEntries {
                    let dropped = pendingTurnEntries.removeFirst()
                    Self.log.info("[pairing \(speaker)] pending-turn queue over \(Self.maxPendingTurnEntries)"
                        + " — dropping oldest utterance \(dropped) (turnComplete lost or translation far behind)")
                }
            }
            transcriptContinuation.yield(TranscriptDelta(
                entryId: inputEntryId, speaker: speaker, kind: .original, text: text, isFinal: false))
        case .outputTranscript(let text):
            receivedAnyData = true
            markOutputStartedForCurrentTurn()
            // Translation routes to the OLDEST utterance still awaiting its
            // translation — not to wherever the input side has moved on to.
            transcriptContinuation.yield(TranscriptDelta(
                entryId: pendingTurnEntries.first ?? inputEntryId,
                speaker: speaker, kind: .translated, text: text, isFinal: false))
        case .turnComplete:
            // Turn boundary — the model finished a turn and pauses until it
            // decides the next turn started (governed by the VAD
            // `silenceDurationMs`). Logged so a big `[audio-rx]` gap can be
            // attributed to a turn boundary (VAD wait) vs. a mid-turn stall.
            let sinceAudio = lastAudioAt.map { Int(clock.now().timeIntervalSince($0) * 1000) }
            Self.log.debug("[turn \(speaker)] turnComplete (\(sinceAudio.map { "\($0)ms since last audio" } ?? "no audio yet"),"
                + " pending=\(pendingTurnEntries.count))")
            // This turn's translation is done — its utterance leaves the
            // FIFO. If the input side is still writing into that same entry
            // (no speech-pause boundary detected), rotate it too so the next
            // original starts a fresh bubble — the pre-existing behavior —
            // and clear the input timeline so the gap splitter doesn't
            // double-rotate the freshly-minted entry. When the input already
            // ran AHEAD of the translation, its entry and timeline stay
            // untouched: nil-ing `lastInputDeltaAt` here would blind the
            // splitter to the very next speech pause.
            if pendingTurnEntries.isEmpty {
                inputEntryId = UUID()
                sawOutputForCurrentInput = false
                lastInputDeltaAt = nil
            } else {
                let done = pendingTurnEntries.removeFirst()
                if done == inputEntryId {
                    inputEntryId = UUID()
                    sawOutputForCurrentInput = false
                    lastInputDeltaAt = nil
                }
            }
        case .goAway:
            // Session time limit / server rotation: the socket WILL die
            // shortly. Surface it now so the orchestrator swaps in a fresh
            // stream immediately (zero-backoff reconnect) instead of losing
            // audio when the connection actually drops mid-utterance.
            Self.log.info("\(String(describing: speaker)) goAway — server will close soon; requesting proactive stream swap")
            connectionContinuation.yield(.failed(.serverGoingAway, receivedAnyData: receivedAnyData))
        case .unknown:
            break
        }
    }

    /// Arm the input-side splitter once the CURRENT input entry's own
    /// translation has begun: output belongs to the FIFO head, so only when
    /// the head IS the entry the input is still filling (or nothing is
    /// queued yet) does output prove "this turn is being translated". Output
    /// for an OLDER queued turn says nothing about the current one.
    private func markOutputStartedForCurrentTurn() {
        if pendingTurnEntries.isEmpty || pendingTurnEntries.first == inputEntryId {
            sawOutputForCurrentInput = true
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
