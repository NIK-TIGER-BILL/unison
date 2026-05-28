import Foundation

// MARK: - Client (outgoing) events

public enum RealtimeClientEvent: Encodable, Sendable {
    case sessionUpdate(SessionUpdatePayload)
    case inputAudioBufferAppend(InputAudioBufferAppendPayload)
    case sessionClose

    private enum CodingKeys: String, CodingKey { case type }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .sessionUpdate(let p):
            try p.encodeWrapped(to: encoder, type: "session.update")
        case .inputAudioBufferAppend(let p):
            // GA event name per OpenAI cookbook
            // (`examples/voice_solutions/realtime_translation_guide.mdx`):
            // `session.input_audio_buffer.append`. The Beta API used the
            // unprefixed `input_audio_buffer.append`, which still works on
            // the generic `/v1/realtime` endpoint for backwards-compat but
            // is not the canonical shape for `/v1/realtime/translations`.
            try p.encodeWrapped(to: encoder, type: "session.input_audio_buffer.append")
        case .sessionClose:
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("session.close", forKey: .type)
        }
    }
}

/// GA `session.update` for `gpt-realtime-translate`.
///
/// Shape per OpenAI cookbook (`examples/voice_solutions/realtime_translation_guide.mdx`):
///
/// ```json
/// {
///   "type": "session.update",
///   "session": {
///     "audio": {
///       "input": {
///         "transcription": { "model": "gpt-realtime-whisper" },
///         "noise_reduction": { "type": "near_field" }
///       },
///       "output": { "language": "<target>" }
///     }
///   }
/// }
/// ```
///
/// `gpt-realtime-translate` does NOT support custom voice selection or
/// `instructions` — it uses dynamic voice adaptation tracking the source
/// speaker. The model is implicit in the connection URL
/// (`?model=gpt-realtime-translate`), so the payload omits it.
public struct SessionUpdatePayload: Sendable {
    public let targetLanguage: String
    public init(targetLanguage: String) { self.targetLanguage = targetLanguage }

    /// Resolves the noise-reduction preset for the session from
    /// `UNISON_NOISE_REDUCTION`:
    ///   - unset             → default `"near_field"` (cookbook recommendation)
    ///   - `"off" | "none"`  → field omitted from the payload entirely
    ///   - any other string  → sent verbatim (e.g. `"far_field"`)
    /// Investigating whether near_field's AGC component degrades amplitude
    /// over long sessions on system-audio (non-mic) input — flip via env
    /// var to A/B without a rebuild.
    private static func resolveNoiseReductionType() -> String? {
        let raw = ProcessInfo.processInfo.environment["UNISON_NOISE_REDUCTION"]
        guard let raw else { return "near_field" }
        let v = raw.lowercased()
        if v.isEmpty || v == "off" || v == "none" { return nil }
        return raw
    }

    func encodeWrapped(to encoder: Encoder, type: String) throws {
        struct Output: Encodable { let language: String }
        struct TranscriptionModel: Encodable { let model: String }
        struct NoiseReduction: Encodable { let type: String }
        struct Input: Encodable {
            let transcription: TranscriptionModel
            let noise_reduction: NoiseReduction?

            enum CodingKeys: String, CodingKey {
                case transcription, noise_reduction
            }
            // Custom encode so a nil `noise_reduction` is sent as explicit
            // JSON `null` (not omitted). OpenAI's docs example for
            // disabling NR shows `"noise_reduction": null` — omitting the
            // field would let the server fall back to the default
            // `near_field` preset.
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(transcription, forKey: .transcription)
                if let nr = noise_reduction {
                    try c.encode(nr, forKey: .noise_reduction)
                } else {
                    try c.encodeNil(forKey: .noise_reduction)
                }
            }
        }
        struct Audio: Encodable { let input: Input; let output: Output }
        struct Session: Encodable { let audio: Audio }
        struct Envelope: Encodable { let type: String; let session: Session }

        let nr: NoiseReduction? = Self.resolveNoiseReductionType().map(NoiseReduction.init(type:))
        let session = Session(audio: Audio(
            input: Input(
                transcription: .init(model: "gpt-realtime-whisper"),
                noise_reduction: nr
            ),
            output: .init(language: targetLanguage)
        ))
        try Envelope(type: type, session: session).encode(to: encoder)
    }
}

