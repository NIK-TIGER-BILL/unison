import SwiftUI

/// Small glass popover above the transcript's control pill. Hosts two
/// sliders: bubble size and original-track volume. DESIGN.md §5.19.
public struct TranscriptSettingsPopover: View {
    @Binding public var sizeIndex: Double // 0..4 continuous, mapped to XS/S/M/L/XL
    @Binding public var volume: Double    // 0..1

    public init(sizeIndex: Binding<Double>, volume: Binding<Double>) {
        self._sizeIndex = sizeIndex
        self._volume = volume
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                groupHead(title: "Размер транскрипта", value: Self.sizeLabel(for: sizeIndex))
                HStack(spacing: 10) {
                    Text("A")
                        .font(UnisonFonts.mono(10.5))
                        .tracking(0.4)
                        .foregroundStyle(UnisonColors.whiteAlpha(0.45))
                    NeutralSlider(value: $sizeIndex, in: 0...4)
                        .frame(maxWidth: .infinity)
                    Text("A")
                        .font(.system(size: 13))
                        .foregroundStyle(UnisonColors.whiteAlpha(0.45))
                }
                .padding(.top, 6)
            }
            Divider()
                .frame(height: 0.5)
                .overlay(UnisonColors.whiteAlpha(0.08))
                .padding(.vertical, 14)
            Group {
                groupHead(title: "Громкость оригинала", value: "\(Int((volume * 100).rounded()))%")
                NeutralSlider(value: $volume, in: 0...1)
                    .padding(.top, 6)
            }
        }
        .padding(16)
        .frame(width: 280)
        .liquidGlass(cornerRadius: 14)
    }

    private func groupHead(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(UnisonColors.whiteAlpha(0.9))
            Spacer()
            Text(value)
                .font(UnisonFonts.mono(11))
                .tracking(0.4)
                .foregroundStyle(UnisonColors.whiteAlpha(0.55))
        }
    }

    /// XS/S/M/L/XL from the discrete `0..4` index. Public so tests / hosts
    /// can mirror the label without re-deriving it.
    public nonisolated static func sizeLabel(for index: Double) -> String {
        let idx = max(0, min(4, Int(index.rounded())))
        return ["XS", "S", "M", "L", "XL"][idx]
    }

    /// Map the slider's `0..4` index to a bubble `scale` in `0.75 ... 1.3`
    /// (XS … XL). Continuous so the slider thumb moves smoothly.
    public nonisolated static func bubbleScale(for index: Double) -> Double {
        let clamped = max(0.0, min(4.0, index))
        return 0.75 + (clamped / 4.0) * (1.30 - 0.75)
    }
}

