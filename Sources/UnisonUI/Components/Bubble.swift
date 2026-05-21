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
                .strokeBorder(border, lineWidth: 0.5)
        )
        .clipShape(shape)
        .shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 14)
        .frame(maxWidth: .infinity, alignment: speaker == .me ? .leading : .trailing)
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
        switch speaker {
        case .me:
            return AnyView(
                LinearGradient(
                    colors: [
                        Color(red: 160 / 255, green: 210 / 255, blue: 1.0).opacity(0.20),
                        Color(red: 100 / 255, green: 160 / 255, blue: 220 / 255).opacity(0.09),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        case .peer:
            return AnyView(
                LinearGradient(
                    colors: [
                        UnisonColors.whiteAlpha(0.10),
                        UnisonColors.whiteAlpha(0.035),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private var border: Color {
        switch speaker {
        case .me:
            Color(red: 180 / 255, green: 220 / 255, blue: 1.0).opacity(0.24)
        case .peer:
            UnisonColors.whiteAlpha(0.13)
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

    public var body: some View {
        HStack(spacing: 3 * scale) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(UnisonColors.whiteAlpha(0.6))
                    .frame(width: 4 * scale, height: 4 * scale)
                    .offset(y: phase == i ? -2 * scale : 0)
                    .opacity(phase == i ? 1.0 : 0.25)
            }
        }
        .onAppear {
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

