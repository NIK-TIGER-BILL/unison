import Foundation

/// Which realtime translation engine a session uses. Flat enum (one model
/// per provider today); extends by adding a case. Persisted in `Settings`.
public enum TranslationModel: String, CaseIterable, Codable, Sendable {
    case openAIRealtime        // gpt-realtime-translate
    case geminiLiveTranslate   // gemini-3.5-live-translate-preview

    public var displayName: String {
        switch self {
        case .openAIRealtime: "OpenAI Realtime"
        case .geminiLiveTranslate: "Gemini 3.5 Live Translate"
        }
    }

    /// Short provider name for user-facing error copy (e.g. "серверами <X>").
    public var providerName: String {
        switch self {
        case .openAIRealtime: "OpenAI"
        case .geminiLiveTranslate: "Gemini"
        }
    }

    /// Keychain account (service is constant `com.unison.app`). The two
    /// engines store their keys in independent slots.
    public var keychainAccount: String {
        switch self {
        case .openAIRealtime: "openai-api-key"
        case .geminiLiveTranslate: "gemini-api-key"
        }
    }

    /// Prefixes accepted by key validation. Google issues both new `AQ.`
    /// auth keys and legacy `AIza` keys — accept both so a valid legacy
    /// key isn't rejected.
    public var acceptedKeyPrefixes: [String] {
        switch self {
        case .openAIRealtime: ["sk-"]
        case .geminiLiveTranslate: ["AQ.", "AIza"]
        }
    }

    public var apiKeyPlaceholder: String {
        switch self {
        case .openAIRealtime: "sk-proj-…"
        case .geminiLiveTranslate: "AQ.… / AIza…"
        }
    }

    public var getKeyURL: URL {
        switch self {
        case .openAIRealtime: URL(string: "https://platform.openai.com/api-keys")!
        case .geminiLiveTranslate: URL(string: "https://aistudio.google.com/apikey")!
        }
    }

    /// PCM sample rate (Hz) the engine expects on the input wire. Output
    /// is 24 kHz for both, so only the input differs.
    public var inputWireSampleRate: Int {
        switch self {
        case .openAIRealtime: 24_000
        case .geminiLiveTranslate: 16_000
        }
    }

    /// Languages selectable as a translation target for this engine.
    public var supportedTargets: [Language] {
        switch self {
        case .openAIRealtime: Language.openAITargets
        case .geminiLiveTranslate: Language.geminiTargets
        }
    }

    /// Coerce a pair so both sides are supported targets of this engine.
    /// Each unsupported language is replaced with a supported one, picking
    /// a distinct fallback so the pair never collapses to mine == peer.
    public func coerced(_ pair: LanguagePair) -> LanguagePair {
        let supported = supportedTargets
        func fix(_ lang: Language, avoiding other: Language) -> Language {
            if supported.contains(lang) { return lang }
            return supported.first(where: { $0 != other }) ?? supported.first ?? lang
        }
        let mine = fix(pair.mine, avoiding: pair.peer)
        let peer = fix(pair.peer, avoiding: mine)
        return LanguagePair(mine: mine, peer: peer)
    }
}
