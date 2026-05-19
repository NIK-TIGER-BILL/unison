import SwiftUI
import UnisonDomain

public struct TranscriptView: View {
    @Bindable var vm: TranscriptViewModel

    public init(vm: TranscriptViewModel) {
        self.vm = vm
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(vm.entries) { entry in
                    entryRow(entry)
                }
            }
            .padding(12)
        }
        .frame(width: 400, height: 480)
    }

    @ViewBuilder
    private func entryRow(_ entry: TranscriptEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.speaker == .me ? "Я" : "Собеседник")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let original = entry.originalText {
                Text(original)
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
            Text(entry.translatedText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
    }
}
