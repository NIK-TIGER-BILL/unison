import SwiftUI
import Testing
@testable import UnisonDomain
@testable import UnisonUI

private typealias Settings = UnisonDomain.Settings

@MainActor
struct SettingsViewSnapshotTests {

    private func makeVM() -> SettingsViewModel {
        SettingsViewModel(
            initial: .default,
            deviceRegistry: PreviewDeviceRegistry(),
            onChange: { _ in },
            keychain: PreviewKeychain(),
            installer: PreviewInstaller()
        )
    }

    private func panel<V: View>(_ view: V, size: CGSize) -> some View {
        ZStack {
            Color.black
            view
        }
        .frame(width: size.width, height: size.height)
    }

    @Test func settings_default() throws {
        let vm = makeVM()
        snap(panel(SettingsView(vm: vm), size: SnapSize.settings), size: SnapSize.settings)
    }

    @Test func settings_hotkeyRecording() throws {
        let vm = makeVM()
        vm.beginRecordingHotkey(.startStop)
        snap(panel(SettingsView(vm: vm), size: SnapSize.settings), size: SnapSize.settings)
    }
}
