public enum Language: String, CaseIterable, Codable, Sendable {
    case ru, en, es, fr, de, it, pt, zh, ja, ko

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
        }
    }
}
