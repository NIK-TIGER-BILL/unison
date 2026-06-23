import AVFoundation
import CoreAudio
import Darwin
import Foundation
import UnisonDomain

/// Captures system-wide audio output via CoreAudio Process Tap, excluding a
/// set of processes by bundle ID (macOS 14.2+). Emits Float32 `AudioFrame`s
/// at the tap's native sample rate over an `AsyncStream`.
public final class ProcessTapCapture: PeerAudioCapture, @unchecked Sendable {
    /// Closure that returns the current list of bundle IDs to exclude from
    /// the tap. Called at every `start()` so changes to Settings take effect
    /// on the next session without app restart.
    private let excludedBundleIDsProvider: @Sendable () -> [String]
    private var processObjectIDs: [AudioObjectID] = []  // resolved at start()
    private var tapObjectID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AudioFrame>.Continuation?
    private var nativeSampleRate: Double = 48000
    private var started = false
    private let log: UnisonLog

    /// Listener on the system audio-process list. Excluded apps that weren't
    /// producing audio at `start()` have no Audio Process Object yet, so they
    /// can't be resolved up front — but the global tap captures (and mutes)
    /// them the moment they do start. This keeps the live tap's exclusion
    /// list current so an excluded app always plays at its original volume.
    private var processListListenerBlock: AudioObjectPropertyListenerBlock?
    /// Guards `tapObjectID`/`processObjectIDs` mutation between the listener
    /// (which sets the tap description) and `teardown()` (which destroys it).
    private let tapLock = NSLock()

    /// Static-list init (mostly for tests).
    public init(excludedBundleIDs: [String] = []) {
        self.excludedBundleIDsProvider = { excludedBundleIDs }
        self.log = UnisonLog(category: "ProcessTapCapture")
    }

    /// Closure-based init (production — re-reads on every start).
    public init(excludedBundleIDsProvider: @escaping @Sendable () -> [String]) {
        self.excludedBundleIDsProvider = excludedBundleIDsProvider
        self.log = UnisonLog(category: "ProcessTapCapture")
    }

    public func start() -> AsyncStream<AudioFrame> {
        if started { stop() }
        return AsyncStream { [weak self] c in
            guard let self else { c.finish(); return }
            self.continuation = c
            do {
                self.resolveExcludedProcessObjects()
                self.log.info("[tap.tcc] kTCCServiceAudioCapture status=notQueryable (silent-frame watchdog will verify at runtime)")
                try self.createTap()
                try self.createAggregateDevice()
                try self.queryNativeSampleRate()
                try self.installIOProc()
                try self.startDevice()
                self.started = true
                self.installProcessListListener()
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
        processObjectIDs = resolvedExclusionObjectIDs()
        let bundleIDsList = excludedBundleIDsProvider().joined(separator: ", ")
        log.info("[tap.start] excluded=\(bundleIDsList.isEmpty ? "<self only>" : bundleIDsList) processObjectIDs=\(processObjectIDs)")
    }

    /// Resolves the current exclusion set (self + user bundle IDs) to live
    /// Audio Process Object IDs. Apps not currently producing audio have no
    /// object yet and are skipped — the process-list listener re-resolves
    /// once they do, so the omission is temporary, not permanent.
    private func resolvedExclusionObjectIDs() -> [AudioObjectID] {
        var ids: [AudioObjectID] = []
        // Always exclude ourselves to avoid feedback.
        if let own = AudioProcessRegistry.processObjectID(forPID: getpid()) {
            ids.append(own)
        }
        for bundleID in excludedBundleIDsProvider() {
            if let obj = AudioProcessRegistry.processObjectID(forBundleID: bundleID) {
                ids.append(obj)
            }
        }
        return ids
    }

    // MARK: - Dynamic exclusions
    //
    // A `monoGlobalTapButExcludeProcesses` tap captures every process — present
    // and future — except the ones in its description's list. That list is a
    // snapshot of object IDs taken at `start()`, so an excluded app that starts
    // producing audio later isn't in it and gets tapped (hence muted by
    // `.mutedWhenTapped`). We watch the process list and re-push an updated
    // description onto the live tap, which `kAudioTapPropertyDescription`
    // supports without recreating the tap.

    private func installProcessListListener() {
        // Only the user's exclusions can appear/disappear over a session; with
        // none configured there's nothing to keep current (self is stable).
        guard !excludedBundleIDsProvider().isEmpty else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshTapExclusions()
        }
        processListListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, .main, block
        )
        // Close the gap between tap creation and listener registration: an
        // excluded app may already have started in that window.
        refreshTapExclusions()
    }

    private func removeProcessListListener() {
        guard let block = processListListenerBlock else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, .main, block
        )
        processListListenerBlock = nil
    }

    /// Re-resolve exclusions and, if the set changed, update the live tap.
    private func refreshTapExclusions() {
        tapLock.lock()
        defer { tapLock.unlock() }
        guard started, tapObjectID != 0 else { return }

        let newIDs = resolvedExclusionObjectIDs()
        guard Set(newIDs) != Set(processObjectIDs) else { return }
        processObjectIDs = newIDs

        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: newIDs)
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var box = desc
        let size = UInt32(MemoryLayout<CATapDescription>.size)
        let status = withUnsafeMutablePointer(to: &box) { ptr in
            AudioObjectSetPropertyData(tapObjectID, &addr, 0, nil, size, ptr)
        }
        if status == noErr {
            log.info("[tap.update] exclusions refreshed processObjectIDs=\(newIDs)")
        } else {
            log.error("[tap.update] kAudioTapPropertyDescription set failed status=\(status)")
        }
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
        let aggUID = "com.unison.app.tap.\(UUID().uuidString)"
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "UnisonProcessTap",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceTapListKey as String: [
                [kAudioSubTapUIDKey as String: uid]
            ],
            kAudioAggregateDeviceIsPrivateKey as String: true
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
        let proc: AudioDeviceIOProc = { _, _, inInputData, inInputTime, _, _, inClientData in
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
        let totalFloats = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float>.size
        let src = mData.assumingMemoryBound(to: Float.self)
        // The CATapDescription requests a mono mixdown, but the HAL may
        // deliver multi-channel buffers in some configurations. A
        // multi-channel AudioBuffer (`mNumberChannels > 1`) is
        // interleaved by definition — average the channels here so the
        // rest of the pipeline always sees mono (the resampler's
        // internals are mono-only).
        let channels = max(1, Int(firstBuffer.mNumberChannels))
        let frameCount = totalFloats / channels
        let byteCount = frameCount * MemoryLayout<Float>.size
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { raw in
            guard let dst = raw.bindMemory(to: Float.self).baseAddress else { return }
            if channels == 1 {
                dst.initialize(from: src, count: frameCount)
            } else {
                for i in 0..<frameCount {
                    var acc: Float = 0
                    for c in 0..<channels { acc += src[i * channels + c] }
                    dst[i] = acc / Float(channels)
                }
            }
        }
        let frame = AudioFrame(
            pcm: data,
            sampleRate: Int(nativeSampleRate),
            channels: 1,
            format: .float32
        )
        continuation?.yield(frame)
    }

    // MARK: - Teardown

    private func teardown() {
        // Stop new listener invocations before tearing the tap down; any
        // already-dispatched block will see tapObjectID == 0 under the lock.
        removeProcessListListener()
        tapLock.lock()
        defer { tapLock.unlock() }
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
        UInt8(status & 0xff)
    ]
    return String(bytes: bytes, encoding: .ascii)?
        .filter { ($0.asciiValue ?? 0) >= 32 && ($0.asciiValue ?? 0) < 127 } ?? "----"
}
