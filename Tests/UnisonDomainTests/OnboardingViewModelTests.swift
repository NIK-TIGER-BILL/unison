import Testing
@testable import UnisonDomain
@testable import UnisonUI

// Mock helpers
final class MockInstaller: BlackHoleInstaller, @unchecked Sendable {
    var installed2ch = true
    var _runBundledInstaller: (() async throws -> Void)?
    func is2chInstalled() -> Bool { installed2ch }
    func runBundledInstaller() async throws {
        if let action = _runBundledInstaller {
            try await action()
        } else {
            installed2ch = true
        }
    }
}

final class MockKeychain: KeychainService, @unchecked Sendable {
    private var stored: String?
    func loadAPIKey() -> String? { stored }
    func saveAPIKey(_ key: String) throws { stored = key }
    func deleteAPIKey() throws { stored = nil }
}

@MainActor
@Test func onboarding_initialState_listsRequiredSteps() {
    let vm = OnboardingViewModel(
        permissions: MockPermissionsService(),
        installer: MockInstaller(),
        keychain: MockKeychain()
    )
    #expect(vm.steps.count >= 3)
    #expect(vm.allDone == false)
}

@MainActor
@Test func onboarding_markBlackHoleInstalled_advancesStep() async {
    let installer = MockInstaller()
    installer.installed2ch = false
    let vm = OnboardingViewModel(
        permissions: MockPermissionsService(),
        installer: installer,
        keychain: MockKeychain()
    )
    #expect(vm.blackHoleInstallStatus == .pending)

    installer.installed2ch = true
    vm.refresh()
    // Install sub-task is now done (2ch appeared in CoreAudio).
    // Overall .blackHole step still requires audio capture grant.
    #expect(vm.blackHoleInstallStatus == .done)
    #expect(vm.steps.first { $0.kind == .blackHole }?.isDone == false)
}

@MainActor
@Test func onboarding_saveApiKey_marksKeyStepDone() throws {
    let kc = MockKeychain()
    let vm = OnboardingViewModel(
        permissions: MockPermissionsService(),
        installer: MockInstaller(),
        keychain: kc
    )
    // Route through the validated draft path — the raw-string overload
    // was an unvalidated keychain write kept only for test convenience.
    vm.apiKeyDraft = "sk-test-12345678901234567890"
    vm.saveAPIKey()
    vm.refresh()
    #expect(vm.steps.first { $0.kind == .apiKey }?.isDone == true)
}

// MARK: - Phase 3b additions

@Test
func onboarding_validateAPIKey_rejectsShortAndUnprefixed() {
    #expect(OnboardingViewModel.validateAPIKey("abc") == false)
    #expect(OnboardingViewModel.validateAPIKey("") == false)
    #expect(OnboardingViewModel.validateAPIKey("sk-") == false)
    #expect(OnboardingViewModel.validateAPIKey("sk-short") == false)
    // No prefix.
    #expect(OnboardingViewModel.validateAPIKey("proj-1234567890abcdef") == false)
}

@Test
func onboarding_validateAPIKey_acceptsLongPrefixedKey() {
    #expect(OnboardingViewModel.validateAPIKey("sk-proj-1234567890abc"))
    #expect(OnboardingViewModel.validateAPIKey("sk-test-thisisalongkey1234567"))
    // Trims whitespace.
    #expect(OnboardingViewModel.validateAPIKey("  sk-proj-1234567890abc  "))
}

@MainActor
@Test
func onboarding_apiKeyDraft_drivesCanSaveKey() {
    let vm = OnboardingViewModel(
        permissions: MockPermissionsService(),
        installer: MockInstaller(),
        keychain: MockKeychain()
    )
    #expect(vm.canSaveKey == false)
    vm.apiKeyDraft = "abc"
    #expect(vm.canSaveKey == false)
    vm.apiKeyDraft = "sk-proj-1234567890abcdef"
    #expect(vm.canSaveKey)
}

@MainActor
@Test
func onboarding_saveAPIKey_invalidDraft_setsErrorStatus() {
    let kc = MockKeychain()
    let vm = OnboardingViewModel(
        permissions: MockPermissionsService(),
        installer: MockInstaller(),
        keychain: kc
    )
    vm.apiKeyDraft = "abc"
    vm.saveAPIKey()
    if case .error = vm.status[.apiKey] {
        // expected
    } else {
        Issue.record("Expected .error for invalid draft, got \(String(describing: vm.status[.apiKey]))")
    }
    // Keychain must be untouched.
    #expect(kc.loadAPIKey() == nil)
}

