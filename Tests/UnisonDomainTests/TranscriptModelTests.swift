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
