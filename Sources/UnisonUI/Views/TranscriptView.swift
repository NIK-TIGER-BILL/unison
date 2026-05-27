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
            // Bottom anchor — transcript reads bottom-up, older
            // entries fade off the top under the soft edge effect.
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
        BubbleGroupView(
            groups: vm.bubbleGroups,
            scale: vm.bubbleScale,
            isTestMode: vm.isTestMode
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Pill + popover

    private var controlPillWithPopover: some View {
        // `GlassEffectContainer` groups the pill + settings popover
        // into one rendering pass when both are on screen — per
        // Apple's Liquid Glass guidance.
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
            .liquidGlass(cornerRadius: 18)
            // Reduce Motion skips the entrance scale/offset — the
            // modal still fades in via the outer `.transition(.opacity)`.
            .scaleEffect(reduceMotion ? 1.0 : (vm.showStopConfirmation ? 1.0 : 0.92))
            .offset(y: reduceMotion ? 0 : (vm.showStopConfirmation ? 0 : 8))
        }
    }
}
