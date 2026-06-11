import Testing
@testable import UnisonDomain
@testable import UnisonUI

// MARK: - Helpers

private func makeEntry(
    _ speaker: Speaker,
    original: String?,
    translated: String
) -> TranscriptEntry {
    TranscriptEntry(
        id: freshUUID(),
        speaker: speaker,
        originalText: original,
        translatedText: translated,
        sourceLanguage: speaker == .me ? .ru : .en,
        targetLanguage: speaker == .me ? .en : .ru,
        timestamp: epochDate(0)
    )
}

// MARK: - Basic shape

@Test func grouping_emptyInput_returnsEmpty() {
    let groups = TranscriptGrouping.group(entries: [])
    #expect(groups.isEmpty)
}

@Test func grouping_singleMeEntry_yieldsOneGroupOneBubble() {
    let e = makeEntry(.me, original: "Привет", translated: "Hi")
    let groups = TranscriptGrouping.group(entries: [e])
    #expect(groups.count == 1)
    #expect(groups[0].speaker == .me)
    #expect(groups[0].bubbles.count == 1)
    let b = groups[0].bubbles[0]
    #expect(b.primaryText == "Привет")
    #expect(b.secondaryText == "Hi")
    #expect(b.isFirstInGroup == true)
    #expect(b.isLastInGroup == true)
}

@Test func grouping_singlePeerEntry_swapsPrimaryAndSecondary() {
    let e = makeEntry(.peer, original: "Hello", translated: "Привет")
    let groups = TranscriptGrouping.group(entries: [e])
    #expect(groups.count == 1)
    let b = groups[0].bubbles[0]
    #expect(b.primaryText == "Привет")
    #expect(b.secondaryText == "Hello")
}

// MARK: - Same-speaker grouping

@Test func grouping_consecutiveSameSpeaker_collapseIntoOneGroup() {
    let a = makeEntry(.me, original: "Первая фраза.", translated: "First.")
    let b = makeEntry(.me, original: "Вторая фраза.", translated: "Second.")
    let groups = TranscriptGrouping.group(entries: [a, b])
    #expect(groups.count == 1)
    #expect(groups[0].bubbles.count == 2)
    #expect(groups[0].bubbles.first?.isFirstInGroup == true)
    #expect(groups[0].bubbles.last?.isLastInGroup == true)
}

@Test func grouping_speakerSwitch_startsNewGroup() {
    let a = makeEntry(.me, original: "Я.", translated: "I.")
    let b = makeEntry(.peer, original: "You.", translated: "Ты.")
    let groups = TranscriptGrouping.group(entries: [a, b])
    #expect(groups.count == 2)
    #expect(groups[0].speaker == .me)
    #expect(groups[1].speaker == .peer)
    #expect(groups[0].bubbles.first?.isLastInGroup == true)
    #expect(groups[1].bubbles.first?.isLastInGroup == true)
}

// MARK: - Long text splitting

@Test func grouping_shortTextDoesNotSplit() {
    let e = makeEntry(.me, original: "Короткий текст.", translated: "Short text.")
    let groups = TranscriptGrouping.group(entries: [e], splitThreshold: 240)
    #expect(groups[0].bubbles.count == 1)
}

@Test func grouping_singleSentenceLongerThanThresholdHardSplits() {
    // A single sentence (no `.!?` boundary inside) used to flow through
    // as one oversized bubble. The splitter now falls back to a length
    // split at whitespace, so every bubble respects the threshold.
    let long = String(repeating: "слово ", count: 100) // ~600 chars, no terminator
    let e = makeEntry(.me, original: long, translated: long)
    let groups = TranscriptGrouping.group(entries: [e], splitThreshold: 240)
    #expect(groups[0].bubbles.count >= 2)
    for b in groups[0].bubbles {
        #expect(b.primaryText.count <= 240)
    }
}

@Test func grouping_multipleSentencesAtThresholdGetSplit() {
    // Six 60-char sentences = ~360 chars total; with threshold 240 we
    // expect at least 2 bubbles.
    let sentence = String(repeating: "слов ", count: 11) + "."
    let primary = String(repeating: sentence, count: 6)
    let e = makeEntry(.me, original: primary, translated: primary)
    let groups = TranscriptGrouping.group(entries: [e], splitThreshold: 240)
    #expect(groups[0].bubbles.count >= 2)
    #expect(groups[0].bubbles.first?.isFirstInGroup == true)
    #expect(groups[0].bubbles.last?.isLastInGroup == true)
    // Middle bubble (if any) is neither first nor last in group.
    if groups[0].bubbles.count >= 3 {
        let middle = groups[0].bubbles[1]
        #expect(middle.isFirstInGroup == false)
        #expect(middle.isLastInGroup == false)
    }
}

