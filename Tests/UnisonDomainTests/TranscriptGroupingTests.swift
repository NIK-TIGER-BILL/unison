import Foundation
import Testing
@testable import UnisonDomain
@testable import UnisonUI

// MARK: - Timestamped entry builder (for liveBubbles tests)

private func makeEntryAt(
    _ speaker: Speaker,
    original: String?,
    translated: String,
    at seconds: TimeInterval,
    id: UUID = freshUUID()
) -> TranscriptEntry {
    TranscriptEntry(
        id: id,
        speaker: speaker,
        originalText: original,
        translatedText: translated,
        sourceLanguage: speaker == .me ? .ru : .en,
        targetLanguage: speaker == .me ? .en : .ru,
        timestamp: epochDate(seconds),
        lastActivityAt: epochDate(seconds)
    )
}

// MARK: - liveBubbles (commit-and-freeze derivation)

@Test func liveBubbles_completedSentence_freezesNoLive() {
    let e = makeEntryAt(.peer, original: "Hi there.", translated: "Привет.", at: 0)
    let b = TranscriptGrouping.liveBubbles(entries: [e], now: epochDate(0))
    #expect(b.count == 1)
    #expect(b[0].isLive == false)
    #expect(b[0].primaryText == "Привет.")     // peer: primary = translation
    #expect(b[0].secondaryText == "Hi there.")
}

@Test func liveBubbles_incompleteTranslation_staysLive() {
    let e = makeEntryAt(.peer, original: "Hi there.", translated: "Прив", at: 0)
    let b = TranscriptGrouping.liveBubbles(entries: [e], now: epochDate(0))
    #expect(b.count == 1)
    #expect(b[0].isLive == true)
    #expect(b[0].primaryText == "Прив")
    #expect(b[0].secondaryText == "Hi there.")
}

// Two finished utterances (separate entries) → two bubbles, each with its
// own matched pair.
@Test func liveBubbles_twoUtterances_twoBubbles() {
    let e1 = makeEntryAt(.peer, original: "One.", translated: "Раз.", at: 0)
    let e2 = makeEntryAt(.peer, original: "Two.", translated: "Два.", at: 0)
    let b = TranscriptGrouping.liveBubbles(entries: [e1, e2], now: epochDate(0))
    #expect(b.count == 2)
    #expect(b[0].primaryText == "Раз.")
    #expect(b[0].secondaryText == "One.")
    #expect(b[1].primaryText == "Два.")
    #expect(b[1].secondaryText == "Two.")
}

// The crux: a bubble keeps the SAME id from live → frozen, so it locks in
// place instead of re-inserting (no "pop", no re-init).
@Test func liveBubbles_liveThenFrozen_keepsStableId() {
    let id = freshUUID()
    let incomplete = makeEntryAt(.peer, original: "Hi there.", translated: "Прив", at: 0, id: id)
    let liveId = TranscriptGrouping.liveBubbles(entries: [incomplete], now: epochDate(0))[0].id
    let complete = makeEntryAt(.peer, original: "Hi there.", translated: "Привет.", at: 0, id: id)
    let frozen = TranscriptGrouping.liveBubbles(entries: [complete], now: epochDate(0))[0]
    #expect(frozen.isLive == false)
    #expect(frozen.id == liveId)
}

// Translation lags: the original is finished but its translation is still
// streaming (no terminator) → the bubble stays LIVE so it fills in, rather
// than freezing half-translated.
@Test func liveBubbles_translationLag_utteranceStaysLive() {
    let e = makeEntryAt(.peer, original: "One sentence.", translated: "Одно", at: 0)
    let b = TranscriptGrouping.liveBubbles(entries: [e], now: epochDate(0))
    #expect(b.count == 1)
    #expect(b[0].isLive == true)
    #expect(b[0].secondaryText == "One sentence.")
    #expect(b[0].primaryText == "Одно")
}

// A speaker change closes the previous run: its trailing fragment freezes
// even without a terminator (the utterance is definitively over).
@Test func liveBubbles_speakerChange_closesPrevRun() {
    let p = makeEntryAt(.peer, original: "Hi", translated: "Прив", at: 0)
    let m = makeEntryAt(.me, original: "Yes", translated: "", at: 1)
    let b = TranscriptGrouping.liveBubbles(entries: [p, m], now: epochDate(1))
    #expect(b.count == 2)
    #expect(b[0].isLive == false)
    #expect(b[0].primaryText == "Прив")
    #expect(b[1].isLive == true)
    #expect(b[1].primaryText == "Yes")          // me: primary = original
}

