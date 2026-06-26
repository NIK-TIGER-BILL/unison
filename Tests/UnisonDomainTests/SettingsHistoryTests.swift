import Foundation
import Testing
@testable import UnisonDomain

@Test func settings_history_defaults() {
    #expect(Settings.default.saveHistoryEnabled == true)
    #expect(Settings.default.historySizeLimitMB == 50)
}

@Test func settings_history_codableRoundTrip() throws {
    var s = Settings.default
    s.saveHistoryEnabled = false
    s.historySizeLimitMB = 100
    let decoded: Settings = try encodeDecode(s)
    #expect(decoded.saveHistoryEnabled == false)
    #expect(decoded.historySizeLimitMB == 100)
}

@Test func settings_history_legacyDecodeUsesDefaults() throws {
    let legacy = """
    {"sessionMode":"call","languagePair":{"mine":"ru","peer":"en"},"originalMixVolume":0.2}
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(Settings.self, from: legacy)
    #expect(decoded.saveHistoryEnabled == true)
    #expect(decoded.historySizeLimitMB == 50)
}
