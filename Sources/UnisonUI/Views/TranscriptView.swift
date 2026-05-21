import SwiftUI
import UnisonDomain

/// Floating transcript window — bubbles stacked above a control pill.
///
/// Strictly mirrors `design/transcript-final/index.html`:
/// - bottom-centered floating panel (positioning handled by the host
///   `TranscriptWindowController`);
/// - `BubbleGroupView` stacks up to three groups; the fourth fades up;
/// - `ControlPill` with status dot, mono `mm:ss` timer, gear, hide/show
///   toggle, and stop button;
/// - `TranscriptSettingsPopover` anchored above the pill, sliding from
///   below with a small scale/opacity transition;
/// - a custom destructive `Остановить перевод?` modal rendered inside the
///   panel as an overlay so the SwiftUI design tokens match the spec.
///
/// The view itself is transparent — the host panel uses
/// `backgroundColor = .clear` so only the glass surfaces are drawn.
public struct TranscriptView: View {
    @Bindable var vm: TranscriptViewModel

    public init(vm: TranscriptViewModel) {
        self.vm = vm
    }

    @SwiftUI.State private var isSettingsOpen: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        ZStack {
            // Per Apple's Liquid Glass guidance ("Adopting Liquid Glass"):
            //   "Optimize for legibility when content scrolls beneath
            //    controls. Scroll views offer a scroll edge effect that
            //    helps maintain sufficient legibility and contrast for
            //    controls by obscuring content that scrolls beneath them."
            //
            // The bubbles live inside a ScrollView with `.scrollEdgeEffectStyle(.soft, for: .all)`
            // so the top/bottom edges fade as bubbles scroll past the pill.
            // The pill itself is pinned via `.safeAreaBar(edge: .bottom)`,
            // which keeps it in view without overlapping the content.
            ScrollView {
                if !vm.isHidden {
                    bubbles
                        .transition(.opacity)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                }
            }
            .scrollIndicators(.hidden)
            // Keep the most recent bubbles pinned near the pill — the
            // transcript reads bottom-up, with older entries scrolling
            // off the top under the soft scroll-edge effect.
            .defaultScrollAnchor(.bottom)
            .scrollEdgeEffectStyle(.soft, for: .all)
            .safeAreaBar(edge: .bottom) {
                controlPillWithPopover
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 22)
                    .padding(.horizontal, 8)
            }

            if vm.showStopConfirmation {
                stopModal
                    .transition(.opacity)
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
        BubbleGroupView(groups: vm.bubbleGroups, scale: vm.bubbleScale)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pill + popover

    private var controlPillWithPopover: some View {
        // The pill is centered; the popover is anchored above it, aligned
        // to the pill's leading edge — matching the CSS `bottom: 100%;
        // left: 0;` rule in the HTML mock.
        //
        // Per Apple's Liquid Glass guidance, multiple adjacent glass
        // surfaces should be wrapped in a `GlassEffectContainer` for
        // best rendering performance. The pill (capsule glass) and
        // settings popover (rounded-rectangle glass) are visible at the
        // same time when the gear is open, so we container them.
        GlassEffectContainer {
            ZStack(alignment: .bottomLeading) {
                controlPill
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: PillFrameKey.self,
                                value: proxy.frame(in: .local)
                            )
                        }
                    )
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
                    .alignmentGuide(.bottom) { d in d[.top] + 12 }
                    .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                    .zIndex(20)
                }
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
                onToggleSettings: { isSettingsOpen.toggle() },
                onToggleHidden: { vm.toggleHidden() },
                onStop: { vm.requestStop() }
            )
        }
    }

    // MARK: - Stop modal

    private var stopModal: some View {
        ZStack {
            // Backdrop — dimmed blur per `.modal-backdrop`.
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { vm.cancelStop() }

            VStack(alignment: .leading, spacing: 0) {
                // HIG Materials: vibrant `.primary` for the modal title
                // and `.secondary` for the supporting paragraph on top
                // of the `.liquidGlass` modal surface.
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
            .liquidGlass(cornerRadius: 18)
            // Reduce Motion skips the scale + offset entrance — the
            // modal still fades in via the outer `.transition(.opacity)`
            // on the ZStack.
            .scaleEffect(reduceMotion ? 1.0 : (vm.showStopConfirmation ? 1.0 : 0.92))
            .offset(y: reduceMotion ? 0 : (vm.showStopConfirmation ? 0 : 8))
        }
    }
}

// MARK: - PreferenceKey

private struct PillFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
