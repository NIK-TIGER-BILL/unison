import AVFoundation
import CoreAudio
import Darwin
import Foundation

public final class SignalGenerator {
    public private(set) var expectedClickHostTimes: [UInt64] = []

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 48000
    private let clickDurationMs: Double = 2
    private let intervalMs: Double = 200
    private let clickAmplitude: Float = 0.7
    private var clickBuffer: AVAudioPCMBuffer?

    public init() throws {
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        clickBuffer = try makeClickBuffer(format: format)
    }

    /// Bind the engine's output to a specific CoreAudio device (e.g. BlackHole 16ch
    /// for the BlackHole phase, or default output for the Tap phase).
    public func setOutputDevice(_ deviceID: AudioDeviceID) throws {
        guard let outputUnit = engine.outputNode.audioUnit else {
            throw SignalGeneratorError.outputUnitUnavailable
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw SignalGeneratorError.setOutputDeviceFailed(status: status)
        }
    }

    public func setGain(dB: Float) {
        engine.mainMixerNode.outputVolume = pow(10, dB / 20)
    }

    /// Starts the engine and schedules `clickCount` clicks separated by `intervalMs`.
    /// Returns when scheduling is done; clicks play out over `clickCount * intervalMs` real time.
    public func startAndScheduleClicks(clickCount: Int) throws {
        guard let click = clickBuffer else { throw SignalGeneratorError.bufferUnavailable }
        try engine.start()
        player.play()

        // Schedule clicks at absolute host times, starting 500ms in the future
        // to give the engine time to warm up and avoid the first click being lost.
        let warmupMs: Double = 500
        let firstTicks = HostTimeClock.now() + HostTimeClock.ticks(forMilliseconds: warmupMs)
        let intervalTicks = HostTimeClock.ticks(forMilliseconds: intervalMs)

        expectedClickHostTimes.removeAll(keepingCapacity: true)
        for i in 0..<clickCount {
            let scheduleTicks = firstTicks + UInt64(i) * intervalTicks
            let when = AVAudioTime(hostTime: scheduleTicks)
            player.scheduleBuffer(click, at: when, options: [])
            expectedClickHostTimes.append(scheduleTicks)
        }
    }

    public func stop() {
        player.stop()
        engine.stop()
    }

    /// Wait until all scheduled clicks have played out (last expected + 200ms grace).
    public func waitUntilFinished() async throws {
        guard let last = expectedClickHostTimes.last else { return }
        let waitTarget = last + HostTimeClock.ticks(forMilliseconds: 200)
        while HostTimeClock.now() < waitTarget {
            try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
        }
    }

    private func makeClickBuffer(format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(sampleRate * clickDurationMs / 1000)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw SignalGeneratorError.bufferAllocationFailed
        }
        buf.frameLength = frameCount
        guard let data = buf.floatChannelData?[0] else {
            throw SignalGeneratorError.bufferAllocationFailed
        }
        // Hann-windowed white noise → broadband click, clean amplitude profile.
        for i in 0..<Int(frameCount) {
            let window = 0.5 - 0.5 * cos(2 * .pi * Float(i) / Float(frameCount - 1))
            data[i] = clickAmplitude * window * Float.random(in: -1...1)
        }
        return buf
    }
}

public enum SignalGeneratorError: Error {
    case outputUnitUnavailable
    case setOutputDeviceFailed(status: OSStatus)
    case bufferAllocationFailed
    case bufferUnavailable
}