// A run that goes quiet for `finalizeAfter` freezes wholesale.
@Test func liveBubbles_inactivity_freezesLastRun() {
    let e = makeEntryAt(.peer, original: "Hi", translated: "Прив", at: 0)
    let active = TranscriptGrouping.liveBubbles(entries: [e], now: epochDate(1))
    #expect(active[0].isLive == true)
    let stale = TranscriptGrouping.liveBubbles(entries: [e], now: epochDate(5))
    #expect(stale[0].isLive == false)
}

// Clause-fragments across separate entries reconstruct into one sentence.
@Test func liveBubbles_concatenatesRunAcrossEntries() {
    let e1 = makeEntryAt(.peer, original: "Sometimes I'm", translated: "", at: 0)
    let e2 = makeEntryAt(.peer, original: "halfway through it.", translated: "Иногда я на середине.", at: 0)
    let b = TranscriptGrouping.liveBubbles(entries: [e1, e2], now: epochDate(0))
    #expect(b.count == 1)
    #expect(b[0].isLive == false)
    #expect(b[0].secondaryText == "Sometimes I'm halfway through it.")
    #expect(b[0].primaryText == "Иногда я на середине.")
}

// Regression: reconstructing the run and re-splitting by sentence mispaired
// original↔translation whenever the two languages' sentence boundaries
// differ (RU showed a sentence ahead of the EN in the same bubble). Each
// entry's own (original, translation) pair — which the store matches per
// turn — must stay together.
@Test func liveBubbles_preservesPerEntryPairing() {
    let e1 = makeEntryAt(.peer, original: "And there is also the gateway.", translated: "И есть также шлюз", at: 0)
    let e2 = makeEntryAt(.peer, original: "The gateway is always running.", translated: "Шлюз всегда работает.", at: 0)
    let b = TranscriptGrouping.liveBubbles(entries: [e1, e2], now: epochDate(0))
    #expect(b.count == 2)
    #expect(b[0].secondaryText == "And there is also the gateway.")
    #expect(b[0].primaryText == "И есть также шлюз")
    #expect(b[1].secondaryText == "The gateway is always running.")
    #expect(b[1].primaryText == "Шлюз всегда работает.")
}

// Regression: an abbreviation like "и т.д." (etc.) must NOT be split into a
// second bubble — the bubble shows the utterance whole, unsplit.
@Test func liveBubbles_abbreviationDoesNotSplitBubble() {
    let e = makeEntryAt(.peer, original: "We support Telegram, email, and more.",
                        translated: "Мы поддерживаем Telegram, почту, Slack и т.д.", at: 0)
    let b = TranscriptGrouping.liveBubbles(entries: [e], now: epochDate(0))
    #expect(b.count == 1)
    #expect(b[0].primaryText.contains("и т.д."))
}

// MARK: - groupDisplayBubbles

@Test func groupDisplay_bucketsBySpeaker_flagsAndLive() {
    let bubbles = [
        DisplayBubble(id: freshUUID(), speaker: .peer, primaryText: "A", secondaryText: "", isLive: false, translationLost: false, lastActivityAt: epochDate(0)),
        DisplayBubble(id: freshUUID(), speaker: .peer, primaryText: "B", secondaryText: "", isLive: false, translationLost: false, lastActivityAt: epochDate(0)),
        DisplayBubble(id: freshUUID(), speaker: .me, primaryText: "C", secondaryText: "", isLive: true, translationLost: false, lastActivityAt: epochDate(0))
    ]
    let g = TranscriptGrouping.groupDisplayBubbles(bubbles)
    #expect(g.count == 2)
    #expect(g[0].speaker == .peer)
    #expect(g[0].bubbles.count == 2)
    #expect(g[0].bubbles.first?.isFirstInGroup == true)
    #expect(g[0].bubbles.last?.isLastInGroup == true)
    #expect(g[1].speaker == .me)
    #expect(g[1].bubbles[0].isLive == true)
}

@Test func groupDisplay_empty_returnsEmpty() {
    #expect(TranscriptGrouping.groupDisplayBubbles([]).isEmpty)
}
