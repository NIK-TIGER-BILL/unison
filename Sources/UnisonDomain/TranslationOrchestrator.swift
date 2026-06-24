// swiftlint:disable file_length
// The orchestrator is one deliberately-cohesive state machine: session
// lifecycle, per-speaker reconnect, network pause/resume, watchdogs and
// connectivity health all mutate the same @MainActor state and are
// documented inline with their review history. Splitting it to satisfy
// the length thresholds would scatter that state behind accessors
// without reducing real complexity. Roughly a third of the line count
// is rationale comments.
import Foundation
import Observation

@MainActor
@Observable
// swiftlint:disable:next type_body_length
public final class TranslationOrchestrator {
    /// Diagnostic logger for the orchestrator. Every state mutation
    /// and every guard failure writes a line here, which is mirrored
    /// to both unified logging and `~/Library/Logs/Unison/unison.log`
    /// — see `UnisonLog` for the rationale.
    @ObservationIgnored
    static let log = UnisonLog(category: "Orchestrator")

    public private(set) var state: SessionState = .idle {
        didSet {
            Self.log.info("state \(String(describing: oldValue)) → \(String(describing: self.state))")
        }
    }

    /// Orthogonal QoS dimension published alongside `state`. UI binds
    /// to this for the per-stream status indicator (popover dot, pill
    /// hint, transcript banner). Only meaningful while `state ==
    /// .translating`; the other states (`.paused`, `.reconnecting`,
    /// `.error`) already speak for themselves.
    public private(set) var connectivityHealth: ConnectivityHealth = .healthy {
        didSet {
            Self.log.info("connectivityHealth \(String(describing: oldValue)) → \(String(describing: self.connectivityHealth))")
        }
    }

    /// Per-stream health. UI reads the aggregate via
    /// `connectivityHealth`; the diagnostic dialog reads per-speaker for
    /// asymmetric-failure debugging.
    private var healthBySpeaker: [Speaker: ConnectivityHealth] = [:]

    /// `clock.now()` of the most recent delta (input / output / audio)
    /// per speaker. The slow-detection watchdog measures from here.
    private var lastDeltaAtBySpeaker: [Speaker: Date] = [:]
    /// `clock.now()` of the most recent mic frame whose RMS was above the
    /// audible threshold (0.001). Slow only fires when the user is
    /// actually speaking — pure silence is *not* a network problem.
    private var lastAudibleMicAt: Date?
    /// Peer-side analogue of `lastAudibleMicAt`. The Process Tap pipeline
    /// delivers continuous frames even when nobody on the peer call is
    /// talking; we stamp this only when an actually-audible frame
    /// arrives so peer slow-detection isn't gated on the local user's
    /// mic activity (review finding: peer slow never fired in `.listen`
    /// mode and during quiet stretches of `.call` mode).
    private var lastAudiblePeerAt: Date?

    /// Task driving the slow-detection scan. Restarted on every
    /// session start / reconnect. Cancelled on stop.
    private var slowDetectionTask: Task<Void, Never>?
    /// Holds the 2 s post-resume "recovering → healthy" flash. Stored so
    /// `stopAllStreams()` can cancel it — without that, a stale flash
    /// from session N can clobber the connectivity health of a fast
    /// session-N+1 restart (review finding: cross-session bleed).
    private var recoveringFlashTask: Task<Void, Never>?

    private static let slowThresholdSeconds: TimeInterval = 3
    private static let slowCheckIntervalSeconds: TimeInterval = 0.5
    /// Read from non-MainActor pipeline tasks (splitter computes peer
    /// RMS); `nonisolated` is explicit so a future Swift 6 mode
    /// migration doesn't break the compile.
    nonisolated static let micAudibleRMSThreshold: Float = 0.001
    /// How long after the most recent audible mic frame the user is
    /// still considered "speaking" for the purpose of the slow check.
    /// Wider than `slowThresholdSeconds` so the watchdog catches the
    /// scenario "user said one phrase, then waited 3+ s for the
    /// translation that never arrived" — in that scenario, by the time
    /// we mark slow the last audible frame is already 3 s in the past,
    /// so a 1 s window would never fire. The grace beyond
    /// `slowThresholdSeconds` keeps us from over-firing in the
    /// opposite direction (long sessions of pure silence).
    private static let userSpeakingWindowSeconds: TimeInterval = 4

    public let transcript: TranscriptStore

    private let micCapture: any MicrophoneCapture
    private let peerCapture: any PeerAudioCapture
    private let outputMixer: any AudioOutputMixer
    private let virtualMicPlayer: any AudioPlayer
    private let translationFactory: any TranslationStreamFactory
    private let permissions: any PermissionsService
    private let deviceRegistry: any AudioDeviceRegistry
    private let clock: any Clock
    private let transformer: any AudioFormatTransformer
    /// System-network path watcher. The orchestrator subscribes to its
    /// `statusStream` once per session start; an `.unsatisfied` event
    /// tears down streams + captures and flips to
    /// `.paused(.networkLost)`, a subsequent `.satisfied` resumes.
    /// The protocol lives in `UnisonDomain` so the orchestrator can
    /// depend on it without dragging `Network.framework` into the
    /// domain layer; production wires the `NWPathMonitor`-backed
    /// `NetworkMonitor` from `UnisonSystem`.
    private let networkMonitor: any NetworkPathMonitoring
    /// Task draining `networkMonitor.statusStream`. Spawned in `start`,
    /// cancelled in `stopAllStreams` so a stopped orchestrator doesn't
    /// keep observing the network.
    private var networkObserverTask: Task<Void, Never>?
    /// Force terminal `.error(.networkLost)` if pause-recovery hasn't
    /// succeeded in `pauseRecoveryWatchdogSeconds`. Defense in depth —
    /// without it a never-returning network would leave the app stuck
    /// in `.paused` forever.
    private var pauseRecoveryWatchdogTask: Task<Void, Never>?
    private static let pauseRecoveryWatchdogSeconds: TimeInterval = 60

    private var meStream: (any TranslationStream)?
    private var peerStream: (any TranslationStream)?
    private var silentFrameWatchdog: SilentFrameWatchdog?
    // Pipeline tasks bucketed per speaker so a reconnect cancels exactly the
    // tasks bound to the failed stream and leaves the healthy side untouched.
    private var pipelineTasksBySpeaker: [Speaker: [Task<Void, Never>]] = [:]
    /// Per-speaker reconnect retry loop. Deliberately NOT stored in
    /// `pipelineTasksBySpeaker`: `handleStreamFailure` cancels the failed
    /// speaker's pipeline tasks — including the connection-state observer
    /// it is itself running on — so the retry loop must live on a fresh
    /// unstructured task. Run inline, the loop would execute on an
    /// already-cancelled task and the production `SystemClock`'s
    /// `Task.sleep` would throw `CancellationError` on the first backoff
    /// delay, silently aborting every reconnect (the session then rides
    /// the reconnect watchdog into terminal `.error(.networkLost)`).
    /// The mock clocks ignore cancellation, which is why tests never saw
    /// it. Cancelled in `stopAllStreams` and `enterNetworkPause`.
    private var reconnectTasks: [Speaker: Task<Void, Never>] = [:]
    /// Per-speaker short-window ring buffer of wire-format outbound
    /// audio. The mic-frame consumer appends each frame after
    /// `transformer.toWire(...)`; on reconnect the orchestrator drains
    /// the buffer onto the fresh stream BEFORE wiring live mic so a
    /// brief flap doesn't drop the in-flight phrase. Cleared on
    /// `.paused` (audio captured during a long outage is stale; see
    /// `docs/superpowers/specs/2026-05-27-network-aware-session-design.md`)
    /// and removed in `stopAllStreams`.
    private var audioBufferBySpeaker: [Speaker: AudioRingBuffer] = [:]
    /// 3 s at ~100 ms frames = 30 frames. Matches the design's
    /// brief-blip recovery window.
    private static let audioBufferFrames: Int = 30
    // Tasks not bound to a single stream (device observer, etc).
    private var globalTasks: [Task<Void, Never>] = []
    private var currentLanguages: LanguagePair = .default
    private var currentSettings: Settings = .default
    /// `clock.now()` at the moment `start()` first entered `.translating`.
    /// Preserved across reconnects so the popover timer counts from the
    /// user's click instead of resetting to 00:00 each time a stream
    /// flaps. Cleared in `stop()`.
    private var sessionStartedAt: Date?
    /// Per-speaker count of consecutive WS closes that happened **before**
    /// the server delivered any translated chunk. The handshake succeeds
    /// then the socket drops within milliseconds — the classic pattern
    /// for a rejected API key, account not enabled for realtime, or
    /// unsupported model. After this many such closes in a row we stop
    /// retrying and surface `.apiKeyInvalid` so the user gets a fast,
    /// terminal signal instead of an endless `.translating ↔
    /// .reconnecting` flap.
    private var consecutiveEmptyCloses: [Speaker: Int] = [.me: 0, .peer: 0]
    /// Threshold for the empty-close escalation. A single connect-then-
    /// close-without-data is already a very strong signal of a
    /// credential/policy failure: macOS NSURLSession would not close a
    /// successful realtime stream within the milliseconds-window
    /// available between the WS upgrade and the first delta; that
    /// behaviour is exclusively a server-side rejection. Hitting the
    /// threshold once → immediate terminal `.error(.apiKeyInvalid)`.
    private static let emptyCloseTerminalThreshold = 1
    /// Watchdog that fires if the orchestrator stays in `.reconnecting`
    /// without ever receiving translation data for longer than
    /// `reconnectWatchdogSeconds`. Defense in depth: even if the
    /// empty-close counter somehow doesn't escalate (e.g. the stream
    /// hangs after the handshake instead of closing), the user still
    /// gets a terminal error within a bounded time. Cleared on
    /// successful data delivery and on `stop()`.
    private var reconnectWatchdogTask: Task<Void, Never>?
    /// How long we'll tolerate being in `.reconnecting` before forcing
    /// a terminal `.error(.apiKeyInvalid)`. 15s is comfortably longer
    /// than the regular reconnect retry budget (~10s across 5 attempts)
    /// while still being short enough to feel responsive.
    private static let reconnectWatchdogSeconds: TimeInterval = 15