// MARK: - Live entry marking

@Test func grouping_liveEntryId_marksLastBubbleOfLastGroup() {
    let a = makeEntry(.me, original: "Привет.", translated: "Hello.")
    let b = TranscriptEntry(
        id: freshUUID(),
        speaker: .peer,
        originalText: "Hi.",
        translatedText: "Привет.",
        sourceLanguage: .en,
        targetLanguage: .ru,
        timestamp: epochDate(0)
    )
    let groups = TranscriptGrouping.group(entries: [a, b], liveEntryId: b.id)
    #expect(groups.count == 2)
    #expect(groups[0].bubbles.first?.isLive == false)
    #expect(groups[1].bubbles.last?.isLive == true)
}

@Test func grouping_liveEntryId_doesNotMatch_noLive() {
    let a = makeEntry(.me, original: "Привет.", translated: "Hello.")
    let unrelated = freshUUID()
    let groups = TranscriptGrouping.group(entries: [a], liveEntryId: unrelated)
    #expect(groups[0].bubbles.first?.isLive == false)
}

// MARK: - Sentence splitter helper (white-box)

@Test func splitOnSentence_shortText_passesThrough() {
    let parts = TranscriptGrouping.splitOnSentence("Hello.", threshold: 100)
    #expect(parts == ["Hello."])
}

@Test func splitOnSentence_emptyText_returnsEmpty() {
    let parts = TranscriptGrouping.splitOnSentence("", threshold: 100)
    #expect(parts.isEmpty)
}

@Test func splitOnSentence_threeSentencesAboveThreshold_splits() {
    // 3 sentences of 90 chars each → ~270 chars total. Threshold = 100
    // forces a flush after each sentence.
    let s = String(repeating: "x", count: 89) + "."
    let text = s + s + s
    let parts = TranscriptGrouping.splitOnSentence(text, threshold: 100)
    #expect(parts.count == 3)
}

// MARK: - Hard length split (terminator-less fallback)

@Test func splitOnSentence_terminatorless600Chars_allChunksWithinThreshold() {
    let text = String(repeating: "слово ", count: 100) // 600 chars, no `.!?`
    let parts = TranscriptGrouping.splitOnSentence(text, threshold: 240)
    #expect(parts.count >= 2)
    for p in parts {
        #expect(!p.isEmpty)
        #expect(p.count <= 240)
    }
    // No words lost or reordered by the split.
    let originalWords = text.split(separator: " ").map(String.init)
    let rejoinedWords = parts.joined(separator: " ").split(separator: " ").map(String.init)
    #expect(rejoinedWords == originalWords)
}

@Test func splitOnSentence_unbrokenRun_hardCutsAtThreshold() {
    // 500 identical characters with no whitespace anywhere — nothing to
    // break on, so the splitter hard-cuts at the threshold boundary.
    let text = String(repeating: "ы", count: 500)
    let parts = TranscriptGrouping.splitOnSentence(text, threshold: 240)
    #expect(parts.count == 3) // 240 + 240 + 20
    for p in parts {
        #expect(p.count <= 240)
    }
    #expect(parts.joined() == text)
}

@Test func splitOnSentence_oversizedSentenceAmongNormalOnes_isLengthSplit() {
    // A normal short sentence followed by one oversized unterminated
    // fragment: the short one keeps sentence-boundary behaviour, the
    // oversized tail is captured (not dropped) and length-split so no
    // chunk exceeds the threshold.
    let short = "Коротко. "
    let oversized = String(repeating: "слово ", count: 50) // 300 chars, no terminator
    let parts = TranscriptGrouping.splitOnSentence(short + oversized, threshold: 240)
    #expect(parts.count >= 2)
    for p in parts {
        #expect(p.count <= 240)
    }
    // No words lost: 1 ("Коротко.") + 50 ("слово").
    let words = parts.joined(separator: " ").split(separator: " ")
    #expect(words.count == 51)
}
