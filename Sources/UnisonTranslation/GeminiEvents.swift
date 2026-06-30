import Foundation

/// Client → server messages for the Gemini Live API (raw WebSocket JSON).
/// Shapes per https://ai.google.dev/gemini-api/docs/live-api .
public enum GeminiClientEvent: Encodable, Sendable {
    case setup(GeminiSetupPayload)
    case realtimeAudio(base64: String)

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .setup(let p):
            try p.encode(to: encoder)
        case .realtimeAudio(let b64):
            struct Audio: Encodable { let data: String; let mimeType: String }
            struct RealtimeInput: Encodable { let audio: Audio }
            struct Envelope: Encodable { let realtimeInput: RealtimeInput }
            try Envelope(realtimeInput: .init(
                audio: .init(data: b64, mimeType: "audio/pcm;rate=16000")
            )).encode(to: encoder)
        }
    }
}

public struct GeminiSetupPayload: Sendable {
    public let targetLanguage: String
    public init(targetLanguage: String) { self.targetLanguage = targetLanguage }

    func encode(to encoder: Encoder) throws {
        struct TranslationConfig: Encodable { let targetLanguageCode: String }
        struct Empty: Encodable {}
        struct GenerationConfig: Encodable {
            let responseModalities: [String]
            let translationConfig: TranslationConfig
        }
        // `inputAudioTranscription` / `outputAudioTranscription` are TOP-LEVEL
        // `setup` fields (siblings of `model`/`generationConfig`), NOT nested
        // inside `generationConfig` — the live API rejects them there with a
        // 1007 "Unknown name … at 'setup.generation_config'" close.
        struct Setup: Encodable {
            let model: String
            let generationConfig: GenerationConfig
            let inputAudioTranscription: Empty
            let outputAudioTranscription: Empty
        }
        struct Envelope: Encodable { let setup: Setup }
        try Envelope(setup: .init(
            model: "models/gemini-3.5-live-translate-preview",
            generationConfig: .init(
                responseModalities: ["AUDIO"],
                translationConfig: .init(targetLanguageCode: targetLanguage)
            ),
            inputAudioTranscription: .init(),
            outputAudioTranscription: .init()
        )).encode(to: encoder)
    }
}

/// Server → client messages we act on. Everything else → `.unknown`.
///
/// One event per WS message, decoded audio-first. If a single
/// `serverContent` frame ever carried BOTH a `modelTurn` audio part AND
/// `turnComplete`, the boundary signal would be dropped — but that's not
/// observed in practice (audio and `turnComplete` arrive in separate
/// frames), and a dropped boundary self-heals via the stream's
/// `rotateOnInputGap` plus the turn-aware `TranscriptStore`. Kept simple
/// deliberately; revisit only if the API starts coalescing them.
public enum GeminiServerEvent: Sendable {
    case setupComplete
    case audio(base64: String)         // 24 kHz int16 PCM
    case inputTranscript(String)        // source-language text
    case outputTranscript(String)       // translated text
    case turnComplete
    case goAway
    case unknown
}

extension GeminiServerEvent: Decodable {
    private enum Top: String, CodingKey { case serverContent, setupComplete, goAway }
    private enum Content: String, CodingKey {
        case modelTurn, inputTranscription, outputTranscription, turnComplete
    }
    private enum Turn: String, CodingKey { case parts }
    private enum Part: String, CodingKey { case inlineData }
    private enum Inline: String, CodingKey { case data }
    private enum Text: String, CodingKey { case text }

    public init(from decoder: Decoder) throws {
        let top = try decoder.container(keyedBy: Top.self)
        if top.contains(.setupComplete) { self = .setupComplete; return }
        if top.contains(.goAway) { self = .goAway; return }
        guard top.contains(.serverContent) else { self = .unknown; return }
        let content = try top.nestedContainer(keyedBy: Content.self, forKey: .serverContent)

        // Audio in the first inlineData part of the model turn.
        if let turn = try? content.nestedContainer(keyedBy: Turn.self, forKey: .modelTurn),
           var parts = try? turn.nestedUnkeyedContainer(forKey: .parts) {
            while !parts.isAtEnd {
                let part = try parts.nestedContainer(keyedBy: Part.self)
                if let inline = try? part.nestedContainer(keyedBy: Inline.self, forKey: .inlineData),
                   let data = try? inline.decode(String.self, forKey: .data) {
                    self = .audio(base64: data); return
                }
            }
        }
        if let t = try? content.nestedContainer(keyedBy: Text.self, forKey: .inputTranscription),
           let text = try? t.decode(String.self, forKey: .text) {
            self = .inputTranscript(text); return
        }
        if let t = try? content.nestedContainer(keyedBy: Text.self, forKey: .outputTranscription),
           let text = try? t.decode(String.self, forKey: .text) {
            self = .outputTranscript(text); return
        }
        // Gemini sends turnComplete as a JSON bool `true`; be tolerant of an
        // empty-object form too. Present-and-not-explicitly-false ⇒ turn boundary.
        if content.contains(.turnComplete),
           (try? content.decode(Bool.self, forKey: .turnComplete)) != false {
            self = .turnComplete; return
        }
        self = .unknown
    }
}
