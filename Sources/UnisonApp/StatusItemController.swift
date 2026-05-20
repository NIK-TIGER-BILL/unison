import AppKit
import SwiftUI
import UnisonDomain
import UnisonUI

@MainActor
public final class StatusItemController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let popoverVM: PopoverViewModel
    private let onOpenSettings: () -> Void

    public init(
        popoverVM: PopoverViewModel,
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.popoverVM = popoverVM
        self.onOpenSettings = onOpenSettings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        popover.behavior = .transient
        // 340pt width matches the redesigned PopoverView (DESIGN §4.3).
        // Height comes from the SwiftUI ideal size — we enable
        // `preferredContentSize` so the popover grows when the dropdown
        // overlay expands the SwiftUI hierarchy.
        let popoverRef = popover
        let host = NSHostingController(
            rootView: PopoverView(vm: popoverVM, onOpenSettings: { [popoverRef] in
                // Dismiss the popover before opening Settings so it
                // doesn't sit on top of the new window.
                popoverRef.performClose(nil)
                onOpenSettings()
            })
        )
        host.sizingOptions = [.preferredContentSize]
        popover.contentSize = NSSize(width: 340, height: 320)
        popover.contentViewController = host

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Unison")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    public func setActiveIcon(_ active: Bool) {
        let name = active ? "globe.badge.chevron.backward" : "globe"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Unison")
    }
}