    /// Watchdog that surfaces `.noDataFromServer` if the orchestrator
    /// stays in `.translating` for `noDataWatchdogSeconds` without a
    /// single frame flowing from the mic side AND without any
    /// audio/transcript delta from the server. The aliveness signal
    /// is **mic-frame-or-server-delta**, deliberately — if mic frames
    /// are flowing (even silence), the pipeline is healthy and the
    /// user is simply not speaking. The earlier "any server delta"
    /// gate was too aggressive: it false-positived whenever the user
    /// opened the popover, clicked Start, then sat quietly for 12s
    /// (OpenAI's server-side VAD returns nothing on silence).
    private var noDataWatchdogTask: Task<Void, Never>?
    /// Longer now because we're only catching truly broken sessions
    /// (no mic frames at all, no server response at all). A real mic
    /// device produces frames within the first audio-buffer cycle
    /// (~100ms), so 20s is comfortably past any reasonable boot delay.
    private static let noDataWatchdogSeconds: TimeInterval = 20
    /// Latched on first mic frame entering the wire pipeline (proves
    /// the input side is alive — capture engine started, tap working,
    /// frames arriving).
    private var anyMicFrameThisSession: Bool = false
    /// Latched on first audio/transcript delta arriving FROM the
    /// server. Separate from the mic latch so we can tell apart
    /// "input dead" from "input alive, server silent (user not
    /// speaking)".
    private var anyServerDeltaThisSession: Bool = false

    public init(
        micCapture: any MicrophoneCapture,
        peerCapture: any PeerAudioCapture,
        outputMixer: any AudioOutputMixer,
        virtualMicPlayer: any AudioPlayer,
        translationFactory: any TranslationStreamFactory,
        permissions: any PermissionsService,
        deviceRegistry: any AudioDeviceRegistry,
        clock: any Clock,
        transformer: any AudioFormatTransformer,
        networkMonitor: any NetworkPathMonitoring
    ) {
        self.transcript = TranscriptStore()
        self.micCapture = micCapture
        self.peerCapture = peerCapture
        self.outputMixer = outputMixer
        self.virtualMicPlayer = virtualMicPlayer
        self.translationFactory = translationFactory
        self.permissions = permissions
        self.deviceRegistry = deviceRegistry
        self.clock = clock
        self.transformer = transformer
        self.networkMonitor = networkMonitor
    }

    public func start(mode: SessionMode, languages: LanguagePair, settings: Settings = .default) async {
        Self.log.info("start() — mode=\(mode.rawValue), pair=\(languages.mine.rawValue)→\(languages.peer.rawValue)")
        guard case .idle = state else {
            Self.log.error("start() rejected — state is not .idle (state=\(String(describing: self.state)))")
            return
        }
        state = .connecting(mode: mode)
        currentLanguages = languages
        currentSettings = settings
        transcript.clear()
        transcript.currentLanguagePair = languages

        // Permission gates. Mic permission is required by both `.call`
        // and `.test` (anything that captures from the mic). `.listen`
        // only consumes Process Tap audio, no mic permission needed.
        if mode.requiresMicrophone {
            let status = permissions.currentStatus(.microphone)
            Self.log.info("start() — microphone permission currentStatus=\(String(describing: status))")
            let resolved = status == .notDetermined ? await permissions.request(.microphone) : status
            Self.log.info("start() — microphone permission resolved=\(String(describing: resolved))")
            guard resolved == .granted else {
                Self.log.error("start() guard failed: microphone permission denied → .error(.permissionDenied)")
                state = .error(.permissionDenied(.microphone))
                return
            }
        }
        // BlackHole 2ch gate. Only `.call` writes to BH 2ch (virtual mic).
        // `.listen` uses Process Tap only — no BH 2ch needed.
        // `.test` doesn't touch BlackHole at all — that's the whole
        // point of the mode (verify translation without needing the
        // driver installed or a real call active).
        if mode == .call {
            guard deviceRegistry.findBlackHole2ch() != nil else {
                Self.log.error("start() guard failed: BlackHole 2ch not found → .error(.blackHole2chMissing)")
                state = .error(.blackHole2chMissing)
                return
            }
        }

        Self.log.info("start() — starting output mixer (outputDeviceUID=\(settings.outputDeviceUID ?? "default"))")
        do {
            try await outputMixer.start(deviceUID: settings.outputDeviceUID)
            outputMixer.setOriginalGain(settings.originalMixVolume)
        } catch {
            Self.log.error("start() output mixer failed: \(String(describing: error)) → .error(.outputDeviceUnavailable)")
            state = .error(.outputDeviceUnavailable)
            return
        }

        // Peer (incoming) stream — used in `.call` and `.listen`.
        // Not in `.test` — test mode only verifies the user's own
        // mic→translate→speakers loop.
        if mode == .call || mode == .listen {
            Self.log.info("start() — connecting peer stream (target=\(languages.mine.rawValue))")
            let peer = translationFactory.make(speaker: .peer)
            peerStream = peer
            do {
                try await peer.connect(target: languages.mine)
            } catch {
                let mapped = mapConnectError(error)
                Self.log.error("start() peer.connect failed: \(String(describing: error)) → .error(\(String(describing: mapped)))")
                // Partial-start teardown: the output mixer is already
                // running and `peerStream` holds a half-open stream.
                // Without this, they keep running behind a terminal
                // `.error` state (and `start()` refuses to run again
                // because the state never returns to `.idle`).
                await stopAllStreams()
                state = .error(mapped)
                return
            }
            Self.log.info("start() — peer stream connected; wiring incoming pipeline")
            wireIncomingPipeline(stream: peer)
            observeConnectionState(stream: peer, speaker: .peer, target: languages.mine, mode: mode)
        }

        // Me (outgoing) stream — used in `.call` and `.test`.
        // The pipeline diverges by destination:
        //   .call: me-stream output → BlackHole 2ch (peer hears in their Zoom)
        //   .test: me-stream output → speakers (user hears their own translation)
        if mode == .call || mode == .test {
            // Allocate the outbound audio ring buffer alongside the
            // me-stream — see `audioBufferBySpeaker` for rationale.
            audioBufferBySpeaker[.me] = AudioRingBuffer(maxFrames: Self.audioBufferFrames)
            Self.log.info("start() — connecting me stream (target=\(languages.peer.rawValue))")
            let me = translationFactory.make(speaker: .me)
            meStream = me
            do {
                try await me.connect(target: languages.peer)
            } catch {
                let mapped = mapConnectError(error)
                Self.log.error("start() me.connect failed: \(String(describing: error)) → .error(\(String(describing: mapped)))")
                // Partial-start teardown: in `.call` mode the peer
                // pipeline is already wired and translating at this
                // point — leaving it running behind `.error` keeps
                // streaming audio to OpenAI with no way to stop it
                // from the UI (`start()` requires `.idle`).
                await stopAllStreams()
                state = .error(mapped)
                return
            }
            Self.log.info("start() — me stream connected; wiring outgoing pipeline (destination=\(mode == .test ? "speakers" : "BlackHole 2ch"))")
            wireOutgoingPipeline(stream: me, destination: mode == .test ? .speakers : .virtualMic)
            observeConnectionState(stream: me, speaker: .me, target: languages.peer, mode: mode)
        }

        // Capture session start time once and reuse across reconnects so
        // the popover timer never resets mid-session. `stop()` clears it.
        let startedAt = clock.now()
        sessionStartedAt = startedAt
        // Fresh session — reset empty-close counters; a previous run's
        // counter must not leak into the new one.
        consecutiveEmptyCloses = [.me: 0, .peer: 0]
        anyMicFrameThisSession = false
        anyServerDeltaThisSession = false
        state = .translating(mode: mode, startedAt: startedAt)
        // Seed per-stream connectivity health for whichever streams
        // this mode actually opens. The slow-detection loop iterates
        // only over speakers that have a live stream, so seeding the
        // dictionary here also acts as the "is this stream tracked"
        // gate.
        healthBySpeaker = [:]
        if mode == .call || mode == .test { healthBySpeaker[.me] = .healthy }
        if mode == .call || mode == .listen { healthBySpeaker[.peer] = .healthy }
        lastDeltaAtBySpeaker = [:]
        lastAudibleMicAt = nil
        lastAudiblePeerAt = nil
        connectivityHealth = .healthy
        startSlowDetectionLoop()
        startNetworkObserver(mode: mode, languages: languages)
        observeDeviceChanges()
        armNoDataWatchdog()
        Self.log.info("start() — translating session active")
    }

