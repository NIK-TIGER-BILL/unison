import Testing
@testable import UnisonDomain
@testable import UnisonUI

@Test func languageFlag_ru_returnsRussianFlag() {
    #expect(Language.ru.flagEmoji == "🇷🇺")
}

@Test func languageFlag_en_returnsGreatBritainFlag() {
    // English uses 🇬🇧, not 🇺🇸 — chosen in the popover-final design.
    #expect(Language.en.flagEmoji == "🇬🇧")
}

@Test func languageFlag_ja_returnsJapanFlag() {
    #expect(Language.ja.flagEmoji == "🇯🇵")
}

@Test func languageFlag_zh_returnsChinaFlag() {
    #expect(Language.zh.flagEmoji == "🇨🇳")
}

@Test func languageFlag_ko_returnsKoreaFlag() {
    #expect(Language.ko.flagEmoji == "🇰🇷")
}

@Test func languageFlag_allCases_returnTwoCharacterFlags() {
    // Regional-indicator flags are 2 scalars (one per letter).
    for lang in Language.allCases {
        #expect(lang.flagEmoji.unicodeScalars.count == 2)
    }
}
