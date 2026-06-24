import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UnisonDomain
import UnisonUI

/// Hosts the meeting-archive `NSWindow`. Standard `.titled` glass chrome
/// like Settings. Bridges `MeetingHistoryView`'s export closure into an
/// `NSSavePanel` (UnisonUI can't import AppKit).
@MainActor
public final class MeetingHistoryWindowController {
    private var window: NSWindow?
    private let viewModel: MeetingHistoryViewModel

    public init(viewModel: MeetingHistoryViewModel) {
        self.viewModel = viewModel
    }

    public func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "Unison · История"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.minSize = NSSize(width: 720, height: 460)

            let root = MeetingHistoryView(
                vm: viewModel,
                onExport: { [weak self] record in self?.exportToFile(record) }
            )
            w.contentViewController = GlassHostingViewController(
                rootView: root,
                style: .regular,
                cornerRadius: 10
            )
            w.setContentSize(NSSize(width: 820, height: 560))
            w.center()
            window = w
        }
        // Refresh the list each show in case sessions ended (or rotation
        // ran) while the window was closed.
        viewModel.reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func exportToFile(_ record: MeetingRecord) {
        // Render the export text up front so the (nonisolated) save-panel
        // completion closure only captures value types (`String` + `URL`).
        let text = record.exportText()
        let filename = record.displayTitle + ".txt"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = filename
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
