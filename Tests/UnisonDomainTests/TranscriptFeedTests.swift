import Foundation
import Testing
@testable import UnisonDomain
@testable import UnisonUI

// MARK: - Helpers

private func peerEntry(_ original: String, _ translated: String, at seconds: TimeInterval) -> TranscriptEntry {
    TranscriptEntry(
        id: freshUUID(),
        speaker: .peer,
        originalText: original,
        translatedText: translated,
        sourceLanguage: .en,
        targetLanguage: .ru,
        timestamp: epochDate(seconds),
        lastActivityAt: epochDate(seconds)
    )
}

// MARK: - Whole-unit expiry

// A frozen bubble stays for its full `window`, then vanishes as ONE unit.
@MainActor
@Test func feed_frozenBubble_expiresWholeAfterWindow() {
    let feed = TranscriptFeed(config: .init(finalizeAfter: 2.5, window: 30, maxBubbles: 6))
    let e = peerEntry("Hi.", "Привет.", at: 0) // completed → freezes at t=0
    #expect(feed.visibleBubbles(entries: [e], now: epochDate(0)).count == 1)
    #expect(feed.visibleBubbles(entries: [e], now: epochDate(29)).count == 1)
    #expect(feed.visibleBubbles(entries: [e], now: epochDate(31)).isEmpty)
}

// MARK: - Live bubble

@MainActor
@Test func feed_liveBubble_neverExpiresWhileActive() {
    let feed = TranscriptFeed(config: .init(finalizeAfter: 2.5, window: 30, maxBubbles: 6))
    let e = peerEntry("Hi there", "Привет", at: 0) // incomplete translation → live
    let v = feed.visibleBubbles(entries: [e], now: epochDate(2)) // 2 < 2.5 → still live
    #expect(v.count == 1)
    #expect(v[0].isLive == true)
}

// MARK: - Count cap

// Regression (review round 2): a bubble that froze with a lagging
// translation, then is revived by a late `.translated` delta and re-settles,
// must NOT vanish from a stale freeze time — its lifetime resets on the new
// activity. (This is the exact "bubble disappears / re-initialises" failure
// the model is meant to prevent.)
@MainActor
@Test func feed_lateTranslationRevivesBubble_withFreshLifetime() {
    let feed = TranscriptFeed(config: .init(finalizeAfter: 2.5, window: 30, maxBubbles: 6))
    let id = freshUUID()
    func entry(_ translated: String, activeAt seconds: TimeInterval) -> TranscriptEntry {
        TranscriptEntry(
            id: id, speaker: .peer, originalText: "Hi there.", translatedText: translated,
            sourceLanguage: .en, targetLanguage: .ru,
            timestamp: epochDate(0), lastActivityAt: epochDate(seconds))
    }
    // Translation incomplete + run quiet → frozen around t=5.
    _ = feed.visibleBubbles(entries: [entry("Прив", activeAt: 0)], now: epochDate(5))
    #expect(feed.visibleBubbles(entries: [entry("Прив", activeAt: 0)], now: epochDate(29)).count == 1)
    // A late translation lands at t=40 (> window since first freeze) and
    // completes the sentence. The bubble must still be visible (fresh
    // lifetime), re-frozen — not expired against the old freeze time.
    let v = feed.visibleBubbles(entries: [entry("Привет.", activeAt: 40)], now: epochDate(41))
    #expect(v.count == 1)
    #expect(v[0].isLive == false)
}

@MainActor
@Test func feed_capsToMaxBubbles_keepingNewest() {
    let feed = TranscriptFeed(config: .init(finalizeAfter: 2.5, window: 30, maxBubbles: 6))
    // Eight finished utterances → eight bubbles; the cap keeps the last six.
    let entries = (0..<8).map { i in peerEntry("S\(i).", "П\(i).", at: 0) }
    let v = feed.visibleBubbles(entries: entries, now: epochDate(0))
    #expect(v.count == 6)
    #expect(v.first?.primaryText == "П2.") // П0, П1 dropped
    #expect(v.last?.primaryText == "П7.")
}
