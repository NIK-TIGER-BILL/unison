import Foundation
import Observation

@MainActor
@Observable
public final class TranslationOrchestrator {
    public private(set) var state: SessionState = .idle
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
    private var pipelineTasks: [Task<Void, Never>] = []
    private var currentLanguages: LanguagePair = .default
    private var currentSettings: Settings = .default

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
        guard case .idle = state else { return }
        state = .connecting(mode: mode)
        currentLanguages = languages
        currentSettings = settings
        transcript.clear()

        if mode == .call {
            let status = permissions.currentStatus(.microphone)
            let resolved = status == .notDetermined ? await permissions.request(.microphone) : status
            guard resolved == .granted else { state = .error(.permissionDenied(.microphone)); return }
            guard deviceRegistry.findBlackHole2ch() != nil else { state = .error(.blackHole2chMissing); return }
        }
        guard deviceRegistry.findBlackHole16ch() != nil else { state = .error(.blackHole16chMissing); return }

        do {
            try await outputMixer.start(deviceUID: settings.outputDeviceUID)
            outputMixer.setOriginalGain(settings.originalMixVolume)
        } catch {
            state = .error(.outputDeviceUnavailable); return
        }

        // Peer (incoming) stream — used in both modes
        let peer = translationFactory.make(speaker: .peer)
        peerStream = peer
        do {
            try await peer.connect(target: languages.mine)
        } catch {
            state = .error(mapConnectError(error))
            return
        }
        wireIncomingPipeline(stream: peer)
        observeConnectionState(stream: peer, speaker: .peer, target: languages.mine, mode: mode)

        if mode == .call {
            let me = translationFactory.make(speaker: .me)
            meStream = me
            do {
                try await me.connect(target: languages.peer)
            } catch {
                state = .error(mapConnectError(error))
                return
            }
            wireOutgoingPipeline(stream: me)
            observeConnectionState(stream: me, speaker: .me, target: languages.peer, mode: mode)
        }

        state = .translating(mode: mode, startedAt: clock.now())
    }

    private func mapConnectError(_ error: Error) -> TranslationError {
        if let te = error as? TranslationError { return te }
        return .networkLost
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
                guard let self else { return }
                switch connState {
                case .failed(let err):
                    await self.handleStreamFailure(error: err, speaker: speaker, target: target, mode: mode)
                case .disconnected:
                    // Treat ungraceful disconnect as failure while translating
                    if case .translating = self.state {
                        await self.handleStreamFailure(error: .networkLost, speaker: speaker, target: target, mode: mode)
                    }
                case .connecting, .connected, .reconnecting:
                    break
                }
            }
        }
        pipelineTasks.append(task)
    }

    private func handleStreamFailure(
        error: TranslationError,
        speaker: Speaker,
        target: Language,
        mode: SessionMode
    ) async {
        // Don't try to recover from terminal errors
        switch error {
        case .apiKeyInvalid, .insufficientCredits, .permissionDenied:
            state = .error(error)
            return
        default:
            break
        }
        state = .reconnecting(mode: mode, since: clock.now())
        var backoff = BackoffPolicy(initial: 1, cap: 30)
        // Re-create the stream and try again, up to 5 attempts then give up
        for _ in 0..<5 {
            let delay = backoff.nextDelay()
            do {
                try await clock.sleep(for: delay)
            } catch {
                return // cancelled
            }
            if Task.isCancelled { return }
            let newStream = translationFactory.make(speaker: speaker)
            do {
                try await newStream.connect(target: target)
                // Success — replace stream reference and re-wire pipeline
                switch speaker {
                case .peer:
                    peerStream = newStream
                    wireIncomingPipeline(stream: newStream)
                case .me:
                    meStream = newStream
                    wireOutgoingPipeline(stream: newStream)
                }
                observeConnectionState(stream: newStream, speaker: speaker, target: target, mode: mode)
                state = .translating(mode: mode, startedAt: clock.now())
                return
            } catch {
                continue // try next backoff iteration
            }
        }
        // All retries failed
        state = .error(.networkLost)
    }

    public func stop() async {
        for t in pipelineTasks { t.cancel() }
        pipelineTasks.removeAll()
        micCapture.stop()
        peerCapture.stop()
        outputMixer.stop()
        virtualMicPlayer.stop()
        await meStream?.close()
        await peerStream?.close()
        meStream = nil
        peerStream = nil
        state = .idle
    }

    public func updateOriginalMixVolume(_ v: Float) {
        outputMixer.setOriginalGain(min(max(v, 0), 1))
    }

    // MARK: - Pipelines

    private func wireOutgoingPipeline(stream: any TranslationStream) {
        let micFrames = micCapture.start(deviceUID: currentSettings.inputDeviceUID)
        let transformer = self.transformer
        let task1 = Task { [stream] in
            for await frame in micFrames {
                let wire = transformer.toWire(frame)
                await stream.send(wire)
            }
        }
        let task2 = Task { [virtualMicPlayer, stream, transformer] in
            let resampled = AsyncStream<AudioFrame> { continuation in
                Task {
                    for await wireFrame in stream.output {
                        continuation.yield(transformer.fromWire(wireFrame, targetSampleRate: 48_000))
                    }
                    continuation.finish()
                }
            }
            await virtualMicPlayer.play(resampled)
        }
        let task3 = Task { @MainActor [transcript, stream] in
            for await d in stream.transcripts {
                transcript.apply(d)
            }
        }
        pipelineTasks.append(contentsOf: [task1, task2, task3])
    }

    private func wireIncomingPipeline(stream: any TranslationStream) {
        let peerFrames = peerCapture.start()
        let transformer = self.transformer

        var translationContinuation: AsyncStream<AudioFrame>.Continuation!
        var passthroughContinuation: AsyncStream<AudioFrame>.Continuation!
        let translationFrames = AsyncStream<AudioFrame> { translationContinuation = $0 }
        let passthroughFrames = AsyncStream<AudioFrame> { passthroughContinuation = $0 }

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
        let translatedPlay = Task { [outputMixer, stream, transformer] in
            let resampled = AsyncStream<AudioFrame> { continuation in
                Task {
                    for await wireFrame in stream.output {
                        continuation.yield(transformer.fromWire(wireFrame, targetSampleRate: 48_000))
                    }
                    continuation.finish()
                }
            }
            await outputMixer.playTranslated(resampled)
        }
        let originalPlay = Task { [outputMixer] in
            await outputMixer.playOriginal(passthroughFrames)
        }
        let transcripts = Task { @MainActor [transcript, stream] in
            for await d in stream.transcripts {
                transcript.apply(d)
            }
        }
        pipelineTasks.append(contentsOf: [splitter, sender, translatedPlay, originalPlay, transcripts])
    }
}
