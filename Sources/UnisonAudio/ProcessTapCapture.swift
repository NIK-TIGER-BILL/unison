import AVFoundation
import CoreAudio
import Darwin
import Foundation
import UnisonDomain

/// Captures system-wide audio output via CoreAudio Process Tap, excluding a
/// set of processes by bundle ID (macOS 14.2+). Emits Float32 `AudioFrame`s
/// at the tap's native sample rate over an `AsyncStream`.
public final class ProcessTapCapture: PeerAudioCapture, @unchecked Sendable {
    private let scopeProvider: @Sendable () -> TapScope
    private var tappedObjectIDs: [AudioObjectID] = []  // last-applied, for change detection
    private var tapObjectID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AudioFrame>.Continuation?
    private var nativeSampleRate: Double = 48000
    private var started = false
    private let log: UnisonLog

    /// Listener on the system audio-process list. Apps that weren't producing
    /// audio at `start()` have no Audio Process Object yet, so they can't be
    /// resolved up front. This keeps the live tap's scope list current so the
    /// correct set of processes is always captured.
    private var processListListenerBlock: AudioObjectPropertyListenerBlock?
    /// Guards `tapObjectID`/`tappedObjectIDs` mutation between the listener
    /// (which sets the tap description) and `teardown()` (which destroys it).
    private let tapLock = NSLock()

    /// Static-scope init (tests, benchmark, permission probe). Defaults to a
    /// blocklist with no user exclusions = tap everything except self.
    public init(scope: TapScope = .allExcept([])) {
        self.scopeProvider = { scope }
        self.log = UnisonLog(category: "ProcessTapCapture")
    }

    /// Closure-based init (production — re-reads on every start).
    public init(scopeProvider: @escaping @Sendable () -> TapScope) {
        self.scopeProvider = scopeProvider
        self.log = UnisonLog(category: "ProcessTapCapture")
    }

    public func start() -> AsyncStream<AudioFrame> {
        if started { stop() }
        return AsyncStream { [weak self] c in
            guard let self else { c.finish(); return }
            self.continuation = c
            do {
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

    /// Resolve the active scope's bundle IDs to live Audio Process Object
    /// IDs. `.allExcept` always includes self (anti-feedback); `.onlySelected`
    /// never taps self. Apps with no audio object yet are skipped — the
    /// process-list listener re-resolves once they appear.
    private func resolveScope() -> (scope: TapScope, ids: [AudioObjectID]) {
        let scope = scopeProvider()
        var ids: [AudioObjectID] = []
        if case .allExcept = scope, let own = AudioProcessRegistry.processObjectID(forPID: getpid()) {
            ids.append(own)
        }
        for bundleID in scope.bundleIDs {
            if let obj = AudioProcessRegistry.processObjectID(forBundleID: bundleID) {
                ids.append(obj)
            }
        }
        return (scope, ids)
    }

    private func makeTapDescription(scope: TapScope, ids: [AudioObjectID]) -> CATapDescription {
        let desc: CATapDescription
        switch scope {
        case .allExcept:    desc = CATapDescription(monoGlobalTapButExcludeProcesses: ids)
        case .onlySelected: desc = CATapDescription(monoMixdownOfProcesses: ids)
        }
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        return desc
    }

    // MARK: - Dynamic scope updates
    //
    // A `monoGlobalTapButExcludeProcesses` tap captures every process — present
    // and future — except the ones in its description's list. That list is a
    // snapshot of object IDs taken at `start()`, so an excluded app that starts
    // producing audio later isn't in it and gets tapped (hence muted by
    // `.mutedWhenTapped`). Similarly, a `monoMixdownOfProcesses` tap captures
    // only the listed processes. We watch the process list and re-push an updated
    // description onto the live tap, which `kAudioTapPropertyDescription`
    // supports without recreating the tap.

    private func installProcessListListener() {
        // Install only when the user has a non-empty list whose resolution
        // can change as apps come and go. (Empty `.allExcept` = self only,
        // stable; empty `.onlySelected` is blocked from starting.)
        guard !scopeProvider().bundleIDs.isEmpty else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshTapDescription()
        }
        processListListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, .main, block
        )
        refreshTapDescription()
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

    private func refreshTapDescription() {
        tapLock.lock()
        defer { tapLock.unlock() }
        guard started, tapObjectID != 0 else { return }

        let (scope, ids) = resolveScope()
        guard Set(ids) != Set(tappedObjectIDs) else { return }
        tappedObjectIDs = ids

        let desc = makeTapDescription(scope: scope, ids: ids)
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
            log.info("[tap.update] scope refreshed tappedObjectIDs=\(ids)")
        } else {
            log.error("[tap.update] kAudioTapPropertyDescription set failed status=\(status)")
        }
    }

    private func createTap() throws {
        let (scope, ids) = resolveScope()
        tappedObjectIDs = ids
        log.info("[tap.start] scope=\(scope) tappedObjectIDs=\(ids)")
        let desc = makeTapDescription(scope: scope, ids: ids)
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
        tappedObjectIDs.removeAll()
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
