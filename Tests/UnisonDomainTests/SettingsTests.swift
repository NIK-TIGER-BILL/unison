import Testing
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
