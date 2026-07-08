import Testing
@testable import UnisonDomain

@Test func segmenter_twoSentences_plusTrailing() {
    let r = SentenceSegmenter.segment("Hi there. How are you? And then", language: .en)
    #expect(r.complete == ["Hi there.", "How are you?"])
    #expect(r.trailing == "And then")
}

@Test func segmenter_noTerminator_allTrailing() {
    let r = SentenceSegmenter.segment("still going on", language: .en)
    #expect(r.complete.isEmpty)
    #expect(r.trailing == "still going on")
}

@Test func segmenter_empty() {
    let r = SentenceSegmenter.segment("   ", language: .en)
    #expect(r.complete.isEmpty)
    #expect(r.trailing == "")
}

@Test func segmenter_abbreviations_notSplit() {
    // Russian: NLTokenizer's own model is abbreviation-aware — it already keeps
    // "и т.д."/"Н.В."/"стр." intact and splits only real boundaries (verified
    // empirically). So ru needs NO merge list; adding one would wrongly rejoin
    // real boundaries like "…и т.д. Это удобно." into a single sentence.
    #expect(SentenceSegmenter.segment("Мы поддерживаем Telegram и т.д. Это удобно.", language: .ru).complete
            == ["Мы поддерживаем Telegram и т.д.", "Это удобно."])
    #expect(SentenceSegmenter.segment("Замулдинов Н.В. пришёл. Всё хорошо.", language: .ru).complete
            == ["Замулдинов Н.В. пришёл.", "Всё хорошо."])
    #expect(SentenceSegmenter.segment("См. стр. 5 внимательно. Там всё.", language: .ru).complete
            == ["См. стр. 5 внимательно.", "Там всё."])
    // Guards: a broad ru list (the wrong fix) would break these two.
    #expect(SentenceSegmenter.segment("Итого мы имеем и т.д.", language: .ru).complete
            == ["Итого мы имеем и т.д."])
    #expect(SentenceSegmenter.segment("Например, см. рис. 3 и т.д. Далее идём.", language: .ru).complete
            == ["Например, см. рис. 3 и т.д.", "Далее идём."])
    // Portuguese: NLTokenizer WRONGLY splits the title from the name
    // ("O Sr." | "Silva chegou.") — the title merge rejoins them.
    #expect(SentenceSegmenter.segment("O Sr. Silva chegou. Tudo bem.", language: .pt).complete
            == ["O Sr. Silva chegou.", "Tudo bem."])
}

@Test func segmenter_cjk_and_danda() {
    #expect(SentenceSegmenter.segment("今天天气很好。我们去公园吧。", language: .zh).complete
            == ["今天天气很好。", "我们去公园吧。"])
    #expect(SentenceSegmenter.segment("मैं ठीक हूँ। आप कैसे हैं।", language: .hi).complete
            == ["मैं ठीक हूँ।", "आप कैसे हैं।"])
}
