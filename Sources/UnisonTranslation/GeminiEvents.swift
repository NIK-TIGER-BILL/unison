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

    /// How long the server waits through silence before ending a speech
    /// turn (`automaticActivityDetection.silenceDurationMs`). **This was the
    /// freeze root cause.** We never configured `realtimeInputConfig`, so the
    /// API's ~800 ms default applied: the model sat through ~800 ms of every
    /// clause-boundary pause before committing+emitting the translation,
    /// which is exactly the 700–830 ms gaps the real-session logs showed
    /// draining the player dry. Dropping it makes the model translate more
    /// eagerly → smaller output gaps AND lower latency. Lower = smoother but
    /// risks ending a turn at a mid-clause micro-pause (choppier/less
    /// coherent translation); 300 ms is the balance. Tune live with
    /// `UNISON_VAD_SILENCE_MS` (e.g. 150 for smoothest, 500 for best clause
    /// coherence). Set to a value ≥ 800 to restore the old default behaviour.
    static var silenceDurationMs: Int {
        ProcessInfo.processInfo.environment["UNISON_VAD_SILENCE_MS"]
            .flatMap { Int($0) }.map { max(0, $0) } ?? 300
    }

    func encode(to encoder: Encoder) throws {
        struct TranslationConfig: Encodable { let targetLanguageCode: String }
        struct Empty: Encodable {}
        struct GenerationConfig: Encodable {
            let responseModalities: [String]
            let translationConfig: TranslationConfig
        }
        // Tighten turn detection so the model doesn't sit through the API's
        // ~800 ms default silence window before emitting each clause — that
        // default WAS the audible freeze (see `silenceDurationMs`). HIGH
        // end-of-speech sensitivity + a short silence window make it commit
        // translations promptly; a small prefix pad still catches onsets.
        struct ActivityDetection: Encodable {
            let startOfSpeechSensitivity: String
            let endOfSpeechSensitivity: String
            let prefixPaddingMs: Int
            let silenceDurationMs: Int
        }
        struct RealtimeInputConfig: Encodable {
            let automaticActivityDetection: ActivityDetection
        }
        // `inputAudioTranscription` / `outputAudioTranscription` and
        // `realtimeInputConfig` are TOP-LEVEL `setup` fields (siblings of
        // `model`/`generationConfig`), NOT nested inside `generationConfig`
        // — the live API rejects misplaced fields with a 1007 "Unknown name"
        // close (learned the hard way with the transcription fields).
        struct Setup: Encodable {
            let model: String
            let generationConfig: GenerationConfig
            let realtimeInputConfig: RealtimeInputConfig
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
            realtimeInputConfig: .init(automaticActivityDetection: .init(
                startOfSpeechSensitivity: "START_SENSITIVITY_HIGH",
                endOfSpeechSensitivity: "END_SENSITIVITY_HIGH",
                prefixPaddingMs: 20,
                silenceDurationMs: Self.silenceDurationMs
            )),
            inputAudioTranscription: .init(),
            outputAudioTranscription: .init()
        )).encode(to: encoder)
    }
}

/// Server → client signals we act on. Everything else → `.unknown`.
public enum GeminiServerEvent: Sendable, Equatable {
    case setupComplete
    case audio(base64: String)         // 24 kHz int16 PCM
    case inputTranscript(String)        // source-language text
    case outputTranscript(String)       // translated text
    case turnComplete
    case goAway
    case unknown
}

/// One decoded WS frame → the ORDERED list of signals it carried.
///
/// A single Gemini `serverContent` routinely BUNDLES `turnComplete` into the
/// SAME frame as the final content chunk (an `outputTranscription`/audio
/// part), and can also carry audio plus a transcription together. Decoding a
/// frame to a single event dropped every bundled signal but the first — so
/// `turnComplete` was silently dropped on every turn (field log 2026-07-07:
/// zero turnComplete decoded), the pairing FIFO never popped, and
/// original↔translation crossed. A frame therefore surfaces EVERY present
/// signal in a fixed order (audio, input, output, then the `turnComplete`
/// boundary LAST — so the stream routes the final content before the
/// boundary pops the FIFO).
public struct GeminiServerFrame: Sendable {
    public let events: [GeminiServerEvent]
}

extension GeminiServerFrame: Decodable {
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
        if top.contains(.setupComplete) { events = [.setupComplete]; return }
        if top.contains(.goAway) { events = [.goAway]; return }
        guard top.contains(.serverContent) else { events = [.unknown]; return }
        let content = try top.nestedContainer(keyedBy: Content.self, forKey: .serverContent)

        var out: [GeminiServerEvent] = []
        // Audio: first inlineData part of the model turn.
        if let turn = try? content.nestedContainer(keyedBy: Turn.self, forKey: .modelTurn),
           var parts = try? turn.nestedUnkeyedContainer(forKey: .parts) {
            while !parts.isAtEnd {
                guard let part = try? parts.nestedContainer(keyedBy: Part.self) else { break }
                if let inline = try? part.nestedContainer(keyedBy: Inline.self, forKey: .inlineData),
                   let data = try? inline.decode(String.self, forKey: .data) {
                    out.append(.audio(base64: data)); break
                }
            }
        }
        if let t = try? content.nestedContainer(keyedBy: Text.self, forKey: .inputTranscription),
           let text = try? t.decode(String.self, forKey: .text) {
            out.append(.inputTranscript(text))
        }
        if let t = try? content.nestedContainer(keyedBy: Text.self, forKey: .outputTranscription),
           let text = try? t.decode(String.self, forKey: .text) {
            out.append(.outputTranscript(text))
        }
        // Gemini sends turnComplete as a JSON bool `true`; tolerate an empty-
        // object form too. Present-and-not-explicitly-false ⇒ turn boundary.
        if content.contains(.turnComplete),
           (try? content.decode(Bool.self, forKey: .turnComplete)) != false {
            out.append(.turnComplete)
        }
        events = out.isEmpty ? [.unknown] : out
    }
}
