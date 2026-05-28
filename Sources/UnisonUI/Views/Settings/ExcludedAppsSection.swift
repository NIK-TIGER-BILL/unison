import AppKit
import SwiftUI
import UnisonAudio
import UnisonDomain

/// Settings section for managing the list of bundle IDs the Process Tap
/// will exclude from translation. Default empty; user can add running
/// audio apps via a picker sheet.
public struct ExcludedAppsSection: View {
    @Binding public var excludedBundleIDs: [String]
    @State private var showingPicker = false

    public init(excludedBundleIDs: Binding<[String]>) {
        self._excludedBundleIDs = excludedBundleIDs
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Не переводить звук из:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if excludedBundleIDs.isEmpty {
                Text("Музыкальные плееры и другое — Unison будет их пропускать")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                ForEach(excludedBundleIDs, id: \.self) { bundleID in
                    HStack {
                        appIcon(for: bundleID)
                            .frame(width: 18, height: 18)
                        Text(appDisplayName(for: bundleID))
                        Spacer()
                        Button {
                            excludedBundleIDs.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "xmark")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }

            Button("+ Добавить") {
                showingPicker = true
            }
            .buttonStyle(.link)
        }
        .sheet(isPresented: $showingPicker) {
            ExcludedAppsPicker(
                already: Set(excludedBundleIDs),
                onSelect: { bundleID in
                    if !excludedBundleIDs.contains(bundleID) {
                        excludedBundleIDs.append(bundleID)
                    }
                    showingPicker = false
                },
                onCancel: { showingPicker = false }
            )
        }
    }

    @ViewBuilder
    private func appIcon(for bundleID: String) -> some View {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = app.icon {
            Image(nsImage: icon)
                .resizable()
        } else {
            Image(systemName: "app")
                .foregroundStyle(.secondary)
        }
    }

    private func appDisplayName(for bundleID: String) -> String {
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        return app?.localizedName ?? bundleID
    }
}
