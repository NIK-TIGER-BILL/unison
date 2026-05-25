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

@Test func language_allCasesHasThirteenLanguages() {
    // The 13 supported output targets per OpenAI cookbook:
    // Spanish, Portuguese, French, Japanese, Russian, Chinese, German,
    // Korean, Hindi, Indonesian, Vietnamese, Italian, English.
    #expect(Language.allCases.count == 13)
}

@Test func language_supportedTargets_isAllThirteen() {
    // `supportedTargets` powers the picker. All current cases are
    // valid output targets — adding a source-only language in the
    // future must set `isTargetSupported = false`.
    #expect(Language.supportedTargets.count == 13)
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
