import Foundation
import Testing
@testable import UnisonDomain

private func summary(_ id: UUID = UUID(), daysAgo: Double, sizeMB: Int, pinned: Bool = false) -> MeetingSummary {
    MeetingSummary(
        id: id, title: nil,
        startedAt: Date(timeIntervalSince1970: 2_000_000_000 - daysAgo * 86_400),
        durationSeconds: 60, mode: .call,
        languagePair: LanguagePair(mine: .ru, peer: .en),
        lineCount: 1, preview: "", pinned: pinned, sizeBytes: sizeMB * 1024 * 1024
    )
}

@Test func rotation_underLimit_evictsNothing() {
    let s = [summary(daysAgo: 1, sizeMB: 10), summary(daysAgo: 2, sizeMB: 10)]
    #expect(meetingsToEvict(s, limitMB: 50).isEmpty)
}

@Test func rotation_zeroLimit_evictsNothing() {
    let s = [summary(daysAgo: 1, sizeMB: 100), summary(daysAgo: 2, sizeMB: 100)]
    #expect(meetingsToEvict(s, limitMB: 0).isEmpty)
}

@Test func rotation_overLimit_evictsOldestFirst() {
    let newest = summary(daysAgo: 1, sizeMB: 20)
    let mid = UUID(); let old = UUID()
    let s = [newest, summary(mid, daysAgo: 2, sizeMB: 20), summary(old, daysAgo: 3, sizeMB: 20)]
    #expect(meetingsToEvict(s, limitMB: 50) == [old])   // 60MB → drop oldest 20 → 40 ≤ 50
}

@Test func rotation_neverEvictsNewest() {
    let newest = summary(daysAgo: 1, sizeMB: 60)         // alone exceeds the 50MB limit
    let s = [newest, summary(daysAgo: 2, sizeMB: 5)]
    #expect(!meetingsToEvict(s, limitMB: 50).contains(newest.id))
}

@Test func rotation_neverEvictsPinned() {
    let pinnedOld = summary(daysAgo: 5, sizeMB: 30, pinned: true)
    let newest = summary(daysAgo: 1, sizeMB: 30)
    let mid = UUID()
    let s = [pinnedOld, newest, summary(mid, daysAgo: 2, sizeMB: 30)]   // 90MB
    let evicted = meetingsToEvict(s, limitMB: 50)
    #expect(!evicted.contains(pinnedOld.id))
    #expect(evicted.contains(mid))
}
