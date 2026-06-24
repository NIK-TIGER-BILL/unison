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
