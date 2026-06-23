import Testing
import Foundation
@testable import UnisonAudio

@Test func installedApplications_isNonEmpty() {
    // /System/Applications is always populated on macOS, so the scan must
    // find at least the bundled system apps.
    #expect(!InstalledAppsRegistry.installedApplications().isEmpty)
}

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

@Test func installedApplications_includeAppleSystemApp() {
    // Unlike CoreAudio's audio-process list, this must surface apps that
    // have never made a sound — e.g. Apple's bundled system apps.
    let ids = Set(InstalledAppsRegistry.installedApplications().map(\.bundleID))
    #expect(ids.contains { $0.hasPrefix("com.apple.") })
}
