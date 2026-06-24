import Foundation
import Testing
@testable import UnisonDomain
@testable import UnisonUI

// MARK: - Helpers

@MainActor
private func makeOrchestrator(mixer: MockAudioOutputMixer = .init()) -> TranslationOrchestrator {
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .granted
    return TranslationOrchestrator(
        micCapture: MockMicrophoneCapture(),
        peerCapture: MockPeerAudioCapture(),
        outputMixer: mixer,
        virtualMicPlayer: MockAudioPlayer(),
        translationFactory: MockTranslationStreamFactory(),
        permissions: perms,
        deviceRegistry: registry,
        clock: SystemClock(),
        transformer: MockAudioFormatTransformer(),
        networkMonitor: MockNetworkPathMonitor(initial: .satisfied)
    )
}

@MainActor
@discardableResult
private func appendMe(_ store: TranscriptStore, _ original: String, _ translated: String) -> TranscriptEntry {
    let id = freshUUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: original, isFinal: true))
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .translated, text: translated, isFinal: true))
    return store.entries.last!
}

@MainActor
@discardableResult
private func appendPeer(_ store: TranscriptStore, _ original: String, _ translated: String) -> TranscriptEntry {
    let id = freshUUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .peer, kind: .original, text: original, isFinal: true))
    store.apply(TranscriptDelta(entryId: id, speaker: .peer, kind: .translated, text: translated, isFinal: true))
    return store.entries.last!
}

// MARK: - Pure helpers (size label, bubble scale, elapsed formatting)

@Test func transcriptVM_bubbleScale_interpolatesLinearlyBetween075and130() {
    // Endpoints
    #expect(TranscriptViewModel.bubbleScale(forSizeIndex: 0) == 0.75)
    #expect(TranscriptViewModel.bubbleScale(forSizeIndex: 4) == 1.30)
    // Midpoint
    let mid = TranscriptViewModel.bubbleScale(forSizeIndex: 2)
    #expect(abs(mid - (0.75 + 1.30) / 2.0) < 1e-9)
    // A quarter of the way through
    let quarter = TranscriptViewModel.bubbleScale(forSizeIndex: 1)
    #expect(abs(quarter - (0.75 + (1.0 / 4.0) * (1.30 - 0.75))) < 1e-9)
    // Clamping
    #expect(TranscriptViewModel.bubbleScale(forSizeIndex: -3) == 0.75)
    #expect(TranscriptViewModel.bubbleScale(forSizeIndex: 99) == 1.30)
}

@Test func transcriptVM_formatElapsed_paddsAndClamps() {
    #expect(TranscriptViewModel.formatElapsed(0) == "00:00")
    #expect(TranscriptViewModel.formatElapsed(2.5) == "00:02")
    #expect(TranscriptViewModel.formatElapsed(59) == "00:59")
    #expect(TranscriptViewModel.formatElapsed(60) == "01:00")
    #expect(TranscriptViewModel.formatElapsed(125) == "02:05")
    #expect(TranscriptViewModel.formatElapsed(-1) == "00:00")
}

// MARK: - Slider mutations

@MainActor
@Test func transcriptVM_updateSizeIndex_clampsAndUpdatesScale() {
    let vm = TranscriptViewModel(store: TranscriptStore())
    vm.updateSizeIndex(2.8)
    #expect(vm.sizeIndex == 2.8)
    #expect(abs(vm.sizeIndex - 2.8) < 0.0001)
    // Out-of-range
    vm.updateSizeIndex(10)
    #expect(vm.sizeIndex == 4)
    #expect(abs(vm.sizeIndex - 4.0) < 0.0001)
    vm.updateSizeIndex(-5)
    #expect(vm.sizeIndex == 0)
    #expect(vm.bubbleScale == 0.75)
}

