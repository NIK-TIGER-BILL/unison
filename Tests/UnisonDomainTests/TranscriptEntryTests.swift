import Testing
@testable import UnisonDomain

@Test func transcriptEntry_speakerIdentifies() {
    let e = TranscriptEntry(
        id: freshUUID(), speaker: .me, originalText: nil, translatedText: "Hello",
        sourceLanguage: nil, targetLanguage: .en, timestamp: epochDate(0)
    )
    #expect(e.speaker == .me)
}

@Test func transcriptDelta_partialAppend() {
    let id = freshUUID()
    let d1 = TranscriptDelta(entryId: id, speaker: .peer, kind: .translated, text: "Hello ", isFinal: false)
    let d2 = TranscriptDelta(entryId: id, speaker: .peer, kind: .translated, text: "world", isFinal: true)
    #expect(d1.isFinal == false)
    #expect(d2.isFinal == true)
}
