import AppKit
import SwiftUI
import UnisonAudio

/// Modal sheet for picking an app to add to the exclusion list.
///
/// Lists every installed application (via `InstalledAppsRegistry`), unioned
/// with anything currently producing audio so apps installed in non-standard
/// locations are still reachable. Apps making sound right now are surfaced to
/// the top with a speaker badge. The exclusion is stored as a bundle ID and
/// resolved to a live audio object only when the tap starts, so picking a
/// not-running app is valid.
struct ExcludedAppsPicker: View {
    let already: Set<String>
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @State private var apps: [ExcludableApp] = []
    @State private var query = ""
    @State private var loaded = false
    @FocusState private var searchFocused: Bool

    private var filtered: [ExcludableApp] {
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

            searchField

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
                        row(for: app)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .frame(width: 380, height: 460)
        .task { await loadIfNeeded() }
    }

    // A self-drawn search field rather than the shared `SearchField`: that
    // component's underline is tuned for dark liquid-glass dropdowns, whereas
    // this sheet follows the (possibly light) system appearance. `.quaternary`
    // and `.secondary` are adaptive, so the field stays visible either way.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Найти…", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func row(for app: ExcludableApp) -> some View {
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

    /// Builds the candidate list once, off the main thread — the disk scan
    /// plus CoreAudio enumeration is too heavy to run while the sheet is
    /// animating in. The `ProgressView` covers the brief gather.
    private func loadIfNeeded() async {
        guard !loaded else { return }
        searchFocused = true
        let result = await Task.detached(priority: .userInitiated) {
            InstalledAppsRegistry.excludableApps()
        }.value
        apps = result
        loaded = true
    }

    @ViewBuilder
    private func icon(for app: ExcludableApp) -> some View {
        if let path = app.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
        } else {
            Image(systemName: "app")
                .foregroundStyle(.secondary)
        }
    }
}
