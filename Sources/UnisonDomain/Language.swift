public enum Language: String, CaseIterable, Codable, Sendable {
    case ru, en, es, fr, de, it, pt, zh, ja, ko, hi, id, vi
    // Gemini-only targets (curated subset of its 70+).
    case pl, nl, tr, ar, uk, he, th, sv, no, da, fi, cs, el, ro, hu

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
        case .pl: "Polski"
        case .nl: "Nederlands"
        case .tr: "Türkçe"
        case .ar: "العربية"
        case .uk: "Українська"
        case .he: "עברית"
        case .th: "ไทย"
        case .sv: "Svenska"
        case .no: "Norsk"
        case .da: "Dansk"
        case .fi: "Suomi"
        case .cs: "Čeština"
        case .el: "Ελληνικά"
        case .ro: "Română"
        case .hu: "Magyar"
        }
    }

    /// Whether this language can be used as a translation *target*.
    ///
    /// Forward-compatibility hook — not directly consumed by production
    /// code, which reads the authoritative per-engine lists
    /// (`openAITargets` / `geminiTargets`). All cases in this enum are
    /// valid targets for at least one engine (the original 13 for
    /// OpenAI, the full set for Gemini); the flag exists so a future
    /// source-only addition can return `false` and stay out of the
    /// target pickers.
    public var isTargetSupported: Bool {
        switch self {
        case .ru, .en, .es, .fr, .de, .it, .pt, .zh, .ja, .ko, .hi, .id, .vi,
             .pl, .nl, .tr, .ar, .uk, .he, .th, .sv, .no, .da, .fi, .cs, .el, .ro, .hu:
            return true
        }
    }

    /// Output languages OpenAI gpt-realtime-translate honors (the
    /// canonical 13 per the cookbook). Stable — do NOT derive from
    /// allCases, which now also contains Gemini-only targets.
    public static let openAITargets: [Language] =
        [.ru, .en, .es, .pt, .fr, .ja, .zh, .de, .ko, .hi, .id, .vi, .it]

    /// Gemini 3.5 Live Translate target set (curated subset of its 70+).
    public static let geminiTargets: [Language] = allCases

    /// Legacy alias — pickers now read TranslationModel.supportedTargets.
    public static var supportedTargets: [Language] { openAITargets }
}
