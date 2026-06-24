import Foundation
import Testing
@testable import UnisonDomain

@Test func meetingRecord_exportText_includesTitleAndLines() {
    let rec = MeetingRecord(
        id: UUID(), title: "Планёрка",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        endedAt: Date(timeIntervalSince1970: 1_700_000_060),
        mode: .call, languagePair: LanguagePair(mine: .ru, peer: .en),
        entries: [
            sampleEntry(.peer, "Привет"),
            sampleEntry(.me, "Здравствуйте")
        ])
    let text = rec.exportText()
    #expect(text.contains("Планёрка"))
    #expect(text.contains("Привет"))
    #expect(text.contains("Здравствуйте"))
}

@Test func meetingRecord_exportText_usesDisplayTitleWhenUntitled() {
    let rec = MeetingRecord(
        id: UUID(), title: nil,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        endedAt: Date(timeIntervalSince1970: 1_700_000_060),
        mode: .listen, languagePair: LanguagePair(mine: .ru, peer: .en),
        entries: [sampleEntry()])
    #expect(rec.exportText().hasPrefix("Прослушивание · "))
}
