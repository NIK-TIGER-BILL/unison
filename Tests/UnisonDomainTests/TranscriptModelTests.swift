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

@MainActor @Test func model_maxLength_forcesCommit_noInfiniteBubble() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    m.config.maxSegmentChars = 40
    // No punctuation, keeps growing.
    let chunk = "word word word word word word word "
    for _ in 0..<4 {
        m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                                 text: chunk, isFinal: false, language: .en))
        m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated,
                                 text: chunk, isFinal: false, language: .en))
    }
    // No pause; but the segment must have been force-sealed at least once.
    #expect(m.bubbles.contains { !$0.isLive })
    #expect(m.bubbles.allSatisfy { $0.source.count <= 40 + chunk.count })
}

@MainActor @Test func model_translationNeverArrives_commitsWithLostMarker() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                             text: "Hello there.", isFinal: false, language: .en))
    // Translation never comes; after lag timeout, commit source-only.
    clock.advance(by: 6); m.tick(now: clock.now())
    let b = m.bubbles.filter { !$0.isLive }
    #expect(b.count == 1)
    #expect(b[0].source == "Hello there.")
    #expect(b[0].translation.isEmpty)
    #expect(b[0].translationLost == true)
}

@MainActor @Test func model_mismatchedSentenceCounts_stayWholeSegment() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    // Source: 2 sentences; translation merged into 1 → counts differ.
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                             text: "First one. Second one.", isFinal: false, language: .en))
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated,
                             text: "Первое и второе вместе.", isFinal: false, language: .ru))
    clock.advance(by: 3); m.tick(now: clock.now())
    let b = m.bubbles.filter { !$0.isLive }
    #expect(b.count == 1)   // NOT split into a wrong pair
    #expect(b[0].source == "First one. Second one.")
    #expect(b[0].translation == "Первое и второе вместе.")
}

// A bad/mismatched segment must NOT poison the next one — each segment is
// independent (pause resets alignment).
@MainActor @Test func model_badSegment_doesNotDriftNext() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                             text: "First one. Second one.", isFinal: false, language: .en))
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated,
                             text: "Первое и второе.", isFinal: false, language: .ru))
    clock.advance(by: 3); m.tick(now: clock.now())
    // New, clean segment.
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                             text: "All good now.", isFinal: false, language: .en))
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated,
                             text: "Теперь всё хорошо.", isFinal: false, language: .ru))
    clock.advance(by: 3); m.tick(now: clock.now())
    let b = m.bubbles.filter { !$0.isLive }
    #expect(b.last?.source == "All good now.")
    #expect(b.last?.translation == "Теперь всё хорошо.")   // correctly paired, no carryover
}

@MainActor @Test func model_ordersBubblesByTime_acrossSpeakers() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original, text: "Hi.", isFinal: false, language: .en))
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated, text: "Привет.", isFinal: false, language: .ru))
    clock.advance(by: 3); m.tick(now: clock.now())
    clock.advance(by: 1)
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .me, kind: .original, text: "Да.", isFinal: false, language: .ru))
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .me, kind: .translated, text: "Yes.", isFinal: false, language: .en))
    clock.advance(by: 3); m.tick(now: clock.now())
    let b = m.bubbles
    #expect(b.count == 2)
    #expect(b[0].speaker == .peer && b[1].speaker == .me)
}

@MainActor @Test func model_cumulativeRestatement_replacesNotAppends() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original, text: "Hello", isFinal: false, language: .en))
    // Some models re-send the cumulative transcript: "Hello world" contains "Hello".
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original, text: "Hello world", isFinal: false, language: .en))
    #expect(m.bubbles.first?.source == "Hello world")   // replaced, not "Hello Hello world"
}

@MainActor @Test func model_liveBubbleId_isStableIntoFrozen() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                             text: "One whole thought.", isFinal: false, language: .en))
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated,
                             text: "Одна цельная мысль.", isFinal: false, language: .ru))
    let liveId = m.bubbles.first?.id
    clock.advance(by: 3); m.tick(now: clock.now())
    let frozen = m.bubbles.filter { !$0.isLive }
    #expect(frozen.count == 1)
    #expect(frozen.first?.id == liveId)   // freeze is an in-place lock, not delete+insert
}

@MainActor @Test func model_cjkChunks_joinWithoutSpuriousSpace() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                             text: "今天天气", isFinal: false, language: .zh))
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                             text: "很好。", isFinal: false, language: .zh))
    #expect(m.bubbles.first?.source == "今天天气很好。")   // no spurious inter-chunk space
}

@MainActor @Test func model_historyCap_trimsOldest() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    m.config.historyCap = 3
    for i in 0..<6 {
        m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                                 text: "Line \(i).", isFinal: false, language: .en))
        m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated,
                                 text: "Строка \(i).", isFinal: false, language: .ru))
        clock.advance(by: 3); m.tick(now: clock.now())
    }
    let frozen = m.bubbles.filter { !$0.isLive }
    #expect(frozen.count == 3)                    // capped
    #expect(frozen.first?.source == "Line 3.")    // oldest three dropped
}

@MainActor @Test func model_bothSpeakersLive_orderedByStart() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    // peer starts first…
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                             text: "Peer talking", isFinal: false, language: .en))
    clock.advance(by: 1)
    // …then me starts while peer is still live (overlap / double capture).
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .me, kind: .original,
                             text: "Я говорю", isFinal: false, language: .ru))
    let b = m.bubbles
    #expect(b.count == 2)
    #expect(b[0].speaker == .peer && b[1].speaker == .me)   // deterministic: by segment start
}

// End-to-end regression: the real captured Gemini timeline from the spec §2
// (en→ru, real audio, real pace) — two sentences streamed with the translation
// lagging ~0.5–1 s, then a ~5 s pause. It must pair source↔translation as a
// unit and split into two correctly-aligned bubbles on the pause.
@MainActor @Test func model_recordedGeminiTimeline_pairsCorrectly() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    func at(_ t: Double, _ kind: TranscriptDelta.Kind, _ text: String, _ lang: Language) {
        clock.set(epochDate(t))
        m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: kind,
                                 text: text, isFinal: false, language: lang))
    }
    at(6.083, .original, "First, we look at a simple idea.", .en)
    at(6.451, .translated, "Сначала мы рассмотрим", .ru)
    at(7.159, .translated, " простую идею.", .ru)
    at(7.536, .original, " Then we", .en)
    at(9.598, .original, " make it more complex.", .en)
    at(10.278, .translated, " Затем мы делаем ее более сложной.", .ru)
    clock.set(epochDate(14.0)); m.tick(now: clock.now())   // ~5 s pause → commit
    let b = m.bubbles.filter { !$0.isLive }
    #expect(b.count == 2)
    #expect(b[0].source.contains("simple idea") && b[0].translation.contains("простую идею"))
    #expect(b[1].source.contains("more complex") && b[1].translation.contains("сложной"))
}
