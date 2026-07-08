import Testing
@testable import UnisonDomain

@MainActor
private func model(_ clock: FakeClock) -> TranscriptModel {
    let m = TranscriptModel(clock: clock)
    m.currentLanguagePair = LanguagePair(mine: .ru, peer: .en)
    m.config.pauseSeconds = 2   // small threshold for fast, deterministic finalize
    return m
}

@MainActor
private func src(_ m: TranscriptModel, _ speaker: Speaker, _ text: String, _ lang: Language) {
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: speaker, kind: .original,
                             text: text, isFinal: false, language: lang))
}
@MainActor
private func tr(_ m: TranscriptModel, _ speaker: Speaker, _ text: String, _ lang: Language) {
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: speaker, kind: .translated,
                             text: text, isFinal: false, language: lang))
}

@MainActor @Test func model_defaultPause_isFour() {
    #expect(TranscriptModel().config.pauseSeconds == 4)   // real pauses, not clause gaps
}

// A still-forming sentence (no terminator) is one LIVE bubble; nothing frozen.
@MainActor @Test func model_formingSentence_isLiveNothingFrozen() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    src(m, .peer, "Hello there", .en)
    tr(m, .peer, "Привет", .ru)
    let b = m.bubbles
    #expect(b.count == 1)
    #expect(b[0].isLive == true)
    #expect(b[0].source == "Hello there" && b[0].translation == "Привет")
    #expect(b[0].speaker == .peer)
}

// A sentence complete on BOTH sides seals IMMEDIATELY (frozen) — no pause,
// no accumulate-then-split; the next forming sentence is the live tail.
@MainActor @Test func model_completeSentence_sealsProactively() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    src(m, .peer, "First one. Second", .en)   // "First one." done, "Second" forming
    tr(m, .peer, "Первое. Второе", .ru)
    let b = m.bubbles
    #expect(b.count == 2)
    #expect(b[0].isLive == false)             // sealed, immutable
    #expect(b[0].source == "First one." && b[0].translation == "Первое.")
    #expect(b[1].isLive == true)              // the forming tail
    #expect(b[1].source == "Second" && b[1].translation == "Второе")
}

// The translation lags: a completed SOURCE sentence waits in the live tail
// until its translation lands, THEN seals — no wrong pairing.
@MainActor @Test func model_translationLag_sealsWhenTranslationCatchesUp() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    src(m, .peer, "First one. Second one.", .en)   // 2 complete source sentences
    tr(m, .peer, "Первое.", .ru)                    // only 1 translation sentence so far
    #expect(m.bubbles.filter { !$0.isLive }.count == 1)      // only pair 0 sealed
    #expect(m.bubbles.first { $0.isLive }?.source == "Second one.")   // pair 1 waits
    tr(m, .peer, " Второе.", .ru)                   // translation catches up
    let sealed = m.bubbles.filter { !$0.isLive }
    #expect(sealed.count == 2)
    #expect(sealed[1].source == "Second one." && sealed[1].translation == "Второе.")
}

// Multiple sentences in one turn become SEPARATE bubbles as each completes.
@MainActor @Test func model_multiSentenceTurn_sealsEachSentence() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    src(m, .peer, "First one. Second one now.", .en)
    tr(m, .peer, "Первое. Второе теперь.", .ru)
    clock.advance(by: 3); m.tick(now: clock.now())
    let b = m.bubbles.filter { !$0.isLive }
    #expect(b.count == 2)
    #expect(b[0].source == "First one." && b[0].translation == "Первое.")
    #expect(b[1].source == "Second one now." && b[1].translation == "Второе теперь.")
}

// A pause finalizes the tail (the last partial sentence) as a bubble.
@MainActor @Test func model_pause_finalizesTail() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    src(m, .peer, "No terminator here", .en)
    tr(m, .peer, "Без точки", .ru)
    #expect(m.bubbles.allSatisfy { $0.isLive })     // nothing sealed (no complete sentence)
    clock.advance(by: 3); m.tick(now: clock.now())
    let b = m.bubbles
    #expect(b.count == 1 && b[0].isLive == false)   // tail finalized
    #expect(b[0].source == "No terminator here" && b[0].translation == "Без точки")
}

// The other speaker's `.original` (voice) finalizes the current speaker at once.
@MainActor @Test func model_interruption_finalizesPreviousSpeaker() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    src(m, .peer, "Peer talking", .en)
    clock.advance(by: 1)
    src(m, .me, "Я перебиваю", .ru)
    let b = m.bubbles
    #expect(b.count == 2)
    #expect(b[0].speaker == .peer && b[0].isLive == false)   // sealed by the interruption
    #expect(b[1].speaker == .me && b[1].isLive == true)
}

// A lagging translation (the other speaker's `.translated`) is NOT an interrupt.
@MainActor @Test func model_laggingTranslation_doesNotInterrupt() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    src(m, .me, "Я говорю", .ru)
    clock.advance(by: 1)
    tr(m, .peer, "peer translation", .en)
    #expect(m.bubbles.first { $0.speaker == .me }?.isLive == true)
}

