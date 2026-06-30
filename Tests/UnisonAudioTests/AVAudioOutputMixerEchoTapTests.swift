import AVFoundation
import Testing
@testable import UnisonAudio
import UnisonDomain

@Test func echoFrame_fromFloatBuffer_isMono48kF32() throws {
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                            sampleRate: 48_000, channels: 1, interleaved: false)!
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4)!
    buf.frameLength = 4
    for i in 0..<4 { buf.floatChannelData![0][i] = Float(i) * 0.1 }

    let frame = try #require(AVAudioOutputMixer.echoFrame(from: buf))
    #expect(frame.sampleRate == 48_000)
    #expect(frame.channels == 1)
    #expect(frame.format == .float32)
    #expect(frame.sampleCount == 4)
}
