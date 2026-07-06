// swiftlint:disable file_length
// One deliberately-cohesive engine wrapper (same rationale as
// TranslationOrchestrator): the seam-declick, gap-concealment and
// route-quality machinery all mutate the same counterLock-guarded state and
// are documented inline with their race analyses from the PR #16 review.
// Splitting to satisfy the length threshold would scatter that state behind
// internal accessors without reducing real complexity; a large share of the
// line count is lock-ordering rationale.
import Foundation
import AVFoundation
import CoreAudio
import UnisonDomain

public final class AVAudioOutputMixer: AudioOutputMixer, @unchecked Sendable {
    /// Diagnostic logger. Without this class logging anything, a silent
    /// "the translation/original isn't playing on the device I picked"
    /// failure (typically a misconfigured `outputDeviceUID` or a
    /// silently-failed `AudioUnitSetProperty` call) is invisible. Mirrors
    /// to `~/Library/Logs/Unison/unison.log` — see `UnisonLog`.
    private static let log = UnisonLog(category: "AudioOutput")

    private let engine = AVAudioEngine()
    private let translatedPlayer = AVAudioPlayerNode()
    private let originalPlayer = AVAudioPlayerNode()
    /// Time-stretch node inserted between `translatedPlayer` and the
    /// main mixer. Its `rate` is modulated by `pacing` based on queue
    /// depth so OpenAI Realtime's burst-rate audio doesn't accumulate
    /// unbounded latency on Bluetooth output.
    private let timePitch = AVAudioUnitTimePitch()
    private let mixer: AVAudioMixerNode
    /// Cached 48k F32 mono format. We rebuild a new `AVAudioPCMBuffer`
    /// per scheduled chunk but stop rebuilding the `AVAudioFormat`
    /// — it's the same instance for every chunk and the connect-time
    /// node format, so sharing it avoids tiny allocations on the hot
    /// path and guarantees the player accepts each buffer.
    private let playerFormat: AVAudioFormat
    /// Pacing controller that drives `timePitch.rate`. Lifecycle is
    /// tied to the player; created lazily on first `start(_:)`.
    private var pacing: PlaybackPacing?
    /// Latches on first successful `start(_:)` so the second start in a
    /// stop-restart cycle doesn't `engine.attach(_:)` already-attached
    /// nodes. `AVAudioEngine.attach` is documented to throw an Obj-C
    /// exception if the same node is attached twice — and Obj-C
    /// exceptions in Swift are non-recoverable. The previous version
    /// got away with it on this OS revision but the contract is
    /// fragile; latching makes it explicit. `stop()` deliberately
    /// does *not* detach (the engine reuses the same player instances
    /// on restart, so detach+reattach buys nothing but reset risk).
    private var attached = false
    /// Serializes engine-lifecycle transitions — `start`, `stop`, and the
    /// device-change `reconfigure` — so a config-change self-heal (on the
    /// observer's private serial queue) can never mutate the engine concurrently
    /// with a stop() on the orchestrator's detached teardown task. Distinct from
    /// `counterLock` (the hot scheduling path) to avoid contention.
    ///
    /// `scheduleTranslated` deliberately does NOT take this lock: it runs on the
    /// `playTranslated` task and could overlap a `reconfigure`'s `engine.connect`.
    /// That's the same threading the existing `stop()` already had (player reset
    /// off-main while scheduling may be in flight); `AVAudioPlayerNode`
    /// scheduling is documented thread-safe and a buffer scheduled on the briefly
    /// stopped player is simply queued until the restart's `play()`.
    private let engineLock = NSLock()
    /// True between a successful `start` and a `stop`. The config-change
    /// handler restarts the engine only while this holds — a notification that
    /// lands after stop() must not resurrect a torn-down session.
    private var started = false
    /// The device UID the active session was started with, replayed verbatim
    /// when the engine self-heals after a device change (re-pin an explicit
    /// device; `nil` follows the new system default — the BT-connect case).
    private var currentDeviceUID: String?
    /// Observes `AVAudioEngineConfigurationChange` on `engine` and drives the
    /// self-heal. Created on first `start`, reused across stop-restart cycles.
    private var configObserver: DebouncedNotificationObserver?
    /// Frame counter for periodic RMS logging on the translated path —
    /// every 10th chunk (~1s at 100ms chunks) emits one debug line so
    /// diagnostics can see whether the source audio amplitude itself
    /// is drifting (as opposed to the playback path mangling it).
    private var translatedChunkIndex = 0
    /// Compensating AGC for translation audio. Counteracts the
    /// progressive amplitude fade that `gpt-realtime-translate` applies
    /// to its own output over long continuous sessions (verified by
    /// harness measurement; tests in CompensatingAGCTests).
    private let agc = CompensatingAGCRunner()
    /// Diagnostic counters for the "audio chunks cut off mid-play" bug.
    /// Compare schedule count (each successful scheduleBuffer call) vs
    /// playback count (from `.dataPlayedBack` completion type). If the
    /// player ever drops a buffer for whatever reason (engine reset,
    /// queue overflow, format-renegotiation), the playback counter
    /// will lag the schedule counter — easy to spot in the periodic log.
    private let counterLock = NSLock()
    private var scheduledBufferCount: Int = 0
    private var playedBackBufferCount: Int = 0
    /// Schedule-cadence instrumentation (always-on dev diagnostic): the
    /// wall-clock of the last `scheduleTranslated` call, so each new frame
    /// can log the inter-schedule gap (`schedGap`). Authoritative
    /// queue-depth / underrun is tracked by `PlaybackPacing` (real
    /// completion counters); this only measures how steadily frames reach
    /// the player.
    private var lastScheduleAt: Date?
    /// Duration (ms) of the previously-scheduled chunk — the expected
    /// inter-schedule cadence. `isSchedStall` compares each gap against it
    /// instead of a fixed threshold: the model ships 250–400 ms chunks at
    /// real-time rate, so a fixed 250 ms fired on nearly every healthy chunk
    /// (145 false stalls in one field log). Guarded by `counterLock` with
    /// `lastScheduleAt`.
    private var lastScheduledChunkDurMs: Double = 0
    /// Last sample value of the previously-scheduled translated buffer, used
    /// to declick chunk seams: the first samples of each new buffer are
    /// ramped from this value so a boundary discontinuity (resampler reset
    /// transient, AGC gain step) is smoothed rather than stepped. Reset to 0
    /// on each `play(_:)` so the first chunk (and any chunk resuming after the
    /// player ran dry) ramps up from silence. Touched only from the mixer
    /// actor's schedule path — no extra locking needed.
    private var lastTranslatedSample: Float = 0
    /// Host-clock (`DispatchTime`) seconds at which the currently-queued
    /// translated audio finishes playing. The seam declick reads this to tell a
    /// REAL underrun (player on silence → ramp the next buffer from 0) from
    /// jitter the cushion absorbed (queue still has audio → ramp from the last
    /// sample). Wall-clock based, so it's immune to the `.dataPlayedBack`
    /// completion lag that made the old `scheduled<=played` test miss brief
    /// gaps and click. Read/written under `counterLock`; reset in
    /// `resetPlaybackCounters`.
    private var translatedQueueEndsAt: Double = 0
    // Seam-declick ramp + A/B gate live in `SeamDeclick`, shared with
    // `BlackHole2chPlayer` so the peer path gets the same treatment.

