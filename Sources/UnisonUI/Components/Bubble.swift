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
        // HIG Materials note: bubbles render on top of *flat tinted
        // gradients* (blue tint for `me`, white tint for `peer`) — not
        // on a Liquid Glass material. Vibrant `.primary` / `.secondary`
        // foregrounds are designed for material surfaces; on a flat
        // tinted background they would desaturate or shift unexpectedly.
        // Keep explicit `Color.white` (and a half-opacity for the
        // translated subtext) so the bubble text reads consistently
        // regardless of light/dark or Increase Contrast settings.
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
                    .foregroundStyle(UnisonColors.whiteAlpha(0.52))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 11 * scale)
        .padding(.horizontal, 15 * scale)
        .background(background)
        .overlay(
            shape
                .strokeBorder(border, lineWidth: borderWidth)
        )
        .clipShape(shape)
        .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 14)
        .frame(maxWidth: .infinity, alignment: speaker == .me ? .leading : .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
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

    private var background: some View {
        // Two layers: `.regularMaterial` provides the backdrop blur
        // (HTML mock uses `backdrop-filter: blur(30px) saturate(190%)`),
        // which gives the bubble enough density to read against any
        // wallpaper — bright (white sand, water) or dark. The tinted
        // gradient on top adds the speaker colour (blue for `me`,
        // white for `peer`). Without the material underneath, the
        // gradient alone (0.10–0.20 alpha) is invisible on bright
        // backgrounds.
        ZStack {
            Rectangle().fill(.regularMaterial)
            LinearGradient(
                colors: gradientColors,
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var gradientColors: [Color] {
        // The `me` bubble's blue tint has to survive the `.regularMaterial`
        // underneath (which heavily desaturates) and any wallpaper tint
        // pulled through by the material's vibrancy. Earlier alpha values
        // (0.32 / 0.14, then 0.48 / 0.26) still washed out against the
        // sea wallpaper used by the VM screenshots — the `me` bubbles
        // came out greenish, not blue. Cycle 3 bumps the stops to
        // 0.55 / 0.30 (me) and 0.16 / 0.06 (peer) so the side colour
        // affordance survives material vibrancy on any backdrop.
        switch speaker {
        case .me:
            return [
                Color(red: 140 / 255, green: 200 / 255, blue: 1.0).opacity(0.55),
                Color(red: 95 / 255, green: 165 / 255, blue: 220 / 255).opacity(0.30),
            ]
        case .peer:
            return [
                UnisonColors.whiteAlpha(0.16),
                UnisonColors.whiteAlpha(0.06),
            ]
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

