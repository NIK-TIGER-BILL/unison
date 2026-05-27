import SwiftUI

/// "Как пользоваться" — explains the audio routing diagram and the
/// Zoom / Meet setup steps. Same chromeless glass-card design as
/// `SettingsView`.
public struct HelpView: View {
    public init() {}

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                flowDiagramSection
                zoomSetupSection
                launchSection
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .scrollEdgeEffectStyle(.hard, for: .top)
        .frame(minWidth: HelpLayout.windowWidth, minHeight: HelpLayout.minWindowHeight)
    }

    // MARK: - Sections

    private var flowDiagramSection: some View {
        card(title: "Поток звука") {
            VStack(alignment: .leading, spacing: 12) {
                // Outgoing: real mic → Unison → BlackHole 2ch → Zoom mic.
                HStack(spacing: 6) {
                    flowItem(icon: "mic.fill", label: "Ваш\nмикрофон")
                    flowArrow
                    flowItem(icon: "waveform.path.ecg", label: "Unison\nперевод")
                    flowArrow
                    flowItem(icon: "speaker.wave.2.fill", label: "BlackHole\n2ch")
                    flowArrow
                    flowItem(icon: "phone.fill", label: "Zoom\nmic")
                }
                // Incoming: Zoom audio → Process Tap → Unison → headphones.
                HStack(spacing: 6) {
                    flowItem(icon: "phone.fill", label: "Zoom\naudio")
                    flowArrow
                    flowItem(icon: "waveform.path.ecg", label: "Unison\nперевод")
                    flowArrow
                    flowItem(icon: "speaker.wave.3.fill", label: "Ваши\nнаушники")
                }
            }
        }
    }

    private var zoomSetupSection: some View {
        card(title: "Настройка Zoom / Meet") {
            VStack(alignment: .leading, spacing: 8) {
                stepRow(index: 1, text: "Откройте настройки звука в Zoom (или Google Meet, Discord и т. д.)")
                stepRow(index: 2, text: "Микрофон → BlackHole 2ch")
            }
        }
    }

    private var launchSection: some View {
        card(title: "Запуск") {
            VStack(alignment: .leading, spacing: 8) {
                stepRow(index: 1, text: "В настройках выберите ваш реальный микрофон и динамик")
                stepRow(index: 2, text: "В меню выберите нужные языки")
                stepRow(index: 3, text: "Нажмите «Начать перевод»")
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func card<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(UnisonColors.whiteAlpha(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(UnisonColors.whiteAlpha(0.08), lineWidth: 0.5)
            )
        }
    }

    private func flowItem(icon: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var flowArrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
    }

    private func stepRow(index: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private enum HelpLayout {
    static let windowWidth: CGFloat = 560
    static let minWindowHeight: CGFloat = 380
}
