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
