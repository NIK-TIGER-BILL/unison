import Foundation
import Testing
@testable import UnisonDomain
@testable import UnisonUI

@MainActor
private func makeOrchestratorForVM(perms: MockPermissionsService = .init()) -> TranslationOrchestrator {
    if perms.statuses[.microphone] == nil { perms.statuses[.microphone] = .granted }
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
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
        networkMonitor: MockNetworkPathMonitor(initial: .satisfied)
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
    var settings = Settings.default
    settings.sessionMode = .listen
    let vm = PopoverViewModel(orchestrator: orch, permissions: perms, deviceRegistry: registry, settings: settings)
    #expect(vm.canStart)
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
func popoverVM_statusDot_readyWhenIdleAndValid() {
    let vm = makeReadyVM(
        settings: Settings(languagePair: LanguagePair(mine: .ru, peer: .en))
    )
    #expect(vm.statusDotState == .ready)
}

@MainActor
@Test
func popoverVM_statusDot_warnWhenSameLanguage() {
    let vm = makeReadyVM(
        settings: Settings(languagePair: LanguagePair(mine: .ja, peer: .ja))
    )
    #expect(vm.statusDotState == .warn)
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
func popoverVM_updateSessionMode_setsModeAndPersists() {
    var settings = Settings.default
    settings.sessionMode = .call
    let vm = makeReadyVM(settings: settings)
    var persisted: [SessionMode] = []
    vm.onSettingsChanged = { persisted.append($0.sessionMode) }
    vm.updateSessionMode(.listen)
    #expect(vm.settings.sessionMode == .listen)
    // Same-value writes must not spam the persistence pipeline.
    vm.updateSessionMode(.listen)
    vm.updateSessionMode(.call)
    #expect(vm.settings.sessionMode == .call)
    #expect(persisted == [.listen, .call])
}

@MainActor
@Test
func popoverVM_updateLanguagePair_firesSettingsChanged() {
    let vm = makeReadyVM(settings: .default)
    var persistedPairs: [LanguagePair] = []
    vm.onSettingsChanged = { persistedPairs.append($0.languagePair) }
    let pair = LanguagePair(mine: .de, peer: .ja)
    vm.updateLanguagePair(pair)
    #expect(vm.settings.languagePair == pair)
    #expect(persistedPairs == [pair])
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

@Test
func popoverVM_userMessage_apiKeyInvalidPointsToPlatformDashboard() {
    // The terminal-empty-close escalation surfaces .apiKeyInvalid; the
    // user-facing copy must direct the user to the OpenAI dashboard so
    // they know exactly where to verify or rotate the key.
    let msg = PopoverViewModel.userMessage(for: .apiKeyInvalid)
    #expect(msg.contains("platform.openai.com"))
}

@MainActor
@Test
func popoverVM_elapsedSecondsString_keepsCountingDuringReconnecting() {
    // The timer reads `state.sessionStartedAt` which must be preserved
    // across reconnects. With a state value of `.reconnecting(...,
    // startedAt: ~60s ago)`, the formatted string should be at least
    // "00:60" (i.e. not "00:00").
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .granted
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    let started = nowOffset(-60)
    let vm = PopoverViewModel.previewing(
        state: .reconnecting(mode: .call, since: nowDate(), startedAt: started),
        permissions: perms,
        deviceRegistry: registry
    )
    // ~60 seconds elapsed — must read "01:00" (or near it). The
    // important guard is that it's NOT "00:00".
    let elapsed = vm.elapsedSecondsString
    #expect(elapsed != "00:00", "Timer should keep ticking during .reconnecting — got \(elapsed)")
}

@MainActor
@Test
func popoverVM_statusText_marksOnlyReconnecting() {
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .granted
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    let start = nowDate()

    let idle = PopoverViewModel.previewing(state: .idle, permissions: perms, deviceRegistry: registry)
    #expect(idle.statusText.isEmpty)

    let translating = PopoverViewModel.previewing(
        state: .translating(mode: .call, startedAt: start),
        permissions: perms, deviceRegistry: registry
    )
    #expect(translating.statusText.isEmpty)

    let reconnecting = PopoverViewModel.previewing(
        state: .reconnecting(mode: .call, since: start, startedAt: start),
        permissions: perms, deviceRegistry: registry
    )
    #expect(reconnecting.statusText == "Переподключение…")

    let errored = PopoverViewModel.previewing(state: .error(.networkLost), permissions: perms, deviceRegistry: registry)
    #expect(errored.statusText.isEmpty)
}

// MARK: - statusText / statusDotState (T11)

@MainActor
@Test func popoverVM_pausedNetworkLost_statusText() {
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .granted
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    let started = nowDate()
    let preview = PopoverViewModel.previewing(
        settings: .default,
        state: .paused(mode: .call, since: nowDate(), startedAt: started, reason: .networkLost),
        permissions: perms,
        deviceRegistry: registry
    )
    #expect(preview.statusText == "Нет интернета. Ждём…")
    #expect(preview.statusDotState == .paused)
}

@MainActor
@Test func popoverVM_translatingSlow_statusText() {
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .granted
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    let started = nowDate()
    let preview = PopoverViewModel.previewing(
        settings: .default,
        state: .translating(mode: .call, startedAt: started),
        permissions: perms,
        deviceRegistry: registry,
        connectivityHealth: .slow
    )
    #expect(preview.statusText == "Медленная сеть")
    #expect(preview.statusDotState == .warn)
}

@MainActor
@Test func popoverVM_translatingHealthy_statusText_empty() {
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .granted
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    let started = nowDate()
    let preview = PopoverViewModel.previewing(
        settings: .default,
        state: .translating(mode: .call, startedAt: started),
        permissions: perms,
        deviceRegistry: registry,
        connectivityHealth: .healthy
    )
    #expect(preview.statusText == "")
    #expect(preview.statusDotState == .active)
}

// The dot mapping for the remaining spec rows. These lock the
// final-review fix that re-pointed the popover header dot from the
// old 4-state projection (which collapsed paused / slow / recovering
// all to cyan and showed error as red only) to the spec table.

@MainActor
@Test func popoverVM_pausedAwaitingNetwork_dotIsActive() {
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .granted
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    let preview = PopoverViewModel.previewing(
        settings: .default,
        state: .paused(mode: .call, since: nowDate(), startedAt: nowDate(), reason: .awaitingNetwork),
        permissions: perms,
        deviceRegistry: registry
    )
    // Spec: awaiting-network shows cyan ("returning"), NOT the grey
    // paused dot — distinguishes "we're coming back" from "we're
    // stuck offline".
    #expect(preview.statusText == "Возобновляем…")
    #expect(preview.statusDotState == .active)
}

@MainActor
@Test func popoverVM_reconnecting_dotIsWarn() {
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .granted
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    let preview = PopoverViewModel.previewing(
        settings: .default,
        state: .reconnecting(mode: .call, since: nowDate(), startedAt: nowDate()),
        permissions: perms,
        deviceRegistry: registry
    )
    #expect(preview.statusDotState == .warn)
}

@MainActor
@Test func popoverVM_error_dotIsError() {
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .granted
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    let preview = PopoverViewModel.previewing(
        settings: .default,
        state: .error(.networkLost),
        permissions: perms,
        deviceRegistry: registry
    )
    // Spec: terminal error is RED, not the yellow warn dot. The old
    // statusDotState mapped .error → .warn — a real regression the
    // final review caught.
    #expect(preview.statusDotState == .error)
}

@MainActor
@Test func popoverVM_translatingRecovering_dotIsRecovering() {
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .granted
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    let preview = PopoverViewModel.previewing(
        settings: .default,
        state: .translating(mode: .call, startedAt: nowDate()),
        permissions: perms,
        deviceRegistry: registry,
        connectivityHealth: .recovering
    )
    #expect(preview.statusDotState == .recovering)
}