@MainActor
@Test
func onboarding_saveAPIKey_validDraft_persistsAndClearsDraft() {
    let kc = MockKeychain()
    let vm = OnboardingViewModel(
        permissions: MockPermissionsService(),
        installer: MockInstaller(),
        keychain: kc
    )
    vm.apiKeyDraft = "sk-proj-1234567890abcdef"
    vm.saveAPIKey()
    #expect(vm.status[.apiKey] == .done)
    #expect(vm.apiKeyDraft == "")
    #expect(kc.loadAPIKey() == "sk-proj-1234567890abcdef")
}

@MainActor
@Test
func onboarding_clearError_dropsErrorState() {
    let vm = OnboardingViewModel(
        permissions: MockPermissionsService(),
        installer: MockInstaller(),
        keychain: MockKeychain()
    )
    vm.apiKeyDraft = "abc"
    vm.saveAPIKey()
    // Sanity check we're starting from .error.
    #expect(vm.status[.apiKey]?.errorMessage != nil)
    vm.clearError(for: .apiKey)
    #expect(vm.status[.apiKey] == .pending)
}

@MainActor
@Test
func onboarding_installBlackHole_succeedsTransitionsToDone() async {
    let installer = MockInstaller()
    installer.installed2ch = false
    let vm = OnboardingViewModel(
        permissions: MockPermissionsService(),
        installer: installer,
        keychain: MockKeychain()
    )
    await vm.installBlackHole()
    // Install sub-task done. Overall .blackHole still requires audio capture.
    #expect(vm.blackHoleInstallStatus == .done)
    #expect(vm.steps.first { $0.kind == .blackHole }?.isDone == false)
}

@MainActor
@Test
func onboarding_installBlackHole_failureSetsErrorStatus() async {
    final class FailingInstaller: BlackHoleInstaller, @unchecked Sendable {
        struct InstallError: Error {}
        func is2chInstalled() -> Bool { false }
        func runBundledInstaller() async throws { throw InstallError() }
    }
    let vm = OnboardingViewModel(
        permissions: MockPermissionsService(),
        installer: FailingInstaller(),
        keychain: MockKeychain()
    )
    await vm.installBlackHole()
    if case .error = vm.status[.blackHole] {
        // expected
    } else {
        Issue.record("Expected .error for failing installer, got \(String(describing: vm.status[.blackHole]))")
    }
}

// MARK: - Silent-install regression (the bug this PR fixes)

@MainActor
@Test
func onboarding_installBlackHole_verificationFailedShowsExplicitError() async {
    // Regression for the original bug: installer returns success
    // but the devices never appear in CoreAudio. The installer
    // contract is now to throw `verificationFailed` so the VM can
    // render a specific error row. Previously this silently flipped
    // back to `.pending` with no message — the user couldn't tell
    // anything went wrong.
    final class VerificationFailingInstaller: BlackHoleInstaller, @unchecked Sendable {
        func is2chInstalled() -> Bool { false }
        func runBundledInstaller() async throws {
            throw BlackHoleInstallError.verificationFailed
        }
    }
    let vm = OnboardingViewModel(
        permissions: MockPermissionsService(),
        installer: VerificationFailingInstaller(),
        keychain: MockKeychain()
    )
    await vm.installBlackHole()
    let message = vm.status[.blackHole]?.errorMessage ?? ""
    #expect(!message.isEmpty, "verification failure must surface a non-empty error")
    #expect(
        message.contains("BlackHole") || message.contains("аудиоустройств"),
        "error must mention BlackHole / audio devices, got: \(message)"
    )
}

@MainActor
@Test
func onboarding_installBlackHole_userCanceledAuthShowsCancelError() async {
    // When `osascript ... with administrator privileges` is
    // dismissed by the user, the installer surfaces
    // `installFailed("User canceled.")`. The VM should branch on
    // this and show a cancel-specific message rather than the
    // generic "see Console.app" copy.
    final class CancelingInstaller: BlackHoleInstaller, @unchecked Sendable {
        func is2chInstalled() -> Bool { false }
        func runBundledInstaller() async throws {
            throw BlackHoleInstallError.installFailed("0:0: execution error: User canceled. (-128)")
        }
    }
    let vm = OnboardingViewModel(
        permissions: MockPermissionsService(),
        installer: CancelingInstaller(),
        keychain: MockKeychain()
    )
    await vm.installBlackHole()
    let message = vm.status[.blackHole]?.errorMessage ?? ""
    #expect(
        message.lowercased().contains("отмен") || message.lowercased().contains("пароль"),
        "cancellation must produce a cancel/password-specific message, got: \(message)"
    )
}

