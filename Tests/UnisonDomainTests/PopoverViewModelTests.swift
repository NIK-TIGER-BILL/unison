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
