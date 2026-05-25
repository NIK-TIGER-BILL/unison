import Foundation
import AVFoundation
import CoreAudio
import UnisonDomain

public final class AVAudioOutputMixer: AudioOutputMixer, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let translatedPlayer = AVAudioPlayerNode()
    private let originalPlayer = AVAudioPlayerNode()
    private let mixer: AVAudioMixerNode
    /// Latches on first successful `start(_:)` so the second start in a
    /// stop-restart cycle doesn't `engine.attach(_:)` already-attached
    /// nodes. `AVAudioEngine.attach` is documented to throw an Obj-C
    /// exception if the same node is attached twice — and Obj-C
    /// exceptions in Swift are non-recoverable. The previous version
    /// got away with it on this OS revision but the contract is
    /// fragile; latching makes it explicit. `stop()` deliberately
    /// does *not* detach (the engine reuses the same player instances
    /// on restart, so detach+reattach buys nothing but reset risk).
    private var attached = false

    public init() {
        self.mixer = engine.mainMixerNode
    }

    public func start(deviceUID: String?) async throws {
        if !attached {
            engine.attach(translatedPlayer)
            engine.attach(originalPlayer)
            attached = true
        }

        // Assign the requested output device before resolving formats so
        // AVAudioEngine can negotiate the mixer→output connection at the
        // device's native sample rate.
        if let uid = deviceUID, let deviceID = audioDeviceID(forUID: uid) {
            var id = deviceID
            AudioUnitSetProperty(
                engine.outputNode.audioUnit!,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        // Players feed 48 kHz F32 mono (the resampler pipeline target).
        // AVAudioEngine inserts a rate converter between the mixer and the
        // output node automatically when the device's hardware rate differs.
        let playerInput = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        engine.connect(translatedPlayer, to: mixer, format: playerInput)
        engine.connect(originalPlayer, to: mixer, format: playerInput)

        translatedPlayer.volume = 1.0
        originalPlayer.volume = 0.2

        do {
            try engine.start()
        } catch {
            throw NSError(
                domain: "AVAudioOutputMixer",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to start audio engine: \(error.localizedDescription)"]
            )
        }
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
