import Testing
@testable import UnisonDomain

@Test func audioFrame_storesPCMData() {
    let data = zeroData(count: 2400 * 2)
    let frame = AudioFrame(pcm: data, sampleRate: 24_000, channels: 1, format: .int16)
    #expect(frame.pcm.count == 4800)
    #expect(frame.sampleRate == 24_000)
    #expect(frame.format == .int16)
}

@Test func audioFrame_durationMs() {
    let frame = AudioFrame(pcm: zeroData(count: 2400 * 2), sampleRate: 24_000, channels: 1, format: .int16)
    #expect(abs(frame.durationMs - 100) < 0.1)
}

@Test func audioDevice_equality() {
    let a = AudioDevice(uid: "BlackHole2ch_UID", name: "BlackHole 2ch", kind: .output)
    let b = AudioDevice(uid: "BlackHole2ch_UID", name: "BlackHole 2ch (renamed)", kind: .output)
    #expect(a == b)
}
