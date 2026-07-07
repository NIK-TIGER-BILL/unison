import Foundation
import NaturalLanguage

/// Splits streaming transcript text into fully-completed sentences plus the
/// trailing (still-forming) fragment, using Apple's language-aware sentence
/// tokenizer. `complete` are safe to freeze; `trailing` stays live.
public enum SentenceSegmenter {
    public static func segment(
        _ text: String, language: Language
    ) -> (complete: [String], trailing: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], "") }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(nlLanguage(for: language))
        tokenizer.string = text

        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { sentences.append(s) }
            return true
        }
        // Merge a sentence into the following one when it ends on a title
        // abbreviation NLTokenizer wrongly split from its name. "When in doubt,
        // merge, don't split" — an over-merge is only a coarser bubble; a wrong
        // split mis-pairs source↔translation.
        let abbr = abbreviations(for: language)
        var merged: [String] = []
        for s in sentences {
            if let prev = merged.last,
               let tok = trailingDottedToken(prev), abbr.contains(tok) {
                merged[merged.count - 1] = prev + " " + s
            } else {
                merged.append(s)
            }
        }
        guard let last = merged.last else { return ([], "") }
        // The tokenizer always emits the trailing fragment as its own token;
        // if that token doesn't end with a terminator it's the live trailing.
        if endsWithTerminator(last) {
            return (merged, "")
        }
        return (Array(merged.dropLast()), last)
    }

    /// Lowercased title abbreviations that precede a (capitalised) name, e.g.
    /// "Sr. Silva", "Dr. Smith". NLTokenizer's Latin-script models wrongly
    /// treat the title's period as a sentence end, so we merge the title back
    /// onto the following fragment. Russian is deliberately absent: its model
    /// already handles "и т.д."/"Н.В."/"стр." correctly (verified), and listing
    /// those stems would wrongly rejoin real boundaries like "…и т.д. Это…".
    private static func abbreviations(for language: Language) -> Set<String> {
        switch language {
        case .pt, .es: return ["sr", "sra", "dr", "dra"]
        case .en: return ["mr", "mrs", "ms", "dr", "prof"]
        case .de: return ["hr", "fr", "dr", "prof"]
        default: return []
        }
    }

    /// The letters immediately before a trailing period, lowercased, or nil.
    private static func trailingDottedToken(_ s: String) -> String? {
        var t = Substring(s)
        while let c = t.last, c.isWhitespace { t = t.dropLast() }
        guard t.last == "." else { return nil }
        t = t.dropLast()
        let letters = t.reversed().prefix { $0.isLetter }
        let token = String(letters.reversed())
        return token.isEmpty ? nil : token.lowercased()
    }

    private static func endsWithTerminator(_ s: String) -> Bool {
        // Unicode scalar escapes used throughout (rather than literal glyphs)
        // to avoid any transport/editor mangling of look-alike punctuation —
        // e.g. ASCII "?" vs fullwidth "\u{FF1F}", or straight vs curly quotes.
        let terminators: Set<Character> = [
            ".", "!", "?",       // ASCII
            "\u{2026}",          // … horizontal ellipsis
            "\u{3002}",          // 。 ideographic full stop
            "\u{FF1F}",          // ？ fullwidth question mark
            "\u{FF01}",          // ！ fullwidth exclamation mark
            "\u{0964}"           // । devanagari danda
        ]
        let closers: Set<Character> = [
            "\"", "'", ")", "]", "}",
            "\u{00BB}",          // right guillemet
            "\u{201D}",          // curly right double quotation mark
            "\u{2019}"           // curly right single quotation mark (apostrophe)
        ]
        var t = Substring(s)
        while let c = t.last, c.isWhitespace || closers.contains(c) { t = t.dropLast() }
        guard let c = t.last else { return false }
        return terminators.contains(c)
    }

    // `Language` currently has 28 cases: the 13 OpenAI targets named in the
    // task spec, plus 15 Gemini-only targets added in PR #12 (pl, nl, tr,
    // ar, uk, he, th, sv, no, da, fi, cs, el, ro, hu) — all present in
    // `NLLanguage`'s own predefined constant set, mapped 1:1 below so this
    // switch stays exhaustive over the real type (and the compiler forces
    // an update here if a case is ever added). It's a flat lookup table,
    // not branchy logic, so the raw arm count isn't a real complexity risk.
    // swiftlint:disable:next cyclomatic_complexity
    private static func nlLanguage(for language: Language) -> NLLanguage {
        switch language {
        case .ru: return .russian
        case .en: return .english
        case .es: return .spanish
        case .fr: return .french
        case .de: return .german
        case .it: return .italian
        case .pt: return .portuguese
        case .zh: return .simplifiedChinese
        case .ja: return .japanese
        case .ko: return .korean
        case .hi: return .hindi
        case .id: return .indonesian
        case .vi: return .vietnamese
        case .pl: return .polish
        case .nl: return .dutch
        case .tr: return .turkish
        case .ar: return .arabic
        case .uk: return .ukrainian
        case .he: return .hebrew
        case .th: return .thai
        case .sv: return .swedish
        case .no: return .norwegian
        case .da: return .danish
        case .fi: return .finnish
        case .cs: return .czech
        case .el: return .greek
        case .ro: return .romanian
        case .hu: return .hungarian
        }
    }
}
