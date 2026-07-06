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

// The lifetime clock starts when the bubble FREEZES, not when its text
// first appeared live.
@MainActor
@Test func feed_lifetimeStartsAtFreeze_notFirstAppearance() {
    let feed = TranscriptFeed(config: .init(finalizeAfter: 2.5, window: 30, maxBubbles: 6))
    let e = peerEntry("Hi", "Прив", at: 0) // no terminator → live while active
    #expect(feed.visibleBubbles(entries: [e], now: epochDate(0)).first?.isLive == true)
    // Goes quiet → freezes at t=10 (inactivity), so its window runs 10…40.
    let atFreeze = feed.visibleBubbles(entries: [e], now: epochDate(10))
    #expect(atFreeze.count == 1)
    #expect(atFreeze[0].isLive == false)
    #expect(feed.visibleBubbles(entries: [e], now: epochDate(39)).count == 1)
    #expect(feed.visibleBubbles(entries: [e], now: epochDate(41)).isEmpty)
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

// The freeze-time memo must not accumulate across sessions: once the store
// is cleared (entries empty), stale stamps are pruned so it can't leak for
// the app's whole lifetime.
@MainActor
@Test func feed_finalizedAt_prunedWhenBubblesGone() {
    let feed = TranscriptFeed(config: .init(finalizeAfter: 2.5, window: 30, maxBubbles: 6))
    let e = peerEntry("Hi.", "Привет.", at: 0) // completed → freezes → stamped
    _ = feed.visibleBubbles(entries: [e], now: epochDate(0))
    #expect(feed.finalizedAt.count == 1)
    // New session: the store was cleared → no entries.
    _ = feed.visibleBubbles(entries: [], now: epochDate(1))
    #expect(feed.finalizedAt.isEmpty)
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
