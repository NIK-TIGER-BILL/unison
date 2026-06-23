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

@Test @MainActor func transcriptStore_targetLanguageFollowsSpeakerDirection() {
    let store = TranscriptStore()
    store.currentLanguagePair = LanguagePair(mine: .ru, peer: .en)
    store.apply(TranscriptDelta(entryId: freshUUID(), speaker: .me, kind: .translated, text: "Hello", isFinal: true))
    store.apply(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated, text: "Привет", isFinal: true))
    #expect(store.entries.count == 2)
    // .me speaks .ru, translated to .en
    #expect(store.entries[0].speaker == .me)
    #expect(store.entries[0].targetLanguage == .en)
    // .peer speaks .en, translated to .ru
    #expect(store.entries[1].speaker == .peer)
    #expect(store.entries[1].targetLanguage == .ru)
}

@MainActor
@Test func transcriptStore_markEntriesAtRisk_setsFlag() {
    let store = TranscriptStore()
    let id = freshUUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: "Привет", isFinal: false))
    #expect(store.entries[0].translationAtRisk == false)
    store.markActiveEntriesAtRisk()
    #expect(store.entries[0].translationAtRisk == true)
}

@MainActor
@Test func transcriptStore_lateTranslationDelta_clearsAtRisk() {
    let store = TranscriptStore()
    let id = freshUUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: "Привет", isFinal: false))
    store.markActiveEntriesAtRisk()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .translated, text: "Hi", isFinal: false))
    #expect(store.entries[0].translationAtRisk == false)
}

@Test @MainActor func transcriptStore_apply_stampsActivityFromClock() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let id = freshUUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: "Привет", isFinal: false))
    #expect(store.entries[0].timestamp == epochDate(1000))
    #expect(store.entries[0].lastActivityAt == epochDate(1000))
}

@Test @MainActor func transcriptStore_apply_bumpsLastActivityAtOnLaterDelta() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let id = freshUUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: "Привет", isFinal: false))
    clock.advance(by: 7)
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .translated, text: "Hi", isFinal: true))
    #expect(store.entries.count == 1)
    #expect(store.entries[0].lastActivityAt == epochDate(1007)) // bumped to latest delta
    #expect(store.entries[0].timestamp == epochDate(1000))      // creation unchanged
}
