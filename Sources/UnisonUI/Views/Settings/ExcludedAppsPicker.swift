import AppKit
import SwiftUI
import UnisonAudio

/// Modal sheet for picking an audio-producing app to add to the
/// exclusion list. Shows all CoreAudio Audio Process Objects (apps that
/// have produced audio at least once during this session).
struct ExcludedAppsPicker: View {
    let already: Set<String>
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @State private var processes: [AudioProcess] = []

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Добавить приложение")
                    .font(.headline)
                Spacer()
                Button("Отмена", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 8)

            if processes.isEmpty {
                Text("Нет запущенных аудио-приложений")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(processes.filter { !already.contains($0.bundleID) }) { process in
                    Button {
                        onSelect(process.bundleID)
                    } label: {
                        HStack {
                            icon(for: process)
                                .frame(width: 20, height: 20)
                            VStack(alignment: .leading) {
                                Text(process.name)
                                Text(process.bundleID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if process.isProducingAudio {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .frame(width: 360, height: 360)
        .onAppear {
            processes = AudioProcessRegistry.runningAudioProcesses()
        }
    }

    @ViewBuilder
    private func icon(for process: AudioProcess) -> some View {
        if let path = process.bundlePath {
            let nsIcon = NSWorkspace.shared.icon(forFile: path)
            Image(nsImage: nsIcon)
                .resizable()
        } else {
            Image(systemName: "app")
                .foregroundStyle(.secondary)
        }
    }
}
