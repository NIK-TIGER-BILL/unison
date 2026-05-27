import AudioToolbox
import CoreAudio
import Darwin
import Foundation

/// Reads audio from a specific CoreAudio device via a raw AUHAL input
/// unit, bypassing AVAudioEngine. Used by the benchmark for the
/// BlackHole 16ch phase — production code uses `BlackHoleSinkCapture`
/// which works fine when the producer is a different process (Zoom),
/// but a same-process AUHAL producer + AVAudioEngine consumer combo
/// produced zero chunks (HAL device conflict). Same-process raw AUHAL
/// on both ends works.
public final class AUHALInputCapture {
    public struct Chunk {
        public let hostTime: UInt64
        public let samples: [Float]
        public let sampleRate: Int
    }

    private var unit: AudioUnit?
    private var sampleRate: Double = 48000
    private var chunks: [Chunk] = []
    private let lock = NSLock()

    public init() {}

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

        // Enable input scope, disable output scope (we're capturing).
        var enable: UInt32 = 1
        try check(
            AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO,
                                  kAudioUnitScope_Input, 1,
                                  &enable, UInt32(MemoryLayout<UInt32>.size)),
            "EnableIO input")
        var disable: UInt32 = 0
        try check(
            AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO,
                                  kAudioUnitScope_Output, 0,
                                  &disable, UInt32(MemoryLayout<UInt32>.size)),
            "DisableIO output")

        // Bind to the capture device.
        var devID = deviceID
        try check(
            AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice,
                                  kAudioUnitScope_Global, 0,
                                  &devID, UInt32(MemoryLayout<AudioDeviceID>.size)),
            "setCurrentDevice")

        // Query the device's native input format, then ask the AU to expose mono Float32.
        var fmt = AudioStreamBasicDescription()
        var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioUnitGetProperty(u, kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input, 1,
                                  &fmt, &fmtSize),
            "getInputStreamFormat")
        sampleRate = fmt.mSampleRate

        // Our consumer format: Float32 mono interleaved at the device's sample rate.
        var outFmt = AudioStreamBasicDescription()
        outFmt.mSampleRate = sampleRate
        outFmt.mFormatID = kAudioFormatLinearPCM
        outFmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked
        outFmt.mFramesPerPacket = 1
        outFmt.mChannelsPerFrame = 1
        outFmt.mBitsPerChannel = 32
        outFmt.mBytesPerFrame = 4
        outFmt.mBytesPerPacket = 4
        try check(
            AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Output, 1,
                                  &outFmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
            "setOutputStreamFormat")

        // Input callback (the AU calls us, we call AudioUnitRender to pull samples).
        var cb = AURenderCallbackStruct(
            inputProc: { (inRefCon, ioActionFlags, inTimeStamp,
                          inBusNumber, inNumberFrames, _) -> OSStatus in
                let capture = Unmanaged<AUHALInputCapture>.fromOpaque(inRefCon).takeUnretainedValue()
                return capture.inputCallback(
                    ioActionFlags: ioActionFlags,
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

    private func inputCallback(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        busNumber: UInt32,
        numberFrames: UInt32
    ) -> OSStatus {
        guard let u = unit else { return noErr }
        let frameCount = Int(numberFrames)
        // Allocate a scratch buffer list pointing at heap-allocated Float storage.
        let byteCount = frameCount * MemoryLayout<Float>.size
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer { storage.deallocate() }

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(byteCount),
                mData: UnsafeMutableRawPointer(storage)
            )
        )
        let status = AudioUnitRender(u, ioActionFlags, timeStamp,
                                     busNumber, numberFrames, &bufferList)
        guard status == noErr else { return status }

        let samples = Array(UnsafeBufferPointer(start: storage, count: frameCount))
        let host = timeStamp.pointee.mHostTime
        let rate = Int(sampleRate)
        lock.lock()
        chunks.append(Chunk(hostTime: host, samples: samples, sampleRate: rate))
        lock.unlock()
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

    public func takeChunks() -> [Chunk] {
        lock.lock()
        let out = chunks
        chunks.removeAll(keepingCapacity: true)
        lock.unlock()
        return out
    }

    deinit { stop() }

    private func check(_ status: OSStatus, _ name: String) throws {
        guard status == noErr else {
            throw AUHALError.coreAudio(call: name, status: status)
        }
    }
}
