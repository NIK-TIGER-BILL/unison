import SwiftUI
import UnisonDomain

/// Floating transcript window content. Bubbles in a ScrollView with a
/// `ControlPill` pinned at the bottom via `.safeAreaBar`. Transparent
/// background — host `NSPanel` is `backgroundColor = .clear` and the
/// glass lives on each bubble / pill / modal (see CLAUDE.md).
public struct TranscriptView: View {
    @Bindable var vm: TranscriptViewModel

    public init(vm: TranscriptViewModel) {
        self.vm = vm
    }

    @SwiftUI.State private var isSettingsOpen: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Cadence at which the recency window is re-evaluated so bubbles
    /// expire during silence (not only on new content). Finer than
    /// `TranscriptViewModel.windowSeconds` — 1 s gives ≤ 1 s visual
    /// latency on expiry at trivial cost.
    private static let windowTickInterval: TimeInterval = 1

    /// Height of the top fade-out band where scrolling bubbles dissolve
    /// into the transparent panel edge instead of hitting a hard clip line.
    private static let topFadeHeight: CGFloat = 24

    public var body: some View {
        ZStack {
            ScrollView {
                if !vm.isHidden {
                    bubbles
                        .transition(.opacity)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                }
            }
            .scrollIndicators(.hidden)
            // Bottom anchor — transcript reads bottom-up, older entries
            // dissolve off the top through the fade mask below.
            .defaultScrollAnchor(.bottom)
            .scrollEdgeEffectStyle(.soft, for: .all)
            // Soft top edge: fade the scrolling content — live AppKit glass
            // included — to transparent over `topFadeHeight`, so bubbles
            // dissolve past the top instead of hitting a hard clip line. A
            // SwiftUI `.mask` becomes a CALayer mask, which fades the
            // compositor glass too (the same layer-mask mechanism
            // `LiquidGlassLive` clips each bubble with). The control pill
            // sits in the `.safeAreaBar` outside this mask, so it stays
            // fully opaque.
            .mask(alignment: .top) {
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: Self.topFadeHeight)
                    Color.black
                }
            }
            .safeAreaBar(edge: .bottom) {
                controlPillWithPopover
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 22)
                    .padding(.horizontal, 8)
            }

            if vm.showStopConfirmation {
                // Entrance/exit runs through the transition (driven by the
                // `glassAppear` animation below) — scale+fade in, reverse
                // out. Reduce Motion keeps just the fade.
                stopModal
                    .transition(reduceMotion
                        ? .opacity
                        : .scale(scale: 0.92).combined(with: .opacity))
                    .zIndex(50)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(Color.clear)
        .animation(UnisonAnimations.state.reduceMotion(reduceMotion), value: vm.isHidden)
        .animation(UnisonAnimations.glassAppear.reduceMotion(reduceMotion), value: vm.showStopConfirmation)
        .animation(UnisonAnimations.glassAppear.reduceMotion(reduceMotion), value: isSettingsOpen)
    }

    // MARK: - Bubbles

    private var bubbles: some View {
        // 1 s tick so the recency window re-evaluates during silence —
        // bubbles cross the 30 s boundary and dissolve on the clock, not
        // only when new content arrives. The dissolve itself is the
        // existing removal transition in `BubbleGroupView`; the
        // `.animation(value:)` just opens an animated transaction when
        // the visible set changes.
        TimelineView(.periodic(from: .now, by: Self.windowTickInterval)) { context in
            let groups = vm.visibleBubbleGroups(at: context.date)
            BubbleGroupView(
                groups: groups,
                scale: vm.bubbleScale,
                isTestMode: vm.isTestMode
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.default, value: groups.flatMap { $0.bubbles.map(\.id) })
        }
    }

    // MARK: - Pill + popover

    private var controlPillWithPopover: some View {
        // Retained as a layout passthrough. The pill and settings popover
        // moved to live `.liquidGlassLive` (AppKit NSGlassEffectView), so
        // there's no SwiftUI `.glassEffect` pass left for this container to
        // merge — pill and popover no longer visually merge.
        GlassEffectContainer {
            VStack(spacing: 12) {
                if isSettingsOpen {
                    TranscriptSettingsPopover(
                        sizeIndex: Binding(
                            get: { vm.sizeIndex },
                            set: { vm.updateSizeIndex($0) }
                        ),
                        volume: Binding(
                            get: { Double(vm.originalVolume) / 100.0 },
                            set: { vm.updateOriginalVolume(Int(($0 * 100).rounded())) }
                        )
                    )
                    .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                    .zIndex(20)
                }
                controlPill
            }
        }
    }

    private var controlPill: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            ControlPill(
                isActive: vm.elapsedSeconds > 0
                    || (vm.orchestrator?.state.isActive ?? false),
                elapsedLabel: vm.elapsedSecondsString,
                isHidden: vm.isHidden,
                isSettingsOpen: isSettingsOpen,
                isTestMode: vm.isTestMode,
                dotState: vm.pillDotState,
                statusText: vm.pillStatusText,
                onToggleSettings: { isSettingsOpen.toggle() },
                onToggleHidden: { vm.toggleHidden() },
                onStop: { vm.requestStop() }
            )
        }
    }

    // MARK: - Stop modal

    private var stopModal: some View {
        // No backdrop dim — the host panel is transparent, a full-window
        // dim would just render as a stray dark rectangle. Invisible
        // click-catcher under the card keeps "tap outside to cancel".
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { vm.cancelStop() }

            VStack(alignment: .leading, spacing: 0) {
                Text("Остановить перевод?")
                    .font(.system(size: 16, weight: .medium))
                    .tracking(-0.24)
                    .foregroundStyle(.primary)
                Text("Сессия будет закрыта и транскрипт исчезнет.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .padding(.top, 6)
                HStack(spacing: 8) {
                    Spacer()
                    Button(action: { vm.cancelStop() }) {
                        Text("Отмена")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .keyboardShortcut(.cancelAction)

                    Button(action: { vm.confirmStop() }) {
                        Text("Остановить")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Color(red: 220 / 255, green: 60 / 255, blue: 90 / 255))
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 18)
            }
            .padding(22)
            .frame(width: 340)
            .liquidGlassLive(cornerRadius: 18)
        }
    }
}
