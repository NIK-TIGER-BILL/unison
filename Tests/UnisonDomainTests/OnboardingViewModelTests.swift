import Testing
@testable import UnisonDomain
@testable import UnisonUI

// Mock helpers
final class MockInstaller: BlackHoleInstaller, @unchecked Sendable {
    var installed2ch = true
    var installed16ch = true
    func is2chInstalled() -> Bool { installed2ch }
    func is16chInstalled() -> Bool { installed16ch }
    func runBundledInstaller() async throws { installed2ch = true; installed16ch = true }
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
    installer.installed16ch = false
    let vm = OnboardingViewModel(
        permissions: MockPermissionsService(),
        installer: installer,
        keychain: MockKeychain()
    )
    #expect(vm.steps.first { $0.kind == .blackHole }?.isDone == false)

    installer.installed2ch = true
    installer.installed16ch = true
    vm.refresh()
    #expect(vm.steps.first { $0.kind == .blackHole }?.isDone == true)
}

@MainActor
@Test func onboarding_saveApiKey_marksKeyStepDone() throws {
    let kc = MockKeychain()
    let vm = OnboardingViewModel(
        permissions: MockPermissionsService(),
        installer: MockInstaller(),
        keychain: kc
    )
    try vm.saveAPIKey("sk-test-123")
    vm.refresh()
    #expect(vm.steps.first { $0.kind == .apiKey }?.isDone == true)
}
