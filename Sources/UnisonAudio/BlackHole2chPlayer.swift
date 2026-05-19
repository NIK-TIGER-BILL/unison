import Foundation
import AVFoundation
import CoreAudio
import UnisonDomain

public final class BlackHole2chPlayer: AudioPlayer, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let registry: CoreAudioDeviceRegistry
    private var started = false

    public init(registry: CoreAudioDeviceRegistry) {
        self.registry = registry
    }

    public func play(_ frames: AsyncStream<AudioFrame>) async {
        do { try startIfNeeded() } catch { return }
        for await frame in frames {
            schedule(frame)
        }
    }

    public func stop() {
        player.stop()
        engine.stop()
        started = false
    }

    private func startIfNeeded() throws {
        guard !started else { return }
        guard let bh2 = registry.findBlackHole2ch() else {
            throw NSError(domain: "BlackHole2chPlayer", code: -1)
        }
        engine.attach(player)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        engine.connect(player, to: engine.mainMixerNode, format: format)

        if let deviceID = audioDeviceID(forUID: bh2.uid) {
            var id = deviceID
            AudioUnitSetProperty(
                engine.outputNode.audioUnit!,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }
        try engine.start()
        player.play()
        started = true
    }

    private func schedule(_ frame: AudioFrame) {
        guard frame.format == .float32 else { return }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(frame.sampleRate),
            channels: AVAudioChannelCount(frame.channels),
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(frame.sampleCount)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buf.frameLength = frameCount
        frame.pcm.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self).baseAddress!
            memcpy(buf.floatChannelData![0], p, frame.pcm.count)
        }
        player.scheduleBuffer(buf, completionHandler: nil)
    }
}
