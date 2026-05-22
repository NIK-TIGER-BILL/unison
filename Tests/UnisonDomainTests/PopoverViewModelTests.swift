import Testing
@testable import UnisonDomain
@testable import UnisonUI

@MainActor
private func makeOrchestratorForVM(perms: MockPermissionsService = .init()) -> TranslationOrchestrator {
    if perms.statuses[.microphone] == nil { perms.statuses[.microphone] = .granted }
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    registry.bh16ch = AudioDevice(uid: "bh16", name: "BlackHole 16ch", kind: .input)
    return TranslationOrchestrator(
        micCapture: MockMicrophoneCapture(),
        peerCapture: MockPeerAudioCapture(),
        outputMixer: MockAudioOutputMixer(),
        virtualMicPlayer: MockAudioPlayer(),
        translationFactory: MockTranslationStreamFactory(),
        permissions: perms,
        deviceRegistry: registry,
        clock: SystemClock(),
        transformer: MockAudioFormatTransformer()
    )
}

@MainActor
private func makeReadyVM(
    settings: Settings = .default,
    perms: MockPermissionsService = .init()
) -> PopoverViewModel {
    if perms.statuses[.microphone] == nil { perms.statuses[.microphone] = .granted }
    let orch = makeOrchestratorForVM(perms: perms)
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    registry.bh16ch = AudioDevice(uid: "bh16", name: "BlackHole 16ch", kind: .input)
    return PopoverViewModel(
        orchestrator: orch,
        permissions: perms,
        deviceRegistry: registry,
        settings: settings
    )
}

@MainActor
@Test func popoverVM_initialIsIdle() {
    let perms = MockPermissionsService()
    let orch = makeOrchestratorForVM(perms: perms)
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    registry.bh16ch = AudioDevice(uid: "bh16", name: "BlackHole 16ch", kind: .input)
    perms.statuses[.microphone] = .granted
    let vm = PopoverViewModel(orchestrator: orch, permissions: perms, deviceRegistry: registry, settings: .default)
    #expect(vm.canStart)
    #expect(vm.runningTimeSeconds == 0)
}

@MainActor
@Test func popoverVM_disablesStartWhenMicDeniedInCallMode() {
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .denied
    let orch = makeOrchestratorForVM(perms: perms)
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    registry.bh16ch = AudioDevice(uid: "bh16", name: "BlackHole 16ch", kind: .input)
    var settings = Settings.default
    settings.sessionMode = .call
    let vm = PopoverViewModel(orchestrator: orch, permissions: perms, deviceRegistry: registry, settings: settings)
    #expect(vm.canStart == false)
    #expect(vm.startBlockedReason == .micPermissionRequired)
}

@MainActor
@Test func popoverVM_enablesStartInListenWithoutMic() {
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .denied
    let orch = makeOrchestratorForVM(perms: perms)
    let registry = MockAudioDeviceRegistry()
    registry.bh16ch = AudioDevice(uid: "bh16", name: "BlackHole 16ch", kind: .input)
    var settings = Settings.default
    settings.sessionMode = .listen
    let vm = PopoverViewModel(orchestrator: orch, permissions: perms, deviceRegistry: registry, settings: settings)
    #expect(vm.canStart)
}

@MainActor
@Test func popoverVM_displayPair() {
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .granted
    let orch = makeOrchestratorForVM(perms: perms)
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    registry.bh16ch = AudioDevice(uid: "bh16", name: "BlackHole 16ch", kind: .input)
    let vm = PopoverViewModel(
        orchestrator: orch,
        permissions: perms,
        deviceRegistry: registry,
        settings: Settings(languagePair: LanguagePair(mine: .ru, peer: .en))
    )
    #expect(vm.languagePairDisplay == "🇷🇺 Русский → 🇬🇧 English")
}

// MARK: - Phase 3a additions

