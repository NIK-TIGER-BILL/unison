import Foundation
import AVFoundation
import CoreAudio
import UnisonDomain

public final class AVAudioEngineMicrophone: MicrophoneCapture, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioFrame>.Continuation?
    /// Latches while a tap is installed on `engine.inputNode`. Apple
    /// docs: "Installing a tap with the same format throws an
    /// exception" — and `AVAudioNode` exceptions are Obj-C, so they
    /// kill the process. `wireOutgoingPipeline` in the orchestrator
    /// calls `start()` on every reconnect, so without this guard a
    /// transient WS drop mid-call would CRASH the app on the second
    /// installTap. Idempotency keeps us safe.
    private var started = false

    public init() {}

    public func start(deviceUID: String?) -> AsyncStream<AudioFrame> {
        // If a previous start() didn't go through a stop() (e.g. the
        // orchestrator's reconnect path re-wires the pipeline without
        // tearing down the mic), reset so the new installTap doesn't
        // throw against the lingering one. The previous AsyncStream
        // consumer was cancelled by the orchestrator before this
        // call, so finishing it here is harmless.
        if started {
            stop()
        }
        return AsyncStream { [weak self] c in
            guard let self else { c.finish(); return }
            self.continuation = c
            do {
                try self.bindInputDevice(uid: deviceUID)
                try self.startEngine()
                self.started = true
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
        started = false
    }

    private func bindInputDevice(uid: String?) throws {
        guard let uid else { return }
        guard let deviceID = audioDeviceID(forUID: uid) else { return }
        var id = deviceID
        let status = AudioUnitSetProperty(
            engine.inputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            throw NSError(domain: "AVAudioEngineMicrophone", code: Int(status))
        }
    }

    private func startEngine() throws {
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
                channels: Int(format.channelCount),
                format: .float32
            )
            self.continuation?.yield(frame)
        }
        try engine.start()
    }
}

// Shared helper for device-UID → AudioDeviceID lookup, used by all audio components in this module.
internal func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    for id in ids {
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: CFString?
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr in
            AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, ptr)
        }
        if status == noErr, let s = cfStr as String?, s == uid { return id }
    }
    return nil
}
