import Foundation
import Testing
@testable import UnisonDomain
@testable import UnisonUI

// MARK: - Helpers

private func peerBubble(_ primary: String, isLive: Bool = false, at seconds: TimeInterval) -> DisplayBubble {
    DisplayBubble(id: freshUUID(), speaker: .peer, primaryText: primary, secondaryText: "",
                  isLive: isLive, translationLost: false, lastActivityAt: epochDate(seconds))
}

// MARK: - Whole-unit expiry

// A frozen bubble stays for its full `window`, then vanishes as ONE unit.
@MainActor
@Test func feed_frozenBubble_expiresWholeAfterWindow() {
    let feed = TranscriptFeed(config: .init(window: 30, maxBubbles: 6))
    let b = peerBubble("Привет.", at: 0) // committed at t=0
    #expect(feed.visible([b], now: epochDate(0)).count == 1)
    #expect(feed.visible([b], now: epochDate(29)).count == 1)
    #expect(feed.visible([b], now: epochDate(31)).isEmpty)
}

// MARK: - Live bubble

@MainActor
@Test func feed_liveBubble_neverExpiresWhileActive() {
    let feed = TranscriptFeed(config: .init(window: 30, maxBubbles: 6))
    let b = peerBubble("Привет", isLive: true, at: 0) // live
    let v = feed.visible([b], now: epochDate(100))     // long past window, but live
    #expect(v.count == 1)
    #expect(v[0].isLive == true)
}

// A bubble whose last activity is recent stays visible regardless of an
// earlier freeze — lifetime is measured from `lastActivityAt`, so a bubble the
// model re-committed with a fresh timestamp can't vanish against a stale one.
@MainActor
@Test func feed_freshLastActivity_staysVisible() {
    let feed = TranscriptFeed(config: .init(window: 30, maxBubbles: 6))
    let revived = peerBubble("Привет.", at: 40)
    let v = feed.visible([revived], now: epochDate(41))
    #expect(v.count == 1)
    #expect(v[0].isLive == false)
}

// MARK: - Count cap

@MainActor
@Test func feed_capsToMaxBubbles_keepingNewest() {
    let feed = TranscriptFeed(config: .init(window: 30, maxBubbles: 6))
    // Eight frozen bubbles; the cap keeps the last six.
    let bubbles = (0..<8).map { i in peerBubble("П\(i).", at: 0) }
    let v = feed.visible(bubbles, now: epochDate(0))
    #expect(v.count == 6)
    #expect(v.first?.primaryText == "П2.") // П0, П1 dropped
    #expect(v.last?.primaryText == "П7.")
}

// The cap must NEVER drop a live bubble, even when it sorts to the front (a
// long-running live segment started before a burst of frozen bubbles from the
// other speaker). The actively-forming bubble must not vanish.
@MainActor
@Test func feed_capNeverDropsLiveBubble() {
    let feed = TranscriptFeed(config: .init(window: 30, maxBubbles: 6))
    var all: [DisplayBubble] = [peerBubble("live", isLive: true, at: 0)]  // front, oldest
    for i in 0..<6 { all.append(peerBubble("f\(i).", at: 10)) }            // 6 newer frozen
    let v = feed.visible(all, now: epochDate(11))
    #expect(v.count == 6)
    #expect(v.first?.primaryText == "live")            // live stayed at the front
    #expect(v.filter { !$0.isLive }.count == 5)        // cap trimmed a FROZEN one instead
}
