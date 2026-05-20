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

    public var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 10) {
                Spacer(minLength: 0)
                if !vm.isHidden {
                    bubbles
                        .transition(.opacity)
                }
                controlPillWithPopover
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.bottom, 22)
            .padding(.horizontal, 8)

            if vm.showStopConfirmation {
                stopModal
                    .transition(.opacity)
                    .zIndex(50)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(Color.clear)
        .animation(UnisonAnimations.state, value: vm.isHidden)
        .animation(UnisonAnimations.glassAppear, value: vm.showStopConfirmation)
        .animation(UnisonAnimations.glassAppear, value: isSettingsOpen)
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
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                .zIndex(20)
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
                Text("Остановить перевод?")
                    .font(.system(size: 16, weight: .medium))
                    .tracking(-0.24)
                    .foregroundStyle(.white)
                Text("Сессия будет закрыта и транскрипт исчезнет.")
                    .font(.system(size: 13))
                    .foregroundStyle(UnisonColors.whiteAlpha(0.65))
                    .lineSpacing(2)
                    .padding(.top, 6)
                HStack(spacing: 8) {
                    Spacer()
                    Button(action: { vm.cancelStop() }) {
                        Text("Отмена")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(UnisonColors.whiteAlpha(0.85))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(UnisonColors.whiteAlpha(0.08))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .strokeBorder(UnisonColors.whiteAlpha(0.12), lineWidth: 0.5)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)

                    Button(action: { vm.confirmStop() }) {
                        Text("Остановить")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color(red: 255 / 255, green: 110 / 255, blue: 130 / 255).opacity(0.55),
                                                Color(red: 220 / 255, green: 60 / 255, blue: 90 / 255).opacity(0.40),
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .strokeBorder(
                                                Color(red: 255 / 255, green: 110 / 255, blue: 130 / 255).opacity(0.45),
                                                lineWidth: 0.5
                                            )
                                    )
                                    .shadow(color: Color(red: 220 / 255, green: 60 / 255, blue: 90 / 255).opacity(0.32), radius: 4, x: 0, y: 4)
                            )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 18)
            }
            .padding(22)
            .frame(width: 340)
            .liquidGlass(cornerRadius: 18)
            .scaleEffect(vm.showStopConfirmation ? 1.0 : 0.92)
            .offset(y: vm.showStopConfirmation ? 0 : 8)
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
