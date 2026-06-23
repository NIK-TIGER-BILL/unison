import AppKit
import SwiftUI
import UnisonAudio
import UnisonDomain

/// Settings section for choosing what the Process Tap translates: either
/// everything except the listed apps (`.allExcept`) or only the listed apps
/// (`.onlySelected`). The mode segmented control sits above a single app
/// list bound to the active mode's selection.
public struct AppScopeSection: View {
    @Binding public var mode: TapScopeMode
    @Binding public var bundleIDs: [String]
    @State private var showingPicker = false

    public init(mode: Binding<TapScopeMode>, bundleIDs: Binding<[String]>) {
        self._mode = mode
        self._bundleIDs = bundleIDs
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $mode) {
                Text("Всё, кроме выбранных").tag(TapScopeMode.allExcept)
                Text("Только выбранные").tag(TapScopeMode.onlySelected)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(mode == .onlySelected ? "Переводить звук только из:" : "Не переводить звук из:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if bundleIDs.isEmpty {
                Text(mode == .onlySelected
                     ? "Выберите приложения — остальное Unison не трогает"
                     : "Музыкальные плееры и другое — Unison будет их пропускать")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                ForEach(bundleIDs, id: \.self) { bundleID in
                    HStack {
                        appIcon(for: bundleID)
                            .frame(width: 18, height: 18)
                        Text(appDisplayName(for: bundleID))
                        Spacer()
                        Button {
                            bundleIDs.removeAll { $0 == bundleID }
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
            AppScopePicker(
                already: Set(bundleIDs),
                onSelect: { bundleID in
                    if !bundleIDs.contains(bundleID) {
                        bundleIDs.append(bundleID)
                    }
                    showingPicker = false
                },
                onCancel: { showingPicker = false }
            )
        }
    }

    @ViewBuilder
    private func appIcon(for bundleID: String) -> some View {
        if let icon = resolvedIcon(for: bundleID) {
            Image(nsImage: icon)
                .resizable()
        } else {
            Image(systemName: "app")
                .foregroundStyle(.secondary)
        }
    }

    private func resolvedIcon(for bundleID: String) -> NSImage? {
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first?.icon {
            return running
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    private func appDisplayName(for bundleID: String) -> String {
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first?.localizedName {
            return running
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return InstalledAppsRegistry.displayName(atPath: url.path)
        }
        return bundleID
    }
}
