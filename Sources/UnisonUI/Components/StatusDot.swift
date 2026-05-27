import SwiftUI

/// Small colored dot used in the popover header and settings rows to
/// communicate session / install status. DESIGN.md §5.5.
public struct StatusDot: View {
    public enum State: Equatable, Sendable {
        case ready
        case active
        case warn
        case error
        case paused
        case recovering
    }

    public let state: State
    public let size: CGFloat
    public let pulse: Bool

    /// - Parameters:
    ///   - state: which color to paint. `.active` and `.recovering` trigger an opacity pulse
    ///     unless `pulse` is explicitly set to `false`.
    ///   - size: dot diameter in points. 6–7 is the design's typical value.
    ///   - pulse: forces the pulse on/off. `nil` means "follow `state`"
    ///     (only `.active` and `.recovering` pulse).
    public init(state: State, size: CGFloat = 7, pulse: Bool? = nil) {
        self.state = state
        self.size = size
        self.pulse = pulse ?? (state == .active || state == .recovering)
    }

    @SwiftUI.State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        let shouldPulse = pulse && !reduceMotion
        return Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.65), radius: size * 0.9)
            .opacity(shouldPulse && pulsing ? 0.5 : 1.0)
            .animation(
                shouldPulse ? UnisonAnimations.pulseAnimation : nil,
                value: pulsing
            )
            .onAppear { if shouldPulse { pulsing = true } }
            .onChange(of: pulse) { _, new in pulsing = new && !reduceMotion }
            .accessibilityLabel(accessibilityLabelText)
            .help(accessibilityLabelText)
    }

    private var color: Color {
        switch state {
        case .ready: UnisonColors.ready
        case .active: UnisonColors.active
        case .warn:  UnisonColors.warn
        case .error: UnisonColors.error
        case .paused: UnisonColors.whiteAlpha(0.30)
        case .recovering: UnisonColors.active
        }
    }

    private var accessibilityLabelText: String {
        switch state {
        case .ready:  "Готов"
        case .active: "Идёт перевод"
        case .warn:   "Предупреждение"
        case .error:  "Ошибка"
        case .paused: "Приостановлено"
        case .recovering: "Восстановление"
        }
    }
}