public struct InputAudioBufferAppendPayload: Sendable {
    public let audio: String
    public init(audio: String) { self.audio = audio }

    func encodeWrapped(to encoder: Encoder, type: String) throws {
        struct Envelope: Encodable { let type: String; let audio: String }
        try Envelope(type: type, audio: audio).encode(to: encoder)
    }
}

// MARK: - Server (incoming) events

public enum RealtimeServerEvent: Sendable {
    case outputAudioDelta(OutputAudioDeltaPayload)
    case outputTranscriptDelta(OutputTranscriptDeltaPayload)
    /// Source-language transcript fragment of what the model heard on
    /// input. Used to populate the `me` bubble's primary text (what
    /// the user actually said) — the design's `.me` bubble shape is
    /// "primary = original, secondary = translated".
    case inputTranscriptDelta(InputTranscriptDeltaPayload)
    /// Server-signalled end of one turn. We rotate the `currentEntryId`
    /// here so each utterance lands in its own bubble instead of
    /// growing the very first bubble forever.
    case outputTranscriptDone
    case inputTranscriptDone
    case sessionClosed
    case error(ErrorPayload)
    case unknown(String)
}

public struct OutputAudioDeltaPayload: Sendable, Equatable {
    public let delta: String
}

public struct OutputTranscriptDeltaPayload: Sendable, Equatable {
    public let delta: String
}

public struct InputTranscriptDeltaPayload: Sendable, Equatable {
    public let delta: String
}

public struct ErrorPayload: Sendable, Equatable {
    public let code: String
    public let message: String
}

extension RealtimeServerEvent: Decodable {
    private enum TopKeys: String, CodingKey { case type, delta, error }
    private enum ErrorKeys: String, CodingKey { case code, message }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TopKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        // GA event names per OpenAI cookbook for gpt-realtime-translate.
        // Carries base64-encoded 24 kHz PCM16 audio in `delta`.
        case "session.output_audio.delta":
            let delta = try c.decode(String.self, forKey: .delta)
            self = .outputAudioDelta(.init(delta: delta))
        // Target-language transcript fragments (what the listener will
        // hear in their language).
        case "session.output_transcript.delta":
            let delta = try c.decode(String.self, forKey: .delta)
            self = .outputTranscriptDelta(.init(delta: delta))
        // Source-language transcript fragments (what was actually
        // spoken). The design's `.me` bubble shape is "primary =
        // original, secondary = translated", so without surfacing
        // these the `.me` bubble's primary text stays empty and the
        // bubble looks blank.
        case "session.input_transcript.delta":
            let delta = try c.decode(String.self, forKey: .delta)
            self = .inputTranscriptDelta(.init(delta: delta))
        // Turn-end markers. Rotating `currentEntryId` on these is how
        // each utterance lands in its own bubble — without them every
        // fragment forever appends to the first bubble.
        case "session.output_transcript.done":
            self = .outputTranscriptDone
        case "session.input_transcript.done":
            self = .inputTranscriptDone
        case "session.closed":
            self = .sessionClosed
        case "error":
            // GA error payload may have a nil `code` (some server errors only
            // carry `type` + `message`). Default to "unknown" so the
            // existing classifier still runs.
            let errC = try c.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error)
            let code = (try? errC.decode(String.self, forKey: .code)) ?? "unknown"
            let msg = (try? errC.decode(String.self, forKey: .message)) ?? ""
            self = .error(.init(code: code, message: msg))
        default:
            // Lifecycle / informational events we don't act on:
            //   session.created, session.updated,
            //   conversation.item.created, response.created, response.done,
            //   input_audio_buffer.{committed,speech_started,speech_stopped},
            //   rate_limits.updated, etc.
            // Forwarded as `.unknown(type)` so the handler can skip silently.
            //
            // TODO(transcript-confirmation): `session.input_transcript.delta`
            // carries the auto-detected source language captions. We could
            // surface these alongside translations as a "what we heard"
            // confirmation row, which would help users notice when source
            // detection drifts (e.g. a fast Russian/English code-switch).
            // Not a blocker for the current feature; tracked here so it's
            // visible to anyone reading the decoder. Implementation
            // sketch: add a `.inputTranscriptDelta(...)` case, wire it to
            // a new TranscriptDelta.kind, and render in the UI as a
            // muted line under each bubble.
            self = .unknown(type)
        }
    }
}
