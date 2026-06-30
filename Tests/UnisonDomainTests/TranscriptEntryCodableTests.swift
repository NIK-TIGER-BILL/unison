import Foundation
import Testing
@testable import UnisonDomain

@Test func transcriptEntry_codableRoundTrip_preservesAllFields() throws {
    let entry = TranscriptEntry(
        id: UUID(),
        speaker: .peer,
        originalText: "Hello",
        translatedText: "Привет",
        sourceLanguage: .en,
        targetLanguage: .ru,
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        lastActivityAt: Date(timeIntervalSince1970: 1_700_000_005),
        translationAtRisk: true
    )
    let decoded: TranscriptEntry = try encodeDecode(entry)
    #expect(decoded == entry)
    #expect(decoded.edited == false)
}

@Test func transcriptEntry_edited_roundTrips() throws {
    var entry = TranscriptEntry(
        id: UUID(), speaker: .me,
        originalText: nil, translatedText: "x",
        sourceLanguage: nil, targetLanguage: .en,
        timestamp: Date(timeIntervalSince1970: 1)
    )
    entry.edited = true
    let decoded: TranscriptEntry = try encodeDecode(entry)
    #expect(decoded.edited == true)
}
