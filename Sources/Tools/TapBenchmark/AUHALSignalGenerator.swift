import AudioToolbox
import CoreAudio
import Darwin
import Foundation

/// Click-train generator that writes directly to a chosen CoreAudio device
/// via a raw AUHAL output unit, bypassing AVAudioEngine.
///
/// Why not AVAudioEngine: setting `kAudioOutputUnitProperty_CurrentDevice`
/// on `AVAudioEngine.outputNode.audioUnit` is accepted (the property
/// reads back correctly) but the engine doesn't actually push audio to
/// the targeted device. Swapping the system default has its own
/// side-effects (`inputNode.outputFormat(0)` shifts to a format that
/// `installTap` rejects). Raw AUHAL with a render callback is the
/// reliable per-device approach used by professional audio apps.
public final class AUHALSignalGenerator {
    public private(set) var expectedClickHostTimes: [UInt64] = []

    private var unit: AudioUnit?
    private let sampleRate: Double = 48000
    private let clickDurationMs: Double = 2
    private let intervalSamples: UInt64
    private let clickSamples: Int
    private let clickAmplitude: Float = 0.7
    private var gain: Float = 1.0
    private var click: [Float] = []

    // Render state — accessed only from the render callback.
    private var renderedSamples: UInt64 = 0
    private var firstHostTime: UInt64 = 0      // mHostTime of the very first render
    private var firstClickAtSample: UInt64 = 0 // when the first click starts (sample count)
    private var totalClicks: Int = 0
    private var intervalMs: Double = 200

    public init() {
        intervalSamples = UInt64(sampleRate * 0.200)  // 200ms interval
        clickSamples = Int(sampleRate * clickDurationMs / 1000)
        click = AUHALSignalGenerator.makeClick(samples: clickSamples, amplitude: clickAmplitude)
    }

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

        // Stream format: Float32 mono interleaved at 48 kHz.
        var fmt = AudioStreamBasicDescription()
        fmt.mSampleRate = sampleRate
        fmt.mFormatID = kAudioFormatLinearPCM
        fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
        fmt.mFramesPerPacket = 1
        fmt.mChannelsPerFrame = 1
        fmt.mBitsPerChannel = 32
        fmt.mBytesPerFrame = 4
        fmt.mBytesPerPacket = 4
        // Input scope = data flowing INTO the audio unit (we're providing samples).
        try check(
            AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input, 0,
                                  &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
            "setStreamFormat")

        // Render callback.
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

    public func setGain(dB: Float) {
        gain = pow(10, dB / 20)
    }

    public func startAndScheduleClicks(clickCount: Int) throws {
        guard let u = unit else { throw AUHALError.unitNotInitialized }
        totalClicks = clickCount
        intervalMs = 200
        renderedSamples = 0
        firstHostTime = 0
        // First click 500ms after render start.
        firstClickAtSample = UInt64(sampleRate * 0.500)
        expectedClickHostTimes.removeAll(keepingCapacity: true)

        try check(AudioOutputUnitStart(u), "AudioOutputUnitStart")

        // Pre-compute expected host times. firstHostTime will be set by the
        // first render callback; we resolve actual host times after that.
        // For now, queue placeholders — analyse() reads them later.
        let ticksPerSample = UInt64(1_000_000_000 / sampleRate) *
            UInt64(HostTimeClock.timebase.denom) /
            UInt64(HostTimeClock.timebase.numer)
        for i in 0..<clickCount {
            let sampleOffset = firstClickAtSample + UInt64(i) * intervalSamples
            // Without firstHostTime yet, we provisionally store ticksPerSample * offset.
            // Real value gets patched in `lockedFirstHostTime()`.
            expectedClickHostTimes.append(sampleOffset * ticksPerSample)
        }
    }

    /// Called from the render callback (audio thread, no allocations).
    private func render(timestamp: AudioTimeStamp,
                        frames: Int,
                        buffers: UnsafeMutablePointer<AudioBufferList>) {
        if firstHostTime == 0 {
            firstHostTime = timestamp.mHostTime
            // Patch the placeholder host times with the real base.
            for i in 0..<expectedClickHostTimes.count {
                expectedClickHostTimes[i] = firstHostTime + expectedClickHostTimes[i]
            }
        }
        let abl = UnsafeMutableAudioBufferListPointer(buffers)
        guard let firstBuf = abl.first,
              let dst = firstBuf.mData?.assumingMemoryBound(to: Float.self) else { return }

        // Zero the buffer, then splat in any clicks whose sample range falls inside [renderedSamples, renderedSamples+frames).
        for i in 0..<frames { dst[i] = 0 }
        let chunkStart = renderedSamples
        let chunkEnd = renderedSamples + UInt64(frames)
        for i in 0..<totalClicks {
            let clickStart = firstClickAtSample + UInt64(i) * intervalSamples
            let clickEnd = clickStart + UInt64(clickSamples)
            if clickEnd <= chunkStart || clickStart >= chunkEnd { continue }
            // Splat overlapping portion.
            let overlapStart = max(clickStart, chunkStart)
            let overlapEnd = min(clickEnd, chunkEnd)
            for j in overlapStart..<overlapEnd {
                let srcIdx = Int(j - clickStart)
                let dstIdx = Int(j - chunkStart)
                if srcIdx >= 0 && srcIdx < click.count && dstIdx >= 0 && dstIdx < frames {
                    dst[dstIdx] = click[srcIdx] * gain
                }
            }
        }
        renderedSamples += UInt64(frames)
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
            // First render hasn't fired yet — give it a brief moment then re-check.
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
