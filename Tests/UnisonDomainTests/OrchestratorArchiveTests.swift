import Foundation
import Testing
@testable import UnisonDomain

@MainActor
private func makeOrchestrator(store: any MeetingStore) -> TranslationOrchestrator {
    let registry = MockAudioDeviceRegistry()
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .granted
    return TranslationOrchestrator(
        micCapture: MockMicrophoneCapture(),
        peerCapture: MockPeerAudioCapture(),
        outputMixer: MockAudioOutputMixer(),
        virtualMicPlayer: MockAudioPlayer(),
        translationFactory: MockTranslationStreamFactory(),
        permissions: perms,
        deviceRegistry: registry,
        clock: SystemClock(),
        transformer: MockAudioFormatTransformer(),
        networkMonitor: MockNetworkPathMonitor(initial: .satisfied),
        meetingStore: store
    )
}

@MainActor
private func makeOrchestratorForE2E(store: any MeetingStore) -> TranslationOrchestrator {
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .granted
    return TranslationOrchestrator(
        micCapture: MockMicrophoneCapture(),
        peerCapture: MockPeerAudioCapture(),
        outputMixer: MockAudioOutputMixer(),
        virtualMicPlayer: MockAudioPlayer(),
        translationFactory: MockTranslationStreamFactory(),
        permissions: perms,
        deviceRegistry: registry,
        clock: InstantClock(),
        transformer: MockAudioFormatTransformer(),
        networkMonitor: MockNetworkPathMonitor(initial: .satisfied),
        meetingStore: store
    )
}

@MainActor
private func seedOneEntry(_ orch: TranslationOrchestrator) {
    orch.transcript.currentLanguagePair = .default
    orch.transcript.apply(TranscriptDelta(
        entryId: UUID(), speaker: .peer, kind: .translated, text: "Привет", isFinal: true))
}

@MainActor
@Test func archiveSession_savesCallWithEntries() {
    let store = InMemoryMeetingStore()
    let orch = makeOrchestrator(store: store)
    seedOneEntry(orch)
    orch.archiveSession(mode: .call, startedAt: Date(timeIntervalSince1970: 1000), enabled: true)
    #expect(store.list().count == 1)
    #expect(store.list().first?.mode == .call)
    #expect(store.list().first?.lineCount == 1)
}

@MainActor
@Test func archiveSession_skipsTestMode() {
    let store = InMemoryMeetingStore()
    let orch = makeOrchestrator(store: store)
    seedOneEntry(orch)
    orch.archiveSession(mode: .test, startedAt: Date(), enabled: true)
    #expect(store.list().isEmpty)
}

@MainActor
@Test func archiveSession_skipsEmptyTranscript() {
    let store = InMemoryMeetingStore()
    let orch = makeOrchestrator(store: store)
    orch.archiveSession(mode: .call, startedAt: Date(), enabled: true)
    #expect(store.list().isEmpty)
}

@MainActor
@Test func archiveSession_skipsWhenDisabled() {
    let store = InMemoryMeetingStore()
    let orch = makeOrchestrator(store: store)
    seedOneEntry(orch)
    orch.archiveSession(mode: .call, startedAt: Date(), enabled: false)
    #expect(store.list().isEmpty)
}

@MainActor
@Test func archiveSession_savesListenSession() {
    let store = InMemoryMeetingStore()
    let orch = makeOrchestrator(store: store)
    seedOneEntry(orch)
    orch.archiveSession(mode: .listen, startedAt: Date(timeIntervalSince1970: 1000), enabled: true)
    #expect(store.list().count == 1)
    #expect(store.list().first?.mode == .listen)
}

@MainActor
@Test func stopArchivesSession_endToEnd() async {
    let store = InMemoryMeetingStore()
    let orch = makeOrchestratorForE2E(store: store)

    await orch.start(mode: .call, languages: .default)
    guard case .translating(let mode, _) = orch.state else {
        Issue.record("Expected .translating after start(), got \(orch.state)")
        return
    }
    #expect(mode == .call)

    // Seed a transcript entry so archiveSession doesn't skip the record.
    orch.transcript.apply(TranscriptDelta(
        entryId: UUID(), speaker: .peer, kind: .translated, text: "Привет", isFinal: true))

    await orch.stop()

    #expect(store.list().count == 1)
    #expect(store.list().first?.mode == .call)
}

@MainActor
@Test func archiveActiveSession_savesWhenTranslating() async {
    let store = InMemoryMeetingStore()
    let orch = makeOrchestratorForE2E(store: store)
    await orch.start(mode: .call, languages: .default)
    seedOneEntry(orch)
    orch.archiveActiveSession()
    #expect(store.list().count == 1)
    #expect(store.list().first?.mode == .call)
}

@MainActor
@Test func archiveActiveSession_noopWhenIdle() {
    let store = InMemoryMeetingStore()
    let orch = makeOrchestrator(store: store)   // state stays .idle
    seedOneEntry(orch)
    orch.archiveActiveSession()
    #expect(store.list().isEmpty)
}

@MainActor
@Test func archiveActiveSession_respectsLiveSaveHistoryToggle() async {
    let store = InMemoryMeetingStore()
    let orch = makeOrchestratorForE2E(store: store)
    await orch.start(mode: .call, languages: .default)
    seedOneEntry(orch)
    orch.updateSaveHistoryEnabled(false)   // user disables history mid-session
    orch.archiveActiveSession()
    #expect(store.list().isEmpty)          // in-flight session must NOT be archived
}

