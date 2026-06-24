import Foundation

/// Pure size-rotation policy. Returns ids to evict (oldest first) so the
/// total drops to or below `limitMB`. Protections:
///  - `limitMB <= 0` → no rotation (empty result)
///  - pinned meetings are never evicted
///  - the newest meeting (max `startedAt`) is never evicted
///  - whole meetings only; a single oversized record is left in place
public func meetingsToEvict(_ summaries: [MeetingSummary], limitMB: Int) -> [UUID] {
    guard limitMB > 0 else { return [] }
    let limit = limitMB * 1024 * 1024
    var total = summaries.reduce(0) { $0 + $1.sizeBytes }
    guard total > limit else { return [] }

    let newestID = summaries.max(by: { $0.startedAt < $1.startedAt })?.id
    let candidates = summaries
        .filter { !$0.pinned && $0.id != newestID }
        .sorted { $0.startedAt < $1.startedAt }

    var evicted: [UUID] = []
    for c in candidates where total > limit {
        evicted.append(c.id)
        total -= c.sizeBytes
    }
    return evicted
}
