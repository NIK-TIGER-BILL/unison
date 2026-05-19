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
        try? await peer.connect(target: languages.mine)
        wireIncomingPipeline(stream: peer)

        if mode == .call {
            let me = translationFactory.make(speaker: .me)
            meStream = me
            try? await me.connect(target: languages.peer)
            wireOutgoingPipeline(stream: me)
        }

        state = .translating(mode: mode, startedAt: clock.now())
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
                let mine = TranscriptDelta(
                    entryId: d.entryId, speaker: .me, kind: d.kind,
                    text: d.text, isFinal: d.isFinal
                )
                transcript.apply(mine)
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
                let peer = TranscriptDelta(
                    entryId: d.entryId, speaker: .peer, kind: d.kind,
                    text: d.text, isFinal: d.isFinal
                )
                transcript.apply(peer)
            }
        }
        pipelineTasks.append(contentsOf: [splitter, sender, translatedPlay, originalPlay, transcripts])
    }
}
