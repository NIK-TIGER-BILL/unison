import Foundation
@testable import UnisonDomain

func sampleEntry(_ speaker: Speaker = .peer, _ translated: String = "Привет") -> TranscriptEntry {
    TranscriptEntry(
        id: UUID(), speaker: speaker, originalText: "Hi",
        translatedText: translated, sourceLanguage: .en, targetLanguage: .ru,
        timestamp: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

func sampleRecord(
    title: String? = nil,
    mode: SessionMode = .call,
    entries: [TranscriptEntry] = []
) -> MeetingRecord {
    MeetingRecord(
        id: UUID(), title: title,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        endedAt: Date(timeIntervalSince1970: 1_700_001_920),   // +1920s
        mode: mode, languagePair: LanguagePair(mine: .ru, peer: .en),
        entries: entries
    )
}

/// Record with a controllable start time (for ordering / rotation tests).
func recordAt(daysAgo: Double, pinned: Bool = false,
              entries: [TranscriptEntry] = [sampleEntry()]) -> MeetingRecord {
    let start = Date(timeIntervalSince1970: 2_000_000_000 - daysAgo * 86_400)
    return MeetingRecord(
        id: UUID(), title: nil, startedAt: start,
        endedAt: start.addingTimeInterval(60), mode: .call,
        languagePair: LanguagePair(mine: .ru, peer: .en),
        entries: entries, pinned: pinned
    )
}
