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

@Test func language_allCasesHasTenLanguages() {
    #expect(Language.allCases.count == 10)
}
