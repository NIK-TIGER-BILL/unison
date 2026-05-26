import AppKit
import SwiftUI

/// Wraps a SwiftUI root view in `NSGlassEffectView` for AppKit windows
/// that need live, compositor-managed Liquid Glass. See CLAUDE.md.
@MainActor
final class GlassHostingViewController<Content: View>: NSViewController {
    private let hosting: NSHostingController<Content>
    private let style: NSGlassEffectView.Style
    private let cornerRadius: CGFloat

    init(
        rootView: Content,
        style: NSGlassEffectView.Style = .regular,
        cornerRadius: CGFloat = 0
    ) {
        self.hosting = NSHostingController(rootView: rootView)
        self.style = style
        self.cornerRadius = cornerRadius
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func loadView() {
        // The CALayer-backed `container` clips the alpha channel to
        // the rounded silhouette. Without it `NSGlassEffectView`
        // leaves the layer bounds rectangular and `hasShadow = true`
        // bleeds dark triangles into the corners.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.masksToBounds = true

        let glass = NSGlassEffectView()
        glass.style = style
        glass.cornerRadius = cornerRadius
        glass.translatesAutoresizingMaskIntoConstraints = false
        addChild(hosting)
        glass.contentView = hosting.view

        container.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        view = container
    }
}
