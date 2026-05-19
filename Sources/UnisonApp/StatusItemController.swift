import AppKit
import SwiftUI
import UnisonDomain
import UnisonUI

@MainActor
public final class StatusItemController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let popoverVM: PopoverViewModel

    public init(popoverVM: PopoverViewModel) {
        self.popoverVM = popoverVM
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 280, height: 240)
        popover.contentViewController = NSHostingController(rootView: PopoverView(vm: popoverVM))

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