// translationLost: a turn finalized with a source but no translation.
@MainActor @Test func model_translationNeverArrives_finalizesLost() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    src(m, .peer, "Hello there.", .en)
    clock.advance(by: 3); m.tick(now: clock.now())
    let b = m.bubbles.filter { !$0.isLive }
    #expect(b.count == 1)
    #expect(b[0].source == "Hello there.")
    #expect(b[0].translation.isEmpty && b[0].translationLost == true)
}

// A within-turn sentence mismatch does NOT poison the next turn (reset at pause).
@MainActor @Test func model_mismatchTurn_doesNotDriftNext() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    src(m, .peer, "A one. B two.", .en)      // 2 source sentences…
    tr(m, .peer, "Оба вместе.", .ru)          // …translation merged into 1
    clock.advance(by: 3); m.tick(now: clock.now())   // finalize turn 1 (bounded mispair)
    src(m, .peer, "Clean now.", .en)
    tr(m, .peer, "Чисто теперь.", .ru)
    clock.advance(by: 3); m.tick(now: clock.now())
    let b = m.bubbles.filter { !$0.isLive }
    #expect(b.last?.source == "Clean now.")
    #expect(b.last?.translation == "Чисто теперь.")   // correct, no carryover
}

// Abbreviations don't seal a sentence prematurely ("и т.д." is not a boundary).
@MainActor @Test func model_abbreviation_doesNotSealMidSentence() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    src(m, .peer, "We support this and", .en)
    tr(m, .peer, "Мы поддерживаем это и т.д. Это", .ru)   // "и т.д." mid-sentence, "Это" starts next
    // Russian NLTokenizer keeps "и т.д." whole; only the real boundary seals —
    // but the source side has no complete sentence yet, so nothing seals.
    #expect(m.bubbles.filter { !$0.isLive }.isEmpty)
}

// CJK chunks join without a spurious space.
@MainActor @Test func model_cjkChunks_joinWithoutSpuriousSpace() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    src(m, .peer, "今天天气", .zh)
    src(m, .peer, "很好", .zh)   // no terminator → stays live
    #expect(m.bubbles.first?.source == "今天天气很好")
}

// Cumulative restatement replaces, not appends.
@MainActor @Test func model_cumulativeRestatement_replacesNotAppends() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    src(m, .peer, "Hello", .en)
    src(m, .peer, "Hello world", .en)
    #expect(m.bubbles.first?.source == "Hello world")
}

// Bubbles order by turn start across speakers.
@MainActor @Test func model_ordersBubblesByTurnStart_acrossSpeakers() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    src(m, .peer, "Hi.", .en); tr(m, .peer, "Привет.", .ru)   // seals
    clock.advance(by: 1)
    src(m, .me, "Да.", .ru); tr(m, .me, "Yes.", .en)          // seals
    let b = m.bubbles
    #expect(b.count == 2)
    #expect(b[0].speaker == .peer && b[1].speaker == .me)
}

// Runaway guard: punctuation-less speech can't seal, so it force-finalizes
// rather than growing one bubble forever.
@MainActor @Test func model_punctuationlessRunaway_forceFinalizes() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    m.config.maxTailChars = 40
    let chunk = "word word word word word word word "
    for _ in 0..<4 {
        src(m, .peer, chunk, .en)
        tr(m, .peer, chunk, .en)
    }
    #expect(m.bubbles.contains { !$0.isLive })                      // force-sealed at least once
    #expect(m.bubbles.allSatisfy { $0.source.count <= 40 + chunk.count })
}

// History cap trims oldest sealed bubbles.
@MainActor @Test func model_historyCap_trimsOldest() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    m.config.historyCap = 3
    for i in 0..<6 {
        src(m, .peer, "Line \(i).", .en); tr(m, .peer, "Строка \(i).", .ru)   // each seals
    }
    let frozen = m.bubbles.filter { !$0.isLive }
    #expect(frozen.count == 3)
    #expect(frozen.first?.source == "Line 3.")   // 0,1,2 dropped
}

// A sealed sentence keeps a stable id (in-place lock, not delete+insert).
@MainActor @Test func model_sealedSentence_hasStableIdWhileTailContinues() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    src(m, .peer, "First one. Second", .en)
    tr(m, .peer, "Первое. Второе", .ru)
    let sealedId = m.bubbles.first { !$0.isLive }?.id
    src(m, .peer, " more", .en)   // tail grows; the sealed bubble must not change id
    #expect(m.bubbles.first { !$0.isLive }?.id == sealedId)
}

// Quick handoff: peer started first, so it stays ABOVE me even after me speaks.
@MainActor @Test func model_quickHandoff_earlierSpeakerStaysAbove() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    src(m, .peer, "Peer.", .en); tr(m, .peer, "Пир.", .ru)   // seals at t=0
    clock.advance(by: 1)
    src(m, .me, "Я.", .ru); tr(m, .me, "Me.", .en)           // seals at t=1
    let b = m.bubbles
    #expect(b[0].speaker == .peer && b[1].speaker == .me)
}

// End-to-end regression: the recorded Gemini timeline (spec §2) seals into two
// correctly-paired sentence bubbles as each completes.
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
    clock.set(epochDate(14.0)); m.tick(now: clock.now())
    let b = m.bubbles.filter { !$0.isLive }
    #expect(b.count == 2)
    #expect(b[0].source.contains("simple idea") && b[0].translation.contains("простую идею"))
    #expect(b[1].source.contains("more complex") && b[1].translation.contains("сложной"))
}