@MainActor
@Test
func onboarding_installBlackHole_successKeepsStatusDoneAfterRefresh() async {
    // The install sub-task must stay `.done` after a subsequent
    // `refresh()` call, so the UI doesn't regress to `.pending`.
    let installer = MockInstaller()
    installer.installed2ch = false
    let vm = OnboardingViewModel(
        permissions: MockPermissionsService(),
        installer: installer,
        keychain: MockKeychain()
    )
    await vm.installBlackHole()
    #expect(vm.blackHoleInstallStatus == .done)
    // Overall step still requires audio capture grant.
    #expect(vm.steps.first { $0.kind == .blackHole }?.isDone == false)
}

@MainActor
@Test
func onboarding_requestMicPermission_grantedTransitionsToDone() async {
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .granted
    let vm = OnboardingViewModel(
        permissions: perms,
        installer: MockInstaller(),
        keychain: MockKeychain()
    )
    await vm.requestMicPermission()
    #expect(vm.status[.microphone] == .done)
}

@MainActor
@Test
func onboarding_requestMicPermission_deniedSetsError() async {
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .denied
    let vm = OnboardingViewModel(
        permissions: perms,
        installer: MockInstaller(),
        keychain: MockKeychain()
    )
    await vm.requestMicPermission()
    #expect(vm.status[.microphone]?.errorMessage != nil)
}

@MainActor
@Test
func onboarding_progressLabel_countsDoneSteps() {
    let installer = MockInstaller()
    installer.installed2ch = false
    let vm = OnboardingViewModel(
        permissions: MockPermissionsService(),
        installer: installer,
        keychain: MockKeychain()
    )
    #expect(vm.progressLabel == "0 / 3 готово")
    installer.installed2ch = true
    vm.refresh()
    // BlackHole install sub-task is done, but audio capture still pending
    // → overall .blackHole step not done yet → still 0 / 3.
    #expect(vm.progressLabel == "0 / 3 готово")
}

@MainActor
@Test
func onboarding_onCompleted_firesExactlyOnce() async {
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .granted
    let kc = MockKeychain()
    try? kc.saveAPIKey("sk-proj-1234567890abcdef")
    // 2ch installed by default in MockInstaller.
    let vm = OnboardingViewModel(
        permissions: perms,
        installer: MockInstaller(),
        keychain: kc
    )
    var fired = 0
    vm.onCompleted = { fired += 1 }
    // Audio capture is still pending — allDone is false. Complete it.
    await vm.requestAudioCapturePermission()
    vm.refresh()
    #expect(fired == 1)
    vm.refresh()
    vm.refresh()
    #expect(fired == 1, "onCompleted must only fire once even with repeated refreshes")
}

@Test
func onboarding_openAIKeysURL_pointsToPlatform() {
    #expect(OnboardingViewModel.openAIKeysURL.absoluteString == "https://platform.openai.com/api-keys")
}

@Test
func onboarding_systemSettingsURL_microphoneOnly() {
    #expect(OnboardingViewModel.systemSettingsURL(for: .microphone) != nil)
    #expect(OnboardingViewModel.systemSettingsURL(for: .blackHole) == nil)
    #expect(OnboardingViewModel.systemSettingsURL(for: .apiKey) == nil)
}

// MARK: - Task 5: Audio setup sub-tasks

@MainActor
@Test func onboarding_audioSetup_requiresBothSubTasks() async {
    // Both sub-tasks must be done for overall .blackHole status.
    let installer = MockInstaller()
    installer.installed2ch = true
    let vm = OnboardingViewModel(
        permissions: MockPermissionsService(),
        installer: installer,
        keychain: MockKeychain()
    )
    vm.refresh()
    // 2ch is installed → install sub-task is done. Audio capture pending → overall pending.
    #expect(vm.blackHoleInstallStatus == .done)
    #expect(vm.audioCaptureStatus == .pending)
    #expect(vm.status[.blackHole] == .pending)
}

@MainActor
@Test func onboarding_audioSetup_bothSubTasksDone_overallDone() async {
    let installer = MockInstaller()
    installer.installed2ch = true
    let vm = OnboardingViewModel(
        permissions: MockPermissionsService(),
        installer: installer,
        keychain: MockKeychain()
    )
    vm.refresh()
    await vm.requestAudioCapturePermission()
    #expect(vm.audioCaptureStatus == .done)
    #expect(vm.status[.blackHole] == .done)
}

@MainActor
@Test func onboarding_audioSetup_installError_propagatesToOverall() async {
    let installer = MockInstaller()
    installer.installed2ch = false
    installer._runBundledInstaller = { throw BlackHoleInstallError.downloadFailed }
    let vm = OnboardingViewModel(
        permissions: MockPermissionsService(),
        installer: installer,
        keychain: MockKeychain()
    )
    await vm.installBlackHole()
    #expect(vm.blackHoleInstallStatus.errorMessage != nil)
    #expect(vm.status[.blackHole]?.errorMessage != nil)
}
