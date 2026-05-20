import SwiftUI
import UnisonDomain

/// Two-segment Call/Listen toggle used at the top of the popover.
/// Hand-drawn (`Picker(.segmented)` carries macOS accent blue, which
/// conflicts with our neutral palette). DESIGN.md §5.6.
public struct SegmentedToggle: View {
    public struct Segment: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let icon: Image
        public let mode: SessionMode

        public init(id: String, title: String, icon: Image, mode: SessionMode) {
            self.id = id
            self.title = title
            self.icon = icon
            self.mode = mode
        }
    }

    @Binding public var selection: SessionMode
    public let segments: [Segment]

    public init(selection: Binding<SessionMode>, segments: [Segment]) {
        self._selection = selection
        self.segments = segments
    }

    public init(selection: Binding<SessionMode>) {
        self._selection = selection
        self.segments = [
            Segment(id: "call", title: "Звонок", icon: Image(systemName: "phone.fill"), mode: .call),
            Segment(id: "listen", title: "Слушать", icon: Image(systemName: "ear.fill"), mode: .listen),
        ]
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { seg in
                SegmentButton(
                    segment: seg,
                    isSelected: seg.mode == selection,
                    onTap: { selectMode(seg.mode) }
                )
            }
        }
        .padding(3)
        .background(trackBackground)
    }

    private func selectMode(_ mode: SessionMode) {
        withAnimation(UnisonAnimations.state) {
            selection = mode
        }
    }

    private var trackBackground: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Color.black.opacity(0.22))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5)
            )
    }
}

private struct SegmentButton: View {
    let segment: SegmentedToggle.Segment
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                segment.icon
                    .font(.system(size: 13, weight: .regular))
                Text(segment.title)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? Color.white : UnisonColors.whiteAlpha(0.55))
            .background(selectedBackground)
            .overlay(selectedBorder)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(
                color: isSelected ? Color.black.opacity(0.2) : .clear,
                radius: 1, x: 0, y: 1
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var selectedBackground: some View {
        if isSelected {
            LinearGradient(
                colors: [UnisonColors.whiteAlpha(0.18), UnisonColors.whiteAlpha(0.06)],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            Color.clear
        }
    }

    private var selectedBorder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(
                isSelected ? UnisonColors.whiteAlpha(0.25) : Color.clear,
                lineWidth: 0.5
            )
    }
}
