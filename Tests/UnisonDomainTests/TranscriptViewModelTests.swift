import Testing
@testable import UnisonDomain
@testable import UnisonUI

// MARK: - Helpers

@MainActor
private func makeOrchestrator(mixer: MockAudioOutputMixer = .init()) -> TranslationOrchestrator {
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    registry.bh16ch = AudioDevice(uid: "bh16", name: "BlackHole 16ch", kind: .input)
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
        transformer: MockAudioFormatTransformer()
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

@Test func transcriptVM_sizeLabel_mapsRoundedIndexToXSthroughXL() {
    #expect(TranscriptViewModel.sizeLabel(forSizeIndex: 0) == "XS")
    #expect(TranscriptViewModel.sizeLabel(forSizeIndex: 0.4) == "XS")
    #expect(TranscriptViewModel.sizeLabel(forSizeIndex: 0.6) == "S")
    #expect(TranscriptViewModel.sizeLabel(forSizeIndex: 1) == "S")
    #expect(TranscriptViewModel.sizeLabel(forSizeIndex: 2) == "M")
    #expect(TranscriptViewModel.sizeLabel(forSizeIndex: 3) == "L")
    #expect(TranscriptViewModel.sizeLabel(forSizeIndex: 4) == "XL")
    // Out-of-range inputs clamp to the nearest end.
    #expect(TranscriptViewModel.sizeLabel(forSizeIndex: -1) == "XS")
    #expect(TranscriptViewModel.sizeLabel(forSizeIndex: 100) == "XL")
}

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
    #expect(vm.sizeLabel == "L") // round(2.8) → 3 → "L"
    // Out-of-range
    vm.updateSizeIndex(10)
    #expect(vm.sizeIndex == 4)
    #expect(vm.sizeLabel == "XL")
    vm.updateSizeIndex(-5)
    #expect(vm.sizeIndex == 0)
    #expect(vm.bubbleScale == 0.75)
}

@MainActor
@Test func transcriptVM_updateBubbleScale_inverseMapsToSizeIndex() {
    let vm = TranscriptViewModel(store: TranscriptStore())
    vm.updateBubbleScale(1.30)
    #expect(vm.sizeIndex == 4)
    vm.updateBubbleScale(0.75)
    #expect(vm.sizeIndex == 0)
    // Midpoint
    vm.updateBubbleScale((0.75 + 1.30) / 2.0)
    #expect(abs(vm.sizeIndex - 2.0) < 1e-9)
    // Out-of-range clamps
    vm.updateBubbleScale(5.0)
    #expect(vm.sizeIndex == 4)
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
    _ = appendMe(store, "Привет.", "Hi.")
    let liveEntry = appendPeer(store, "Hello.", "Привет.")
    vm.setLive(entryId: liveEntry.id)
    #expect(vm.bubbleGroups[1].bubbles.last?.isLive == true)
    #expect(vm.bubbleGroups[0].bubbles.last?.isLive == false)
}

// MARK: - Live bubble finalisation

@MainActor
@Test func transcriptVM_setLive_thenIdle_finalisesAfterDelay() async {
    let store = TranscriptStore()
    let vm = TranscriptViewModel(store: store)
    let liveEntry = appendMe(store, "Привет", "Hi")

    vm.setLive(entryId: liveEntry.id)
    #expect(vm.activeLiveEntryId == liveEntry.id)
    // Wait for `liveFinalizeDelaySeconds + 0.5s` of slack.
    let nanos = UInt64((TranscriptViewModel.liveFinalizeDelaySeconds + 0.5) * 1_000_000_000)
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
