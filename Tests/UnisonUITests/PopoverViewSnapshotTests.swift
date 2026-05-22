import SwiftUI
import Testing
@testable import UnisonDomain
@testable import UnisonUI

// `SwiftUI.Settings` shadows `UnisonDomain.Settings`; alias here so
// snapshot tests don't need to spell out the module everywhere.
private typealias Settings = UnisonDomain.Settings

/// Visual snapshots of `PopoverView`. Compares against the HTML mock in
/// `design/popover-final/index.html` — every state mirrors a panel
/// shown in that page.
@MainActor
struct PopoverViewSnapshotTests {

    // MARK: - Helpers

    private func makeVM(
        state: SessionState = .idle,
        settings: Settings = .default,
        permsGranted: Bool = true,
        bh2chPresent: Bool = true,
        bh16chPresent: Bool = true
    ) -> PopoverViewModel {
        let perms = PreviewPermissions()
        perms.statuses[.microphone] = permsGranted ? .granted : .denied
        let registry = PreviewDeviceRegistry()
        if !bh2chPresent { registry.bh2ch = nil }
        if !bh16chPresent { registry.bh16ch = nil }
        return .previewing(
            settings: settings,
            state: state,
            permissions: perms,
            deviceRegistry: registry
        )
    }

    /// The menu-bar popover lives on top of a system-blur background.
    /// We approximate that here by stacking on top of black so the
    /// glass material has something to multiply against.
    private func darkFloor<V: View>(_ view: V, size: CGSize) -> some View {
        ZStack {
            Color.black
            view
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Cases

    @Test func popover_idle() throws {
        let vm = makeVM(state: .idle)
        snap(darkFloor(PopoverView(vm: vm), size: SnapSize.popover), size: SnapSize.popover)
    }

    @Test func popover_sameLanguageWarn() throws {
        var settings = Settings.default
        settings.languagePair = LanguagePair(mine: .ru, peer: .ru)
        let vm = makeVM(state: .idle, settings: settings)
        snap(darkFloor(PopoverView(vm: vm), size: SnapSize.popover), size: SnapSize.popover)
    }

    @Test func popover_translating() throws {
        // Pretend the session started ~14 seconds ago so the mm:ss
        // label renders a sensible value instead of "13350752:47".
        let started = Date().addingTimeInterval(-14)
        let vm = makeVM(state: .translating(mode: .call, startedAt: started))
        snap(darkFloor(PopoverView(vm: vm), size: SnapSize.popover), size: SnapSize.popover)
    }

    @Test func popover_blockedByMissingBlackHole() throws {
        let vm = makeVM(state: .idle, bh16chPresent: false)
        snap(darkFloor(PopoverView(vm: vm), size: SnapSize.popover), size: SnapSize.popover)
    }

    /// Regression guard for the silent-failure bug: when the orchestrator
    /// surfaces a `.error(...)` state the popover must render an inline
    /// `ErrorRow` so the user knows what went wrong.
    @Test func popover_errorSurfaced() throws {
        let vm = makeVM(state: .error(.networkLost))
        snap(darkFloor(PopoverView(vm: vm), size: SnapSize.popover), size: SnapSize.popover)
    }
}