    /// Tail of the most recent REAL translated buffer (post-AGC, post-
    /// declick, ≤ `GapConcealment.tailSamples`) — the raw material for a
    /// gap-concealment fade. Guarded by `counterLock`.
    private var concealTail: [Float] = []
    /// One concealment per dry spell: latched when the watcher fires,
    /// cleared by the next real buffer. Guarded by `counterLock`.
    private var concealedSinceLastReal = false
    /// One-shot watcher armed after every real schedule to fire just before
    /// `translatedQueueEndsAt`. If no newer buffer re-armed it by then, the
    /// player is about to run dry mid-stream → schedule the concealment
    /// fade. Replaced on every schedule; cancelled on stop/reconfigure.
    /// The REFERENCE is guarded by `counterLock` (written from the
    /// `playTranslated` consumer, cancelled from `stop()` under `engineLock`
    /// and from the next session's `resetPlaybackCounters` — three different
    /// tasks; `Task.cancel()` itself is thread-safe, the property swap is not).
    private var concealWatcher: Task<Void, Never>?
    /// True between `stop()` and the next session's `resetPlaybackCounters`.
    /// Guarded by `counterLock`. Closes the stale-fire hole: an in-flight
    /// `scheduleTranslated` racing `stop()` could otherwise arm a FRESH
    /// watcher whose fire passes the queue-end guard (counters reset only at
    /// the NEXT `playTranslated`) and schedules a 200 ms ghost fade onto the
    /// just-reset player — which would then play at the next session's start.
    private var concealSessionStopped = false

    /// Route-quality event channel the orchestrator subscribes to (see
    /// `AudioOutputMixer.routeDegradedEvents`). One long-lived stream per
    /// mixer instance; `configureGraphAndStartLocked` yields the verdict
    /// after every (re)configuration — which is exactly when a Bluetooth
    /// HFP↔A2DP profile flip lands (each flip posts a
    /// `AVAudioEngineConfigurationChange` and rebuilds the graph).
    public var routeDegradedEvents: AsyncStream<Bool> { routeEvents }
    private let routeEvents: AsyncStream<Bool>
    private let routeContinuation: AsyncStream<Bool>.Continuation

