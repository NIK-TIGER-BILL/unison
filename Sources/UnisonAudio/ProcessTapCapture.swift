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
    private let muteBehavior: CATapMuteBehavior
    private var tapObjectID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AudioFrame>.Continuation?
    private var nativeSampleRate: Double = 48000
    private var started = false
    private let log: UnisonLog
    /// Serial lifecycle queue. Tap + aggregate-device creation is
    /// synchronous IPC to coreaudiod; `start()` used to run it inline on
    /// the caller (the @MainActor orchestrator), freezing the whole UI
    /// whenever coreaudiod was busy or wedged. Bring-up now runs as an
    /// async block on this queue, teardown as a sync one — the serial
    /// queue preserves the FIFO start/stop ordering the old synchronous
    /// code had (a `Task.detached` would not), and all mutable state
    /// above is only touched from this queue (the realtime IOProc reads
    /// `continuation`/`nativeSampleRate` set strictly before
    /// `AudioDeviceStart` and cleared strictly after `AudioDeviceStop`).
    private let workQueue = DispatchQueue(
        label: "com.unison.app.ProcessTapCapture.lifecycle", qos: .userInitiated)
    /// Marks `workQueue` so `deinit` can detect it is ALREADY running on
    /// it — the bring-up block briefly holds the only strong reference
    /// (weak→strong upgrade); if the owner dropped theirs mid-bring-up,
    /// the block's release triggers deinit ON the queue, where a
    /// `workQueue.sync` would self-deadlock. Unreachable with today's
    /// owners (Composition holds the capture for the process lifetime),
    /// but two lines close it for good.
    private static let workQueueKey = DispatchSpecificKey<Bool>()

    /// Static-scope init (tests, benchmark, permission probe). Defaults to a
    /// blocklist with no user exclusions = tap everything except self.
    public init(scope: TapScope = .allExcept([]),
                muteBehavior: CATapMuteBehavior = .mutedWhenTapped) {
        self.scopeProvider = { scope }
        self.muteBehavior = muteBehavior
        self.log = UnisonLog(category: "ProcessTapCapture")
        workQueue.setSpecific(key: Self.workQueueKey, value: true)
    }

    /// Closure-based init (production — re-reads on every start).
    public init(scopeProvider: @escaping @Sendable () -> TapScope,
                muteBehavior: CATapMuteBehavior = .mutedWhenTapped) {
        self.scopeProvider = scopeProvider
        self.muteBehavior = muteBehavior
        self.log = UnisonLog(category: "ProcessTapCapture")
        workQueue.setSpecific(key: Self.workQueueKey, value: true)
    }

    public func start() -> AsyncStream<AudioFrame> {
        AsyncStream { [weak self] c in
            guard let self else { c.finish(); return }
            // Async on the lifecycle queue — the caller (MainActor) returns
            // immediately with the stream; frames start flowing once the
            // HAL bring-up completes. Failures finish the stream, which the
            // orchestrator's no-data watchdog surfaces within its budget.
            self.workQueue.async { [weak self] in
                guard let self else { c.finish(); return }
                if self.started { self.stopOnQueue(reason: "restart") }
                self.continuation = c
                do {
                    let (scope, ids) = self.resolveScope()
                    self.log.info("[tap.start] scope=\(scope) processObjectIDs=\(ids)")
                    // An allowlist that resolves to no audio objects (the chosen
                    // apps aren't producing audio yet) must NOT build a
                    // `monoMixdownOfProcesses:[]` tap of nothing — that device
                    // wedges CoreAudio on teardown and the Stop button hangs. Keep
                    // the stream open but idle: it captures nothing and tears down
                    // cleanly. The user restarts once an allowed app is playing.
                    if case .onlySelected = scope, ids.isEmpty {
                        self.log.info("[tap.start] allowlist apps produce no audio yet — idle capture (stoppable)")
                        self.started = true
                        return
                    }
                    self.log.info("[tap.tcc] kTCCServiceAudioCapture status=notQueryable (silent-frame watchdog will verify at runtime)")
                    try self.createTap(scope: scope, ids: ids)
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
    }

    public func stop() {
        // Sync so callers keep the completion semantics the old inline
        // teardown had: the orchestrator's HAL-teardown chain relies on
        // each component's stop() having fully finished before the next
        // one starts (sequential HAL destroys — concurrent ones can crash
        // coreaudiod). Callers are the detached teardown task / deinit /
        // applicationWillTerminate — never this workQueue itself.
        workQueue.sync { [weak self] in
            self?.stopOnQueue(reason: "user")
        }
    }

    /// Teardown body — must run on `workQueue`. `AudioDeviceStop` is
    /// synchronous (returns only after the last IOProc callback), so no
    /// IOProc races the continuation mutation below.
    private func stopOnQueue(reason: String) {
        self.log.info("[tap.stop] reason=\(reason)")
        teardown()
        continuation?.finish()
        continuation = nil
        started = false
    }

    deinit {
        // Must finish the continuation so any pending AsyncStream consumer
        // doesn't hang forever when the owner is dropped without calling
        // stop(). Sync on the lifecycle queue: any queued bring-up holds
        // only weak self, so it cannot delay deinit indefinitely, and FIFO
        // ordering runs it (as a no-op) before this block. If deinit fires
        // ON the queue itself (a bring-up block's strong ref was the last
        // one — see `workQueueKey`), run inline: we're already serialized.
        self.log.info("[tap.stop] reason=deinit")
        if DispatchQueue.getSpecific(key: Self.workQueueKey) == true {
            teardown()
            continuation?.finish()
        } else {
            workQueue.sync {
                teardown()
                continuation?.finish()
            }
        }
    }

    // MARK: - Setup steps

    /// Resolve the active scope's bundle IDs to live Audio Process Object
    /// IDs (including each app's audio-producing helper processes via
    /// `AudioProcessRegistry.audioObjectIDs(forBundleID:)`). `.allExcept`
    /// also excludes self (anti-feedback); `.onlySelected` never taps self.
    /// Resolved once per session at `start()`: an app must be producing audio
    /// at that moment to be matched.
    private func resolveScope() -> (scope: TapScope, ids: [AudioObjectID]) {
        let scope = scopeProvider()
        var ids: [AudioObjectID] = []
        if case .allExcept = scope, let own = AudioProcessRegistry.processObjectID(forPID: getpid()) {
            ids.append(own)
        }
        for bundleID in scope.bundleIDs {
            ids.append(contentsOf: AudioProcessRegistry.audioObjectIDs(forBundleID: bundleID))
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
        desc.muteBehavior = muteBehavior
        return desc
    }

    private func createTap(scope: TapScope, ids: [AudioObjectID]) throws {
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
        // Synchronous HAL teardown. All four calls return promptly (verified in
        // the VM tap harness — the Stop wedge was AVAudioPlayerNode.stop(), not
        // any of these); log only on a genuine non-noErr status so a real
        // destroy failure (which would leak an aggregate device) is visible.
        if let procID = ioProcID, aggregateDeviceID != 0 {
            let stopStatus = AudioDeviceStop(aggregateDeviceID, procID)
            let destroyProc = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            if stopStatus != noErr || destroyProc != noErr {
                log.error("[tap.teardown] AudioDeviceStop=\(stopStatus) DestroyIOProcID=\(destroyProc)")
            }
        }
        ioProcID = nil
        if aggregateDeviceID != 0 {
            let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if status != noErr { log.error("[tap.teardown] DestroyAggregateDevice=\(status)") }
            aggregateDeviceID = 0
        }
        if tapObjectID != 0 {
            let status = AudioHardwareDestroyProcessTap(tapObjectID)
            if status != noErr { log.error("[tap.teardown] DestroyProcessTap=\(status)") }
            tapObjectID = 0
        }
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
