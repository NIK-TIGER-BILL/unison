import AppKit
import SwiftUI

/// A transparent SwiftUI background that lets the user drag the host
/// window by clicking on it. Use as `.background(WindowDragHandle())`
/// on the pill or any region that should function as a drag surface.
///
/// **Why this instead of `isMovableByWindowBackground = true`?**
/// `NSWindow.isMovableByWindowBackground` moves the window from *any*
/// region that the AppKit hit-test thinks is non-interactive. On the
/// transcript panel this competes with SwiftUI sliders inside the
/// settings popover — depending on hit-test ordering, drags on the
/// slider thumb can fall through to the window and move it instead of
/// the slider value.
///
/// This view inserts a dedicated `NSView` whose
/// `mouseDownCanMoveWindow` is `true`, scoped strictly to its frame.
/// AppKit handles the drag at the view layer, and nothing else
/// (sliders, buttons, content) inherits drag behaviour.
public struct WindowDragHandle: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView {
        DragView()
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        // Transparent — we only exist to provide the drag-handle hit
        // region. The visual surface lives in the parent SwiftUI view.
        override func hitTest(_ point: NSPoint) -> NSView? {
            // Standard hit-test so the drag region is its full bounds.
            super.hitTest(point)
        }
    }
}
