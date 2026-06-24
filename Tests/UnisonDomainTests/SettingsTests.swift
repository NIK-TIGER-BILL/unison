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

@Test func settings_tapScopeMode_defaultsToAllExcept() {
    #expect(Settings().tapScopeMode == .allExcept)
    #expect(Settings().includedTapBundleIDs.isEmpty)
}

@Test func settings_activeTapBundleIDs_followsMode() {
    var s = Settings()
    s.excludedTapBundleIDs = ["com.exclude.one"]
    s.includedTapBundleIDs = ["com.include.one"]
    s.tapScopeMode = .allExcept
    #expect(s.activeTapBundleIDs == ["com.exclude.one"])
    s.tapScopeMode = .onlySelected
    #expect(s.activeTapBundleIDs == ["com.include.one"])
}

@Test func settings_scopeFields_codableRoundTrip() throws {
    var s = Settings()
    s.tapScopeMode = .onlySelected
    s.includedTapBundleIDs = ["com.apple.Music"]
    s.excludedTapBundleIDs = ["com.spotify.client"]
    let decoded: Settings = try encodeDecode(s)
    #expect(decoded == s)
}

@Test func settings_scopeFields_legacyJSONDecodesToDefaults() throws {
    let legacyJSON = """
    {
        "sessionMode": "call",
        "languagePair": { "mine": "ru", "peer": "en" },
        "excludedTapBundleIDs": ["com.spotify.client"],
        "originalMixVolume": 0.2
    }
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(Settings.self, from: legacyJSON)
    #expect(decoded.tapScopeMode == .allExcept)
    #expect(decoded.includedTapBundleIDs.isEmpty)
    #expect(decoded.excludedTapBundleIDs == ["com.spotify.client"])
}
