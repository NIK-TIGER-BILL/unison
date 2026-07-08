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
private func makeModel(_ clock: FakeClock = FakeClock(now: epochDate(0))) -> TranscriptModel {
    let m = TranscriptModel(clock: clock)
    m.currentLanguagePair = LanguagePair(mine: .ru, peer: .en)
    m.config.pauseSeconds = 2   // small threshold for fast, deterministic tests
    return m
}

/// Ingest one utterance (original + translation) for a speaker. Leaves it as
/// the live segment — advance the clock past `pauseSeconds` and `tick` to
/// freeze it.
@MainActor
private func ingestUtterance(_ model: TranscriptModel, _ speaker: Speaker,
                             _ original: String, _ translated: String) {
    let srcLang: Language = speaker == .me ? .ru : .en
    let trLang: Language = speaker == .me ? .en : .ru
    model.ingest(TranscriptDelta(entryId: freshUUID(), speaker: speaker, kind: .original,
                                 text: original, isFinal: false, language: srcLang))
    model.ingest(TranscriptDelta(entryId: freshUUID(), speaker: speaker, kind: .translated,
                                 text: translated, isFinal: false, language: trLang))
}

/// Ingest an utterance and immediately freeze it (advance past the pause, tick).
@MainActor
private func commitUtterance(_ model: TranscriptModel, _ clock: FakeClock, _ speaker: Speaker,
                             _ original: String, _ translated: String) {
    ingestUtterance(model, speaker, original, translated)
    clock.advance(by: 3)
    model.tick(now: clock.now())
}

// MARK: - Pure helpers (size label, bubble scale, elapsed formatting)

@Test func transcriptVM_bubbleScale_interpolatesLinearlyBetween075and130() {
    #expect(TranscriptViewModel.bubbleScale(forSizeIndex: 0) == 0.75)
    #expect(TranscriptViewModel.bubbleScale(forSizeIndex: 4) == 1.30)
    let mid = TranscriptViewModel.bubbleScale(forSizeIndex: 2)
    #expect(abs(mid - (0.75 + 1.30) / 2.0) < 1e-9)
    let quarter = TranscriptViewModel.bubbleScale(forSizeIndex: 1)
    #expect(abs(quarter - (0.75 + (1.0 / 4.0) * (1.30 - 0.75))) < 1e-9)
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
    let vm = TranscriptViewModel(model: TranscriptModel())
    vm.updateSizeIndex(2.8)
    #expect(vm.sizeIndex == 2.8)
    #expect(abs(vm.sizeIndex - 2.8) < 0.0001)
    vm.updateSizeIndex(10)
    #expect(vm.sizeIndex == 4)
    vm.updateSizeIndex(-5)
    #expect(vm.sizeIndex == 0)
    #expect(vm.bubbleScale == 0.75)
}

@MainActor
@Test func transcriptVM_updateOriginalVolume_propagatesToMixer() async {
    let mixer = MockAudioOutputMixer()
    let orch = makeOrchestrator(mixer: mixer)
    let vm = TranscriptViewModel(model: orch.transcriptModel, orchestrator: orch)
    vm.updateOriginalVolume(50)
    #expect(vm.originalVolume == 50)
    #expect(mixer.currentGain == 0.5)
    vm.updateOriginalVolume(0)
    #expect(mixer.currentGain == 0.0)
    vm.updateOriginalVolume(100)
    #expect(mixer.currentGain == 1.0)
    vm.updateOriginalVolume(150)
    #expect(vm.originalVolume == 100)
    vm.updateOriginalVolume(-10)
    #expect(vm.originalVolume == 0)
}

@MainActor
@Test func transcriptVM_updateOriginalVolume_firesOnOriginalVolumeChanged() {
    let vm = TranscriptViewModel(model: TranscriptModel())
    var captured: [Float] = []
    vm.onOriginalVolumeChanged = { v in captured.append(v) }
    vm.updateOriginalVolume(50)
    vm.updateOriginalVolume(100)
    vm.updateOriginalVolume(0)
    vm.updateOriginalVolume(150)
    #expect(captured == [0.5, 1.0, 0.0, 1.0])
}

// MARK: - Hidden / stop modal

@MainActor
@Test func transcriptVM_toggleHidden_flipsBool() {
    let vm = TranscriptViewModel(model: TranscriptModel())
    #expect(vm.isHidden == false)
    vm.toggleHidden()
    #expect(vm.isHidden == true)
    vm.toggleHidden()
    #expect(vm.isHidden == false)
}

@MainActor
@Test func transcriptVM_requestStop_showsModal_confirmInvokesCallback() {
    let vm = TranscriptViewModel(model: TranscriptModel())
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
    let vm = TranscriptViewModel(model: TranscriptModel())
    var stopCalled = 0
    vm.onStopRequested = { stopCalled += 1 }
    vm.requestStop()
    vm.cancelStop()
    #expect(vm.showStopConfirmation == false)
    #expect(stopCalled == 0)
}

