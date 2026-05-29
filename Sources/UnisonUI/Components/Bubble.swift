import SwiftUI
import UnisonDomain

/// Single transcript bubble. Speaker-coloured Liquid Glass with an
/// `UnevenRoundedRectangle` corner tail. Switches to a yellow palette
/// in `.test` mode (see CLAUDE.md).
public struct Bubble: View {
    public let speaker: Speaker
    public let primary: String
    public let secondary: String
    public let isContinued: Bool
    public let isLastInGroup: Bool
    public let isLive: Bool
    /// Multiplier driven by the transcript size slider (0.75 … 1.30).
    public let scale: Double
    public let isTestMode: Bool
    /// When true, the translation never arrived for this entry (the
    /// orchestrator paused/reconnected mid-flight). Renders a grey
    /// italic "перевод не получен" placeholder where the translation
    /// would normally appear — for `.me` that's the `secondary` slot,
    /// for `.peer` it's the `primary` slot.
    public let translationLost: Bool

    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        speaker: Speaker,
        primary: String,
        secondary: String,
        isContinued: Bool,
        isLastInGroup: Bool,
        isLive: Bool,
        scale: Double = 1.0,
        isTestMode: Bool = false,
        translationLost: Bool = false
    ) {
        self.speaker = speaker
        self.primary = primary
        self.secondary = secondary
        self.isContinued = isContinued
        self.isLastInGroup = isLastInGroup
        self.isLive = isLive
        self.scale = scale
        self.isTestMode = isTestMode
        self.translationLost = translationLost
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5 * scale) {
            HStack(spacing: 6 * scale) {
                if speaker == .peer && translationLost && primary.isEmpty {
                    // Peer's translation is the primary slot — when it
                    // never arrived, show the placeholder here.
                    lostPlaceholder
                } else {
                    Text(primary)
                        .font(.system(size: 14.5 * scale, weight: .medium))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .shadow(color: .black.opacity(0.25), radius: 0, x: 0, y: 1)
                }
                if isLive {
                    TypingDots(scale: scale)
                }
            }
            if speaker == .me && translationLost && secondary.isEmpty {
                // My translation is the secondary slot — when it never
                // arrived, show the placeholder here.
                lostPlaceholder
            } else if !secondary.isEmpty {
                Text(secondary)
                    .font(.system(size: 11 * scale, weight: .regular))
                    .italic()
                    .foregroundStyle(UnisonColors.whiteAlpha(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 11 * scale)
        .padding(.horizontal, 15 * scale)
        .liquidGlass(shape: shape, tint: tintColor, highContrastHairline: false)
        .overlay(
            shape
                .strokeBorder(border, lineWidth: borderWidth)
        )
        .frame(maxWidth: .infinity, alignment: speaker == .me ? .leading : .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
    }

    /// Grey italic placeholder rendered where the translation would
    /// normally appear when the orchestrator lost the translation
    /// mid-flight.
    private var lostPlaceholder: some View {
        HStack(spacing: 4 * scale) {
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 10 * scale))
            Text("Перевод не получен — нестабильная сеть")
                .font(.system(size: 13 * scale, weight: .regular).italic())
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(UnisonColors.whiteAlpha(0.45))
    }

    /// Opacities stay ≤ 0.25 so the system's specular / refraction
    /// still picks up the wallpaper. Higher opacities flatten the
    /// glass to a solid colour panel.
    private var tintColor: Color {
        if isTestMode {
            switch speaker {
            case .me:   return UnisonColors.warn.opacity(0.25)
            case .peer: return UnisonColors.warn.opacity(0.10)
            }
        }
        switch speaker {
        case .me:
            return Color(red: 110 / 255, green: 180 / 255, blue: 245 / 255).opacity(0.25)
        case .peer:
            return UnisonColors.whiteAlpha(0.10)
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

    /// `me`: bottom-leading is the speaker tail corner. `peer`: bottom-trailing.
    private var shape: UnevenRoundedRectangle {
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
        if isTestMode {
            switch speaker {
            case .me:
                return UnisonColors.warn.opacity(contrast == .increased ? 0.70 : 0.45)
            case .peer:
                return UnisonColors.warn.opacity(contrast == .increased ? 0.38 : 0.20)
            }
        }
        switch speaker {
        case .me:
            return Color(red: 180 / 255, green: 220 / 255, blue: 1.0)
                .opacity(contrast == .increased ? 0.70 : 0.45)
        case .peer:
            return UnisonColors.whiteAlpha(contrast == .increased ? 0.38 : 0.20)
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
                    .fill(UnisonColors.whiteAlpha(0.6))
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
