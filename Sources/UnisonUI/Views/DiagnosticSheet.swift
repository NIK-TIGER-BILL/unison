import SwiftUI

/// Modal diagnostic dialog. Renders a snapshot of `DiagnosticInfo` with
/// a "Скопировать в буфер" button so the user can paste the full dump
/// into a bug report.
///
/// Hosted by `DiagnosticWindowController` (in `UnisonApp`) which feeds
/// `info` from a `DiagnosticCollector` and bridges the close callback
/// to the `NSWindow`'s `orderOut(_:)`.
public struct DiagnosticSheet: View {
    public let info: DiagnosticInfo
    public let onCopy: () -> Void
    public let onClose: () -> Void

    /// Briefly flipped to true when the user taps the copy button so the
    /// label flashes "Скопировано" before reverting.
    @SwiftUI.State private var didCopy = false

    public init(
        info: DiagnosticInfo,
        onCopy: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.info = info
        self.onCopy = onCopy
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    section(title: "Система", lines: info.systemLines)
                    section(title: "Состояние", lines: info.statusLines)
                    if !info.recentErrors.isEmpty {
                        section(title: "Последние ошибки", lines: info.recentErrors)
                    }
                    logsSection
                }
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            footer
        }
        .padding(20)
        .frame(width: 600, height: 600)
        .liquidGlass(cornerRadius: 18)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "stethoscope")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
            Text("Диагностика")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button("Закрыть", action: onClose)
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
        }
    }

    private func section(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(UnisonColors.whiteAlpha(0.80))
            VStack(alignment: .leading, spacing: 3) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.18))
            )
        }
    }

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Логи (последние 60 с)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(UnisonColors.whiteAlpha(0.80))
            VStack(alignment: .leading, spacing: 2) {
                if info.recentLogLines.isEmpty {
                    Text("(нет записей)")
                        .font(.system(size: 11))
                        .foregroundStyle(UnisonColors.whiteAlpha(0.50))
                } else {
                    ForEach(Array(info.recentLogLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.92))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.22))
            )
        }
    }

    private var footer: some View {
        HStack {
            Text("Не содержит вашего ключа — только наличие и длину.")
                .font(.caption)
                .foregroundStyle(UnisonColors.whiteAlpha(0.55))
            Spacer()
            Button(action: {
                onCopy()
                didCopy = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    didCopy = false
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                    Text(didCopy ? "Скопировано" : "Скопировать в буфер")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut("c", modifiers: [.command])
        }
    }
}

