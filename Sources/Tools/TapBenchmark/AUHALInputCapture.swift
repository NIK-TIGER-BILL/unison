import AudioToolbox
import CoreAudio
import Darwin
import Foundation

/// Reads audio from a specific CoreAudio device via a raw AUHAL input
/// unit, bypassing AVAudioEngine.
///
/// Operates in the device's native channel count and reads channel 0
/// only. Going via the native format avoids CoreAudio's downmix from
/// N→1 channels (an average across all channels), which would attenuate
/// the signal by ~1/N when only channel 0 carries it.
///
/// Realtime-safe: the input callback writes into pre-allocated ring
/// storage without locks or heap allocations. The consumer reads the
/// captured range after `stop()`.
public final class AUHALInputCapture {
    public struct Chunk {
        public let hostTime: UInt64
        public let samples: [Float]
        public let sampleRate: Int
    }

    private var unit: AudioUnit?
    private var sampleRate: Double = 48000
    private var deviceChannels: UInt32 = 1

    // Pre-allocated ring storage: holds channel-0 samples and per-callback
    // host-time anchors. Sized for 30 s at 48 kHz to comfortably cover any
    // realistic benchmark phase.
    private var ringSamples: UnsafeMutableBufferPointer<Float>
    private var ringHostTimes: UnsafeMutableBufferPointer<UInt64>
    private var ringChunkStarts: UnsafeMutableBufferPointer<Int>
    private var ringSampleCounts: UnsafeMutableBufferPointer<Int>
    private var chunkCount: Int = 0
    private var sampleCount: Int = 0
    private let ringCapacity: Int
    private let chunkSlotsCapacity: Int

    // Scratch buffer list for AudioUnitRender output. Sized for max plausible
    // frames per callback (4096 is generous for any aggregate device).
    private let maxFramesPerSlice = 4096
    private var renderScratch: UnsafeMutableBufferPointer<Float>
    private var renderBufferList: UnsafeMutablePointer<AudioBufferList>
    private var renderBufferListByteSize: Int

    public init(maxDurationSeconds: Int = 30) {
        ringCapacity = 48000 * maxDurationSeconds
        chunkSlotsCapacity = ringCapacity / 64  // upper bound on callback firings
        ringSamples = .allocate(capacity: ringCapacity)
        ringSamples.initialize(repeating: 0)
        ringHostTimes = .allocate(capacity: chunkSlotsCapacity)
        ringHostTimes.initialize(repeating: 0)
        ringChunkStarts = .allocate(capacity: chunkSlotsCapacity)
        ringChunkStarts.initialize(repeating: 0)
        ringSampleCounts = .allocate(capacity: chunkSlotsCapacity)
        ringSampleCounts.initialize(repeating: 0)

        // Scratch for AU render. Sized for max device channels (16) × maxFrames.
        renderScratch = .allocate(capacity: 16 * maxFramesPerSlice)
        renderScratch.initialize(repeating: 0)
        // Allocate an AudioBufferList that can hold up to 16 non-interleaved buffers.
        let buffersByteSize = MemoryLayout<AudioBufferList>.size
            + MemoryLayout<AudioBuffer>.size * 15  // ABL has 1 inline + (N-1) tail
        renderBufferListByteSize = buffersByteSize
        renderBufferList = UnsafeMutableRawPointer
            .allocate(byteCount: buffersByteSize,
                      alignment: MemoryLayout<AudioBufferList>.alignment)
            .assumingMemoryBound(to: AudioBufferList.self)
    }

    deinit {
        stop()
        ringSamples.deallocate()
        ringHostTimes.deallocate()
        ringChunkStarts.deallocate()
        ringSampleCounts.deallocate()
        renderScratch.deallocate()
        UnsafeMutableRawPointer(renderBufferList).deallocate()
    }

    public func start(deviceID: AudioDeviceID) throws {
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

        var enable: UInt32 = 1
        try check(
            AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO,
                                  kAudioUnitScope_Input, 1,
                                  &enable, UInt32(MemoryLayout<UInt32>.size)),
            "EnableIO input")
        // Note: previously we disabled output scope on this AU. With BH 16ch,
        // disabling output here apparently disables the device's output clock
        // for *all* AUs in the same process, which made the producer AUHAL
        // freeze after one render call. Leaving output enabled here keeps the
        // device clock alive without affecting capture behavior.

