import Foundation
import Observation

@MainActor
@Observable
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

    private var meStream: (any TranslationStream)?
    private var peerStream: (any TranslationStream)?
    // Pipeline tasks bucketed per speaker so a reconnect cancels exactly the
    // tasks bound to the failed stream and leaves the healthy side untouched.
    private var pipelineTasksBySpeaker: [Speaker: [Task<Void, Never>]] = [:]
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
        transformer: any AudioFormatTransformer
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
        // only consumes BlackHole 16ch, no mic permission needed.
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
        // BlackHole device gates. Only required by modes that touch
        // BlackHole — `.call` writes to BH 2ch (virtual mic) and reads
        // BH 16ch (system audio). `.listen` only reads BH 16ch.
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
        if mode == .call || mode == .listen {
            guard deviceRegistry.findBlackHole16ch() != nil else {
                Self.log.error("start() guard failed: BlackHole 16ch not found → .error(.blackHole16chMissing)")
                state = .error(.blackHole16chMissing)
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
            Self.log.info("start() — connecting me stream (target=\(languages.peer.rawValue))")
            let me = translationFactory.make(speaker: .me)
            meStream = me
            do {
                try await me.connect(target: languages.peer)
            } catch {
                let mapped = mapConnectError(error)
                Self.log.error("start() me.connect failed: \(String(describing: error)) → .error(\(String(describing: mapped)))")
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
        guard !anyMicFrameThisSession else { return }
        anyMicFrameThisSession = true
        Self.log.info("first mic frame — format=\(format) sampleRate=\(sampleRate)Hz rms=\(String(format: "%.5f", rms))")
        if rms < 0.0005 {
            Self.log.error("first mic frame — RMS \(String(format: "%.5f", rms)) is near-silent; OpenAI VAD will not trigger. Check the input gain in System Settings → Sound, or pick a different mic in the popover.")
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

        // BlackHole 16ch is required in both modes — losing it is fatal.
        if deviceRegistry.findBlackHole16ch() == nil {
            Self.log.error("handleDeviceChange — BlackHole 16ch disappeared mid-session → stop + .error(.blackHole16chMissing)")
            Task { @MainActor in
                await self.stop()
                self.state = .error(.blackHole16chMissing)
            }
            return
        }
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
                    case .translating, .reconnecting:
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
        // us on the first message. If we see this twice in a row on the
        // same speaker, escalate to terminal `.apiKeyInvalid` so the user
        // gets a clear error instead of a `.translating ↔ .reconnecting`
        // flicker.
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
        for t in globalTasks { t.cancel() }
        for (_, tasks) in pipelineTasksBySpeaker {
            for t in tasks { t.cancel() }
        }
        globalTasks.removeAll()
        pipelineTasksBySpeaker.removeAll()
        micCapture.stop()
        peerCapture.stop()
        outputMixer.stop()
        virtualMicPlayer.stop()
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
    }

    public func updateOriginalMixVolume(_ v: Float) {
        outputMixer.setOriginalGain(min(max(v, 0), 1))
    }

    // MARK: - Pipelines

    // Bound buffer size for splitter/resampled streams. At ~100ms per frame,
    // 50 frames ≈ 5 seconds of audio — enough to ride out brief network
    // stalls while preventing unbounded memory growth on prolonged stalls.
    private static let pipelineFrameBuffer = 50

    /// Quick RMS over the PCM samples in a frame, normalized to
    /// [0, 1]. Used by the mic-level diagnostic so support can tell
    /// "user spoke but app stayed silent" from "user spoke but mic
    /// was muted at the OS level". Returns 0 for empty / malformed
    /// frames.
    private static func rms(_ frame: AudioFrame) -> Float {
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
        let task1 = Task { [stream, weak self] in
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
            let resampled = AsyncStream<AudioFrame>(bufferingPolicy: .bufferingNewest(Self.pipelineFrameBuffer)) {
                resampledContinuation = $0
            }
            let pump = Task {
                for await wireFrame in stream.output {
                    // First audio delta from the server — disarm the
                    // no-data watchdog. `markFirstDataReceived` is
                    // @MainActor-isolated; this Task isn't, so hop
                    // explicitly. Doing it in the pipeline (not in
                    // the stream's handle()) means we mark "we
                    // actually delivered data" rather than just "we
                    // parsed an event".
                    await MainActor.run { self?.markFirstDataReceived() }
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
        let translationFrames = AsyncStream<AudioFrame>(bufferingPolicy: .bufferingNewest(Self.pipelineFrameBuffer)) {
            translationContinuation = $0
        }
        let passthroughFrames = AsyncStream<AudioFrame>(bufferingPolicy: .bufferingNewest(Self.pipelineFrameBuffer)) {
            passthroughContinuation = $0
        }

        let splitter = Task {
            for await frame in peerFrames {
                translationContinuation.yield(frame)
                passthroughContinuation.yield(frame)
            }
            translationContinuation.finish()
            passthroughContinuation.finish()
        }
        let sender = Task { [stream] in
            for await frame in translationFrames {
                let wire = transformer.toWire(frame)
                await stream.send(wire)
            }
        }
        let translatedPlay = Task { [outputMixer, stream, transformer, weak self] in
            var resampledContinuation: AsyncStream<AudioFrame>.Continuation!
            let resampled = AsyncStream<AudioFrame>(bufferingPolicy: .bufferingNewest(Self.pipelineFrameBuffer)) {
                resampledContinuation = $0
            }
            let pump = Task {
                for await wireFrame in stream.output {
                    await MainActor.run { self?.markFirstDataReceived() }
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
                self?.markFirstDataReceived()
                transcript.apply(d)
            }
        }
        pipelineTasksBySpeaker[.peer, default: []].append(contentsOf: [splitter, sender, translatedPlay, originalPlay, transcripts])
    }
}
