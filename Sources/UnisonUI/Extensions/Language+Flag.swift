import UnisonDomain

/// Presentation-layer extensions on `Language`. Flags and display strings
/// belong in `UnisonUI`, not the domain — the domain shouldn't know about
/// pictographs (and indeed `Language.displayName` already lives in the
/// domain because it is rendering-agnostic; the flag is.
public extension Language {
    /// Emoji flag for this language. Uses the regional indicator letters
    /// of the country most commonly associated with the language (English
    /// → UK, Chinese → mainland CN, Korean → South). 🌐 is used where
    /// there is no single representative country flag.
    var flagEmoji: String {
        switch self {
        case .ru: "🇷🇺"
        case .en: "🇬🇧"
        case .es: "🇪🇸"
        case .fr: "🇫🇷"
        case .de: "🇩🇪"
        case .it: "🇮🇹"
        case .pt: "🇵🇹"
        case .zh: "🇨🇳"
        case .ja: "🇯🇵"
        case .ko: "🇰🇷"
        case .hi: "🇮🇳"
        case .id: "🇮🇩"
        case .vi: "🇻🇳"
        case .pl: "🇵🇱"
        case .nl: "🇳🇱"
        case .tr: "🇹🇷"
        case .ar: "🌐"
        case .uk: "🇺🇦"
        case .he: "🇮🇱"
        case .th: "🇹🇭"
        case .sv: "🇸🇪"
        case .no: "🇳🇴"
        case .da: "🇩🇰"
        case .fi: "🇫🇮"
        case .cs: "🇨🇿"
        case .el: "🇬🇷"
        case .ro: "🇷🇴"
        case .hu: "🇭🇺"
        }
    }
}