@MainActor
@Test func transcriptVM_updateOriginalVolume_propagatesToMixer() async {
    let mixer = MockAudioOutputMixer()
    let orch = makeOrchestrator(mixer: mixer)
    let vm = TranscriptViewModel(store: orch.transcript, orchestrator: orch)
    vm.updateOriginalVolume(50)
    #expect(vm.originalVolume == 50)
    #expect(mixer.currentGain == 0.5)
    vm.updateOriginalVolume(0)
    #expect(mixer.currentGain == 0.0)
    vm.updateOriginalVolume(100)
    #expect(mixer.currentGain == 1.0)
    // Clamps
    vm.updateOriginalVolume(150)
    #expect(vm.originalVolume == 100)
    vm.updateOriginalVolume(-10)
    #expect(vm.originalVolume == 0)
}

@MainActor
@Test func transcriptVM_updateOriginalVolume_firesOnOriginalVolumeChanged() {
    // The composition layer uses `onOriginalVolumeChanged` to mirror
    // volume drags back into `SettingsViewModel` for persistence.
    let vm = TranscriptViewModel(store: TranscriptStore())
    var captured: [Float] = []
    vm.onOriginalVolumeChanged = { v in captured.append(v) }
    vm.updateOriginalVolume(50)
    vm.updateOriginalVolume(100)
    vm.updateOriginalVolume(0)
    // Clamped values still fire the callback.
    vm.updateOriginalVolume(150)
    #expect(captured == [0.5, 1.0, 0.0, 1.0])
}

// MARK: - Hidden / stop modal

@MainActor
@Test func transcriptVM_toggleHidden_flipsBool() {
    let vm = TranscriptViewModel(store: TranscriptStore())
    #expect(vm.isHidden == false)
    vm.toggleHidden()
    #expect(vm.isHidden == true)
    vm.toggleHidden()
    #expect(vm.isHidden == false)
}

@MainActor
@Test func transcriptVM_requestStop_showsModal_confirmInvokesCallback() {
    let vm = TranscriptViewModel(store: TranscriptStore())
    var stopCalled = 0
    vm.onStopRequested = { stopCalled += 1 }

    vm.requestStop()
    #expect(vm.showStopConfirmation == true)
    #expect(stopCalled == 0)

    vm.confirmStop()
    #expect(vm.showStopConfirmation == false)
    #expect(stopCalled == 1)
}

@MainActor
@Test func transcriptVM_cancelStop_hidesModalWithoutCallback() {
    let vm = TranscriptViewModel(store: TranscriptStore())
    var stopCalled = 0
    vm.onStopRequested = { stopCalled += 1 }

    vm.requestStop()
    vm.cancelStop()
    #expect(vm.showStopConfirmation == false)
    #expect(stopCalled == 0)
}

// MARK: - Bubble groups (delegation to TranscriptGrouping)

@MainActor
@Test func transcriptVM_bubbleGroups_reflectsStoreEntries() {
    let store = TranscriptStore()
    let vm = TranscriptViewModel(store: store)
    vm.windowingEnabled = false   // testing group() delegation, not the recency window
    _ = appendMe(store, "Привет.", "Hi.")
    _ = appendPeer(store, "Hello.", "Привет.")
    #expect(vm.bubbleGroups.count == 2)
    #expect(vm.bubbleGroups[0].speaker == .me)
    #expect(vm.bubbleGroups[1].speaker == .peer)
}

@MainActor
@Test func transcriptVM_bubbleGroups_setLive_marksLastBubbleLive() {
    let store = TranscriptStore()
    let vm = TranscriptViewModel(store: store)
    vm.windowingEnabled = false   // testing live-flag delegation, not the recency window
    _ = appendMe(store, "Привет.", "Hi.")
    let liveEntry = appendPeer(store, "Hello.", "Привет.")
    vm.setLive(entryId: liveEntry.id)
    #expect(vm.bubbleGroups[1].bubbles.last?.isLive == true)
    #expect(vm.bubbleGroups[0].bubbles.last?.isLive == false)
}

// MARK: - translationLost surfacing (T9)

@MainActor
@Test func bubble_translationAtRiskWithEmptyTranslation_marksLost() {
    let store = TranscriptStore()
    let id = UUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: "Тест", isFinal: false))
    store.markActiveEntriesAtRisk()
    let vm = TranscriptViewModel(store: store)
    vm.windowingEnabled = false   // testing translationLost surfacing, not the recency window
    let groups = vm.bubbleGroups
    #expect(groups.first?.bubbles.first?.translationLost == true)
}

