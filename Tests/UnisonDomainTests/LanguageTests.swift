import Testing
@testable import UnisonDomain

@Test func language_rawValueIsISO639_1() {
    #expect(Language.ru.rawValue == "ru")
    #expect(Language.en.rawValue == "en")
    #expect(Language.zh.rawValue == "zh")
}

@Test func language_displayNameIsNative() {
    #expect(Language.ru.displayName == "Русский")
    #expect(Language.en.displayName == "English")
    #expect(Language.ja.displayName == "日本語")
}

@Test func language_allCasesHasTwentyEightLanguages() {
    // 13 original OpenAI targets + 15 Gemini-only targets = 28.
    #expect(Language.allCases.count == 28)
    #expect(Language.openAITargets.count == 13)
}

@Test func language_supportedTargets_isOpenAIThirteen() {
    // `supportedTargets` is the legacy OpenAI picker list — the
    // canonical 13. Each entry must be a real enum case.
    #expect(Language.supportedTargets.count == 13)
    for lang in Language.supportedTargets {
        #expect(Language.allCases.contains(lang))
    }
}

@Test func language_isTargetSupported_trueForAllCurrentCases() {
    // Forward-compat hook: every enum case today is a target for at least one engine.
    // Adding a source-only language in the future must set `isTargetSupported = false`.
    for lang in Language.allCases {
        #expect(lang.isTargetSupported)
    }
}

@Test func languagePair_defaultIsRuEn() {
    let pair = LanguagePair.default
    #expect(pair.mine == .ru)
    #expect(pair.peer == .en)
}

@Test func languagePair_swapped() {
    let pair = LanguagePair(mine: .ru, peer: .en)
    let swapped = pair.swapped
    #expect(swapped.mine == .en)
    #expect(swapped.peer == .ru)
}

@Test func languagePair_codable() throws {
    let pair = LanguagePair(mine: .ja, peer: .ko)
    let decoded = try encodeDecode(pair)
    #expect(decoded == pair)
}