    /// Arm the no-data watchdog. Fires `.noDataFromServer` ONLY when
    /// neither side of the pipeline produced any data — i.e. mic
    /// frames never started AND server never sent a delta. The
    /// previous version fired purely on "no server delta", which
    /// false-positived for the most common case: user clicks Start
    /// and sits quietly for 12s. OpenAI's server-side VAD returns
    /// nothing on silence, so that's expected behaviour, not a
    /// failure. With the mic-frame latch added the watchdog only
    /// catches genuinely broken sessions (capture engine dead,
    /// permission revoked, device disappeared post-Start).
    private func armNoDataWatchdog() {
        noDataWatchdogTask?.cancel()
        let clock = self.clock
        noDataWatchdogTask = Task { @MainActor [weak self] in
            try? await clock.sleep(for: Self.noDataWatchdogSeconds)
            guard let self else { return }
            if Task.isCancelled { return }
            // The pipeline is "alive" if EITHER mic frames are
            // flowing OR the server sent anything. Both being silent
            // for 20s is the real failure mode.
            let micAlive = self.anyMicFrameThisSession
            let serverAlive = self.anyServerDeltaThisSession
            if case .translating = self.state, !micAlive, !serverAlive {
                Self.log.error("no-data watchdog fired after \(Self.noDataWatchdogSeconds)s — no mic frames AND no server deltas → .noDataFromServer")
                await self.stopAllStreams()
                self.state = .error(.noDataFromServer)
            } else {
                Self.log.info("no-data watchdog check passed (micAlive=\(micAlive), serverAlive=\(serverAlive)) — pipeline healthy")
            }
        }
    }

    private func cancelNoDataWatchdog() {
        noDataWatchdogTask?.cancel()
        noDataWatchdogTask = nil
    }

    /// Called by the wire-out pipeline on first mic frame. Doesn't
    /// disarm the watchdog by itself — the watchdog still wants to
    /// fire if BOTH sides stay silent. But it does latch one side
    /// of the aliveness check.
    /// The RMS value passed in tells us whether the mic is actually
    /// hearing anything (close to 0.0 = silence / mute / wrong device
    /// / system audio gain at 0). The user-facing diagnostic includes
    /// this so support can see at a glance whether the mic was
    /// physically picking up sound when the user "spoke".
    func markMicFrameReceived(format: String = "?", sampleRate: Int = 0, rms: Float = 0) {
        // Slow detection: stamp the most recent audible mic frame so
        // the watchdog only fires when the user is actually speaking.
        if rms >= Self.micAudibleRMSThreshold {
            lastAudibleMicAt = clock.now()
        }
        guard !anyMicFrameThisSession else { return }
        anyMicFrameThisSession = true
        Self.log.info("first mic frame — format=\(format) sampleRate=\(sampleRate)Hz rms=\(String(format: "%.5f", rms))")
        if rms < 0.0005 {
            Self.log.error("first mic frame — RMS \(String(format: "%.5f", rms)) is near-silent; OpenAI VAD will not trigger. Check the input gain in System Settings → Sound, or pick a different mic in the popover.")
        }
    }

    /// Peer-stream analogue of `markMicFrameReceived`. The
    /// `wireIncomingPipeline` splitter computes RMS over each frame
    /// from Process Tap; we stamp `lastAudiblePeerAt` only when the
    /// signal is above the same audibility threshold as the mic side.
    /// This is the "peer is currently speaking" signal the slow loop
    /// uses to decide whether peer slow-detection should fire (vs.
    /// false-positiving during a quiet meeting).
    func markPeerFrameReceived(rms: Float) {
        if rms >= Self.micAudibleRMSThreshold {
            lastAudiblePeerAt = clock.now()
        }
    }

    /// Periodic mic level snapshot — logged every Nth frame so users
    /// hitting the "no transcript appears" symptom can see in the
    /// diagnostic whether the mic gain ramped up when they spoke
    /// (RMS going from 0.0001 → 0.05 means the mic is hot) or stayed
    /// dead-flat (RMS pegged at near-zero → mic is muted/wrong-device).
    func logMicLevel(rms: Float, frameIndex: Int) {
        // 1 log per second at 100ms frames (= every 10th frame).
        guard frameIndex % 10 == 0 else { return }
        Self.log.debug("mic level — frame=\(frameIndex) rms=\(String(format: "%.5f", rms))")
    }

    /// Called by the wire-in pipelines on first server delta (audio
    /// or transcript). Same role as `markMicFrameReceived` for the
    /// server side, plus disarms the watchdog outright — once data
    /// flows both directions, nothing's wrong worth alerting on.
    func markFirstDataReceived() {
        guard !anyServerDeltaThisSession else { return }
        anyServerDeltaThisSession = true
        cancelNoDataWatchdog()
        Self.log.info("first server delta received — no-data watchdog disarmed")
    }

    /// Called by every server-delta callsite (audio + transcript on
    /// both me / peer streams). Records the arrival time and, if the
    /// speaker was previously `.slow`, flips it back to `.healthy`
    /// and recomputes the published aggregate. Must be called BEFORE
    /// `markFirstDataReceived()` so the order matches the test
    /// expectation that a delta produces `.healthy` immediately.
    private func recordDeltaArrival(speaker: Speaker) {
        lastDeltaAtBySpeaker[speaker] = clock.now()
        if healthBySpeaker[speaker] != .healthy {
            healthBySpeaker[speaker] = .healthy
            recomputeAggregateHealth()
        }
    }

    private func recomputeAggregateHealth() {
        let values = Array(healthBySpeaker.values)
        let aggregate: ConnectivityHealth
        switch values.count {
        case 0: aggregate = .healthy
        case 1: aggregate = ConnectivityHealth.aggregate(values[0])
        default: aggregate = values.reduce(.healthy, ConnectivityHealth.aggregate)
        }
        if aggregate != connectivityHealth {
            connectivityHealth = aggregate
        }
    }

