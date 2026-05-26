import AppKit
import SwiftUI

/// Transparent SwiftUI background that drags the host window when
/// clicked. Use as `.background(WindowDragHandle())`.
///
/// Drags via manual `mouseDown`/`mouseDragged` rather than
/// `mouseDownCanMoveWindow` because the latter silently no-ops on
/// borderless `nonactivatingPanel`s — exactly the transcript panel's
/// style mask. Driving the drag ourselves keeps the behaviour
/// consistent across NSWindow subclasses.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        private var dragStartMouseScreenLocation: NSPoint?
        /// Captured once at mouseDown — we re-apply `start + delta`
        /// every drag tick so motion stays 1:1 with the cursor even
        /// if the OS coalesces events.
        private var dragStartWindowOrigin: NSPoint?

        override func mouseDown(with event: NSEvent) {
            guard let win = window else {
                super.mouseDown(with: event)
                return
            }
            dragStartMouseScreenLocation = NSEvent.mouseLocation
            dragStartWindowOrigin = win.frame.origin
        }

        override func mouseDragged(with event: NSEvent) {
            guard let win = window,
                  let startMouse = dragStartMouseScreenLocation,
                  let startOrigin = dragStartWindowOrigin else {
                super.mouseDragged(with: event)
                return
            }
            let current = NSEvent.mouseLocation
            let dx = current.x - startMouse.x
            let dy = current.y - startMouse.y
            win.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        }

        override func mouseUp(with event: NSEvent) {
            dragStartMouseScreenLocation = nil
            dragStartWindowOrigin = nil
            super.mouseUp(with: event)
        }
    }
}
