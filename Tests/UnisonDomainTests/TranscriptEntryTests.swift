import Testing
@testable import UnisonDomain

@Test func transcriptEntry_speakerIdentifies() {
    let e = TranscriptEntry(
        id: freshUUID(), speaker: .me, originalText: nil, translatedText: "Hello",
        sourceLanguage: nil, targetLanguage: .en, timestamp: epochDate(0)
    )
    #expect(e.speaker == .me)
}

@Test @MainActor func transcriptDelta_partialAppend() {
    // Two partial deltas for the same entry must CONCATENATE in the
    // store (the earlier version only asserted back the initializer
    // arguments and tested nothing about appending).
    let store = TranscriptStore()
    let id = freshUUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .peer, kind: .translated, text: "Hello ", isFinal: false))
    store.apply(TranscriptDelta(entryId: id, speaker: .peer, kind: .translated, text: "world", isFinal: true))
    #expect(store.entries.count == 1)
    #expect(store.entries.first?.translatedText == "Hello world")
}
