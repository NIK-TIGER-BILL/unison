import AppKit
import QuartzCore
import SwiftUI

// Живое, композитор-управляемое Liquid Glass для SwiftUI-поверхностей —
// AppKit-двойник `LiquidGlassPanel` (`.glassEffect`). В отличие от
// SwiftUI-стекла (статичного между перерисовками view-tree), этот путь
// пересэмплирует фон каждый кадр, поэтому поверхность продолжает
// подстраиваться, пока контент за окном движется. См. CLAUDE.md.
//
// Вешается по-поверхностно как `.background`, hit-test-прозрачно — чтобы
// не перехватывать мышь у drag-хэндла пилла и контролов поверх.

// MARK: - AppKit-контейнер (юнит-тестируемый, без SwiftUI Context)

/// Хостит `NSGlassEffectView`, клипованный произвольным путём формы.
/// Вынесен из representable, чтобы конструироваться и проверяться прямо
/// в тестах (`NSViewRepresentable.Context` вне SwiftUI не синтезируется).
final class LiquidGlassContainerView: NSView {
    private let glass = NSGlassEffectView()
    private let maskLayer = CAShapeLayer()

    /// bounds → путь клипа, в top-left системе SwiftUI (flip в `layout()`).
    var pathProvider: (CGRect) -> CGPath = { CGPath(rect: $0, transform: nil) } {
        didSet { needsLayout = true }
    }

    /// Тинт стекла (рефрагируется материалом, как `Glass.tint`).
    var glassTint: NSColor? {
        didSet { glass.tintColor = glassTint }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glass.style = .regular
        // Uniform cornerRadius = 0: клип делает маска формы, чтобы
        // сохранять неровный хвост бабла.
        glass.cornerRadius = 0
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        // `maskLayer` is a detached CAShapeLayer (no view delegate), so its
        // animatable `path`/`contentsScale` would implicit-animate (~0.25s)
        // on every change. A clip mask must track content synchronously —
        // otherwise a growing live bubble briefly shows its newest line with
        // no glass behind it until the mask catches up. Disable the actions.
        maskLayer.actions = ["path": NSNull(), "contentsScale": NSNull()]
        layer?.mask = maskLayer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // Чистая декорация: никогда не перехватываем указатель, чтобы
    // WindowDragHandle / слайдеры / кнопки поверх сохранили события.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        glass.frame = bounds
        // Manually-created mask layers default to contentsScale 1.0 and do
        // NOT auto-track the window scale — set it so the clipped silhouette
        // stays crisp on Retina (matters for pill/popover/modal, which have
        // no border to hide a soft edge).
        maskLayer.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2.0
        // Пути SwiftUI — top-left origin; маски CALayer — bottom-left.
        // Flip по Y, чтобы верхне-тяжёлый хвост бабла лёг на верный край.
        let raw = pathProvider(bounds)
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
        maskLayer.path = raw.copy(using: &flip) ?? raw
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
}

// MARK: - SwiftUI-мост

struct LiquidGlassLive<S: Shape>: NSViewRepresentable {
    let shape: S
    let tint: Color?

    func makeNSView(context: Context) -> LiquidGlassContainerView {
        let view = LiquidGlassContainerView(frame: .zero)
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: LiquidGlassContainerView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: LiquidGlassContainerView) {
        let shape = self.shape
        view.pathProvider = { rect in shape.path(in: rect).cgPath }
        view.glassTint = tint.map { NSColor($0) }
    }
}

// MARK: - Модификатор + сахар (зеркалит LiquidGlassPanel / .liquidGlass)

struct LiquidGlassLivePanel<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let highContrastHairline: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            // Reduce Transparency → делегируем на статичный путь: он даёт
            // `.identity`-стекло, так что a11y-паритет достаётся бесплатно.
            content.liquidGlass(shape: shape, tint: tint, highContrastHairline: highContrastHairline)
        } else {
            content
                .background { LiquidGlassLive(shape: shape, tint: tint) }
                .overlay {
                    if highContrastHairline && contrast == .increased {
                        shape.strokeBorder(UnisonColors.whiteAlpha(0.30), lineWidth: 1.5)
                    }
                }
        }
    }
}

extension View {
    /// Живое Liquid Glass с произвольной формой. Параметры зеркалят
    /// `.liquidGlass`; `highContrastHairline: false`, когда вызывающий
    /// рисует свой бордер (Bubble).
    func liquidGlassLive<S: InsettableShape>(
        shape: S,
        tint: Color? = nil,
        highContrastHairline: Bool = true
    ) -> some View {
        modifier(LiquidGlassLivePanel(
            shape: shape,
            tint: tint,
            highContrastHairline: highContrastHairline
        ))
    }

    /// Rounded-rectangle сокращение.
    func liquidGlassLive(
        cornerRadius: CGFloat = 14,
        tint: Color? = nil,
        highContrastHairline: Bool = true
    ) -> some View {
        liquidGlassLive(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            tint: tint,
            highContrastHairline: highContrastHairline
        )
    }
}
