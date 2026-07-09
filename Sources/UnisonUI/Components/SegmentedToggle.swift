import SwiftUI
import UnisonDomain

/// Session-mode toggle at the top of the popover — Call / Listen.
/// A single Liquid-Glass "chip" glides between the two halves on a
/// spring, instead of each segment lighting its own background.
///
/// The chip is real, live glass (`NSGlassEffectView` via
/// `.liquidGlassLive`) — a subtle white *tint* (not an opaque fill, which
/// would flatten the material into a bright slab and hide the active
/// label) plus a top-lit hairline rim for the raised edge. The active
/// label is white with a 1px dark shadow so it stays legible over the
/// frosted chip even when it refracts bright call content — the same
/// tinted-glass + shadowed-white-text recipe as the transcript `Bubble`.
/// Positioning is done with
/// `matchedGeometryEffect` against a per-segment anchor rather than a
/// `GeometryReader`/`.alignmentGuide` measurement: both of those can
/// drive the popover's auto-sizing `NSHostingView` into a layout-size
/// recursion crash, and matched geometry needs no second layout pass
/// (so it renders correctly in one synchronous offscreen pass). One
/// chip instance is slaved to the selected anchor, so a single glass
/// view survives the whole slide — no representable teardown mid-move.
///
/// Still hand-drawn rather than `Picker(.segmented)`, which carries
/// macOS accent blue that clashes with the neutral palette. DESIGN.md
/// §5.6. The third mode (Проверка / test) stays a separate header
/// button (`testButton` in `PopoverView`), so this picker remains
/// binary for the two real-world routing modes.
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
            Segment(id: "listen", title: "Слушать", icon: Image(systemName: "ear.fill"), mode: .listen)
        ]
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Namespace private var chipNamespace

    private let trackPadding: CGFloat = 3

    /// The segment whose anchor the chip snaps to. Falls back to the
    /// first segment if `selection` isn't among them (shouldn't happen),
    /// so the chip always has a source frame to adopt.
    private var selectedID: String {
        (segments.first { $0.mode == selection } ?? segments.first)?.id ?? ""
    }

    public var body: some View {
        ZStack {
            // Behind the labels: one chip, slaved to the selected
            // segment's anchor frame. `isSource: false` means it adopts
            // that frame without publishing its own, so it never affects
            // the row's size — the label buttons define the geometry.
            chip
                .matchedGeometryEffect(id: selectedID, in: chipNamespace, isSource: false)
                .allowsHitTesting(false)

            HStack(spacing: 0) {
                ForEach(segments) { seg in
                    segmentButton(seg)
                }
            }
        }
        .padding(trackPadding)
        .background(trackBackground)
    }

    private func segmentButton(_ seg: Segment) -> some View {
        let isSelected = seg.mode == selection
        return Button {
            selectMode(seg.mode)
        } label: {
            HStack(spacing: 6) {
                seg.icon
                    .font(.system(size: 13, weight: .regular))
                Text(seg.title)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            // Active: white — reads on the frosted chip. Inactive: dimmed
            // white on the dark track (contrast-aware, like `Bubble`).
            .foregroundStyle(isSelected ? Color.white : inactiveLabelColor)
            // A 1px dark shadow keeps the active label legible on the
            // frosted chip even when it refracts light call content —
            // the transcript bubbles use the same trick.
            .shadow(color: .black.opacity(isSelected ? 0.25 : 0), radius: 0, x: 0, y: 1)
            // Claim the whole half as the tap target; a text-only hit
            // area would leave most of the column dead.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Each button publishes its frame as a chip slide target.
        .matchedGeometryEffect(id: seg.id, in: chipNamespace, isSource: true)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var inactiveLabelColor: Color {
        UnisonColors.whiteAlpha(contrast == .increased ? 0.85 : 0.6)
    }

    private func selectMode(_ mode: SessionMode) {
        withAnimation(UnisonAnimations.segmentSlide.reduceMotion(reduceMotion)) {
            selection = mode
        }
    }

    // MARK: - Chip

    /// The sliding selection chip: tinted live glass under a top-lit
    /// hairline rim. `Color.clear` is a flexible base, so the glass fills
    /// whatever frame matched geometry hands the chip. The tint stays low
    /// (≤ 0.16) so the material keeps refracting rather than flattening
    /// into an opaque slab — same guidance as `Bubble`'s tint.
    private var chip: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Color.clear
            .liquidGlassLive(
                shape: shape,
                tint: UnisonColors.whiteAlpha(0.14),
                highContrastHairline: false
            )
            .overlay(
                // Top-lit rim: bright along the top edge, fading down —
                // the cue that reads as a raised glass tile.
                shape.strokeBorder(
                    LinearGradient(
                        colors: [UnisonColors.whiteAlpha(0.38), UnisonColors.whiteAlpha(0.10)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.6
                )
            )
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
