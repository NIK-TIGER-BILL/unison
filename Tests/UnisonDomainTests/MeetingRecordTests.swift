import Foundation
import Testing
@testable import UnisonDomain

@Test func meetingRecord_codableRoundTrip() throws {
    let rec = sampleRecord(title: "Синк", entries: [sampleEntry(), sampleEntry(.me, "Ок")])
    let decoded: MeetingRecord = try encodeDecode(rec)
    #expect(decoded == rec)
    #expect(decoded.schemaVersion == MeetingRecord.currentSchemaVersion)
}

@Test func meetingRecord_durationSeconds_computed() {
    #expect(sampleRecord().durationSeconds == 1920)
}

@Test func meetingRecord_displayTitle_usesCustomTitleWhenSet() {
    #expect(sampleRecord(title: "Синк с командой").displayTitle == "Синк с командой")
}

@Test func meetingRecord_displayTitle_autoForCall() {
    #expect(sampleRecord(title: nil, mode: .call).displayTitle.hasPrefix("Звонок · "))
}

@Test func meetingRecord_displayTitle_autoForListen_blankTitleFallsBack() {
    #expect(sampleRecord(title: "   ", mode: .listen).displayTitle.hasPrefix("Прослушивание · "))
}

@Test func meetingSummary_fromRecord_derivesFields() {
    var rec = sampleRecord(title: "T", entries: [sampleEntry(.peer, "Первая реплика"), sampleEntry(.me, "Вторая")])
    rec.pinned = true
    let s = MeetingSummary(record: rec, sizeBytes: 1234)
    #expect(s.lineCount == 2)
    #expect(s.preview == "Первая реплика")
    #expect(s.pinned == true)
    #expect(s.sizeBytes == 1234)
    #expect(s.durationSeconds == 1920)
}

@Test func meetingSummary_preview_truncatesLongFirstLine() {
    let long = String(repeating: "а", count: 200)
    let s = MeetingSummary(record: sampleRecord(entries: [sampleEntry(.peer, long)]), sizeBytes: 0)
    #expect(s.preview.count == 81)        // 80 chars + ellipsis
    #expect(s.preview.hasSuffix("…"))
}
