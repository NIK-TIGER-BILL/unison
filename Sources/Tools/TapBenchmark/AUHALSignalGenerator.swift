import AudioToolbox
import CoreAudio
import Darwin
import Foundation

/// Click-train generator that writes directly to a chosen CoreAudio device
/// via a raw AUHAL output unit, bypassing AVAudioEngine.
///
/// Operates in the device's native channel count. The click is written to
/// channel 0; other channels are zeroed. Going via the device's native
/// format avoids CoreAudio's mono→multichannel upmix, which would otherwise
/// route through a downmix on the input side and attenuate the round-trip
/// amplitude by ~1/N for an N-channel device.
public final class AUHALSignalGenerator {
    public private(set) var expectedClickHostTimes: [UInt64] = []

    private var unit: AudioUnit?
    private var sampleRate: Double = 48000
    private var deviceChannels: UInt32 = 1
    private let clickDurationMs: Double = 2
    private let intervalMs: Double = 200
    private let clickAmplitude: Float = 0.7
    private var gain: Float = 1.0
    private var click: [Float] = []
    private var intervalSamples: UInt64 = 0
    private var clickSamples: Int = 0

    // Render state — only mutated on the render callback thread.
    private var renderedSamples: UInt64 = 0
    private var firstHostTime: UInt64 = 0
    private var firstClickAtSample: UInt64 = 0
    private var totalClicks: Int = 0

    public init() {}

