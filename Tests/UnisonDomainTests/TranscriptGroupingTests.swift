import Foundation
import Testing
@testable import UnisonDomain
@testable import UnisonUI

// MARK: - groupDisplayBubbles

@Test func groupDisplay_bucketsBySpeaker_flagsAndLive() {
    let bubbles = [
        DisplayBubble(id: freshUUID(), speaker: .peer, primaryText: "A", secondaryText: "",
                      isLive: false, translationLost: false, lastActivityAt: epochDate(0)),
        DisplayBubble(id: freshUUID(), speaker: .peer, primaryText: "B", secondaryText: "",
                      isLive: false, translationLost: false, lastActivityAt: epochDate(0)),
        DisplayBubble(id: freshUUID(), speaker: .me, primaryText: "C", secondaryText: "",
                      isLive: true, translationLost: false, lastActivityAt: epochDate(0))
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
