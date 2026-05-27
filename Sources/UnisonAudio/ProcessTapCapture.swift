import AVFoundation
import CoreAudio
import Darwin
import Foundation
import UnisonDomain

/// Captures system-wide audio output via CoreAudio Process Tap, excluding a
/// set of processes by bundle ID (macOS 14.2+). Emits Float32 `AudioFrame`s
/// at the tap's native sample rate over an `AsyncStream`.
public final class ProcessTapCapture: PeerAudioCapture, @unchecked Sendable {
    public let excludedBundleIDs: [String]
    private var processObjectIDs: [AudioObjectID] = []  // resolved at start()
    private var tapObjectID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AudioFrame>.Continuation?
    private var nativeSampleRate: Double = 48000
    private var started = false
    private let log: UnisonLog

    public init(excludedBundleIDs: [String] = []) {
        self.excludedBundleIDs = excludedBundleIDs
        self.log = UnisonLog(category: "ProcessTapCapture")
    }

    public func start() -> AsyncStream<AudioFrame> {
        if started { stop() }
        return AsyncStream { [weak self] c in
            guard let self else { c.finish(); return }
            self.continuation = c
            do {
                self.resolveExcludedProcessObjects()
                let bundleIDsList = self.excludedBundleIDs.joined(separator: ", ")
                self.log.info("[tap.start] excluded=\(bundleIDsList.isEmpty ? "<self only>" : bundleIDsList) processObjectIDs=\(self.processObjectIDs)")
                self.log.info("[tap.tcc] kTCCServiceAudioCapture status=notQueryable (silent-frame watchdog will verify at runtime)")
                try self.createTap()
                try self.createAggregateDevice()
                try self.queryNativeSampleRate()
                try self.installIOProc()
                try self.startDevice()
                self.started = true
            } catch {
                self.log.error("[tap.stop] reason=error: \(String(describing: error))")
                c.finish()
                self.teardown()
            }
        }
    }

    public func stop() {
        // teardown() invokes AudioDeviceStop, which is synchronous — it returns
        // only after the last IOProc callback completes. So no further IOProc
        // can race with the continuation mutation below.
        self.log.info("[tap.stop] reason=user")
        teardown()
        continuation?.finish()
        continuation = nil
        started = false
    }

    deinit {
        // Must finish the continuation so any pending AsyncStream consumer
        // doesn't hang forever when the owner is dropped without calling stop().
        // teardown() is synchronous on AudioDeviceStop, so no IOProc will fire
        // after this returns.
        self.log.info("[tap.stop] reason=deinit")
        teardown()
        continuation?.finish()
    }

    // MARK: - Setup steps

    private func resolveExcludedProcessObjects() {
        var ids: [AudioObjectID] = []
        // Always exclude ourselves to avoid feedback.
        if let own = AudioProcessRegistry.processObjectID(forPID: getpid()) {
            ids.append(own)
        }
        // Resolve each excluded bundle ID. Apps that aren't running OR
        // haven't produced audio yet won't have an Audio Process Object —
        // silently skip them; they can't appear in the system tap anyway.
        for bundleID in excludedBundleIDs {
            if let obj = AudioProcessRegistry.processObjectID(forBundleID: bundleID) {
                ids.append(obj)
            }
        }
        processObjectIDs = ids
    }

    private func createTap() throws {
        let desc = CATapDescription(
            monoGlobalTapButExcludeProcesses: processObjectIDs
        )
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        let status = AudioHardwareCreateProcessTap(desc, &tapObjectID)
        try check(status, "AudioHardwareCreateProcessTap")
        guard tapObjectID != kAudioObjectUnknown else {
            throw ProcessTapError.tapCreationFailed
        }
    }

