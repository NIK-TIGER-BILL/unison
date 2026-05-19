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
            try p.encodeWrapped(to: encoder, type: "input_audio_buffer.append")
        case .sessionClose:
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("session.close", forKey: .type)
        }
    }
}

public struct SessionUpdatePayload: Sendable {
    public let targetLanguage: String
    public init(targetLanguage: String) { self.targetLanguage = targetLanguage }

    func encodeWrapped(to encoder: Encoder, type: String) throws {
        struct Output: Encodable { let language: String }
        struct Audio: Encodable { let output: Output }
        struct Session: Encodable { let audio: Audio }
        struct Envelope: Encodable { let type: String; let session: Session }
        try Envelope(type: type, session: Session(audio: Audio(output: .init(language: targetLanguage)))).encode(to: encoder)
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
        case "output_audio.delta":
            let delta = try c.decode(String.self, forKey: .delta)
            self = .outputAudioDelta(.init(delta: delta))
        case "output_transcript.delta":
            let delta = try c.decode(String.self, forKey: .delta)
            self = .outputTranscriptDelta(.init(delta: delta))
        case "session.closed":
            self = .sessionClosed
        case "error":
            let errC = try c.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error)
            let code = try errC.decode(String.self, forKey: .code)
            let msg = try errC.decode(String.self, forKey: .message)
            self = .error(.init(code: code, message: msg))
        default:
            self = .unknown(type)
        }
    }
}