    /// Periodic slow-detection scan. For each speaker with an active
    /// stream, if the user has been audibly speaking in the recent
    /// past AND no delta has arrived from that speaker's stream in
    /// `slowThresholdSeconds`, mark the speaker as `.slow`. The loop
    /// runs every 0.5 s — finer than the threshold so we catch the
    /// transition with at most a half-second lag.
    private func startSlowDetectionLoop() {
        slowDetectionTask?.cancel()
        let clock = self.clock
        slowDetectionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await clock.sleep(for: Self.slowCheckIntervalSeconds)
                guard let self else { return }
                self.evaluateSlowDetection()
            }
        }
    }

    private func stopSlowDetectionLoop() {
        slowDetectionTask?.cancel()
        slowDetectionTask = nil
    }

    private func evaluateSlowDetection() {
        guard case .translating = state else { return }
        let now = clock.now()

        // Per-speaker activity gates. Each side has its own audibility
        // window — gating peer slow-detection on the user's mic was a
        // review finding (peer-only stalls in .listen mode never fired,
        // and a quiet stretch on the user's side suppressed peer
        // diagnostics in .call mode). The audibility-based gate is a
        // false-positive shield: if nobody is speaking on that side,
        // we have no reason to expect deltas, so we shouldn't fire
        // "slow" purely on elapsed time.
        let userIsSpeaking: Bool = {
            guard let last = lastAudibleMicAt else { return false }
            return now.timeIntervalSince(last) < Self.userSpeakingWindowSeconds
        }()
        let peerIsSpeaking: Bool = {
            guard let last = lastAudiblePeerAt else { return false }
            return now.timeIntervalSince(last) < Self.userSpeakingWindowSeconds
        }()

        var changed = false
        for speaker in [Speaker.me, Speaker.peer] {
            let hasStream: Bool
            let isSpeaking: Bool
            let lastAudible: Date?
            switch speaker {
            case .me:
                hasStream = meStream != nil
                isSpeaking = userIsSpeaking
                lastAudible = lastAudibleMicAt
            case .peer:
                hasStream = peerStream != nil
                isSpeaking = peerIsSpeaking
                lastAudible = lastAudiblePeerAt
            }
            guard hasStream else { continue }

            // When the speaker is silent: we can't measure staleness
            // (no traffic to translate is expected). Demote any
            // sticky `.slow` back to `.healthy` so the popover hint
            // doesn't get stuck once the trigger condition is gone.
            // `.recovering` is owned by `armRecoveringFlash` and must
            // not be clobbered here.
            guard isSpeaking else {
                if healthBySpeaker[speaker] == .slow {
                    healthBySpeaker[speaker] = .healthy
                    changed = true
                }
                continue
            }

            let lastDelta = lastDeltaAtBySpeaker[speaker]
            let stale: Bool
            if let lastDelta {
                stale = now.timeIntervalSince(lastDelta) >= Self.slowThresholdSeconds
            } else if let lastAudibleAt = lastAudible {
                // No delta yet, but the speaker's most-recent audible
                // frame is ≥ slowThresholdSeconds old with no server
                // response — that IS slow.
                stale = now.timeIntervalSince(lastAudibleAt) >= Self.slowThresholdSeconds
            } else {
                stale = false
            }

            let target: ConnectivityHealth = stale ? .slow : .healthy
            if healthBySpeaker[speaker] == .recovering {
                // Don't disturb the recovering flash. The flash task
                // will transition us to .healthy after its window;
                // letting this loop overwrite would either skip the
                // UX cue or cause flicker.
                continue
            }
            if healthBySpeaker[speaker] != target {
                healthBySpeaker[speaker] = target
                changed = true
            }
        }
        if changed { recomputeAggregateHealth() }
    }

    private func observeDeviceChanges() {
        let changes = deviceRegistry.deviceChanges
        let task = Task { @MainActor [weak self] in
            for await _ in changes {
                if Task.isCancelled { return }
                guard let self else { return }
                self.handleDeviceChange()
            }
        }
        globalTasks.append(task)
    }

    private func handleDeviceChange() {
        guard case .translating(let mode, _) = state else { return }

        // BlackHole 2ch is required only in Call mode — losing it is fatal there.
        if mode == .call, deviceRegistry.findBlackHole2ch() == nil {
            Self.log.error("handleDeviceChange — BlackHole 2ch disappeared mid-call → stop + .error(.blackHole2chMissing)")
            Task { @MainActor in
                await self.stop()
                self.state = .error(.blackHole2chMissing)
            }
            return
        }
        // Soft fallback: selected mic disappeared → revert to system default.
        if let uid = currentSettings.inputDeviceUID,
           !deviceRegistry.availableInputDevices().contains(where: { $0.uid == uid }) {
            currentSettings.inputDeviceUID = nil
        }
        // Soft fallback: selected output disappeared → revert to system default.
        if let uid = currentSettings.outputDeviceUID,
           !deviceRegistry.availableOutputDevices().contains(where: { $0.uid == uid }) {
            currentSettings.outputDeviceUID = nil
        }
    }

    private func mapConnectError(_ error: Error) -> TranslationError {
        if let te = error as? TranslationError { return te }
        return .networkLost
    }

    /// Arm the reconnect watchdog. After `Self.reconnectWatchdogSeconds`
    /// the orchestrator forces a terminal error if it is still in
    /// `.reconnecting` — safety net that guarantees a user-visible
    /// error within a bounded time, even when the empty-close
    /// counter can't see the failure (stream hangs post-handshake,
    /// etc.). The error surfaced is `.networkLost`: the watchdog
    /// fires after the orchestrator already received data this session
    /// (otherwise the empty-close path would have escalated to
    /// `.apiKeyInvalid` long before the watchdog), so the user is
    /// experiencing a network problem, not a credential one. The
    /// previous version surfaced `.apiKeyInvalid` here which was
    /// actively misleading for the most common cause — a real WiFi
    /// drop reading "ключ невалидный".
    private func armReconnectWatchdog() {
        reconnectWatchdogTask?.cancel()
        let clock = self.clock
        reconnectWatchdogTask = Task { @MainActor [weak self] in
            try? await clock.sleep(for: Self.reconnectWatchdogSeconds)
            guard let self else { return }
            if Task.isCancelled { return }
            // Only escalate if we're still in `.reconnecting`. If the
            // orchestrator already recovered (`.translating`), failed
            // some other way (`.error`), or was stopped (`.idle`),
            // the watchdog is moot.
            if case .reconnecting = self.state {
                Self.log.error("reconnect watchdog fired after \(Self.reconnectWatchdogSeconds)s — forcing terminal .networkLost")
                await self.stopAllStreams()
                self.state = .error(.networkLost)
            }
        }
    }

    /// Cancel any pending reconnect watchdog. Called when the session
    /// recovers (back to `.translating`), is stopped, or escalates to
    /// terminal via the empty-close counter — anything that means the
    /// watchdog no longer needs to fire.
    private func cancelReconnectWatchdog() {
        reconnectWatchdogTask?.cancel()
        reconnectWatchdogTask = nil
    }

    // MARK: - NetworkMonitor pause / auto-resume

    /// Subscribe to `networkMonitor.statusStream` for the duration of
    /// the session. The first yield on attach is the current status,
    /// so a `.satisfied` initial value is a no-op; transitions drive
    /// `.paused ↔ .translating` via `handleNetworkStatusChange`.
    ///
    /// `languages` is captured at session start and threaded through to
    /// the resume path. That's safe ONLY because the language pair is
    /// immutable for the life of a session — the popover/settings
    /// pickers are `.disabled` while `state.isActive`, so
    /// `currentLanguages` can't drift from this captured value. If a
    /// future change ever makes the pair editable mid-session, resume
    /// must read `currentLanguages` instead of this capture, or it will
    /// reconnect with stale languages after a network blip.
    private func startNetworkObserver(mode: SessionMode, languages: LanguagePair) {
        networkObserverTask?.cancel()
        let stream = networkMonitor.statusStream
        networkObserverTask = Task { @MainActor [weak self] in
            for await status in stream {
                if Task.isCancelled { return }
                guard let self else { return }
                self.handleNetworkStatusChange(status, mode: mode, languages: languages)
            }
        }
    }

    private func stopNetworkObserver() {
        networkObserverTask?.cancel()
        networkObserverTask = nil
    }

    private func handleNetworkStatusChange(
        _ status: NetworkPathStatus,
        mode: SessionMode,
        languages: LanguagePair
    ) {
        switch status {
        case .unsatisfied:
            enterNetworkPause(mode: mode)
        case .satisfied:
            if case .paused(_, _, _, .networkLost) = state {
                resumeFromNetworkPause(mode: mode, languages: languages)
            }
        }
    }

    /// Tear down streams + captures and flip to `.paused(.networkLost)`.
    ///
    /// Idempotent vs. `.paused(.networkLost)` — calling again is a
    /// no-op. But NOT idempotent vs. `.paused(.awaitingNetwork)`: a
    /// drop arriving while resume is in flight must transition us
    /// back to `.networkLost` so the resumeStreams reentrancy guard
    /// observes a state change and aborts the half-resumed pipeline
    /// (iter-2 review finding: matching all `.paused` would silently
    /// swallow a mid-resume drop, then NetworkMonitor's de-dup would
    /// suppress any later `.unsatisfied`, leaving the orchestrator
    /// in `.translating` against a dead network).
    private func enterNetworkPause(mode: SessionMode) {
        if case .paused(_, _, _, .networkLost) = state { return }
        guard let startedAt = sessionStartedAt else { return }
        Self.log.info("network unsatisfied — entering .paused(.networkLost)")
        // Stamp any in-flight entries (an original chunk arrived but the
        // server never delivered its translation) as at-risk so the
        // bubble view can render the "перевод не получен" placeholder
        // if no late translation lands during / after the pause.
        transcript.markActiveEntriesAtRisk()
        stopSlowDetectionLoop()
        for (_, tasks) in pipelineTasksBySpeaker {
            for t in tasks { t.cancel() }
        }
        pipelineTasksBySpeaker.removeAll()
        // A speaker may be mid-retry when the network drops; the pause /
        // auto-resume path owns recovery from here, so the WS-level
        // retry loop must not keep dialing against a dead path.
        for (_, t) in reconnectTasks { t.cancel() }
        reconnectTasks.removeAll()
        // Audio captured during a long outage is stale — by the time
        // the network returns, replaying old frames would land after
        // the live conversation moved on. The buffer is allocated
        // again when resume re-opens the me-stream.
        audioBufferBySpeaker.values.forEach { $0.clear() }
        micCapture.stop()
        peerCapture.stop()
        // Capture the stream references BEFORE nil-ing — the spawned
        // Task body runs on a later @MainActor turn, by which point
        // `self.meStream` / `self.peerStream` would already be nil and
        // the `close()` calls would be silent no-ops, leaking the
        // underlying WebSockets + their receive/closeReason loops
        // (review finding #2). Compare with `stopAllStreams` (below)
        // which awaits close before nil-out from an async context.
        let meSnapshot = meStream
        let peerSnapshot = peerStream
        meStream = nil
        peerStream = nil
        Task { @MainActor in
            await meSnapshot?.close()
            await peerSnapshot?.close()
        }
        state = .paused(mode: mode, since: clock.now(), startedAt: startedAt, reason: .networkLost)
        armPauseRecoveryWatchdog()
    }

    private func resumeFromNetworkPause(mode: SessionMode, languages: LanguagePair) {
        guard case .paused(_, _, let startedAt, .networkLost) = state else { return }
        Self.log.info("network satisfied during pause — resuming")
        state = .paused(mode: mode, since: clock.now(), startedAt: startedAt, reason: .awaitingNetwork)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.resumeStreams(mode: mode, languages: languages, startedAt: startedAt)
        }
    }

    private func resumeStreams(
        mode: SessionMode,
        languages: LanguagePair,
        startedAt: Date
    ) async {
        // Reentrancy guard at each await boundary: if the network
        // dropped again mid-resume, NWPathMonitor's `.unsatisfied`
        // handler will have flipped us back to `.paused(.networkLost)`.
        // Continuing the resume in that case would wire a fresh
        // pipeline against a path the OS already declared down —
        // resulting in a phantom `.translating` state and a leaked
        // half-connected stream (review finding #9).
        if mode == .call || mode == .listen {
            let peer = translationFactory.make(speaker: .peer)
            do {
                try await peer.connect(target: languages.mine)
                guard case .paused(_, _, _, .awaitingNetwork) = state else {
                    Self.log.info("resumeStreams — state changed during peer.connect (\(String(describing: self.state))); aborting resume")
                    await peer.close()
                    return
                }
                peerStream = peer
                wireIncomingPipeline(stream: peer)
                observeConnectionState(stream: peer, speaker: .peer, target: languages.mine, mode: mode)
            } catch {
                await failResume(error: error)
                return
            }
        }
        if mode == .call || mode == .test {
            // Re-arm the outbound ring buffer so post-resume reconnect
            // flaps continue to enjoy the brief-blip recovery path.
            audioBufferBySpeaker[.me] = AudioRingBuffer(maxFrames: Self.audioBufferFrames)
            let me = translationFactory.make(speaker: .me)
            do {
                try await me.connect(target: languages.peer)
                guard case .paused(_, _, _, .awaitingNetwork) = state else {
                    Self.log.info("resumeStreams — state changed during me.connect (\(String(describing: self.state))); aborting resume")
                    await me.close()
                    // Tear down the peer side too if we wired it above,
                    // since resume as a whole is aborted. Cancel the
                    // pipeline tasks BEFORE closing the stream so the
                    // close()-yielded `.disconnected` event doesn't
                    // race a still-iterating observer (iter-2 review
                    // finding: peer-pipeline tasks were leaked here).
                    for t in pipelineTasksBySpeaker[.peer] ?? [] { t.cancel() }
                    pipelineTasksBySpeaker[.peer] = []
                    let peerSnapshot = peerStream
                    peerStream = nil
                    await peerSnapshot?.close()
                    return
                }
                meStream = me
                wireOutgoingPipeline(stream: me, destination: mode == .test ? .speakers : .virtualMic)
                observeConnectionState(stream: me, speaker: .me, target: languages.peer, mode: mode)
            } catch {
                await failResume(error: error)
                return
            }
        }
        cancelPauseRecoveryWatchdog()
        state = .translating(mode: mode, startedAt: startedAt)
        healthBySpeaker = [:]
        if mode == .call || mode == .test { healthBySpeaker[.me] = .recovering }
        if mode == .call || mode == .listen { healthBySpeaker[.peer] = .recovering }
        recomputeAggregateHealth()
        // Reset the per-session aliveness latches so the re-armed
        // no-data watchdog can fire if the post-resume pipeline never
        // delivers anything (review finding #5: a mic that was
        // unplugged during the outage would otherwise silently strand
        // the session forever).
        anyMicFrameThisSession = false
        anyServerDeltaThisSession = false
        // Drop the pre-pause activity timestamps. Without this, the
        // slow-detection loop sees `now - lastDeltaAtBySpeaker[.me]`
        // = (pause duration + post-resume latency) and fires phantom
        // `.slow` as soon as the recovering-flash window closes —
        // even though the post-resume pipeline is perfectly healthy
        // (iter-2 review finding: every recovery flickered `.slow`
        // 2 s after the green dot returned).
        lastDeltaAtBySpeaker = [:]
        lastAudibleMicAt = nil
        lastAudiblePeerAt = nil
        startSlowDetectionLoop()
        armNoDataWatchdog()
        armRecoveringFlash()
    }

    private func failResume(error: Error) async {
        Self.log.error("resume failed: \(String(describing: error)); falling back to terminal .error")
        await stopAllStreams()
        state = .error(.networkLost)
    }

    /// Force terminal `.error(.networkLost)` if pause-recovery hasn't
    /// succeeded in `pauseRecoveryWatchdogSeconds` (60 s). Defense in
    /// depth — without it a never-returning network leaves the app in
    /// `.paused` forever.
    private func armPauseRecoveryWatchdog() {
        pauseRecoveryWatchdogTask?.cancel()
        let clock = self.clock
        pauseRecoveryWatchdogTask = Task { @MainActor [weak self] in
            try? await clock.sleep(for: Self.pauseRecoveryWatchdogSeconds)
            guard let self else { return }
            if Task.isCancelled { return }
            // Only escalate if we're still stuck on a network outage
            // (`.networkLost`). Once `resumeFromNetworkPause` flips us
            // to `.paused(.awaitingNetwork)`, resume is in flight —
            // killing it would force-error a recovery that might
            // succeed seconds later on a slow OpenAI handshake. The
            // resume path cancels this watchdog when it lands on
            // `.translating`; this guard handles the case where
            // resume is still mid-await past the 60 s budget (review
            // finding #3 — was matching both reasons).
            if case .paused(_, _, _, .networkLost) = self.state {
                Self.log.error("pause-recovery watchdog fired after \(Self.pauseRecoveryWatchdogSeconds)s in .networkLost — forcing terminal .error(.networkLost)")
                await self.stopAllStreams()
                self.state = .error(.networkLost)
            }
        }
    }

    private func cancelPauseRecoveryWatchdog() {
        pauseRecoveryWatchdogTask?.cancel()
        pauseRecoveryWatchdogTask = nil
    }

    /// Hold `.recovering` health for 2 s after resume, then drop to the
    /// natural `.healthy` (or whatever the slow-detection loop computes).
    /// Handle stored in `recoveringFlashTask` so `stopAllStreams()` can
    /// cancel it — without that, a stale flash from session N can
    /// clobber the connectivity health of a fast session-N+1 restart
    /// (review finding #7).
    private func armRecoveringFlash() {
        recoveringFlashTask?.cancel()
        let clock = self.clock
        recoveringFlashTask = Task { @MainActor [weak self] in
            try? await clock.sleep(for: 2)
            guard let self else { return }
            if Task.isCancelled { return }
            for s in [Speaker.me, Speaker.peer] where self.healthBySpeaker[s] == .recovering {
                self.healthBySpeaker[s] = .healthy
            }
            self.recomputeAggregateHealth()
        }
    }

    private func cancelRecoveringFlash() {
        recoveringFlashTask?.cancel()
        recoveringFlashTask = nil
    }

    private func observeConnectionState(
        stream: any TranslationStream,
        speaker: Speaker,
        target: Language,
        mode: SessionMode
    ) {
        let connStates = stream.connectionState
        let task = Task { @MainActor [weak self] in
            for await connState in connStates {
                // Bail out of buffered events after this observer task
                // was cancelled — otherwise the `.disconnected` event
                // that `close()` yields on the way out can be picked
                // up *after* the reconnect cycle has put us back into
                // `.translating` on a fresh stream, which would
                // re-fire `handleStreamFailure` and reset the
                // empty-close counter on the wrong speaker.
                if Task.isCancelled { return }
                guard let self else { return }
                switch connState {
                case .failed(let err, let receivedAnyData):
                    // Only react to stream failures while the session is
                    // still active. Without this guard, a user clicking
                    // Stop quickly (before any audio delta) caused the
                    // server's normalClosure → handleClose → .failed(.apiKeyInvalid)
                    // race to flip the already-settled `.idle` to
                    // `.error(.apiKeyInvalid)`. Mirrors the `.disconnected`
                    // branch's existing state guard. `.reconnecting`
                    // is included so a second speaker's mid-reconnect
                    // failure still triggers its own retry cycle.
                    switch self.state {
                    case .translating, .paused, .reconnecting:
                        await self.handleStreamFailure(
                            error: err,
                            speaker: speaker,
                            target: target,
                            mode: mode,
                            receivedAnyData: receivedAnyData
                        )
                    case .idle, .connecting, .error:
                        break
                    }
                case .disconnected:
                    // Treat ungraceful disconnect as failure while translating.
                    // We have no visibility into whether the stream ever
                    // delivered data on this path, so assume `true` to keep
                    // the orchestrator in its old behaviour for vanilla
                    // disconnects.
                    if case .translating = self.state {
                        await self.handleStreamFailure(
                            error: .networkLost,
                            speaker: speaker,
                            target: target,
                            mode: mode,
                            receivedAnyData: true
                        )
                    }
                case .connecting, .connected, .reconnecting:
                    break
                }
            }
        }
        pipelineTasksBySpeaker[speaker, default: []].append(task)
    }

    private func handleStreamFailure(
        error: TranslationError,
        speaker: Speaker,
        target: Language,
        mode: SessionMode,
        receivedAnyData: Bool
    ) async {
        Self.log.error("handleStreamFailure — speaker=\(String(describing: speaker)), error=\(String(describing: error)), receivedAnyData=\(receivedAnyData)")
        // Stamp this speaker's in-flight entries (original chunk
        // arrived but the server hadn't delivered its translation
        // yet) as at-risk so the bubble view can render the
        // "перевод не получен" placeholder if no late translation
        // lands during the reconnect cycle. Scoped to the failing
        // speaker so the healthy stream's bubbles don't get
        // decorated with the placeholder while their own translation
        // is still mid-flight (iter-3 review finding).
        transcript.markActiveEntriesAtRisk(speaker: speaker)
        // Don't try to recover from terminal errors
        switch error {
        case .apiKeyInvalid, .insufficientCredits, .permissionDenied:
            Self.log.error("handleStreamFailure — terminal error, surfacing as .error(\(String(describing: error)))")
            await stopAllStreams()
            state = .error(error)
            return
        default:
            break
        }

        // Endless-retry guard: a stream that connects, then closes before
        // delivering a single chunk, is almost always a credential or
        // model-access problem. The server happily accepts the WS upgrade
        // (which is why we don't see it on `connect()` itself) and drops
        // us on the first message. The threshold is currently 1 — a
        // single empty close escalates straight to terminal
        // `.apiKeyInvalid` (see `emptyCloseTerminalThreshold` for why a
        // lone occurrence is already conclusive); the counter machinery
        // stays so the threshold can be raised without rework.
        if !receivedAnyData {
            let next = (consecutiveEmptyCloses[speaker] ?? 0) + 1
            consecutiveEmptyCloses[speaker] = next
            if next >= Self.emptyCloseTerminalThreshold {
                Self.log.error("handleStreamFailure — \(String(describing: speaker)) stream closed empty \(next) times in a row → treating as terminal .apiKeyInvalid")
                await stopAllStreams()
                state = .error(.apiKeyInvalid)
                return
            }
        } else {
            // A successful data-bearing session resets the counter — a
            // legitimate mid-call drop should not poison the next session
            // with the previous one's empty-close debt.
            consecutiveEmptyCloses[speaker] = 0
        }

        // Flip to `.reconnecting` BEFORE closing the stale stream so the
        // `.disconnected` event that `close()` yields on the way out
        // doesn't get re-interpreted as a fresh failure by any
        // observer task that's still iterating. The observer's
        // `.disconnected` branch only fires while `state` is
        // `.translating`, so this prevents an accidental
        // counter-resetting failure cascade.
        //
        // `sessionStartedAt` is non-nil whenever the orchestrator has
        // entered `.translating`; falling back to `clock.now()` is a
        // belt-and-braces guard so this code path is always well-formed
        // even if the failure observer somehow runs before `start()`
        // completed (it shouldn't).
        let startedAt = sessionStartedAt ?? clock.now()
        state = .reconnecting(mode: mode, since: clock.now(), startedAt: startedAt)
        // Arm the absolute reconnect watchdog. If the retry loop below
        // never gets us back to `.translating` within
        // `reconnectWatchdogSeconds`, we force terminal so the user
        // doesn't see an endless "Переподключение…" spinner.
        armReconnectWatchdog()

        // Cancel the failed speaker's tasks and close the stale stream so we
        // don't leak Tasks or orphan a still-open WebSocket on repeated reconnects.
        for t in pipelineTasksBySpeaker[speaker] ?? [] { t.cancel() }
        pipelineTasksBySpeaker[speaker] = []
        switch speaker {
        case .me:
            await meStream?.close()
            meStream = nil
        case .peer:
            await peerStream?.close()
            peerStream = nil
        }
        // Spawn the retry loop on a fresh task — see `reconnectTasks` for
        // why running it inline on this (just-self-cancelled) observer
        // task would abort the first backoff sleep in production.
        reconnectTasks[speaker]?.cancel()
        reconnectTasks[speaker] = Task { @MainActor [weak self] in
            await self?.runReconnectLoop(speaker: speaker, target: target, mode: mode, initialError: error)
        }
    }

    /// Backoff-retry loop that re-creates a failed speaker's stream. Runs
    /// on its own task (`reconnectTasks[speaker]`); aborts quietly when
    /// `stop()` / a network pause changes the state out of `.reconnecting`
    /// or cancels the task.
    private func runReconnectLoop(
        speaker: Speaker,
        target: Language,
        mode: SessionMode,
        initialError error: TranslationError
    ) async {
        var backoff = BackoffPolicy(initial: 1, cap: 30)
        var firstAttempt = true
        // Re-create the stream and try again, up to 5 attempts then give up
        for _ in 0..<5 {
            // Honor server-supplied retry-after on the first attempt only;
            // subsequent attempts use exponential backoff.
            let delay: TimeInterval
            if firstAttempt, case .rateLimited(let retryAfter) = error {
                delay = retryAfter
            } else {
                delay = backoff.nextDelay()
            }
            firstAttempt = false
            do {
                try await clock.sleep(for: delay)
            } catch {
                return // cancelled
            }
            // The user may have called stop() while we were sleeping. If state
            // is no longer .reconnecting, abandon the retry loop quietly so we
            // don't stomp on whatever state stop() established.
            guard case .reconnecting = state else { return }

            let newStream = translationFactory.make(speaker: speaker)
            do {
                try await newStream.connect(target: target)
                // stop() may also race with the connect() await — re-check.
                guard case .reconnecting = state else {
                    await newStream.close()
                    return
                }
                // Success — replace stream reference and re-wire pipeline
                switch speaker {
                case .peer:
                    peerStream = newStream
                    wireIncomingPipeline(stream: newStream)
                case .me:
                    meStream = newStream
                    // Drain the outbound audio ring buffer onto the
                    // fresh stream BEFORE `wireOutgoingPipeline` starts
                    // the new mic-frame consumer. This replays the
                    // last ~3 s of in-flight audio so a brief WS flap
                    // doesn't drop the user's mid-phrase. The send
                    // happens off-actor in an unstructured Task because
                    // each `await newStream.send` may yield, and we
                    // don't want to block this @MainActor function.
                    if let buf = audioBufferBySpeaker[.me] {
                        let buffered = buf.drain()
                        if !buffered.isEmpty {
                            Self.log.info("flushing \(buffered.count) buffered audio frames to fresh me-stream")
                            Task { [newStream] in
                                for f in buffered { await newStream.send(f) }
                            }
                        }
                    }
                    // Re-derive the destination from the active mode
                    // so a test-mode session that flapped doesn't
                    // accidentally route to BlackHole 2ch after the
                    // reconnect. .listen never reaches here because
                    // it doesn't have a me-stream.
                    wireOutgoingPipeline(
                        stream: newStream,
                        destination: mode == .test ? .speakers : .virtualMic
                    )
                }
                observeConnectionState(stream: newStream, speaker: speaker, target: target, mode: mode)
                // Preserve the original session start time across reconnects
                // so the popover timer keeps counting from the user's click
                // instead of bouncing back to 00:00. `sessionStartedAt` is
                // guaranteed non-nil here because `start()` set it before
                // ever transitioning to .translating.
                let startedAt = sessionStartedAt ?? clock.now()
                state = .translating(mode: mode, startedAt: startedAt)
                // Reconnect succeeded — disarm the watchdog so it
                // doesn't fire later and tear down a healthy session.
                cancelReconnectWatchdog()
                // Drop the pre-failure activity timestamp for this
                // speaker. Without this, the slow-detection loop
                // would see `now - lastDelta[speaker]` = (failure
                // duration + retry backoff + reconnect latency) and
                // fire phantom `.slow` the moment a post-reconnect
                // mic frame stamps `lastAudibleMicAt` fresh — same
                // class of bug iter-2 caught for resumeStreams
                // (iter-3 review finding).
                lastDeltaAtBySpeaker[speaker] = nil
                healthBySpeaker[speaker] = .healthy
                recomputeAggregateHealth()
                return
            } catch {
                // Close the half-connected stream before retrying. Without
                // this, every failed attempt leaks the WS + its URLSession
                // + the receive/closeReason tasks — connect() opens the WS
                // before sending session.update, so if session.update is
                // what threw, the WS is alive with no owner.
                await newStream.close()
                continue // try next backoff iteration
            }
        }
        // All retries failed
        Self.log.error("handleStreamFailure — all reconnect attempts exhausted → .error(.networkLost)")
        await stopAllStreams()
        state = .error(.networkLost)
    }

    /// Tear down all active streams and pipeline tasks without flipping
    /// state to `.idle`. Used by the terminal-error paths so we leave the
    /// state at `.error(...)` instead of clobbering it back to `.idle`,
    /// which would hide the failure from the popover.
    private func stopAllStreams() async {
        cancelReconnectWatchdog()
        cancelNoDataWatchdog()
        stopNetworkObserver()
        cancelPauseRecoveryWatchdog()
        cancelRecoveringFlash()
        stopSlowDetectionLoop()
        healthBySpeaker = [:]
        lastDeltaAtBySpeaker = [:]
        lastAudibleMicAt = nil
        lastAudiblePeerAt = nil
        connectivityHealth = .healthy
        silentFrameWatchdog?.stop()
        silentFrameWatchdog = nil
        for t in globalTasks { t.cancel() }
        for (_, tasks) in pipelineTasksBySpeaker {
            for t in tasks { t.cancel() }
        }
        for (_, t) in reconnectTasks { t.cancel() }
        globalTasks.removeAll()
        pipelineTasksBySpeaker.removeAll()
        reconnectTasks.removeAll()
        // Drop the per-speaker ring buffers entirely on stop — a fresh
        // start() re-allocates them. Keeping the instance around past
        // session boundaries would leak stale audio into a later
        // reconnect from an unrelated session.
        audioBufferBySpeaker.removeAll()
        // Tear capture + playback down OFF the main thread. These call
        // synchronous CoreAudio HAL teardown — Process Tap
        // aggregate-device + tap destroy, AVAudioEngine.stop,
        // AVCaptureSession.stopRunning — which do IPC to coreaudiod and
        // can block for seconds, or hang outright if coreaudiod is
        // wedged. `stopAllStreams()` runs on the @MainActor (stop() is
        // awaited from the popover on the main thread), so doing this
        // inline froze the whole UI on Stop and forced a kill via
        // Activity Monitor (the log ended at `[tap.stop] reason=user`,
        // mid-teardown). Hopping to a detached task keeps the main
        // thread servicing the run loop while CoreAudio tears down; the
        // `await` resumes us once it finishes. (Apple also recommends
        // calling `AVCaptureSession.stopRunning()` off the main thread.)
        let mic = micCapture
        let peer = peerCapture
        let mixer = outputMixer
        let vmic = virtualMicPlayer
        let log = Self.log
        let teardown = Task.detached(priority: .userInitiated) {
            mic.stop()
            peer.stop()
            mixer.stop()
            vmic.stop()
        }
        // Bound the wait on the synchronous CoreAudio HAL teardown. The
        // mixdown-tap Stop wedge is fixed at its source (AVAudioOutputMixer.stop
        // resets rather than stops its players — `AVAudioPlayerNode.stop()`'s
        // completion-handler flush hangs while a Process Tap is active), but a
        // synchronous HAL call still can't be interrupted and coreaudiod IPC can
        // stall system-wide for reasons outside our control. Proceed to .idle
        // after 5s and let teardown finish (or stay abandoned) in the background
        // rather than freezing Stop forever (which forced a kill via Activity Monitor).
        let gate = StopTeardownGate()
        let finished = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            Task { await teardown.value; await gate.resume(cont, with: true) }
            Task { try? await Task.sleep(for: .seconds(5)); await gate.resume(cont, with: false) }
        }
        if !finished {
            log.error("stop — audio teardown exceeded 5s (coreaudiod IPC stalled); proceeding to idle, teardown continues in background")
        }
        await meStream?.close()
        await peerStream?.close()
        meStream = nil
        peerStream = nil
        sessionStartedAt = nil
    }

    public func stop() async {
        Self.log.info("stop() — tearing down session from state=\(String(describing: self.state))")
        await stopAllStreams()
        consecutiveEmptyCloses = [.me: 0, .peer: 0]
        state = .idle
        // Finalise any diagnostic dumps so the WAV `data` chunk size
        // gets patched from `0xFFFF_FFFF` to the actual byte count.
        // No-op when the env vars aren't set.
        WireDumper.shared.close()
        WireDumper.sent.close()
    }

    public func updateOriginalMixVolume(_ v: Float) {
        outputMixer.setOriginalGain(min(max(v, 0), 1))
    }

    /// Read per-speaker connectivity health for the diagnostic snapshot.
    /// Returns nil if the speaker's stream is not active.
    public func streamHealth(for speaker: Speaker) -> ConnectivityHealth? {
        healthBySpeaker[speaker]
    }

    // MARK: - Pipelines

    // Splitter / resampled streams use `.bufferingOldest(50)` —
    // when the buffer fills, the NEWEST (freshest, just-arrived)
    // frame is dropped instead of the OLDEST (about-to-be-played)
    // one.
    //
    // History:
    // - `.bufferingNewest(50)` (original): drops OLDEST on overflow
    //   → audible "chunk cut off mid-utterance" because the audio
    //   the user is about to hear gets silently discarded.
    // - `.unbounded` (briefly): no drops → unbounded memory +
    //   unbounded latency growth if the consumer ever stalls (with
    //   `PlaybackPacing.minRate=1.0` we cannot drain faster than
    //   real-time, so a sustained model burst keeps growing the
    //   buffer indefinitely).
    // - `.bufferingOldest(50)` (current): caps memory at
    //   ~5 s × 10 KB = ~0.5 MB per stream, and on overflow drops
    //   the freshest audio — the user might hear a brief tail
    //   stutter on the just-arrived burst, but the in-flight audio
    //   they're currently hearing is never cut off.
    private static let pipelineFrameBuffer = 50

    /// Quick RMS over the PCM samples in a frame, normalized to
    /// [0, 1]. Used by the mic-level diagnostic so support can tell
    /// "user spoke but app stayed silent" from "user spoke but mic
    /// was muted at the OS level". Returns 0 for empty / malformed
    /// frames. `nonisolated` because the peer splitter task (which
    /// runs off-MainActor) reads this; relying on Swift 5 mode to
    /// suppress the isolation check would break a future Swift 6
    /// migration.
    nonisolated static func rms(_ frame: AudioFrame) -> Float {
        let bytes = frame.pcm
        guard !bytes.isEmpty else { return 0 }
        switch frame.format {
        case .float32:
            return bytes.withUnsafeBytes { raw -> Float in
                let n = raw.count / MemoryLayout<Float>.size
                guard n > 0, let p = raw.bindMemory(to: Float.self).baseAddress else { return 0 }
                var sumSquares: Float = 0
                for i in 0..<n { sumSquares += p[i] * p[i] }
                return (sumSquares / Float(n)).squareRoot()
            }
        case .int16:
            return bytes.withUnsafeBytes { raw -> Float in
                let n = raw.count / MemoryLayout<Int16>.size
                guard n > 0, let p = raw.bindMemory(to: Int16.self).baseAddress else { return 0 }
                var sumSquares: Float = 0
                for i in 0..<n {
                    let s = Float(p[i]) / 32_768.0
                    sumSquares += s * s
                }
                return (sumSquares / Float(n)).squareRoot()
            }
        }
    }

    /// Where the translated me-stream audio should be sent.
    /// `.virtualMic` = BlackHole 2ch (peer's Zoom hears it).
    /// `.speakers`   = local outputMixer (user hears their own
    /// translated voice — used by `.test` mode).
    enum OutgoingDestination {
        case virtualMic
        case speakers
    }

    private func wireOutgoingPipeline(stream: any TranslationStream, destination: OutgoingDestination) {
        let micFrames = micCapture.start(deviceUID: currentSettings.inputDeviceUID)
        let transformer = self.transformer
        // Capture the buffer reference on @MainActor (right here) so
        // the off-actor mic pump doesn't read `audioBufferBySpeaker`
        // — a Dictionary — concurrently with MainActor mutations
        // (`removeAll`, reassignment, etc.). The AudioRingBuffer
        // instance itself is internally lock-guarded, so calling
        // `append` on the captured reference off-actor is safe.
        // On reconnect or pause the outer task is cancelled, so even
        // if a late frame slips in here it lands on the (now-orphan)
        // old buffer rather than racing the live one.
        // (Review finding #1 — the previous version's "captured into
        // a local under main once (above)" comment was lying.)
        let outboundBuffer = audioBufferBySpeaker[.me]
        let task1 = Task { [stream, outboundBuffer, weak self] in
            var frameIndex = 0
            for await frame in micFrames {
                // First mic frame proves the capture engine spun up
                // and the tap is delivering — watchdog uses this to
                // distinguish "user silent" (don't alert) from "mic
                // dead" (do alert). We also compute RMS so the
                // diagnostic log can show whether the mic is hot
                // (real audio) or pegged at silence (muted / wrong
                // device / system gain at 0).
                let rms = Self.rms(frame)
                let formatLabel = String(describing: frame.format)
                let sampleRate = frame.sampleRate
                let idx = frameIndex
                await MainActor.run { [weak self] in
                    self?.markMicFrameReceived(format: formatLabel, sampleRate: sampleRate, rms: rms)
                    self?.logMicLevel(rms: rms, frameIndex: idx)
                }
                let wire = transformer.toWire(frame)
                outboundBuffer?.append(wire)
                await stream.send(wire)
                frameIndex += 1
            }
        }
        // The "deliver translated audio downstream" task. The branch
        // on `destination` picks the player: BlackHole2chPlayer for
        // real-call virtual-mic mode, or AVAudioOutputMixer's
        // translated-player for test-mode local playback.
        let task2 = Task { [virtualMicPlayer, outputMixer, stream, transformer, weak self] in
            var resampledContinuation: AsyncStream<AudioFrame>.Continuation!
            let resampled = AsyncStream<AudioFrame>(bufferingPolicy: .bufferingOldest(Self.pipelineFrameBuffer)) {
                resampledContinuation = $0
            }
            let pump = Task {
                for await wireFrame in stream.output {
                    // Diagnostic dump of the raw model output. Both
                    // the me-stream pump (this site, used in `.call`
                    // and `.test`) AND the peer-stream pump (the
                    // wireIncomingPipeline equivalent below) write to
                    // the shared `WireDumper.shared`. In `.call` mode
                    // the resulting WAV interleaves both directions
                    // — interpret per arrival timestamps if you need
                    // to separate them.
                    WireDumper.shared.write(wireFrame.pcm)
                    // First audio delta from the server — disarm the
                    // no-data watchdog. `markFirstDataReceived` is
                    // @MainActor-isolated; this Task isn't, so hop
                    // explicitly. Doing it in the pipeline (not in
                    // the stream's handle()) means we mark "we
                    // actually delivered data" rather than just "we
                    // parsed an event".
                    await MainActor.run { [weak self] in
                        self?.recordDeltaArrival(speaker: .me)
                        self?.markFirstDataReceived()
                    }
                    resampledContinuation.yield(transformer.fromWire(wireFrame, targetSampleRate: 48_000))
                }
                resampledContinuation.finish()
            }
            switch destination {
            case .virtualMic:
                await virtualMicPlayer.play(resampled)
            case .speakers:
                // Re-use the outputMixer's "translated" player slot —
                // in `.test` mode the mixer is only carrying our own
                // translated track (no peer audio), so the player
                // delivers it straight to the user's speakers at
                // full volume.
                await outputMixer.playTranslated(resampled)
            }
            pump.cancel()
        }
        let task3 = Task { @MainActor [transcript, stream, weak self] in
            for await d in stream.transcripts {
                self?.recordDeltaArrival(speaker: .me)
                self?.markFirstDataReceived()
                transcript.apply(d)
            }
        }
        pipelineTasksBySpeaker[.me, default: []].append(contentsOf: [task1, task2, task3])
    }

    private func wireIncomingPipeline(stream: any TranslationStream) {
        let peerFrames = peerCapture.start()
        let transformer = self.transformer

        var translationContinuation: AsyncStream<AudioFrame>.Continuation!
        var passthroughContinuation: AsyncStream<AudioFrame>.Continuation!
        let translationFrames = AsyncStream<AudioFrame>(bufferingPolicy: .bufferingOldest(Self.pipelineFrameBuffer)) {
            translationContinuation = $0
        }
        let passthroughFrames = AsyncStream<AudioFrame>(bufferingPolicy: .bufferingOldest(Self.pipelineFrameBuffer)) {
            passthroughContinuation = $0
        }

        // Silent-frame heuristic — informational only. It cannot distinguish
        // "TCC denied capture" from "nothing is playing right now": both
        // produce all-zero samples from Process Tap. We saw the false-positive
        // when TCC log explicitly returned `Auth Right: Allowed (User Consent)`
        // for kTCCServiceAudioCapture but the user wasn't playing any audio
        // when they clicked Start. Hard-erroring the session in that case is
        // wrong UX. We keep the watchdog at a longer threshold and use it for
        // diagnostics only — don't punish a quiet meeting start.
        let watchdog = SilentFrameWatchdog(thresholdSeconds: 30) { [weak self] in
            Task { @MainActor [weak self] in
                Self.log.info("Silent-frame watchdog — 30s of zero amplitude; either TCC denied capture or no app is producing audio right now")
                _ = self  // intentionally not flipping state to .error
            }
        }
        // Stop the previous watchdog BEFORE overwriting — otherwise a
        // reconnect / resume orphans the old one and N flaps produce N
        // parallel watchdogs racing the same callback (review
        // finding #4).
        silentFrameWatchdog?.stop()
        watchdog.start()
        self.silentFrameWatchdog = watchdog

        let splitter = Task { [weak self] in
            for await frame in peerFrames {
                watchdog.observe(frame.pcm)
                // Stamp peer audibility for slow-detection's per-side
                // gate. RMS is computed off-actor (Self.rms is a pure
                // static); the MainActor hop is only for the property
                // write. We avoid hopping on every frame by checking
                // the threshold here first and skipping the hop when
                // it'd be a no-op.
                let rms = Self.rms(frame)
                if rms >= Self.micAudibleRMSThreshold {
                    await MainActor.run { [weak self] in
                        self?.markPeerFrameReceived(rms: rms)
                    }
                }
                translationContinuation.yield(frame)
                passthroughContinuation.yield(frame)
            }
            translationContinuation.finish()
            passthroughContinuation.finish()
        }
        let sender = Task { [stream] in
            for await frame in translationFrames {
                let wire = transformer.toWire(frame)
                // Dump what we sent to OpenAI (24 kHz int16 mono).
                // Pairs with WireDumper.shared (model output) — if SENT
                // is amplitude-stable but WIRE fades, the model is the
                // culprit.
                WireDumper.sent.write(wire.pcm)
                await stream.send(wire)
            }
        }
        let translatedPlay = Task { [outputMixer, stream, transformer, weak self] in
            var resampledContinuation: AsyncStream<AudioFrame>.Continuation!
            let resampled = AsyncStream<AudioFrame>(bufferingPolicy: .bufferingOldest(Self.pipelineFrameBuffer)) {
                resampledContinuation = $0
            }
            let pump = Task {
                for await wireFrame in stream.output {
                    // Diagnostic dump of the raw model output (before
                    // any Resampler / scheduling / playback). Guarded
                    // by env var; silent no-op otherwise. Pairs with
                    // UNISON_DUMP_PLAYBACK_WAV (the post-timePitch
                    // tap) for A/B comparison of what the model
                    // emits vs what the speakers receive.
                    WireDumper.shared.write(wireFrame.pcm)
                    await MainActor.run { [weak self] in
                        self?.recordDeltaArrival(speaker: .peer)
                        self?.markFirstDataReceived()
                    }
                    resampledContinuation.yield(transformer.fromWire(wireFrame, targetSampleRate: 48_000))
                }
                resampledContinuation.finish()
            }
            await outputMixer.playTranslated(resampled)
            pump.cancel()
        }
        let originalPlay = Task { [outputMixer] in
            await outputMixer.playOriginal(passthroughFrames)
        }
        let transcripts = Task { @MainActor [transcript, stream, weak self] in
            for await d in stream.transcripts {
                self?.recordDeltaArrival(speaker: .peer)
                self?.markFirstDataReceived()
                transcript.apply(d)
            }
        }
        pipelineTasksBySpeaker[.peer, default: []].append(contentsOf: [splitter, sender, translatedPlay, originalPlay, transcripts])
    }
}

/// One-shot gate for the stop-teardown-vs-timeout race: whichever finishes
/// first resumes the continuation; the loser's call is a no-op. Ensures the
/// continuation resumes exactly once.
private actor StopTeardownGate {
    private var resumed = false
    func resume(_ cont: CheckedContinuation<Bool, Never>, with value: Bool) {
        guard !resumed else { return }
        resumed = true
        cont.resume(returning: value)
    }
}
