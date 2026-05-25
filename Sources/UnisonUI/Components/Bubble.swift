import SwiftUI
import UnisonDomain

/// Single transcript bubble. T1 corner-tail + B3 inverted hierarchy:
/// primary text is large, secondary translated text is smaller italic.
/// DESIGN.md §5.14.
public struct Bubble: View {
    public let speaker: Speaker
    public let primary: String
    public let secondary: String
    public let isContinued: Bool
    public let isLastInGroup: Bool
    public let isLive: Bool
    /// Scale multiplier driven by the transcript size slider (0.75 … 1.30).
    public let scale: Double

    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        speaker: Speaker,
        primary: String,
        secondary: String,
        isContinued: Bool,
        isLastInGroup: Bool,
        isLive: Bool,
        scale: Double = 1.0
    ) {
        self.speaker = speaker
        self.primary = primary
        self.secondary = secondary
        self.isContinued = isContinued
        self.isLastInGroup = isLastInGroup
        self.isLive = isLive
        self.scale = scale
    }

    public var body: some View {
        // Bubbles use Apple's native Liquid Glass material (the
        // macOS 26 `.glassEffect(.regular.tint(_:), in:)` API). The
        // system handles every glass affordance — specular highlight,
        // conic rim, displacement, depth — automatically and
        // consistently with the rest of macOS Tahoe. The previous
        // implementation hand-rolled `.regularMaterial` underneath a
        // LinearGradient + clipShape + manual shadow, which on
        // macOS 26 looked like a flat blue-tinted blur rather than
        // actual liquid glass.
        //
        // Tint is the speaker affordance (blue for `me`, near-white
        // for `peer`). Text foreground stays explicit `.white` so it
        // reads with consistent contrast against the tinted glass.
        VStack(alignment: .leading, spacing: 5 * scale) {
            HStack(spacing: 6 * scale) {
                Text(primary)
                    .font(.system(size: 14.5 * scale, weight: .medium))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.25), radius: 0, x: 0, y: 1)
                if isLive {
                    TypingDots(scale: scale)
                }
            }
            if !secondary.isEmpty {
                Text(secondary)
                    .font(.system(size: 11 * scale, weight: .regular))
                    .italic()
                    .foregroundStyle(UnisonColors.whiteAlpha(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 11 * scale)
        .padding(.horizontal, 15 * scale)
        .glassEffect(glassStyle, in: shape)
        .overlay(
            shape
                .strokeBorder(border, lineWidth: borderWidth)
        )
        .frame(maxWidth: .infinity, alignment: speaker == .me ? .leading : .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
    }

    /// Speaker-tinted Liquid Glass: blue for `me`, slightly desaturated
    /// for `peer`. Tint passes through the system's glass rendering
    /// so the specular highlight + rim still picks up the underlying
    /// wallpaper / window backdrop — i.e. it actually looks like
    /// tinted glass, not a flat colour panel.
    private var glassStyle: Glass {
        switch speaker {
        case .me:
            // Blue tint pulled from the design's `me` gradient stops.
            return .regular.tint(
                Color(red: 110 / 255, green: 180 / 255, blue: 245 / 255).opacity(0.55)
            )
        case .peer:
            // Near-clear: white tint at low alpha lets the glass read
            // as "the other person", visually distinct from `me`
            // without competing.
            return .regular.tint(UnisonColors.whiteAlpha(0.10))
        }
    }

    private var accessibilityLabelText: String {
        if secondary.isEmpty {
            return primary
        }
        return "\(primary), переведено как \(secondary)"
    }

    private var borderWidth: CGFloat {
        contrast == .increased ? 1.0 : 0.5
    }

    private var shape: UnevenRoundedRectangle {
        // me: bottom-left is the speaker corner; peer: bottom-right.
        let base = 18 * scale
        let tail = 5 * scale
        let top = isContinued ? 8 * scale : base
        switch speaker {
        case .me:
            return UnevenRoundedRectangle(
                topLeadingRadius: top,
                bottomLeadingRadius: isLastInGroup ? tail : base,
                bottomTrailingRadius: base,
                topTrailingRadius: base,
                style: .continuous
            )
        case .peer:
            return UnevenRoundedRectangle(
                topLeadingRadius: base,
                bottomLeadingRadius: base,
                bottomTrailingRadius: isLastInGroup ? tail : base,
                topTrailingRadius: top,
                style: .continuous
            )
        }
    }


    private var border: Color {
        switch speaker {
        case .me:
            Color(red: 180 / 255, green: 220 / 255, blue: 1.0)
                .opacity(contrast == .increased ? 0.70 : 0.45)
        case .peer:
            UnisonColors.whiteAlpha(contrast == .increased ? 0.38 : 0.20)
        }
    }
}

/// Three small dots that pulse in sequence — appended to a `Bubble`'s
/// primary text when `isLive` is set.
public struct TypingDots: View {
    public let scale: Double

    public init(scale: Double = 1.0) {
        self.scale = scale
    }

    @SwiftUI.State private var phase: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        HStack(spacing: 3 * scale) {
            ForEach(0..<3) { i in
                Circle()
                    // When Reduce Motion is on, all three dots stay
                    // visible at half opacity (no animated phase pop)
                    // so the user still sees the typing affordance.
                    .fill(UnisonColors.whiteAlpha(reduceMotion ? 0.6 : 0.6))
                    .frame(width: 4 * scale, height: 4 * scale)
                    .offset(y: (!reduceMotion && phase == i) ? -2 * scale : 0)
                    .opacity(reduceMotion ? 0.55 : (phase == i ? 1.0 : 0.25))
            }
        }
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 2
            }
            Task {
                while true {
                    for i in 0..<3 {
                        await MainActor.run {
                            withAnimation(.easeInOut(duration: 0.4)) { phase = i }
                        }
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                }
            }
        }
    }
}