    private func tapUID() throws -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &uid) { uidPtr -> OSStatus in
            AudioObjectGetPropertyData(tapObjectID, &addr, 0, nil, &size, uidPtr)
        }
        try check(status, "kAudioTapPropertyUID")
        return uid as String
    }

    private func createAggregateDevice() throws {
        let uid = try tapUID()
        let aggUID = "com.unison.tapbench.\(UUID().uuidString)"
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "UnisonProcessTap",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: uid]
            ],
            kAudioAggregateDeviceIsPrivateKey as String: true,
        ]
        let status = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateDeviceID)
        try check(status, "AudioHardwareCreateAggregateDevice")
        guard aggregateDeviceID != kAudioObjectUnknown else {
            throw ProcessTapError.aggregateCreationFailed
        }
    }

    private func queryNativeSampleRate() throws {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = UInt32(MemoryLayout<Float64>.size)
        var sr: Float64 = 48000
        let status = AudioObjectGetPropertyData(aggregateDeviceID, &addr, 0, nil, &size, &sr)
        if status == noErr { nativeSampleRate = sr }
        // Non-fatal: fall back to 48000 if query fails.
    }

    private func installIOProc() throws {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // The IOProc signature is:
        //   (AudioObjectID, *AudioTimeStamp, *AudioBufferList, *AudioTimeStamp,
        //    *AudioBufferList, *AudioTimeStamp, *void?) -> OSStatus
        let proc: AudioDeviceIOProc = {
            _, _, inInputData, inInputTime, _, _, inClientData in
            guard let inClientData = inClientData else { return noErr }
            let capture = Unmanaged<ProcessTapCapture>.fromOpaque(inClientData)
                .takeUnretainedValue()
            capture.onIOProc(inputData: inInputData, inputTime: inInputTime)
            return noErr
        }
        let status = AudioDeviceCreateIOProcID(aggregateDeviceID, proc, refcon, &ioProcID)
        try check(status, "AudioDeviceCreateIOProcID")
    }

    private func startDevice() throws {
        guard let procID = ioProcID else {
            throw ProcessTapError.ioProcMissing
        }
        let status = AudioDeviceStart(aggregateDeviceID, procID)
        try check(status, "AudioDeviceStart")
    }

    // MARK: - IOProc (REALTIME thread)
    //
    // Allocating a `Data` and yielding to `AsyncStream.Continuation` here is
    // technically not strictly realtime-safe. A future optimization would
    // swap this for a lockless ring buffer + consumer thread.

    private func onIOProc(
        inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        _ = inputTime  // timestamp available for future latency measurement
        let abl = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard let firstBuffer = abl.first,
              let mData = firstBuffer.mData else { return }
        let frameCount = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size
        let byteCount = frameCount * MemoryLayout<Float>.size
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { raw in
            if let dst = raw.bindMemory(to: Float.self).baseAddress {
                dst.initialize(from: mData.assumingMemoryBound(to: Float.self),
                               count: frameCount)
            }
        }
        // Use the actual buffer channel count rather than assuming mono — the
        // CATapDescription requests a mono mixdown, but the HAL may deliver
        // multi-channel buffers in some configurations.
        let frame = AudioFrame(
            pcm: data,
            sampleRate: Int(nativeSampleRate),
            channels: Int(firstBuffer.mNumberChannels),
            format: .float32
        )
        continuation?.yield(frame)
    }

    // MARK: - Teardown

    private func teardown() {
        if let procID = ioProcID, aggregateDeviceID != 0 {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        }
        ioProcID = nil
        if aggregateDeviceID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }
        if tapObjectID != 0 {
            AudioHardwareDestroyProcessTap(tapObjectID)
            tapObjectID = 0
        }
        processObjectIDs.removeAll()
    }

    // MARK: - Error helpers

    private func check(_ status: OSStatus, _ call: String) throws {
        guard status == noErr else {
            throw ProcessTapError.coreAudio(call: call, status: status,
                                             fourCC: fourCCString(status))
        }
    }
}

public enum ProcessTapError: Error, CustomStringConvertible {
    case tapCreationFailed
    case aggregateCreationFailed
    case ioProcMissing
    case coreAudio(call: String, status: OSStatus, fourCC: String)

    public var description: String {
        switch self {
        case .tapCreationFailed:       return "ProcessTap: tap creation returned no object"
        case .aggregateCreationFailed: return "ProcessTap: aggregate creation returned no object"
        case .ioProcMissing:           return "ProcessTap: IOProc not installed"
        case .coreAudio(let call, let status, let fourCC):
            return "ProcessTap: \(call) failed with status \(status) ('\(fourCC)')"
        }
    }
}

private func fourCCString(_ status: OSStatus) -> String {
    let bytes: [UInt8] = [
        UInt8((status >> 24) & 0xff),
        UInt8((status >> 16) & 0xff),
        UInt8((status >> 8) & 0xff),
        UInt8(status & 0xff),
    ]
    return String(bytes: bytes, encoding: .ascii)?
        .filter { ($0.asciiValue ?? 0) >= 32 && ($0.asciiValue ?? 0) < 127 } ?? "----"
}