@MainActor
@Test func bubble_translationDelivered_clearsLost() {
    let store = TranscriptStore()
    let id = UUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: "Тест", isFinal: false))
    store.markActiveEntriesAtRisk()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .translated, text: "Test", isFinal: true))
    let vm = TranscriptViewModel(store: store)
    vm.windowingEnabled = false   // testing translationLost clearing, not the recency window
    #expect(vm.bubbleGroups.first?.bubbles.first?.translationLost == false)
}

// MARK: - Live bubble finalisation

@MainActor
@Test func transcriptVM_setLive_thenIdle_finalisesAfterDelay() async {
    let store = TranscriptStore()
    let vm = TranscriptViewModel(store: store)
    let liveEntry = appendMe(store, "Привет", "Hi")

    vm.setLive(entryId: liveEntry.id)
    #expect(vm.activeLiveEntryId == liveEntry.id)
    // Wait for `liveFinalizeDelaySeconds + 1.5s` of slack. The slack
    // was 0.5s historically but flaked under parallel test load (the
    // suite now has 300+ tests and a couple of multi-second sleeps
    // contending for the cooperative executor pushed real elapsed
    // time past the 0.5s margin).
    let nanos = UInt64((TranscriptViewModel.liveFinalizeDelaySeconds + 1.5) * 1_000_000_000)
    try? await Task.sleep(nanoseconds: nanos)
    #expect(vm.activeLiveEntryId == nil)
}

@MainActor
@Test func transcriptVM_extendLive_resetsTimer() async {
    let store = TranscriptStore()
    let vm = TranscriptViewModel(store: store)
    let liveEntry = appendMe(store, "Привет", "Hi")

    vm.setLive(entryId: liveEntry.id)
    // Halfway through the delay, "extend" the live state — should restart
    // the timer so the entry is still marked live afterwards.
    let half = UInt64((TranscriptViewModel.liveFinalizeDelaySeconds / 2.0) * 1_000_000_000)
    try? await Task.sleep(nanoseconds: half)
    vm.extendLive(entryId: liveEntry.id)
    // After another half-delay we are past the original 2.5s but inside the
    // restarted window — the VM must still be live.
    try? await Task.sleep(nanoseconds: half)
    #expect(vm.activeLiveEntryId == liveEntry.id)
}

@MainActor
@Test func transcriptVM_finalizeLive_clearsImmediately() {
    let store = TranscriptStore()
    let vm = TranscriptViewModel(store: store)
    let liveEntry = appendMe(store, "Привет", "Hi")
    vm.setLive(entryId: liveEntry.id)
    #expect(vm.activeLiveEntryId == liveEntry.id)
    vm.finalizeLive()
    #expect(vm.activeLiveEntryId == nil)
}

// MARK: - Elapsed time

@MainActor
@Test func transcriptVM_elapsed_zeroWhenNoOrchestrator() {
    let vm = TranscriptViewModel(store: TranscriptStore())
    #expect(vm.elapsedSeconds == 0)
    #expect(vm.elapsedSecondsString == "00:00")
}

@MainActor
@Test func transcriptVM_elapsed_zeroWhileIdle() {
    let orch = makeOrchestrator()
    let vm = TranscriptViewModel(store: orch.transcript, orchestrator: orch)
    #expect(vm.elapsedSeconds == 0)
    #expect(vm.elapsedSecondsString == "00:00")
}

// MARK: - pillStatusText / pillDotState (T12)

@MainActor
@Test func transcriptVM_pauseNetworkLost_pillStatus() {
    let store = TranscriptStore()
    let vm = TranscriptViewModel(store: store)
    let started = Date()
    vm.previewState = .paused(mode: .call, since: Date(), startedAt: started, reason: .networkLost)
    #expect(vm.pillStatusText == "Пауза")
    #expect(vm.pillDotState == .paused)
}

