import SwiftUI
import Testing
@testable import UnisonDomain
@testable import UnisonUI

/// Visual snapshots of `OnboardingView`. Mirrors the states shown in
/// `design/onboarding-final/index.html` — initial-pending,
/// blackhole-installing, mic-error, all-done.
@MainActor
struct OnboardingViewSnapshotTests {

    private func makeVM(
        installer: PreviewInstaller = PreviewInstaller(),
        permissions: PreviewPermissions = PreviewPermissions(),
        keychain: PreviewKeychain = PreviewKeychain()
    ) -> OnboardingViewModel {
        OnboardingViewModel(
            permissions: permissions,
            installer: installer,
            keychain: keychain
        )
    }

    private func panel<V: View>(_ view: V, size: CGSize) -> some View {
        ZStack {
            Color.black
            view
        }
        .frame(width: size.width, height: size.height)
    }

    @Test func onboarding_initialPending() throws {
        let installer = PreviewInstaller()
        installer.installed2ch = false
        installer.installed16ch = false
        let perms = PreviewPermissions()
        perms.statuses[.microphone] = .notDetermined
        let vm = makeVM(installer: installer, permissions: perms)
        snap(panel(OnboardingView(vm: vm), size: SnapSize.onboarding), size: SnapSize.onboarding)
    }

    @Test func onboarding_blackHoleInstalling() throws {
        let installer = PreviewInstaller()
        installer.installed2ch = false
        installer.installed16ch = false
        let perms = PreviewPermissions()
        perms.statuses[.microphone] = .notDetermined
        let vm = makeVM(installer: installer, permissions: perms)
        vm.setStatus(.inProgress, for: .blackHole)
        snap(panel(OnboardingView(vm: vm), size: SnapSize.onboarding), size: SnapSize.onboarding)
    }

    @Test func onboarding_microphoneError() throws {
        let installer = PreviewInstaller()
        installer.installed2ch = true
        installer.installed16ch = true
        let perms = PreviewPermissions()
        perms.statuses[.microphone] = .denied
        let vm = makeVM(installer: installer, permissions: perms)
        vm.setStatus(.error("Доступ запрещён. Включите микрофон для Unison в Настройках системы."), for: .microphone)
        snap(panel(OnboardingView(vm: vm), size: SnapSize.onboarding), size: SnapSize.onboarding)
    }

    @Test func onboarding_allDone() throws {
        let installer = PreviewInstaller()
        installer.installed2ch = true
        installer.installed16ch = true
        let perms = PreviewPermissions()
        perms.statuses[.microphone] = .granted
        let kc = PreviewKeychain()
        kc.stored = "sk-proj-1234567890abcdef"
        let vm = makeVM(installer: installer, permissions: perms, keychain: kc)
        snap(panel(OnboardingView(vm: vm), size: SnapSize.onboarding), size: SnapSize.onboarding)
    }
}
