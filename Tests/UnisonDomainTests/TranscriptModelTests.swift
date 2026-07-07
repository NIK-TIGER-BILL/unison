import Testing
@testable import UnisonDomain

@MainActor
private func model(_ clock: FakeClock) -> TranscriptModel {
    let m = TranscriptModel(clock: clock)
    m.currentLanguagePair = LanguagePair(mine: .ru, peer: .en)
    return m
}

@MainActor @Test func model_accumulatesLiveSegmentPerSpeaker() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                             text: "Hello there", isFinal: false, language: .en))
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated,
                             text: "Привет", isFinal: false, language: .ru))
    let b = m.bubbles
    #expect(b.count == 1)
    #expect(b[0].isLive == true)
    #expect(b[0].source == "Hello there")
    #expect(b[0].translation == "Привет")
    #expect(b[0].speaker == .peer)
}

@MainActor @Test func model_pauseFreezesSegment_andResets() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                             text: "Hello there", isFinal: false, language: .en))
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated,
                             text: "Привет", isFinal: false, language: .ru))
    // Both streams quiet for > pauseSeconds → segment freezes on tick.
    clock.advance(by: 3)
    m.tick(now: clock.now())
    #expect(m.bubbles.count == 1)
    #expect(m.bubbles[0].isLive == false)
    // A new utterance opens a fresh segment (no carried state).
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                             text: "How are you", isFinal: false, language: .en))
    let b = m.bubbles
    #expect(b.count == 2)
    #expect(b[1].isLive == true)
    #expect(b[1].source == "How are you")
    #expect(b[0].id != b[1].id)
}

@MainActor @Test func model_matchedSentenceCounts_splitIntoPairedBubbles() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    // Two complete sentences on both sides, counts agree.
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                             text: "First one. Second one now.", isFinal: false, language: .en))
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated,
                             text: "Первое. Второе теперь.", isFinal: false, language: .ru))
    clock.advance(by: 3); m.tick(now: clock.now())
    let b = m.bubbles.filter { !$0.isLive }
    #expect(b.count == 2)
    #expect(b[0].source == "First one." && b[0].translation == "Первое.")
    #expect(b[1].source == "Second one now." && b[1].translation == "Второе теперь.")
}