// MARK: - Bubble groups (mapping model → grouped display)

@MainActor
@Test func transcriptVM_bubbleGroups_reflectsModel() {
    let clock = FakeClock(now: epochDate(0))
    let model = makeModel(clock)
    let vm = TranscriptViewModel(model: model)
    vm.windowingEnabled = false   // testing group() delegation, not the recency window
    commitUtterance(model, clock, .me, "Привет.", "Hi.")
    commitUtterance(model, clock, .peer, "Hello.", "Привет.")
    #expect(vm.bubbleGroups.count == 2)
    #expect(vm.bubbleGroups[0].speaker == .me)
    #expect(vm.bubbleGroups[1].speaker == .peer)
}

// `.me` shows the original as primary (bold), translation as secondary;
// `.peer` is the mirror (translation primary).
@MainActor
@Test func transcriptVM_mapsSpeakerToPrimarySecondary() {
    let clock = FakeClock(now: epochDate(0))
    let model = makeModel(clock)
    let vm = TranscriptViewModel(model: model)
    vm.windowingEnabled = false
    commitUtterance(model, clock, .peer, "Hello there.", "Привет.")
    let peer = vm.bubbleGroups.last?.bubbles.last
    #expect(peer?.primaryText == "Привет.")
    #expect(peer?.secondaryText == "Hello there.")
    commitUtterance(model, clock, .me, "Как дела?", "How are you?")
    let me = vm.bubbleGroups.last?.bubbles.last
    #expect(me?.primaryText == "Как дела?")
    #expect(me?.secondaryText == "How are you?")
}

// A still-forming segment (no pause yet) renders as the single live bubble.
@MainActor
@Test func transcriptVM_uncommittedSegment_marksBubbleLive() {
    let clock = FakeClock(now: epochDate(0))
    let model = makeModel(clock)
    let vm = TranscriptViewModel(model: model)
    vm.windowingEnabled = false
    ingestUtterance(model, .peer, "Sometimes I'm", "Иногда я")   // no tick → live
    let groups = vm.bubbleGroups
    #expect(groups.count == 1)
    #expect(groups[0].bubbles.count == 1)
    #expect(groups[0].bubbles[0].isLive == true)
}

// A multi-sentence turn seals as SEPARATE sentence bubbles (proactive).
@MainActor
@Test func transcriptVM_committedMultiSentenceTurn_isSentenceBubbles() {
    let clock = FakeClock(now: epochDate(0))
    let model = makeModel(clock)
    let vm = TranscriptViewModel(model: model)
    vm.windowingEnabled = false
    model.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                                 text: "First sentence. Second sentence.", isFinal: false, language: .en))
    model.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated,
                                 text: "Первое предложение. Второе предложение.", isFinal: false, language: .ru))
    clock.advance(by: 3); model.tick(now: clock.now())
    #expect(vm.bubbleGroups.flatMap { $0.bubbles }.count == 2)
}

// MARK: - translationLost surfacing

@MainActor
@Test func transcriptVM_translationNeverArrived_marksLost() {
    let clock = FakeClock(now: epochDate(0))
    let model = makeModel(clock)
    let vm = TranscriptViewModel(model: model)
    vm.windowingEnabled = false
    model.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .me, kind: .original,
                                 text: "Тест.", isFinal: false, language: .ru))
    clock.advance(by: 3); model.tick(now: clock.now())   // commits source-only
    #expect(vm.bubbleGroups.first?.bubbles.first?.translationLost == true)
}

@MainActor
@Test func transcriptVM_translationArrived_clearsLost() {
    let clock = FakeClock(now: epochDate(0))
    let model = makeModel(clock)
    let vm = TranscriptViewModel(model: model)
    vm.windowingEnabled = false
    commitUtterance(model, clock, .me, "Тест.", "Test.")
    #expect(vm.bubbleGroups.first?.bubbles.first?.translationLost == false)
}

// MARK: - Elapsed time

@MainActor
@Test func transcriptVM_elapsed_zeroWhenNoOrchestrator() {
    let vm = TranscriptViewModel(model: TranscriptModel())
    #expect(vm.elapsedSeconds == 0)
    #expect(vm.elapsedSecondsString == "00:00")
}

@MainActor
@Test func transcriptVM_elapsed_zeroWhileIdle() {
    let orch = makeOrchestrator()
    let vm = TranscriptViewModel(model: orch.transcriptModel, orchestrator: orch)
    #expect(vm.elapsedSeconds == 0)
    #expect(vm.elapsedSecondsString == "00:00")
}

