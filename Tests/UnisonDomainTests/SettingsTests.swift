import Testing
import Foundation
@testable import UnisonDomain

@Test func settings_defaultValues() {
    let s = Settings.default
    #expect(s.sessionMode == .call)
    #expect(s.languagePair == .default)
    #expect(s.inputDeviceUID == nil)
    #expect(s.outputDeviceUID == nil)
    #expect(abs(s.originalMixVolume - 0.2) < 0.01)
}

@Test func settings_clampsOriginalMixVolume() {
    var s = Settings.default
    s.originalMixVolume = 1.5
    #expect(s.originalMixVolume == 1.0)
    s.originalMixVolume = -0.5
    #expect(s.originalMixVolume == 0.0)
}

@Test func settings_codableRoundTrip() throws {
    var s = Settings.default
    s.sessionMode = .listen
    s.languagePair = LanguagePair(mine: .ja, peer: .ko)
    s.inputDeviceUID = "USB-mic-uid"
    s.originalMixVolume = 0.5
    let decoded: Settings = try encodeDecode(s)
    #expect(decoded == s)
}

@Test func settings_excludedTapBundleIDs_defaultsToEmpty() {
    let s = Settings()
    #expect(s.excludedTapBundleIDs.isEmpty)
}

@Test func settings_excludedTapBundleIDs_codableRoundTrip() throws {
    var s = Settings()
    s.excludedTapBundleIDs = ["com.spotify.client", "com.apple.Music"]
    let decoded: Settings = try encodeDecode(s)
    #expect(decoded.excludedTapBundleIDs == ["com.spotify.client", "com.apple.Music"])
}

@Test func settings_excludedTapBundleIDs_codableRoundTrip_missingFieldDecodesEmpty() throws {
    // Settings persisted before this field existed must decode to an empty array.
    let legacyJSON = """
    {
        "sessionMode": "call",
        "languagePair": { "mine": "ru", "peer": "en" },
        "originalMixVolume": 0.2
    }
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(Settings.self, from: legacyJSON)
    #expect(decoded.excludedTapBundleIDs.isEmpty)
}