        var devID = deviceID
        try check(
            AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice,
                                  kAudioUnitScope_Global, 0,
                                  &devID, UInt32(MemoryLayout<AudioDeviceID>.size)),
            "setCurrentDevice")

        // Query the device's native input format and match it.
        var deviceFmt = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioUnitGetProperty(u, kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input, 1,
                                  &deviceFmt, &fmtSize),
            "getInputStreamFormat")
        sampleRate = deviceFmt.mSampleRate
        deviceChannels = deviceFmt.mChannelsPerFrame

        // Ask the AU to deliver in the same channel count, Float32 non-interleaved.
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
                                  kAudioUnitScope_Output, 1,
                                  &ourFmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
            "setOutputStreamFormat")

        var cb = AURenderCallbackStruct(
            inputProc: { (inRefCon, ioFlags, inTimeStamp,
                          inBusNumber, inNumberFrames, _) -> OSStatus in
                let capture = Unmanaged<AUHALInputCapture>.fromOpaque(inRefCon).takeUnretainedValue()
                return capture.inputCallback(
                    ioFlags: ioFlags,
                    timeStamp: inTimeStamp,
                    busNumber: inBusNumber,
                    numberFrames: inNumberFrames
                )
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        try check(
            AudioUnitSetProperty(u, kAudioOutputUnitProperty_SetInputCallback,
                                  kAudioUnitScope_Global, 0,
                                  &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
            "setInputCallback")
        try check(AudioUnitInitialize(u), "AudioUnitInitialize")
        try check(AudioOutputUnitStart(u), "AudioOutputUnitStart")
        unit = u
    }

    // Realtime callback. No allocations, no locks. Writes channel-0 samples
    // into the pre-allocated ring; bumps cursors with simple stores.
    private func inputCallback(
        ioFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        numberFrames: UInt32
    ) -> OSStatus {
        guard let u = unit else { return noErr }
        let n = Int(numberFrames)
        if n > maxFramesPerSlice { return noErr }
        if chunkCount >= chunkSlotsCapacity { return noErr }
        if sampleCount + n > ringCapacity { return noErr }

        // Wire renderBufferList to point into renderScratch (non-interleaved).
        renderBufferList.pointee.mNumberBuffers = deviceChannels
        let ablPtr = UnsafeMutableAudioBufferListPointer(renderBufferList)
        for ch in 0..<Int(deviceChannels) {
            ablPtr[ch] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(n * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(
                    renderScratch.baseAddress!.advanced(by: ch * maxFramesPerSlice)
                )
            )
        }
        let status = AudioUnitRender(u, ioFlags, timeStamp,
                                      busNumber, numberFrames, renderBufferList)
        guard status == noErr else { return status }

        // Copy channel 0 into the ring.
        let dstStart = sampleCount
        let src = renderScratch.baseAddress!  // channel 0
        let dst = ringSamples.baseAddress!.advanced(by: dstStart)
        memcpy(dst, src, n * MemoryLayout<Float>.size)

        ringHostTimes[chunkCount] = timeStamp.pointee.mHostTime
        ringChunkStarts[chunkCount] = dstStart
        ringSampleCounts[chunkCount] = n
        chunkCount += 1
        sampleCount += n
        return noErr
    }

    public func stop() {
        if let u = unit {
            AudioOutputUnitStop(u)
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
            unit = nil
        }
    }

    /// Return the captured chunks as [Chunk]. Call after `stop()`.
    public func snapshot() -> [Chunk] {
        var out: [Chunk] = []
        out.reserveCapacity(chunkCount)
        for i in 0..<chunkCount {
            let start = ringChunkStarts[i]
            let count = ringSampleCounts[i]
            let slice = Array(UnsafeBufferPointer(start: ringSamples.baseAddress!.advanced(by: start),
                                                  count: count))
            out.append(Chunk(hostTime: ringHostTimes[i],
                             samples: slice,
                             sampleRate: Int(sampleRate)))
        }
        return out
    }

    private func check(_ status: OSStatus, _ name: String) throws {
        guard status == noErr else {
            throw AUHALError.coreAudio(call: name, status: status)
        }
    }
}