    public func setOutputDevice(_ deviceID: AudioDeviceID) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw AUHALError.componentNotFound
        }
        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &newUnit), "AudioComponentInstanceNew")
        guard let u = newUnit else { throw AUHALError.componentNotFound }

        var devID = deviceID
        try check(
            AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice,
                                  kAudioUnitScope_Global, 0,
                                  &devID, UInt32(MemoryLayout<AudioDeviceID>.size)),
            "setCurrentDevice")

        // Query the device's native output stream format to match channel count.
        var deviceFmt = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioUnitGetProperty(u, kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Output, 0,
                                  &deviceFmt, &fmtSize),
            "getDeviceOutputFormat")
        sampleRate = deviceFmt.mSampleRate
        deviceChannels = deviceFmt.mChannelsPerFrame
        intervalSamples = UInt64(sampleRate * 0.001 * intervalMs)
        clickSamples = Int(sampleRate * clickDurationMs / 1000)
        click = AUHALSignalGenerator.makeClick(samples: clickSamples,
                                               amplitude: clickAmplitude)

        // Match device channel count, Float32 non-interleaved.
        var ourFmt = AudioStreamBasicDescription()
        ourFmt.mSampleRate = sampleRate
        ourFmt.mFormatID = kAudioFormatLinearPCM
        ourFmt.mFormatFlags = kAudioFormatFlagIsFloat
            | kAudioFormatFlagsNativeEndian
            | kAudioFormatFlagIsPacked
            | kAudioFormatFlagIsNonInterleaved
        ourFmt.mChannelsPerFrame = deviceChannels
        ourFmt.mFramesPerPacket = 1
        ourFmt.mBitsPerChannel = 32
        ourFmt.mBytesPerFrame = 4
        ourFmt.mBytesPerPacket = 4
        try check(
            AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input, 0,
                                  &ourFmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
            "setStreamFormat")

        var cb = AURenderCallbackStruct(
            inputProc: { (inRefCon, _, inTimeStamp, _, inNumberFrames, ioData) -> OSStatus in
                guard let ioData = ioData else { return noErr }
                let gen = Unmanaged<AUHALSignalGenerator>.fromOpaque(inRefCon).takeUnretainedValue()
                gen.render(timestamp: inTimeStamp.pointee,
                           frames: Int(inNumberFrames),
                           buffers: ioData)
                return noErr
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try check(
            AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Input, 0,
                                  &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
            "setRenderCallback")
        try check(AudioUnitInitialize(u), "AudioUnitInitialize")
        unit = u
    }

    public func setGain(dB: Float) { gain = pow(10, dB / 20) }

    public func startAndScheduleClicks(clickCount: Int) throws {
        guard let u = unit else { throw AUHALError.unitNotInitialized }
        totalClicks = clickCount
        renderedSamples = 0
        firstHostTime = 0
        firstClickAtSample = UInt64(sampleRate * 0.500)
        expectedClickHostTimes.removeAll(keepingCapacity: true)

        try check(AudioOutputUnitStart(u), "AudioOutputUnitStart")

        let ticksPerSample = HostTimeClock.ticks(forMilliseconds: 1000.0 / sampleRate)
        for i in 0..<clickCount {
            let sampleOffset = firstClickAtSample + UInt64(i) * intervalSamples
            expectedClickHostTimes.append(sampleOffset * ticksPerSample)
        }
    }

    private func render(timestamp: AudioTimeStamp,
                        frames: Int,
                        buffers: UnsafeMutablePointer<AudioBufferList>) {
        if firstHostTime == 0 {
            firstHostTime = timestamp.mHostTime
            for i in 0..<expectedClickHostTimes.count {
                expectedClickHostTimes[i] = firstHostTime + expectedClickHostTimes[i]
            }
        }
        let abl = UnsafeMutableAudioBufferListPointer(buffers)
        let chunkStart = renderedSamples
        let chunkEnd = renderedSamples + UInt64(frames)
        defer { renderedSamples += UInt64(frames) }

        // Mirror the click on ALL channels — BlackHole may route through a
        // device-specific channel mapping that we cannot assume; replicating
        // makes the signal land somewhere readable downstream.
        for chIdx in 0..<abl.count {
            let buf = abl[chIdx]
            guard let mData = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<frames { mData[i] = 0 }
            for clickIdx in 0..<totalClicks {
                let cStart = firstClickAtSample + UInt64(clickIdx) * intervalSamples
                let cEnd = cStart + UInt64(clickSamples)
                if cEnd <= chunkStart || cStart >= chunkEnd { continue }
                let overlapStart = max(cStart, chunkStart)
                let overlapEnd = min(cEnd, chunkEnd)
                for j in overlapStart..<overlapEnd {
                    let srcIdx = Int(j - cStart)
                    let dstIdx = Int(j - chunkStart)
                    if srcIdx >= 0 && srcIdx < click.count && dstIdx >= 0 && dstIdx < frames {
                        mData[dstIdx] = click[srcIdx] * gain
                    }
                }
            }
        }
    }

    public func stop() {
        if let u = unit {
            AudioOutputUnitStop(u)
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
            unit = nil
        }
    }

    deinit { stop() }

    public func waitUntilFinished() async throws {
        guard let last = expectedClickHostTimes.last, firstHostTime != 0 else {
            try await Task.sleep(nanoseconds: 100_000_000)
            return
        }
        let waitTarget = last + HostTimeClock.ticks(forMilliseconds: 200)
        while HostTimeClock.now() < waitTarget {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func makeClick(samples: Int, amplitude: Float) -> [Float] {
        var click = [Float](repeating: 0, count: samples)
        for i in 0..<samples {
            let window = 0.5 - 0.5 * cos(2 * .pi * Float(i) / Float(samples - 1))
            click[i] = amplitude * window * Float.random(in: -1...1)
        }
        return click
    }

    private func check(_ status: OSStatus, _ name: String) throws {
        guard status == noErr else {
            throw AUHALError.coreAudio(call: name, status: status)
        }
    }
}

public enum AUHALError: Error, CustomStringConvertible {
    case componentNotFound
    case unitNotInitialized
    case coreAudio(call: String, status: OSStatus)

    public var description: String {
        switch self {
        case .componentNotFound: return "AUHAL: kAudioUnitSubType_HALOutput component not found"
        case .unitNotInitialized: return "AUHAL: setOutputDevice must be called before start"
        case .coreAudio(let call, let status):
            return "AUHAL: \(call) failed with status \(status)"
        }
    }
}
