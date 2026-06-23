import Testing
import Foundation
@testable import UnisonAudio

// MARK: - installedApplications (disk scan)
//
// These assert only *shape* invariants that also hold vacuously on an empty
// result — the scan's contract explicitly allows empty (a sandbox without
// file access), so we never hard-require a populated environment here.

@Test func installedApplications_sortedByName() {
    let names = InstalledAppsRegistry.installedApplications().map(\.name)
    let sorted = names.sorted { $0.localizedCompare($1) == .orderedAscending }
    #expect(names == sorted)
}

@Test func installedApplications_deduplicatedByBundleID() {
    let ids = InstalledAppsRegistry.installedApplications().map(\.bundleID)
    #expect(Set(ids).count == ids.count)
}

@Test func installedApplications_haveResolvedMetadata() {
    for app in InstalledAppsRegistry.installedApplications() {
        #expect(!app.bundleID.isEmpty)
        #expect(!app.name.isEmpty)
        #expect(app.path.hasSuffix(".app"))
    }
}

/// Only asserts a populated result *when the environment can actually see
/// system apps* — probing `/System/Applications` directly first. This keeps
/// the meaningful "silent apps are surfaced" check without making the test
/// fail on a file-access-restricted builder.
@Test func installedApplications_findsSystemAppsWhenReadable() {
    let systemApps = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Applications"))?
        .filter { $0.hasSuffix(".app") } ?? []
    guard !systemApps.isEmpty else { return }   // no readable system apps → nothing to assert

    let result = InstalledAppsRegistry.installedApplications()
    #expect(!result.isEmpty)
    // Apple's bundled apps have never produced audio, yet must be listed —
    // the whole point of scanning disk rather than CoreAudio.
    #expect(result.contains { $0.bundleID.hasPrefix("com.apple.") })
}

// MARK: - excludableApps (pure merge of installed + audio-active)

private func installed(_ id: String, _ name: String, _ path: String = "/Applications/X.app") -> InstalledApp {
    InstalledApp(bundleID: id, name: name, path: path)
}

private func audio(_ id: String, _ name: String, path: String? = nil, producing: Bool) -> AudioProcess {
    AudioProcess(pid: 1, bundleID: id, name: name, bundlePath: path, isProducingAudio: producing)
}

@Test func excludableApps_marksInstalledAppProducingWhenAudioActive() {
    let merged = InstalledAppsRegistry.excludableApps(
        installed: [installed("com.a", "Alpha", "/Applications/Alpha.app")],
        audioActive: [audio("com.a", "Alpha", path: "/some/other/Alpha.app", producing: true)]
    )
    #expect(merged.count == 1)                                  // merged, not duplicated
    #expect(merged.first?.isProducingAudio == true)
    #expect(merged.first?.bundlePath == "/Applications/Alpha.app")  // installed path wins
}

@Test func excludableApps_includesAudioActiveAppNotOnDisk() {
    // An app running from a non-standard location won't be in the disk scan,
    // but must still be selectable.
    let merged = InstalledAppsRegistry.excludableApps(
        installed: [],
        audioActive: [audio("com.weird.location", "Weird", path: "/tmp/W.app", producing: true)]
    )
    #expect(merged.map(\.bundleID) == ["com.weird.location"])
    #expect(merged.first?.bundlePath == "/tmp/W.app")
}

@Test func excludableApps_sortsProducingFirstThenByName() {
    let merged = InstalledAppsRegistry.excludableApps(
        installed: [installed("com.b", "Beta"), installed("com.a", "Alpha"), installed("com.c", "Charlie")],
        audioActive: [audio("com.c", "Charlie", producing: true)]
    )
    // Charlie is producing audio → first; the rest fall back to alphabetical.
    #expect(merged.map(\.bundleID) == ["com.c", "com.a", "com.b"])
}

@Test func excludableApps_deduplicatesByBundleID() {
    let merged = InstalledAppsRegistry.excludableApps(
        installed: [installed("com.dup", "Dup"), installed("com.dup", "Dup")],
        audioActive: [audio("com.dup", "Dup", producing: false)]
    )
    #expect(merged.count == 1)
}

@Test func excludableApps_emptyInputsProduceEmptyOutput() {
    #expect(InstalledAppsRegistry.excludableApps(installed: [], audioActive: []).isEmpty)
}

// MARK: - displayName(atPath:)

@Test func displayName_stripsAppExtension() {
    // Finder display name hides the extension by default; when shown, we strip
    // it. A system app path exercises the real FileManager path.
    let name = InstalledAppsRegistry.displayName(atPath: "/System/Applications/Calculator.app")
    #expect(!name.hasSuffix(".app"))
    #expect(!name.isEmpty)
}