@Test
func popoverVM_formatElapsed_padsMinutesAndSeconds() {
    #expect(PopoverViewModel.formatElapsed(0) == "00:00")
    #expect(PopoverViewModel.formatElapsed(2.5) == "00:02")
    #expect(PopoverViewModel.formatElapsed(59) == "00:59")
    #expect(PopoverViewModel.formatElapsed(60) == "01:00")
    #expect(PopoverViewModel.formatElapsed(125) == "02:05")
    // Negative inputs (clock skew) clamp to "00:00".
    #expect(PopoverViewModel.formatElapsed(-3) == "00:00")
}

@MainActor
@Test
func popoverVM_elapsedSecondsString_isZeroWhenIdle() {
    let vm = makeReadyVM()
    #expect(vm.elapsedSecondsString == "00:00")
}

@MainActor
@Test
func popoverVM_isLanguagePairValid_falseWhenSame() {
    let vm = makeReadyVM(
        settings: Settings(languagePair: LanguagePair(mine: .ru, peer: .ru))
    )
    #expect(vm.isLanguagePairValid == false)
    #expect(vm.canStartStrict == false)
}

@MainActor
@Test
func popoverVM_isLanguagePairValid_trueWhenDifferent() {
    let vm = makeReadyVM(
        settings: Settings(languagePair: LanguagePair(mine: .ru, peer: .en))
    )
    #expect(vm.isLanguagePairValid)
    #expect(vm.canStartStrict)
}

@MainActor
@Test
func popoverVM_statusKind_readyWhenIdleAndValid() {
    let vm = makeReadyVM(
        settings: Settings(languagePair: LanguagePair(mine: .ru, peer: .en))
    )
    #expect(vm.statusKind == .ready)
}

@MainActor
@Test
func popoverVM_statusKind_warnWhenSameLanguage() {
    let vm = makeReadyVM(
        settings: Settings(languagePair: LanguagePair(mine: .ja, peer: .ja))
    )
    #expect(vm.statusKind == .warn)
}

@MainActor
@Test
func popoverVM_primaryButton_idleLabelsAndIcon() {
    let vm = makeReadyVM()
    #expect(vm.primaryButtonTitle == "Начать перевод")
    #expect(vm.primaryButtonIcon == .play)
}

@MainActor
@Test
func popoverVM_toggleSessionMode_swapsCallAndListen() {
    var settings = Settings.default
    settings.sessionMode = .call
    let vm = makeReadyVM(settings: settings)
    vm.toggleSessionMode()
    #expect(vm.settings.sessionMode == .listen)
    vm.toggleSessionMode()
    #expect(vm.settings.sessionMode == .call)
}

@MainActor
@Test
func popoverVM_updateLanguagePair_replacesPair() {
    let vm = makeReadyVM(
        settings: Settings(languagePair: LanguagePair(mine: .ru, peer: .en))
    )
    vm.updateLanguagePair(LanguagePair(mine: .ja, peer: .ko))
    #expect(vm.settings.languagePair == LanguagePair(mine: .ja, peer: .ko))
}

// MARK: - User-facing error messages

@Test
func popoverVM_userMessage_mapsEveryTranslationError() {
    // Each branch should yield a non-empty Russian sentence so the
    // ErrorRow detail line is never blank.
    let cases: [TranslationError] = [
        .permissionDenied(.microphone),
        .blackHole2chMissing,
        .blackHole16chMissing,
        .apiKeyInvalid,
        .rateLimited(retryAfter: 1),
        .insufficientCredits,
        .networkLost,
        .inputDeviceUnavailable,
        .outputDeviceUnavailable,
    ]
    for err in cases {
        let msg = PopoverViewModel.userMessage(for: err)
        #expect(!msg.isEmpty, "userMessage for \(err) was empty")
    }
}

@Test
func popoverVM_userMessage_micPermissionPointsToSystemSettings() {
    let msg = PopoverViewModel.userMessage(for: .permissionDenied(.microphone))
    #expect(msg.contains("Privacy"))
    #expect(msg.contains("Microphone"))
}

@Test
func popoverVM_userMessage_apiKeyInvalidMentionsSettings() {
    let msg = PopoverViewModel.userMessage(for: .apiKeyInvalid)
    #expect(msg.contains("Настройках"))
}
