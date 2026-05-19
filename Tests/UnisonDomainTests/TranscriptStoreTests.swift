import Testing
@testable import UnisonDomain

@Test @MainActor func transcriptStore_appendsNewEntry() {
    let store = TranscriptStore()
    let id = freshUUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .translated, text: "Hello", isFinal: true))
    #expect(store.entries.count == 1)
    #expect(store.entries[0].translatedText == "Hello")
    #expect(store.entries[0].speaker == .me)
}

@Test @MainActor func transcriptStore_concatenatesDeltas() {
    let store = TranscriptStore()
    let id = freshUUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .peer, kind: .translated, text: "Hello ", isFinal: false))
    store.apply(TranscriptDelta(entryId: id, speaker: .peer, kind: .translated, text: "world", isFinal: true))
    #expect(store.entries.count == 1)
    #expect(store.entries[0].translatedText == "Hello world")
}

@Test @MainActor func transcriptStore_mergesOriginalAndTranslated() {
    let store = TranscriptStore()
    let id = freshUUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: "Привет", isFinal: true))
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .translated, text: "Hello", isFinal: true))
    #expect(store.entries.count == 1)
    #expect(store.entries[0].originalText == "Привет")
    #expect(store.entries[0].translatedText == "Hello")
}

@Test @MainActor func transcriptStore_clears() {
    let store = TranscriptStore()
    store.apply(TranscriptDelta(entryId: freshUUID(), speaker: .me, kind: .translated, text: "x", isFinal: true))
    store.clear()
    #expect(store.entries.isEmpty)
}

@Test @MainActor func transcriptStore_exportAsText() {
    let store = TranscriptStore()
    store.apply(TranscriptDelta(entryId: freshUUID(), speaker: .me, kind: .translated, text: "Hi", isFinal: true))
    store.apply(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated, text: "Hello", isFinal: true))
    let text = store.exportAsText()
    #expect(text.contains("Me:"))
    #expect(text.contains("Peer:"))
    #expect(text.contains("Hi"))
    #expect(text.contains("Hello"))
}
