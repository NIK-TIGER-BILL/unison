import Foundation
import AVFoundation
import CoreAudio
import UnisonDomain

public final class BlackHoleSinkCapture: PeerAudioCapture, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let registry: CoreAudioDeviceRegistry
    private var continuation: AsyncStream<AudioFrame>.Continuation?

    public init(registry: CoreAudioDeviceRegistry) {
        self.registry = registry
    }

    public func start() -> AsyncStream<AudioFrame> {
        AsyncStream { [weak self] c in
            guard let self else { c.finish(); return }
            self.continuation = c
            do {
                guard let bh16 = self.registry.findBlackHole16ch() else { c.finish(); return }
                try self.bindInput(uid: bh16.uid)
                try self.startTap()
            } catch {
                c.finish()
            }
        }
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }

    private func bindInput(uid: String) throws {
        guard let deviceID = audioDeviceID(forUID: uid) else {
            throw NSError(domain: "BlackHoleSinkCapture", code: -1)
        }
        var id = deviceID
        AudioUnitSetProperty(
            engine.inputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    private func startTap() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2400, format: format) { [weak self] buffer, _ in
            guard let self, let cd = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            let byteCount = n * MemoryLayout<Float>.size
            var data = Data(count: byteCount)
            data.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: Float.self).baseAddress!
                memcpy(p, cd[0], byteCount)
            }
            let frame = AudioFrame(
                pcm: data,
                sampleRate: Int(format.sampleRate),
                channels: 1,
                format: .float32
            )
            self.continuation?.yield(frame)
        }
        try engine.start()
    }
}
