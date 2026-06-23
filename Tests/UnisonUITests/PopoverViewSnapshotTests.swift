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
        bh2chPresent: Bool = true
    ) -> PopoverViewModel {
        let perms = PreviewPermissions()
        perms.statuses[.microphone] = permsGranted ? .granted : .denied
        let registry = PreviewDeviceRegistry()
        if !bh2chPresent { registry.bh2ch = nil }
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

    @Test func popover_blockedByMissingBlackHole2ch() throws {
        var settings = Settings.default
        settings.sessionMode = .call
        let vm = makeVM(state: .idle, settings: settings, bh2chPresent: false)
        snap(darkFloor(PopoverView(vm: vm), size: SnapSize.popover), size: SnapSize.popover)
    }

    /// Regression guard for the silent-failure bug: when the orchestrator
    /// surfaces a `.error(...)` state the popover must render an inline
    /// `ErrorRow` so the user knows what went wrong.
    @Test func popover_errorSurfaced() throws {
        let vm = makeVM(state: .error(.networkLost))
        snap(darkFloor(PopoverView(vm: vm), size: SnapSize.popover), size: SnapSize.popover)
    }

    /// Captures both the inline `ErrorRow` and the secondary
    /// "Подробности…" link below it (the latter sits past the
    /// `SnapSize.popover` 420pt cutoff in production renders). The
    /// taller frame here exists purely to keep the diagnostic affordance
    /// in the snapshot so regressions in that label are caught.
    @Test func popover_errorSurfacedWithDiagnosticLink() throws {
        let vm = makeVM(state: .error(.networkLost))
        let size = CGSize(width: SnapSize.popover.width, height: 480)
        snap(darkFloor(PopoverView(vm: vm), size: size), size: size)
    }

    /// During `.reconnecting` the popover must keep showing the timer +
    /// Stop button (so the UI doesn't flicker when a flapping stream
    /// oscillates between `.translating` and `.reconnecting`) and surface
    /// a small "Переподключение…" hint below. The taller frame captures
    /// the hint label which sits past the normal 420pt cutoff.
    @Test func popover_reconnecting() throws {
        let started = Date().addingTimeInterval(-14)
        let vm = makeVM(state: .reconnecting(mode: .call, since: Date(), startedAt: started))
        let size = CGSize(width: SnapSize.popover.width, height: 480)
        snap(darkFloor(PopoverView(vm: vm), size: size), size: size)
    }

    /// `.translating` + `connectivityHealth == .slow` — the status dot
    /// flips yellow and a "Медленная сеть" hint replaces the language
    /// pair label. Mirrors T1-T12 work that wired `ConnectivityHealth`
    /// into the popover status row.
    @Test func popover_translatingSlow() throws {
        let started = Date().addingTimeInterval(-14)
        let vm = makeVM(state: .translating(mode: .call, startedAt: started))
        vm.previewConnectivityHealth = .slow
        snap(darkFloor(PopoverView(vm: vm), size: SnapSize.popover), size: SnapSize.popover)
    }

    /// `.paused(reason: .networkLost)` — grey dot, "Нет интернета. Ждём…"
    /// hint. Taller frame matches `popover_reconnecting` so the hint that
    /// sits past the 420pt cutoff stays in-frame.
    @Test func popover_pausedNetworkLost() throws {
        let started = Date().addingTimeInterval(-14)
        let size = CGSize(width: SnapSize.popover.width, height: 480)
        let vm = makeVM(state: .paused(mode: .call, since: Date(), startedAt: started, reason: .networkLost))
        snap(darkFloor(PopoverView(vm: vm), size: size), size: size)
    }

    /// `.paused(reason: .awaitingNetwork)` — cyan dot, "Возобновляем…"
    /// hint. Transitional state between network return and WS resume.
    @Test func popover_pausedAwaitingNetwork() throws {
        let started = Date().addingTimeInterval(-14)
        let size = CGSize(width: SnapSize.popover.width, height: 480)
        let vm = makeVM(state: .paused(mode: .call, since: Date(), startedAt: started, reason: .awaitingNetwork))
        snap(darkFloor(PopoverView(vm: vm), size: size), size: size)
    }

    /// Regression guard for the empty-allowlist hint: when `tapScopeMode`
    /// is `.onlySelected` and `includedTapBundleIDs` is empty the popover
    /// must show a `WarnRow` ("Выберите приложения для перевода") and block
    /// the Start button via `.noAppsToTranslate`.
    ///
    /// Uses `.listen` mode so the mic-permission and BlackHole gates are
    /// both skipped — the only blocker is the empty allowlist.
    /// `LanguagePair.default` (`.ru` → `.en`) keeps the same-language
    /// `WarnRow` silent, leaving exactly one warning row in the snapshot.
    @Test func popover_blockedByEmptyAllowlist() throws {
        var settings = Settings.default
        settings.sessionMode = .listen
        settings.tapScopeMode = .onlySelected
        settings.includedTapBundleIDs = []
        let vm = makeVM(state: .idle, settings: settings)
        snap(darkFloor(PopoverView(vm: vm), size: SnapSize.popover), size: SnapSize.popover)
    }
}
