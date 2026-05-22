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

    func encodeWrapped(to encoder: Encoder, type: String) throws {
        struct Output: Encodable { let language: String }
        struct TranscriptionModel: Encodable { let model: String }
        struct NoiseReduction: Encodable { let type: String }
        struct Input: Encodable {
            let transcription: TranscriptionModel
            let noise_reduction: NoiseReduction
        }
        struct Audio: Encodable { let input: Input; let output: Output }
        struct Session: Encodable { let audio: Audio }
        struct Envelope: Encodable { let type: String; let session: Session }
        let session = Session(audio: Audio(
            input: Input(
                transcription: .init(model: "gpt-realtime-whisper"),
                noise_reduction: .init(type: "near_field")
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
        // Target-language transcript fragments. `session.input_transcript.delta`
        // (source-language) is intentionally not surfaced here — Unison only
        // displays the translated side.
        case "session.output_transcript.delta":
            let delta = try c.decode(String.self, forKey: .delta)
            self = .outputTranscriptDelta(.init(delta: delta))
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