@MainActor
@Test func stopArchivesSession_afterTerminalError() async throws {
    // Regression: a session that ends in a terminal `.error` state was
    // previously never archived because `stop()` and `archiveActiveSession()`
    // sourced mode/startedAt from the live `state`, which is nil for
    // `.error`. With `pendingArchiveMeta` the last good values survive the
    // error transition and are consumed on stop.
    let store = InMemoryMeetingStore()
    let orch = makeOrchestratorForE2E(store: store)
    await orch.start(mode: .call, languages: .default)
    guard case .translating = orch.state else {
        Issue.record("Expected .translating after start(), got \(orch.state)")
        return
    }
    seedOneEntry(orch)

    // Drive a terminal error mid-session. `.apiKeyInvalid` with
    // `receivedAnyData: true` hits the terminal-error early-return in
    // `handleStreamFailure` (before the empty-close counter), so the
    // orchestrator transitions straight to `.error(.apiKeyInvalid)` via
    // `stopAllStreams() + state = .error(...)` — the same path taken by
    // a real mid-session invalid-key failure.
    let factory = MockTranslationStreamFactory()
    // The orchestrator under test was constructed with its own factory
    // inside makeOrchestratorForE2E; we need the streams it created.
    // Instead, rebuild a fresh orchestrator with our observable factory.
    let store2 = InMemoryMeetingStore()
    let registry2 = MockAudioDeviceRegistry()
    registry2.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    let perms2 = MockPermissionsService()
    perms2.statuses[.microphone] = .granted
    let orch2 = TranslationOrchestrator(
        micCapture: MockMicrophoneCapture(),
        peerCapture: MockPeerAudioCapture(),
        outputMixer: MockAudioOutputMixer(),
        virtualMicPlayer: MockAudioPlayer(),
        translationFactory: factory,
        permissions: perms2,
        deviceRegistry: registry2,
        clock: InstantClock(),
        transformer: MockAudioFormatTransformer(),
        networkMonitor: MockNetworkPathMonitor(initial: .satisfied),
        meetingStore: store2
    )
    await orch2.start(mode: .call, languages: .default)
    guard case .translating = orch2.state else {
        Issue.record("Expected .translating after start(), got \(orch2.state)")
        return
    }
    seedOneEntry(orch2)

    // Terminal error: apiKeyInvalid with receivedAnyData:true goes through
    // the terminal-error branch in handleStreamFailure directly.
    factory.streams[.peer]?.emitConnectionState(.failed(.apiKeyInvalid, receivedAnyData: true))

    // Wait for the orchestrator to reach .error.
    for _ in 0..<200 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if case .error = orch2.state { break }
    }
    guard case .error(.apiKeyInvalid) = orch2.state else {
        Issue.record("Expected .error(.apiKeyInvalid), got \(orch2.state)")
        return
    }

    // stop() must archive the session even though state is .error.
    await orch2.stop()
    #expect(store2.list().count == 1)
    #expect(store2.list().first?.mode == .call)
}

// Dual-write wiring: a transcript delta coming off the STREAM must reach the
// orchestrator's `transcriptModel` (the live-display source of truth), not only
// the history `transcript` store. Drives the real pipeline, not a direct apply.
@MainActor
@Test func dualWrite_streamDeltaReachesTranscriptModel() async throws {
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .granted
    let factory = MockTranslationStreamFactory()
    let orch = TranslationOrchestrator(
        micCapture: MockMicrophoneCapture(),
        peerCapture: MockPeerAudioCapture(),
        outputMixer: MockAudioOutputMixer(),
        virtualMicPlayer: MockAudioPlayer(),
        translationFactory: factory,
        permissions: perms,
        deviceRegistry: registry,
        clock: InstantClock(),
        transformer: MockAudioFormatTransformer(),
        networkMonitor: MockNetworkPathMonitor(initial: .satisfied)
    )
    await orch.start(mode: .call, languages: .default)
    guard case .translating = orch.state else {
        Issue.record("Expected .translating after start(), got \(orch.state)")
        return
    }

    // Emit an utterance through the peer STREAM (not `orch.transcript` directly).
    let peer = factory.streams[.peer]
    peer?.emitTranscript(TranscriptDelta(entryId: UUID(), speaker: .peer, kind: .original,
                                         text: "Hello there.", isFinal: false, language: .en))
    peer?.emitTranscript(TranscriptDelta(entryId: UUID(), speaker: .peer, kind: .translated,
                                         text: "Привет.", isFinal: false, language: .ru))

    // Let the pipeline task consume the yielded deltas (InstantClock stays at 0,
    // so the segment never pauses → it remains the live bubble carrying both).
    var bubble: TranscriptBubble?
    for _ in 0..<200 {
        try await Task.sleep(nanoseconds: 5_000_000)
        bubble = orch.transcriptModel.bubbles.first { $0.source == "Hello there." }
        if bubble?.translation == "Привет." { break }
    }
    #expect(bubble?.source == "Hello there.")
    #expect(bubble?.translation == "Привет.")   // dual-write delivered both to the model

    await orch.stop()
}
