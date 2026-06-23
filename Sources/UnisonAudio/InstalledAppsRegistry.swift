import AppKit
import Foundation

/// One installed application discoverable on disk — the candidate set for
/// the exclusion picker. Unlike `AudioProcess`, this does not require the
/// app to be running or to have produced audio; the Process Tap resolves
/// a stored bundle ID to a live audio object only when it actually starts
/// (see `ProcessTapCapture.resolveExcludedProcessObjects`).
public struct InstalledApp: Sendable, Identifiable, Hashable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let path: String

    public init(bundleID: String, name: String, path: String) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
    }
}

/// A selectable entry for the exclusion picker: an installed (or currently
/// audio-active) app annotated with whether it is producing audio right now.
/// This is the merge of `InstalledApp` (everything on disk) and
/// `AudioProcess` (everything CoreAudio currently sees).
public struct ExcludableApp: Sendable, Identifiable, Hashable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let bundlePath: String?
    public let isProducingAudio: Bool

    public init(bundleID: String, name: String, bundlePath: String?, isProducingAudio: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.bundlePath = bundlePath
        self.isProducingAudio = isProducingAudio
    }
}

/// Enumerates the applications a user could plausibly want to exclude.
///
/// CoreAudio only knows about apps that have *produced audio this session*
/// (`AudioProcessRegistry`), which is too narrow for proactively excluding
/// something like a music player before it makes a sound. This scans the
/// standard macOS application locations so any installed app — running or
/// not, silent or not — can be picked.
public enum InstalledAppsRegistry {
    /// All installed applications, deduplicated by bundle ID and sorted by
    /// display name. Empty only if none of the standard directories are
    /// readable (e.g. a sandbox without file access).
    public static func installedApplications() -> [InstalledApp] {
        let fm = FileManager.default
        var byBundleID: [String: InstalledApp] = [:]

        for source in searchSources(fm: fm) {
            for url in appBundles(in: source.url, recurseOneLevel: source.recurse, fm: fm) {
                guard let bundle = Bundle(url: url),
                      let bundleID = bundle.bundleIdentifier,
                      !bundleID.isEmpty else { continue }
                // First occurrence wins; user/standard dirs are visited
                // before system ones so a user-installed copy is preferred.
                guard byBundleID[bundleID] == nil else { continue }
                byBundleID[bundleID] = InstalledApp(
                    bundleID: bundleID,
                    name: displayName(atPath: url.path),
                    path: url.path
                )
            }
        }

        return byBundleID.values.sorted {
            $0.name.localizedCompare($1.name) == .orderedAscending
        }
    }

    /// The full exclusion-picker candidate list: every installed app, with
    /// anything currently producing audio merged in (so apps running from a
    /// non-standard location are still reachable). Does disk + CoreAudio I/O;
    /// call off the main thread.
    public static func excludableApps() -> [ExcludableApp] {
        excludableApps(
            installed: installedApplications(),
            audioActive: AudioProcessRegistry.runningAudioProcesses()
        )
    }

    /// Pure merge of installed apps and audio-active processes, keyed by
    /// bundle ID. An app present in both keeps its installed name/path while
    /// inheriting the "producing audio" flag; an audio-active app with no
    /// installed match is still included. Sorted audio-active-first, then by
    /// name. Separated from I/O so the merge can be unit-tested.
    public static func excludableApps(
        installed: [InstalledApp],
        audioActive: [AudioProcess]
    ) -> [ExcludableApp] {
        var byID: [String: ExcludableApp] = [:]
        for app in installed {
            byID[app.bundleID] = ExcludableApp(
                bundleID: app.bundleID, name: app.name,
                bundlePath: app.path, isProducingAudio: false
            )
        }
        for proc in audioActive {
            if let existing = byID[proc.bundleID] {
                byID[proc.bundleID] = ExcludableApp(
                    bundleID: existing.bundleID, name: existing.name,
                    bundlePath: existing.bundlePath ?? proc.bundlePath,
                    isProducingAudio: existing.isProducingAudio || proc.isProducingAudio
                )
            } else {
                byID[proc.bundleID] = ExcludableApp(
                    bundleID: proc.bundleID, name: proc.name,
                    bundlePath: proc.bundlePath, isProducingAudio: proc.isProducingAudio
                )
            }
        }
        return byID.values.sorted { a, b in
            if a.isProducingAudio != b.isProducingAudio {
                return a.isProducingAudio   // currently-playing apps first
            }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }
    }

    /// Finder-localized display name for the app bundle at `path`, with the
    /// `.app` extension stripped (it is present when the user enables "show
    /// all filename extensions"). Shared by the picker and the excluded-apps
    /// list so their naming can't drift.
    public static func displayName(atPath path: String) -> String {
        let raw = FileManager.default.displayName(atPath: path)
        let stripped = raw.hasSuffix(".app") ? String(raw.dropLast(4)) : raw
        return stripped.isEmpty
            ? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            : stripped
    }

    // MARK: - Private helpers

    private struct Source { let url: URL; let recurse: Bool }

    /// Standard locations holding user-launchable apps. `/Applications` and
    /// `~/Applications` are scanned one level deep so apps that vendors nest
    /// in a subfolder (e.g. Adobe suites) are still found — that recursion
    /// also covers their `Utilities` subfolders, so those aren't listed
    /// separately the way the system ones are.
    private static func searchSources(fm: FileManager) -> [Source] {
        var sources = [
            Source(url: URL(fileURLWithPath: "/Applications", isDirectory: true), recurse: true),
            Source(url: URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true), recurse: false),
            Source(url: URL(fileURLWithPath: "/System/Applications", isDirectory: true), recurse: false),
            Source(url: URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true), recurse: false),
        ]
        if let userApps = fm.urls(for: .applicationDirectory, in: .userDomainMask).first {
            sources.append(Source(url: userApps, recurse: true))
        }
        return sources
    }

    private static func appBundles(in dir: URL, recurseOneLevel: Bool, fm: FileManager) -> [URL] {
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var apps: [URL] = []
        for url in entries {
            if url.pathExtension == "app" {
                apps.append(url)
            } else if recurseOneLevel,
                      (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if let nested = try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    apps.append(contentsOf: nested.filter { $0.pathExtension == "app" })
                }
            }
        }
        return apps
    }
}
