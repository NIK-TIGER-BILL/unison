import SwiftUI

/// Small colored dot used in the popover header and settings rows to
/// communicate session / install status. DESIGN.md §5.5.
public struct StatusDot: View {
    public enum State: Equatable, Sendable {
        case ready
        case active
        case warn
        case error
    }

    public let state: State
    public let size: CGFloat
    public let pulse: Bool

    /// - Parameters:
    ///   - state: which color to paint. `.active` triggers an opacity pulse
    ///     unless `pulse` is explicitly set to `false`.
    ///   - size: dot diameter in points. 6–7 is the design's typical value.
    ///   - pulse: forces the pulse on/off. `nil` means "follow `state`"
    ///     (only `.active` pulses).
    public init(state: State, size: CGFloat = 7, pulse: Bool? = nil) {
        self.state = state
        self.size = size
        self.pulse = pulse ?? (state == .active)
    }

    @SwiftUI.State private var pulsing = false

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.65), radius: size * 0.9)
            .opacity(pulse && pulsing ? 0.5 : 1.0)
            .animation(
                pulse ? UnisonAnimations.pulseAnimation : nil,
                value: pulsing
            )
            .onAppear { if pulse { pulsing = true } }
            .onChange(of: pulse) { _, new in pulsing = new }
    }

    private var color: Color {
        switch state {
        case .ready: UnisonColors.ready
        case .active: UnisonColors.active
        case .warn:  UnisonColors.warn
        case .error: UnisonColors.error
        }
    }
}

