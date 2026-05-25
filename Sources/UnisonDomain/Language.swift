public enum Language: String, CaseIterable, Codable, Sendable {
    case ru, en, es, fr, de, it, pt, zh, ja, ko, hi, id, vi

    public var displayName: String {
        switch self {
        case .ru: "Русский"
        case .en: "English"
        case .es: "Español"
        case .fr: "Français"
        case .de: "Deutsch"
        case .it: "Italiano"
        case .pt: "Português"
        case .zh: "中文"
        case .ja: "日本語"
        case .ko: "한국어"
        case .hi: "हिन्दी"
        case .id: "Bahasa Indonesia"
        case .vi: "Tiếng Việt"
        }
    }

    /// Whether this language can be used as a translation *target*.
    ///
    /// Per the OpenAI cookbook (`examples/voice_solutions/realtime_translation_guide.mdx`),
    /// `gpt-realtime-translate` supports exactly 13 output languages:
    /// Spanish, Portuguese, French, Japanese, Russian, Chinese, German,
    /// Korean, Hindi, Indonesian, Vietnamese, Italian, English. The
    /// model accepts 70+ *source* languages via auto-detect, but the
    /// `session.audio.output.language` field only honors the 13 above.
    ///
    /// All cases currently in this enum are supported targets; the flag
    /// exists so a future enum expansion (e.g. source-only Polish) won't
    /// silently slip into the target picker.
    public var isTargetSupported: Bool {
        switch self {
        case .ru, .en, .es, .fr, .de, .it, .pt, .zh, .ja, .ko, .hi, .id, .vi:
            return true
        }
    }

    /// The 13 languages valid as `session.audio.output.language`.
    /// Use this — not `allCases` — when populating a target-language
    /// picker so the user can't pick an unsupported output.
    public static var supportedTargets: [Language] {
        allCases.filter { $0.isTargetSupported }
    }
}
