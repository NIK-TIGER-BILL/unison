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
                    name: displayName(for: url, fm: fm),
                    path: url.path
                )
            }
        }

        return byBundleID.values.sorted {
            $0.name.localizedCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Private helpers

    private struct Source { let url: URL; let recurse: Bool }

    /// Standard locations holding user-launchable apps. `/Applications` and
    /// `~/Applications` are scanned one level deep so apps that vendors nest
    /// in a subfolder (e.g. Adobe suites) are still found.
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

    /// Finder-localized display name, with the `.app` extension stripped if
    /// the user has "show all extensions" enabled.
    private static func displayName(for url: URL, fm: FileManager) -> String {
        let raw = fm.displayName(atPath: url.path)
        if raw.hasSuffix(".app") { return String(raw.dropLast(4)) }
        return raw.isEmpty ? url.deletingPathExtension().lastPathComponent : raw
    }
}
