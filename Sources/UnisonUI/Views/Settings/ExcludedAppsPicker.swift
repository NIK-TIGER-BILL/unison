import AppKit
import SwiftUI
import UnisonAudio

/// Modal sheet for picking an app to add to the exclusion list.
///
/// Lists every installed application (via `InstalledAppsRegistry`), unioned
/// with anything currently producing audio (via `AudioProcessRegistry`) so
/// apps installed in non-standard locations are still reachable. Apps making
/// sound right now are surfaced to the top with a speaker badge. The
/// exclusion is stored as a bundle ID and resolved to a live audio object
/// only when the tap starts, so picking a not-running app is valid.
struct ExcludedAppsPicker: View {
    let already: Set<String>
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @State private var apps: [AppItem] = []
    @State private var query = ""
    @State private var loaded = false

    private struct AppItem: Identifiable, Hashable {
        let bundleID: String
        let name: String
        let path: String?
        let isProducingAudio: Bool
        var id: String { bundleID }
    }

    private var filtered: [AppItem] {
        let available = apps.filter { !already.contains($0.bundleID) }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return available }
        return available.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.bundleID.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Добавить приложение")
                    .font(.headline)
                Spacer()
                Button("Отмена", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }

            SearchField(text: $query)

            if !loaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                Text(query.isEmpty ? "Приложения не найдены" : "Ничего не найдено")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { app in
                    Button {
                        onSelect(app.bundleID)
                    } label: {
                        HStack {
                            icon(for: app)
                                .frame(width: 20, height: 20)
                            VStack(alignment: .leading) {
                                Text(app.name)
                                Text(app.bundleID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if app.isProducingAudio {
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
        .frame(width: 380, height: 460)
        .onAppear(perform: loadIfNeeded)
    }

    /// Builds the candidate list once: all installed apps, with the
    /// audio-active set merged in for badges, top-sorting, and to cover apps
    /// running from non-standard locations.
    private func loadIfNeeded() {
        guard !loaded else { return }

        var byID: [String: AppItem] = [:]
        for app in InstalledAppsRegistry.installedApplications() {
            byID[app.bundleID] = AppItem(
                bundleID: app.bundleID, name: app.name,
                path: app.path, isProducingAudio: false
            )
        }
        for proc in AudioProcessRegistry.runningAudioProcesses() {
            if let existing = byID[proc.bundleID] {
                byID[proc.bundleID] = AppItem(
                    bundleID: existing.bundleID, name: existing.name,
                    path: existing.path ?? proc.bundlePath,
                    isProducingAudio: existing.isProducingAudio || proc.isProducingAudio
                )
            } else {
                byID[proc.bundleID] = AppItem(
                    bundleID: proc.bundleID, name: proc.name,
                    path: proc.bundlePath, isProducingAudio: proc.isProducingAudio
                )
            }
        }

        apps = byID.values.sorted { a, b in
            if a.isProducingAudio != b.isProducingAudio {
                return a.isProducingAudio   // currently-playing apps first
            }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }
        loaded = true
    }

    @ViewBuilder
    private func icon(for app: AppItem) -> some View {
        if let path = app.path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
        } else {
            Image(systemName: "app")
                .foregroundStyle(.secondary)
        }
    }
}