@MainActor
@Test func transcriptVM_translatingHealthy_pillStatus_empty() {
    let store = TranscriptStore()
    let vm = TranscriptViewModel(store: store)
    let started = Date()
    vm.previewState = .translating(mode: .call, startedAt: started)
    vm.previewConnectivityHealth = .healthy
    #expect(vm.pillStatusText == "")
    #expect(vm.pillDotState == .active)
}

@MainActor
@Test func transcriptVM_errorState_pillDotIsError() {
    // Mirrors PopoverViewModel.statusDotState: `.error` surfaces a red
    // error dot, not a warning one.
    let vm = TranscriptViewModel(store: TranscriptStore())
    vm.previewState = .error(.networkLost)
    #expect(vm.pillDotState == .error)
}

// MARK: - isTestMode honors previewState

@MainActor
@Test func transcriptVM_isTestMode_respectsPreviewState() {
    let vm = TranscriptViewModel(store: TranscriptStore())
    #expect(vm.isTestMode == false)
    vm.previewState = .translating(mode: .test, startedAt: Date())
    #expect(vm.isTestMode)
    vm.previewState = .translating(mode: .call, startedAt: Date())
    #expect(vm.isTestMode == false)
}

// MARK: - Recency window (visibleBubbleGroups)

@MainActor
@Test func transcriptVM_window_dropsEntriesOlderThanWindow() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let vm = TranscriptViewModel(store: store)
    _ = appendMe(store, "старое", "old")        // lastActivityAt = 1000
    clock.advance(by: 100)                        // t = 1100
    _ = appendPeer(store, "new", "новое")        // lastActivityAt = 1100
    let groups = vm.visibleBubbleGroups(at: clock.now())  // now = 1100
    #expect(groups.count == 1)
    #expect(groups[0].speaker == .peer)
}

@MainActor
@Test func transcriptVM_window_emptyAfterSilence() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let vm = TranscriptViewModel(store: store)
    _ = appendMe(store, "a", "x")
    let groups = vm.visibleBubbleGroups(at: epochDate(1031)) // 31 s later, silence
    #expect(groups.isEmpty)
}

@MainActor
@Test func transcriptVM_window_capsToMaxVisibleBubbles() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let vm = TranscriptViewModel(store: store)
    for i in 0..<6 { _ = appendMe(store, "m\(i)", "t\(i)") } // one me-run → 6 bubbles
    let groups = vm.visibleBubbleGroups(at: clock.now())
    #expect(groups.flatMap { $0.bubbles }.count == TranscriptViewModel.maxVisibleBubbles)
}

@MainActor
@Test func transcriptVM_windowingDisabled_showsEverything() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let vm = TranscriptViewModel(store: store)
    vm.windowingEnabled = false
    for i in 0..<6 { _ = appendMe(store, "m\(i)", "t\(i)") }
    let groups = vm.visibleBubbleGroups(at: epochDate(99_999)) // far future, silence
    #expect(groups.flatMap { $0.bubbles }.count == 6)
}

@MainActor
@Test func transcriptVM_bubbleGroups_usesNowProvider() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let vm = TranscriptViewModel(store: store)
    vm.nowProvider = { clock.now() }
    _ = appendMe(store, "старое", "old")
    clock.advance(by: 100)
    _ = appendPeer(store, "new", "новое")
    #expect(vm.bubbleGroups.count == 1)          // windowed via nowProvider
    #expect(vm.bubbleGroups[0].speaker == .peer)
}

// Core requirement: the recency window is view-only. Even after every
// bubble has dissolved from view (silence), the store retains the full
// history — the foundation for a future save-meeting-transcript feature.
@MainActor
@Test func transcriptVM_window_keepsFullHistoryInStore() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let vm = TranscriptViewModel(store: store)
    for i in 0..<6 { _ = appendMe(store, "m\(i)", "t\(i)") }
    #expect(vm.visibleBubbleGroups(at: epochDate(9999)).isEmpty) // window emptied
    #expect(store.entries.count == 6)                            // history intact
}

