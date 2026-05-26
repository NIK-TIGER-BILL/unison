import AppKit
import SwiftUI
import UnisonUI

/// Hosts the Settings `NSWindow`. Standard `.titled` chrome with
/// traffic lights, content extends behind the transparent titlebar
/// via `.fullSizeContentView`. See CLAUDE.md.
///
/// `onRecordHotkey` bridges UnisonUI back into the AppKit
/// `HotkeyService` (UnisonUI can't import AppKit).
@MainActor
public final class SettingsWindowController {
    private var window: NSWindow?
    private let viewModel: SettingsViewModel
    private let onRecordHotkey: (HotkeyKind) -> Void
    private let onOpenURL: (URL) -> Void

    public init(
        viewModel: SettingsViewModel,
        onRecordHotkey: @escaping (HotkeyKind) -> Void = { _ in },
        onOpenURL: @escaping (URL) -> Void = { url in NSWorkspace.shared.open(url) }
    ) {
        self.viewModel = viewModel
        self.onRecordHotkey = onRecordHotkey
        self.onOpenURL = onOpenURL
    }

    public func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "Unison · Настройки"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            // Transparent window so NSGlassEffectView is the only
            // visible surface; otherwise the system paints
            // `windowBackgroundColor` on top of the glass.
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.minSize = NSSize(width: 560, height: 480)
            w.maxSize = NSSize(width: 800, height: 1200)

            let root = SettingsView(
                vm: viewModel,
                onOpenURL: onOpenURL,
                onRecordHotkey: onRecordHotkey
            )
            // 10pt matches the system corner radius of `.titled` windows.
            w.contentViewController = GlassHostingViewController(
                rootView: root,
                style: .regular,
                cornerRadius: 10
            )
            w.setContentSize(NSSize(width: 560, height: 620))
            w.center()
            window = w
        }
        // CoreAudio change events feed the VM live, but a stale
        // snapshot can survive an unplug if the window was closed
        // during the change. Re-probe each show.
        viewModel.refreshDeviceList()
        viewModel.refreshBlackHoleStatus()

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        // Steal focus from the menubar popover so hotkey recording
        // and `HotkeyRecorder` get key events.
        NSApp.activate(ignoringOtherApps: true)
    }
}