// MARK: - pillStatusText / pillDotState

@MainActor
@Test func transcriptVM_pauseNetworkLost_pillStatus() {
    let vm = TranscriptViewModel(model: TranscriptModel())
    vm.previewState = .paused(mode: .call, since: Date(), startedAt: Date(), reason: .networkLost)
    #expect(vm.pillStatusText == "Пауза")
    #expect(vm.pillDotState == .paused)
}

@MainActor
@Test func transcriptVM_translatingHealthy_pillStatus_empty() {
    let vm = TranscriptViewModel(model: TranscriptModel())
    vm.previewState = .translating(mode: .call, startedAt: Date())
    vm.previewConnectivityHealth = .healthy
    #expect(vm.pillStatusText == "")
    #expect(vm.pillDotState == .active)
}

@MainActor
@Test func transcriptVM_errorState_pillDotIsError() {
    let vm = TranscriptViewModel(model: TranscriptModel())
    vm.previewState = .error(.networkLost)
    #expect(vm.pillDotState == .error)
}

// MARK: - isTestMode honors previewState

@MainActor
@Test func transcriptVM_isTestMode_respectsPreviewState() {
    let vm = TranscriptViewModel(model: TranscriptModel())
    #expect(vm.isTestMode == false)
    vm.previewState = .translating(mode: .test, startedAt: Date())
    #expect(vm.isTestMode)
    vm.previewState = .translating(mode: .call, startedAt: Date())
    #expect(vm.isTestMode == false)
}

// MARK: - Recency window (visibleBubbleGroups over the feed)

@MainActor
@Test func transcriptVM_window_dropsBubblesOlderThanWindow() {
    let clock = FakeClock(now: epochDate(1000))
    let model = makeModel(clock)
    let vm = TranscriptViewModel(model: model)
    commitUtterance(model, clock, .me, "Старое.", "Old.")   // commits at 1003
    clock.advance(by: 100)                                   // t = 1103
    commitUtterance(model, clock, .peer, "New.", "Новое.")  // commits at 1106
    let groups = vm.visibleBubbleGroups(at: clock.now())    // now = 1106
    #expect(groups.count == 1)                              // "Старое." (103 s old) gone
    #expect(groups[0].speaker == .peer)
}

@MainActor
@Test func transcriptVM_window_emptyAfterSilence() {
    let clock = FakeClock(now: epochDate(1000))
    let model = makeModel(clock)
    let vm = TranscriptViewModel(model: model)
    commitUtterance(model, clock, .me, "Готово.", "Done.")   // commits at 1003
    let groups = vm.visibleBubbleGroups(at: epochDate(1040)) // 37 s later, silence
    #expect(groups.isEmpty)
}

@MainActor
@Test func transcriptVM_window_capsToMaxVisibleBubbles() {
    let clock = FakeClock(now: epochDate(1000))
    let model = makeModel(clock)
    let vm = TranscriptViewModel(model: model)
    let n = TranscriptViewModel.maxVisibleBubbles + 3
    for i in 0..<n { commitUtterance(model, clock, .me, "m\(i).", "t\(i).") }
    let groups = vm.visibleBubbleGroups(at: clock.now())
    #expect(groups.flatMap { $0.bubbles }.count == TranscriptViewModel.maxVisibleBubbles)
}

@MainActor
@Test func transcriptVM_windowingDisabled_showsEverything() {
    let clock = FakeClock(now: epochDate(1000))
    let model = makeModel(clock)
    let vm = TranscriptViewModel(model: model)
    vm.windowingEnabled = false
    for i in 0..<6 { commitUtterance(model, clock, .me, "m\(i).", "t\(i).") }
    let groups = vm.visibleBubbleGroups(at: epochDate(99_999))   // far future, silence
    #expect(groups.flatMap { $0.bubbles }.count == 6)
}

// `bubbleGroups` reads the clock through `nowProvider`, so a frozen bubble
// ages out on schedule as the provider advances.
@MainActor
@Test func transcriptVM_bubbleGroups_usesNowProvider() {
    let clock = FakeClock(now: epochDate(1000))
    let model = makeModel(clock)
    let vm = TranscriptViewModel(model: model)
    var nowSeconds = 1003.0
    vm.nowProvider = { epochDate(nowSeconds) }
    commitUtterance(model, clock, .me, "Первое.", "First.")   // seals at 1000
    #expect(vm.bubbleGroups.flatMap { $0.bubbles }.count == 1)
    nowSeconds = 1029                                          // 29 s after seal → within window
    #expect(vm.bubbleGroups.flatMap { $0.bubbles }.count == 1)
    nowSeconds = 1031                                          // 31 s after seal → expired
    #expect(vm.bubbleGroups.isEmpty)
}
