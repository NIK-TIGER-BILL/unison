import Foundation
import AVFoundation
import CoreAudio
import UnisonDomain

public final class AVAudioOutputMixer: AudioOutputMixer, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let translatedPlayer = AVAudioPlayerNode()
    private let originalPlayer = AVAudioPlayerNode()
    private let mixer: AVAudioMixerNode

    public init() {
        self.mixer = engine.mainMixerNode
    }

    public func start(deviceUID: String?) async throws {
        engine.attach(translatedPlayer)
        engine.attach(originalPlayer)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        engine.connect(translatedPlayer, to: mixer, format: format)
        engine.connect(originalPlayer, to: mixer, format: format)

        if let uid = deviceUID, let deviceID = audioDeviceID(forUID: uid) {
            var id = deviceID
            AudioUnitSetProperty(
                engine.outputNode.audioUnit!,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        translatedPlayer.volume = 1.0
        originalPlayer.volume = 0.2

        try engine.start()
        translatedPlayer.play()
        originalPlayer.play()
    }

    public func playTranslated(_ frames: AsyncStream<AudioFrame>) async {
        for await frame in frames {
            schedule(frame: frame, on: translatedPlayer)
        }
    }

    public func playOriginal(_ frames: AsyncStream<AudioFrame>) async {
        for await frame in frames {
            schedule(frame: frame, on: originalPlayer)
        }
    }

    public func setOriginalGain(_ gain: Float) {
        originalPlayer.volume = min(max(gain, 0), 1)
    }

    public func stop() {
        translatedPlayer.stop()
        originalPlayer.stop()
        engine.stop()
    }

    private func schedule(frame: AudioFrame, on player: AVAudioPlayerNode) {
        guard frame.format == .float32 else { return }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(frame.sampleRate),
            channels: AVAudioChannelCount(frame.channels),
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(frame.sampleCount)
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buf.frameLength = frameCount
        frame.pcm.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self).baseAddress!
            memcpy(buf.floatChannelData![0], p, frame.pcm.count)
        }
        player.scheduleBuffer(buf, completionHandler: nil)
    }
}