    public init() {
        self.playerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 48_000,
                                          channels: 1,
                                          interleaved: false)!
        self.mixer = engine.mainMixerNode
        (routeEvents, routeContinuation) = AsyncStream.makeStream(of: Bool.self)
    }

    /// Whether the underlying `AVAudioEngine` is currently running. Read-only
    /// diagnostic state — used by the device-change repro/tests to detect the
    /// engine stopping itself on an `AVAudioEngineConfigurationChange`.
    public var isEngineRunning: Bool { engine.isRunning }

    /// Harness affordance: mute the engine's FINAL output to the audio device
    /// (mainMixer → outputNode) while leaving the pre-mixer
    /// `UNISON_DUMP_PLAYBACK_WAV` capture tap intact — it taps `timePitch`,
    /// upstream of this mixer, so the captured signal is unchanged. Lets the
    /// full-chain click-verification harness (`pacing-eval --full-chain-render`)
    /// drive the real production chain (AGC + declick + timePitch + scheduling)
    /// without blasting translated audio at whoever runs it. No production
    /// caller — diagnostics only.
    public func muteFinalOutputForCapture() {
        mixer.outputVolume = 0
    }

    public func start(deviceUID: String?) async throws {
        Self.log.info("start(deviceUID=\(deviceUID ?? "<system default>"))")
        // Detached: the body does synchronous CoreAudio HAL IPC (device-UID
        // resolution scans every device, `AudioUnitSetProperty` binds the
        // output, `engine.start()` spins the graph up) — 0.3–0.7 s on
        // Bluetooth in field logs, unbounded on a wedged coreaudiod. The
        // orchestrator awaits this from the @MainActor, so running it
        // inline froze the whole UI for that long at every session start
        // (teardown got the same treatment in stopAllStreams long ago;
        // bring-up was the remaining main-thread HAL surface). `engineLock`
        // inside `startLocked` serializes against the config-change
        // self-heal (observer queue) and `stop()` (teardown task), so the
        // executor hop adds no new interleavings.
        try await Task.detached(priority: .userInitiated) { [self] in
            try startLocked(deviceUID: deviceUID)
        }.value
    }

    private func startLocked(deviceUID: String?) throws {
        engineLock.lock()
        defer { engineLock.unlock() }
        currentDeviceUID = deviceUID
        try configureGraphAndStartLocked(deviceUID: deviceUID)
        started = true
        // Self-heal on output-device changes (e.g. Bluetooth headphones
        // connect/disconnect mid-session): AVAudioEngine stops its graph and
        // posts AVAudioEngineConfigurationChange; without restarting, audio
        // dies until app relaunch. Created lazily, reused across restarts.
        if configObserver == nil {
            configObserver = DebouncedNotificationObserver(
                name: .AVAudioEngineConfigurationChange, object: engine
            ) { [weak self] in
                self?.handleConfigurationChange()
            }
        }
        configObserver?.start()
    }

    /// Attach (once), bind the output device, wire the graph, start the engine,
    /// start the players, and (re-)prime pacing. Shared by `start(deviceUID:)`
    /// and the device-change self-heal. Caller must hold `engineLock`.
    private func configureGraphAndStartLocked(deviceUID: String?) throws {
        if !attached {
            engine.attach(translatedPlayer)
            engine.attach(originalPlayer)
            engine.attach(timePitch)
            attached = true
        }

        // Assign the requested output device before resolving formats so
        // AVAudioEngine can negotiate the mixer→output connection at the
        // device's native sample rate.
        applyOutputDevice(deviceUID)

        // Wiring: translatedPlayer → timePitch → mixer; originalPlayer → mixer.
        // AVAudioEngine inserts a rate converter between the mixer and the
        // output node automatically when the device's hardware rate differs.
        engine.connect(translatedPlayer, to: timePitch, format: playerFormat)
        engine.connect(timePitch, to: mixer, format: playerFormat)
        engine.connect(originalPlayer, to: mixer, format: playerFormat)

        translatedPlayer.volume = 1.0
        originalPlayer.volume = 0.2
        timePitch.rate = 1.0

        do {
            try engine.start()
        } catch {
            Self.log.error("start — engine.start() threw: \(String(describing: error))")
            throw NSError(
                domain: "AVAudioOutputMixer",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to start audio engine: \(error.localizedDescription)"]
            )
        }
        translatedPlayer.play()
        originalPlayer.play()
        let outFormat = engine.outputNode.outputFormat(forBus: 0)
        Self.log.info("start — engine running; outputNode format: \(outFormat.sampleRate)Hz × \(outFormat.channelCount)ch; ready to schedule buffers")
        // Route-quality verdict for THIS configuration. A narrowband route
        // (< 40 kHz) means the output device is on a Bluetooth VOICE profile
        // (HFP — field log: 16000 Hz × 1 ch mid-session): everything the user
        // hears is muffled and quieter until the headset returns to A2DP.
        // Yield on every configure so a mid-session profile flip updates the
        // orchestrator's `outputRouteDegraded` (and the popover hint) live.
        let narrowband = Self.isNarrowbandRoute(sampleRate: outFormat.sampleRate,
                                                channels: Int(outFormat.channelCount))
        if narrowband {
            Self.log.error("[route-degraded] output route is narrowband"
                + " (\(outFormat.sampleRate)Hz × \(outFormat.channelCount)ch) — Bluetooth voice"
                + " profile (HFP): audio will sound muffled/quiet until the headset"
                + " returns to A2DP (usually when its mic is released)")
        }
        routeContinuation.yield(narrowband)

        // Diagnostic dump: if `UNISON_DUMP_PLAYBACK_WAV=<path>` is set,
        // install a tap on the timePitch output and stream every render
        // block to a 48 kHz float32 mono WAV. Captures EXACTLY what the
        // mainMixer receives — the same signal whose amplitude envelope
        // we want to verify against the model output. Used to diagnose
        // the user-reported fade on Bluetooth output without needing
        // them to instrument anything themselves.
        startPlaybackDumpIfRequested()

        if pacing == nil {
            pacing = PlaybackPacing(player: translatedPlayer,
                                    timePitch: timePitch,
                                    log: Self.log,
                                    label: "speakers")
        }
        pacing?.reset()
        pacing?.start()
    }

    /// Pin the output AUHAL to an explicit device UID, or leave it on the
    /// system default when `deviceUID` is `nil` (so the engine follows the
    /// current default after a restart — the BT-connect recovery path).
    private func applyOutputDevice(_ deviceUID: String?) {
        guard let uid = deviceUID else {
            Self.log.info("start — no deviceUID set in Settings; using system default output")
            return
        }
        guard let deviceID = audioDeviceID(forUID: uid) else {
            Self.log.error("start — audioDeviceID(forUID: \(uid)) returned nil; user-selected device is unreachable, falling back to system default")
            return
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            engine.outputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            Self.log.info("start — output device bound to '\(uid)' (id=\(deviceID))")
        } else {
            Self.log.error("start — AudioUnitSetProperty(CurrentDevice → \(uid)) FAILED status=\(status); engine will play to SYSTEM DEFAULT output instead of the user's selection")
        }
    }

    /// Self-heal after an `AVAudioEngineConfigurationChange` (the engine has
    /// already stopped itself — a default-device or format change). Rebuilds
    /// the graph and restarts on the now-current device, replaying the
    /// session's original `deviceUID`. No-op once stopped. Runs on the
    /// observer's private serial queue; `engineLock` serializes it with stop().
    private func handleConfigurationChange() {
        engineLock.lock()
        defer { engineLock.unlock() }
        guard started else {
            Self.log.info("AVAudioEngineConfigurationChange ignored — mixer already stopped")
            return
        }
        Self.log.info("AVAudioEngineConfigurationChange — output device/format changed; engine stopped itself, rebuilding graph and restarting")
        // Reset players first: a `.dataPlayedBack` flush on the stopped engine
        // can wedge the same way Stop did (see stop()); reset clears pending
        // buffers cleanly before we reconnect and restart.
        translatedPlayer.reset()
        originalPlayer.reset()
        // The reset flushed the real queue, so the seam/conceal model must
        // restart from silence: a parked watcher would otherwise pass its
        // queue-end guard (nothing else moves it) and schedule 200 ms of
        // PRE-reconfigure audio onto the rebuilt graph, and the next real
        // buffer would ramp from a stale sample instead of 0. HFP↔A2DP
        // profile flips make reconfigures a first-class mid-session event.
        counterLock.lock()
        concealWatcher?.cancel()
        concealWatcher = nil
        concealTail = []
        concealedSinceLastReal = false
        lastTranslatedSample = 0
        translatedQueueEndsAt = 0
        counterLock.unlock()
        do {
            try configureGraphAndStartLocked(deviceUID: currentDeviceUID)
            Self.log.info("reconfigure — engine restarted on the current device (isRunning=\(engine.isRunning))")
        } catch {
            Self.log.error("reconfigure — failed to restart engine after device change: \(String(describing: error))")
        }
    }

    /// Test-only dump file handle for the pre-mixer tap. Format: float32
    /// mono at 48 kHz. Written incrementally — last 8 bytes of the WAV
    /// header (data chunk size) is patched on stop. If the process is
    /// killed before stop(), the WAV size is the 0xFFFF_FFFF sentinel
    /// and most players will read to EOF anyway.
    private var dumpHandle: FileHandle?
    private var dumpedByteCount: UInt32 = 0

    private func startPlaybackDumpIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["UNISON_DUMP_PLAYBACK_WAV"],
              !path.isEmpty else { return }
        // If we're called from a stop-restart cycle, tap may still be installed.
        timePitch.removeTap(onBus: 0)

        // Reconfigure during an ACTIVE capture (device-change self-heal rebuilt
        // the graph): re-arm the tap on the new timePitch output but keep the
        // existing file + running byte count — don't truncate what we've already
        // captured (which is exactly the window a device change is investigating).
        if dumpHandle != nil {
            installDumpTap()
            return
        }

        let url = URL(fileURLWithPath: path)
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            Self.log.error("UNISON_DUMP_PLAYBACK_WAV — could not open \(path)")
            return
        }
        // Placeholder WAV header (data chunk size = 0xFFFF_FFFF until stop()
        // patches it). 48 kHz mono float32 PCM.
        try? handle.write(contentsOf: Self.buildWAVHeader(sampleRate: 48_000,
                                                          channels: 1,
                                                          bitsPerSample: 32,
                                                          isFloat: true,
                                                          dataSize: 0xFFFF_FFFF))
        dumpHandle = handle
        dumpedByteCount = 0
        Self.log.info("UNISON_DUMP_PLAYBACK_WAV — capturing post-timePitch audio to \(path)")
        installDumpTap()
    }

    private func installDumpTap() {
        let tapFormat = timePitch.outputFormat(forBus: 0)
        timePitch.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let ch = buffer.floatChannelData?[0] else { return }
            let bytes = frames * MemoryLayout<Float>.size
            let data = Data(bytes: ch, count: bytes)
            self.appendDumpData(data)
        }
    }

    private func appendDumpData(_ d: Data) {
        guard let handle = dumpHandle else { return }
        // Throwing write — the legacy `write(_:)` raises an uncatchable
        // ObjC exception on I/O failure and would crash mid-call over a
        // diagnostics file.
        try? handle.write(contentsOf: d)
        dumpedByteCount &+= UInt32(d.count)
    }

    private func closePlaybackDumpIfNeeded() {
        guard let handle = dumpHandle else { return }
        // Stop the tap FIRST and then read `dumpedByteCount`. The tap
        // callback runs on a CoreAudio render thread; `removeTap`
        // drains any pending callbacks before returning, so the read
        // below sees a stable value. We snapshot into a local both
        // to make the data-race-free intent explicit and to avoid
        // re-reading the property during the seek+write below if a
        // late callback ever sneaks in.
        timePitch.removeTap(onBus: 0)
        let dataSize: UInt32 = dumpedByteCount
        let fileSize = dataSize &+ 36
        try? handle.seek(toOffset: 4)
        try? handle.write(contentsOf: Self.uint32LE(fileSize))
        try? handle.seek(toOffset: 40)
        try? handle.write(contentsOf: Self.uint32LE(dataSize))
        try? handle.close()
        dumpHandle = nil
        let durationSec = Double(dataSize) / 4.0 / 48_000.0
        Self.log.info("UNISON_DUMP_PLAYBACK_WAV — closed; \(dataSize) bytes (~\(String(format: "%.2f", durationSec))s)")
    }

    // MARK: - WAV header helpers (shared with BlackHole2chPlayer)

    private static func buildWAVHeader(sampleRate: UInt32,
                                       channels: UInt16,
                                       bitsPerSample: UInt16,
                                       isFloat: Bool,
                                       dataSize: UInt32) -> Data {
        var header = Data()
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        // 0xFFFF_FFFF data-size sentinel must propagate to the RIFF
        // size too — `&+ 36` would wrap it to 35 and strict parsers
        // reject the unterminated file.
        let fileSize = dataSize == 0xFFFF_FFFF ? dataSize : dataSize &+ 36
        header.append(contentsOf: "RIFF".utf8)
        header.append(uint32LE(fileSize))
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(uint32LE(16))
        header.append(uint16LE(isFloat ? 3 : 1)) // 1 = PCM int, 3 = IEEE float
        header.append(uint16LE(channels))
        header.append(uint32LE(sampleRate))
        header.append(uint32LE(byteRate))
        header.append(uint16LE(blockAlign))
        header.append(uint16LE(bitsPerSample))
        header.append(contentsOf: "data".utf8)
        header.append(uint32LE(dataSize))
        return header
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 4)
    }
    private static func uint16LE(_ v: UInt16) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 2)
    }

    public func playTranslated(_ frames: AsyncStream<AudioFrame>) async {
        translatedChunkIndex = 0
        agc.reset()
        resetPlaybackCounters()
        for await frame in frames {
            scheduleTranslated(frame: frame)
        }
    }

    /// Sync helper — Swift 6 strict concurrency disallows `NSLock.lock`
    /// from inside an async function, so the counter reset lives here
    /// and is called from `playTranslated`.
    private func resetPlaybackCounters() {
        counterLock.lock(); defer { counterLock.unlock() }
        concealWatcher?.cancel()
        concealWatcher = nil
        concealSessionStopped = false
        scheduledBufferCount = 0
        playedBackBufferCount = 0
        lastScheduleAt = nil
        lastScheduledChunkDurMs = 0
        lastTranslatedSample = 0
        translatedQueueEndsAt = 0
        concealTail = []
        concealedSinceLastReal = false
    }

    public func playOriginal(_ frames: AsyncStream<AudioFrame>) async {
        for await frame in frames {
            schedule(frame: frame, on: originalPlayer)
        }
    }

    public func setOriginalGain(_ gain: Float) {
        originalPlayer.volume = min(max(gain, 0), 1)
    }

    public func stop() {
        engineLock.lock()
        defer { engineLock.unlock() }
        // Latch stopped + tear down the device-change observer FIRST so a
        // config-change that lands during teardown can't restart the engine
        // we're about to stop (the observer also cancels any pending debounce).
        started = false
        configObserver?.stop()
        pacing?.stop()
        // Kill the concealment machinery for the rest of this session: a
        // parked watcher must not fire into the torn-down engine, and — the
        // subtler hole — an in-flight `scheduleTranslated` (the schedule
        // path deliberately doesn't take `engineLock`) must not ARM a fresh
        // watcher after this point: its fire would pass the queue-end guard
        // and park a ghost 200 ms fade on the reset player, to be played at
        // the START of the next session. `concealSessionStopped` gates both
        // arming and firing; the next `playTranslated` clears it.
        counterLock.lock()
        concealSessionStopped = true
        concealWatcher?.cancel()
        concealWatcher = nil
        concealTail = []
        counterLock.unlock()
        closePlaybackDumpIfNeeded()
        // Reset (not stop) the players. `AVAudioPlayerNode.stop()` flushes the
        // pending `.dataPlayedBack` completion handlers from `scheduleTranslated`,
        // and that flush *wedges* whenever a CoreAudio Process Tap was active in
        // the session — the tap's effect on the render thread makes it never
        // return, hanging Stop (and, since the wedged stop blocked teardown, the
        // whole session). `reset()` clears the scheduled buffers cleanly without
        // that flush. Verified deterministically in the VM tap harness
        // (scripts/vm-repro-teardown.sh): `stop()` wedges 3/3, `reset()` is 3/3 OK.
        translatedPlayer.reset()
        originalPlayer.reset()
        engine.stop()
    }

    /// Schedule a translated-track chunk: account for it in the pacing
    /// controller, log periodic RMS for diagnostics, then queue it on
    /// the player. Frames must already be 48k F32 mono — the resampler
    /// is responsible for that, and the cached `playerFormat` is the
    /// same instance used to connect the node graph, so a buffer built
    /// from it is guaranteed accepted.
    private func scheduleTranslated(frame: AudioFrame) {
        // Hard latency cap. If the queue has blown past the catch-up ceiling
        // — a burst, e.g. the model dumping tens of seconds of buffered audio
        // the instant a slow network recovers — DROP this frame so playback
        // resyncs to live instead of playing ~30 s stale (the "transcript
        // updates but nothing is voiced" bug). The gentle pacing rate (≤1.06×)
        // can't drain a multi-second backlog; only dropping can. `admit()`'s
        // hysteresis keeps dropping until the queue drains to the floor, so we
        // don't flip-flop mid-burst. Skipping the schedule also skips AGC
        // adaptation for this frame — intended: we don't chase gain for audio
        // the listener never hears. The resume AFTER catch-up is deliberately
        // NOT a resume-from-silence: the floor keeps ~0.5s queued so the player
        // never truly hits silence, and the wall-clock model below leaves
        // `resumingFromSilence == false` → the first admitted frame glides from
        // the last sample over 2ms (smoothing the stale→live seam), not from 0.
        if let pacing, !pacing.admit() {
            // Catch-up drop: clear the cadence clock so the FIRST admitted
            // frame after the drop spell doesn't log a spurious
            // `[sched-stall]` for the gap the drops themselves created.
            counterLock.lock()
            lastScheduleAt = nil
            counterLock.unlock()
            return
        }
        // Apply compensating AGC BEFORE building the AVAudioPCMBuffer
        // so the gain ends up baked into the samples we schedule. We
        // chose this over modulating `player.volume` because volume
        // changes are smoothed by AVAudioPlayerNode in a way we can't
        // control, whereas per-sample multiplication is deterministic.
        let frameDurationSec = Double(frame.sampleCount) / Double(frame.sampleRate)
        let (boostedPCM, appliedGain) = agc.apply(pcmF32: frame.pcm,
                                                   frameDurationSec: frameDurationSec)
        let boostedFrame = AudioFrame(pcm: boostedPCM,
                                      sampleRate: frame.sampleRate,
                                      channels: frame.channels,
                                      format: frame.format)
        guard let buf = makeBuffer(from: boostedFrame) else { return }
        if translatedChunkIndex % 10 == 0 {
            let rmsIn = Self.rms(frame)
            let rmsOut = Self.rms(boostedFrame)
            let chunkLine = "[speakers] translated chunk \(translatedChunkIndex)"
                + " rms_in=\(String(format: "%.5f", rmsIn))"
                + " rms_out=\(String(format: "%.5f", rmsOut))"
                + " agc_gain=\(String(format: "%.3f", appliedGain))"
                + " agc_lt_rms=\(String(format: "%.5f", agc.longTermRMS))"
            Self.log.debug(chunkLine)
        }
        translatedChunkIndex += 1
        let frameLength = buf.frameLength

        // --- Schedule-cadence instrumentation (always-on dev diagnostic) ---
        // `schedGap` is the wall-clock gap between consecutive schedule
        // calls = the cadence at which fresh frames actually reach the
        // player. A spike here means the upstream pipeline stalled (no
        // frame to schedule); cross-reference `[audio-rx]` (was the model
        // late?) and `[pump peer]` (did the MainActor hop stall?) to
        // localise it. Authoritative queue-depth / underrun lives in
        // PlaybackPacing's tick log (`[speakers] pacing …` and
        // `[UNDERRUN speakers]`), which uses the real .dataPlayedBack
        // completion counters rather than the version-sensitive
        // playerTime clock.
        let chunkDurMs = Double(frameLength) / 48.0
        counterLock.lock()
        let nowAt = Date()
        let schedGapMs = lastScheduleAt.map { nowAt.timeIntervalSince($0) * 1000 } ?? 0
        lastScheduleAt = nowAt
        let prevChunkDurMs = lastScheduledChunkDurMs
        lastScheduledChunkDurMs = chunkDurMs
        counterLock.unlock()
        Self.log.debug("[sched speakers] schedGap=\(Int(schedGapMs))ms"
            + " frame=\(String(format: "%.0f", chunkDurMs))ms"
            + " rate=\(String(format: "%.3f", Double(timePitch.rate)))")
        if Self.isSchedStall(gapMs: schedGapMs, prevChunkDurMs: prevChunkDurMs) {
            Self.log.info("[sched-stall speakers] \(Int(schedGapMs))ms gap before this frame reached"
                + " the player (cadence ≈\(Int(prevChunkDurMs))ms) — upstream starved"
                + " (cross-check [audio-rx]/[pump peer])")
        }
        // --- end instrumentation ---

        // --- Seam declick ---------------------------------------------------
        // Ramp the first ~2ms of this buffer from where the audio actually
        // left off, so a boundary discontinuity becomes a 2ms glide instead
        // of an instantaneous step (= click). Two cases:
        //  • Continuous playback (queue non-empty): ramp from the previous
        //    buffer's last sample. If the signal is already continuous the
        //    ramp ≈ the signal (no-op); if the resampler/AGC introduced a
        //    small step at the seam, it's smoothed.
        //  • Resume after the player TRULY ran dry: ramp up from 0, otherwise
        //    the first non-zero sample steps from the digital silence the
        //    player emitted and clicks.
        //
        // Dryness signal: a WALL-CLOCK model of when the queued audio ends.
        // `scheduledBufferCount <= playedBackBufferCount` was unreliable — it
        // rode the `.dataPlayedBack` completion, which lags real playout by the
        // HAL/Bluetooth output latency, so a brief gap read "dry" LATE and this
        // buffer got ramped from a stale non-zero `prevSample` even though the
        // player had already emitted digital silence → the 0→prevSample resume
        // click the user heard. Instead we track `translatedQueueEndsAt` (host
        // time the queued audio finishes): if `now` has passed it, the player
        // drained → ramp from 0. Cushion-absorbed jitter keeps
        // `now < translatedQueueEndsAt` (the queue still holds audio), so this
        // does NOT false-fire on healthy clause boundaries — which is why
        // gating on the raw `schedGap` was wrong (a late chunk within the
        // ~0.75s cushion is not a real underrun).
        //
        // `lastTranslatedSample` / `translatedQueueEndsAt` are read+written
        // under `counterLock` (this type is a class, not an actor — it's only
        // serialized in practice by the single `playTranslated` consumer; the
        // lock guards the stop→restart handoff where a late in-flight schedule
        // can race the next session's `resetPlaybackCounters`).
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        let bufDurSec = Double(buf.frameLength) / playerFormat.sampleRate / Double(max(0.5, timePitch.rate))
        counterLock.lock()
        let (resumingFromSilence, newQueueEnd) = Self.seamResumeDecision(
            now: now, queueEndsAt: translatedQueueEndsAt, bufferDurationSec: bufDurSec)
        translatedQueueEndsAt = newQueueEnd
        let prevSample = lastTranslatedSample
        counterLock.unlock()
        if !SeamDeclick.disabled {
            Self.declickSeam(buf, from: resumingFromSilence ? 0 : prevSample)
        }
        if let ch = buf.floatChannelData, buf.frameLength > 0 {
            let last = ch[0][Int(buf.frameLength) - 1]
            // Keep the buffer's tail (post-AGC, post-declick) as gap-
            // concealment material, and re-open the one-per-dry-spell latch:
            // a REAL buffer arrived, so the next dry spell may be masked.
            let len = Int(buf.frameLength)
            let take = min(GapConcealment.tailSamples, len)
            var tail = [Float](repeating: 0, count: take)
            tail.withUnsafeMutableBufferPointer { dst in
                _ = memcpy(dst.baseAddress!, ch[0] + (len - take),
                           take * MemoryLayout<Float>.size)
            }
            counterLock.lock()
            lastTranslatedSample = last
            concealTail = tail
            concealedSinceLastReal = false
            counterLock.unlock()
        }
        // --- end seam declick -----------------------------------------------

        // Use the explicit `.dataPlayedBack` callback type so we can
        // distinguish "buffer was played by hardware" from "buffer was
        // consumed by the next node" (the default callback). When the
        // engine is reset / queue overflows / sample-rate is
        // renegotiated, a buffer can be CONSUMED without being
        // PLAYED — exactly the scenario we suspect for the "chunk cut
        // off before finishing" bug. Comparing played vs scheduled
        // counts in the log will tell us whether that's happening.
        translatedPlayer.scheduleBuffer(
            buf,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self, weak pacing] _ in
            pacing?.didComplete(samples: AVAudioFramePosition(frameLength))
            if let self {
                self.counterLock.lock()
                self.playedBackBufferCount += 1
                let played = self.playedBackBufferCount
                let scheduled = self.scheduledBufferCount
                self.counterLock.unlock()
                // Every 50 buffers (~20 s at 400 ms chunks) emit a
                // diagnostic comparing scheduled vs played-back. A
                // sustained gap > a few buffers indicates real drops.
                if played % 50 == 0 {
                    let gap = scheduled - played
                    // This closure runs on the CoreAudio render/completion
                    // thread — a real-time context. Building the message
                    // string and handing it to os_log/UnisonLog must NOT run
                    // inline here; hop it to a utility queue so a logging
                    // hiccup can never stall playback. Counters are value
                    // types, captured by copy. Debug-level: per-session
                    // periodic diagnostic (a gap growing past a threshold
                    // would warrant an info alert, but we don't have one yet).
                    DispatchQueue.global(qos: .utility).async {
                        Self.log.debug("[speakers] playback counters: scheduled=\(scheduled) played=\(played) gap=\(gap)")
                    }
                }
            }
        }
        counterLock.lock()
        scheduledBufferCount += 1
        counterLock.unlock()
        pacing?.didSchedule(samples: AVAudioFramePosition(frameLength))

        // Gap concealment: watch for the queue running dry before the next
        // real buffer lands, and mask the first ~200 ms of the gap with a
        // pitch-continuation fade instead of a hard cut to digital silence.
        armConcealmentWatcher(armedQueueEnd: newQueueEnd)
    }

    /// Re-arm the dry-spell watcher for the just-scheduled buffer. Fires
    /// 20 ms before the queue's modeled end; a newer real buffer replaces
    /// the watcher (and moves `translatedQueueEndsAt`), so a fire with a
    /// stale `armedQueueEnd` is a no-op.
    private func armConcealmentWatcher(armedQueueEnd: Double) {
        if GapConcealment.disabled { return }
        counterLock.lock(); defer { counterLock.unlock() }
        // A schedule racing `stop()` must not resurrect the machinery the
        // stop just tore down — the ghost fade would play next session.
        guard !concealSessionStopped else { return }
        concealWatcher?.cancel()
        concealWatcher = Task.detached(priority: .userInitiated) { [weak self] in
            let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
            let delay = armedQueueEnd - 0.02 - now
            guard delay > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            self?.fireConcealmentIfStillDry(armedQueueEnd: armedQueueEnd)
        }
    }

    /// Watcher body: if no real buffer arrived since arming (the queue-end
    /// model is unchanged) and we're not deliberately dropping to catch up,
    /// schedule ONE synthetic fade built from the last real tail.
    ///
    /// The dry-check and the commit are TWO lock sections with ~1 ms of
    /// synthesis between them — and that window is adversarially placed: the
    /// watcher fires at queueEnd−20 ms, exactly when a just-in-time real
    /// chunk tends to land. The commit therefore RE-validates the sentinels
    /// (a real buffer always moves `translatedQueueEndsAt` and clears
    /// `concealedSinceLastReal`) and holds `counterLock` across the
    /// `scheduleBuffer` call itself, so a racing real chunk can never end up
    /// ordered BEFORE the concealment in the player queue (which would play
    /// a 200 ms ghost echo of pre-gap material after fresh audio). Safe to
    /// hold: `scheduleBuffer` is non-blocking and its `.dataPlayedBack`
    /// completion is always delivered asynchronously — no lock reentry.
    private func fireConcealmentIfStillDry(armedQueueEnd: Double) {
        if let pacing, pacing.isCatchingUp { return }
        counterLock.lock()
        guard !concealSessionStopped,
              translatedQueueEndsAt == armedQueueEnd,
              !concealedSinceLastReal,
              !concealTail.isEmpty else {
            counterLock.unlock()
            return
        }
        concealedSinceLastReal = true
        let tail = concealTail
        let prevSample = lastTranslatedSample
        counterLock.unlock()

        guard let samples = GapConcealment.makeConcealment(tail: tail, sampleRate: 48_000),
              let buf = makeBuffer(from: AudioFrame(
                pcm: samples.withUnsafeBufferPointer { Data(buffer: $0) },
                sampleRate: 48_000, channels: 1, format: .float32)) else { return }
        // The synthesis continues the waveform one period after the tail's
        // last sample — near-continuous by construction — but ramp from the
        // real last sample anyway so any residual period-estimation step is
        // smoothed exactly like a normal seam.
        if !SeamDeclick.disabled {
            SeamDeclick.ramp(buf, from: prevSample)
        }
        let durSec = Double(samples.count) / 48_000.0
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        let frameLength = buf.frameLength
        counterLock.lock()
        // Re-validate: a real chunk that landed during synthesis wins — it
        // moved the queue end and re-opened the dry-spell latch; scheduling
        // the stale fade behind it would be the artifact, not the cure.
        guard !concealSessionStopped,
              translatedQueueEndsAt == armedQueueEnd,
              concealedSinceLastReal else {
            counterLock.unlock()
            return
        }
        translatedQueueEndsAt = Swift.max(now, translatedQueueEndsAt) + durSec
        lastTranslatedSample = samples.last ?? 0
        scheduledBufferCount += 1
        translatedPlayer.scheduleBuffer(
            buf, at: nil, completionCallbackType: .dataPlayedBack
        ) { [weak self, weak pacing] _ in
            pacing?.didComplete(samples: AVAudioFramePosition(frameLength))
            if let self {
                self.counterLock.lock()
                self.playedBackBufferCount += 1
                self.counterLock.unlock()
            }
        }
        counterLock.unlock()
        pacing?.didSchedule(samples: AVAudioFramePosition(frameLength))
        Self.log.info("[conceal speakers] queue about to run dry — scheduled"
            + " \(Int(durSec * 1000))ms pitch-continuation fade instead of a hard cut"
            + " (one per dry spell; next real chunk resumes via the seam declick)")
    }

    private func schedule(frame: AudioFrame, on player: AVAudioPlayerNode) {
        guard let buf = makeBuffer(from: frame) else { return }
        player.scheduleBuffer(buf, completionHandler: nil)
    }

    /// Build an `AVAudioPCMBuffer` from `frame` using the cached
    /// `playerFormat`. Returns `nil` (and logs) if the frame's shape
    /// doesn't match — a mismatch indicates the resampler pipeline
    /// upstream is broken, so we surface it loudly rather than silently
    /// scheduling a buffer the player will reject.
    private func makeBuffer(from frame: AudioFrame) -> AVAudioPCMBuffer? {
        guard frame.format == .float32,
              frame.sampleRate == Int(playerFormat.sampleRate),
              frame.channels == Int(playerFormat.channelCount) else {
            Self.log.error("makeBuffer — DROPPING frame: expected 48k F32 mono, got \(frame.sampleRate)Hz \(String(describing: frame.format)) × \(frame.channels)ch")
            return nil
        }
        let frameCount = AVAudioFrameCount(frame.sampleCount)
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: frameCount) else { return nil }
        buf.frameLength = frameCount
        frame.pcm.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self).baseAddress!
            memcpy(buf.floatChannelData![0], p, frame.pcm.count)
        }
        return buf
    }

    /// Thin wrapper over the shared `SeamDeclick.ramp` — kept as a `static`
    /// on this type so `DeclickTests` (which prove the seam-smoothing
    /// property deterministically without a live engine) keep their
    /// call-site, and so the mixer's schedule path reads uniformly.
    static func declickSeam(_ buf: AVAudioPCMBuffer, from start: Float) {
        SeamDeclick.ramp(buf, from: start)
    }

    /// Pure: is the negotiated output route narrowband — i.e. the device is
    /// running a Bluetooth VOICE profile (HFP/mSBC 16 kHz, CVSD 8 kHz,
    /// AirPods wideband 24 kHz, LE-Audio voice 32 kHz) instead of its music
    /// profile (A2DP 44.1/48 kHz)? macOS forces that flip whenever something
    /// opens the headset's own mic; everything the user hears collapses to a
    /// muffled, quieter band — the field-log 16000 Hz × 1 ch route behind the
    /// "behind a wall" reports. Full-quality routes are ≥44.1 kHz, so the
    /// <40 kHz cut cleanly separates the voice profiles without flagging
    /// mono-but-full-rate USB routes. `static` + `internal` for tests.
    static func isNarrowbandRoute(sampleRate: Double, channels: Int) -> Bool {
        _ = channels  // mono alone is not evidence — some USB routes are mono
        return sampleRate > 0 && sampleRate < 40_000
    }

    /// Pure: is an inter-schedule gap a genuine upstream stall? The expected
    /// cadence is the PREVIOUS chunk's duration (the model delivers ~real-time,
    /// so the next chunk lands roughly one chunk-duration later); only a gap
    /// exceeding that plus a 150 ms jitter margin is a stall. The 400 ms floor
    /// keeps tiny chunks (a 40 ms tail) from making the detector hair-trigger.
    /// A fixed 250 ms threshold sat BELOW the natural 250–400 ms cadence and
    /// produced 145 false stalls in one field session, drowning the real one.
    /// `static` + `internal` for `SchedStallTests`.
    static func isSchedStall(gapMs: Double, prevChunkDurMs: Double) -> Bool {
        gapMs > Swift.max(400, prevChunkDurMs + 150)
    }

    /// Pure: model the translated queue's end in host-clock seconds to decide
    /// whether the player drained to silence before this buffer. Returns
    /// `(resumingFromSilence, updatedQueueEndsAt)`. `now >= queueEndsAt` ⟺ the
    /// queue emptied and the player is on digital silence → the caller ramps
    /// the seam from 0. Otherwise a chunk landed while audio was still queued
    /// (the cushion absorbed the jitter) → continuous seam, ramp from the last
    /// sample. The new end is `max(now, queueEndsAt) + bufferDurationSec`: a
    /// buffer arriving after a drain restarts the clock at `now`; one that
    /// appends extends the existing queue. `static` + `internal` so it's
    /// unit-testable without a live engine (see `DeclickTests`).
    static func seamResumeDecision(now: Double, queueEndsAt: Double,
                                   bufferDurationSec: Double) -> (resumingFromSilence: Bool, queueEndsAt: Double) {
        SeamDeclick.resumeDecision(now: now, queueEndsAt: queueEndsAt,
                                   bufferDurationSec: bufferDurationSec)
    }

    /// Root-mean-square of a float32 PCM frame, used for periodic
    /// diagnostic logging on the translated track.
    private static func rms(_ frame: AudioFrame) -> Float {
        guard frame.format == .float32, frame.sampleCount > 0 else { return 0 }
        var sumSq: Float = 0
        frame.pcm.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            for i in 0..<frame.sampleCount {
                let s = p[i]
                sumSq += s * s
            }
        }
        return (sumSq / Float(frame.sampleCount)).squareRoot()
    }
}
