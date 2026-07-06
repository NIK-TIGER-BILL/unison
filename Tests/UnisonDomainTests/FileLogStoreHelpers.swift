import Foundation
@testable import UnisonDomain

// Helpers for `FileLogStoreTests`. Lives in a file that does NOT
// `import Testing` so the missing `_Testing_Foundation` cross-import
// overlay (Command Line Tools-only setups) is not triggered.

/// Build a fresh `FileLogStore` rooted at a unique temp dir per test.
/// The shared singleton is anchored at `~/Library/Logs/Unison` and we
/// don't want tests polluting the user's real logs.
func makeTempStore(maxFileBytes: Int = 2 * 1024 * 1024, maxFiles: Int = 5) -> FileLogStore {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("FileLogStoreTests-\(UUID().uuidString)", isDirectory: true)
    return FileLogStore(directory: dir, maxFileBytes: maxFileBytes, maxFiles: maxFiles)
}

/// Inspect filesystem for log files in the store's directory.
func logFileNames(in store: FileLogStore) -> [String] {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []
    return files.filter { $0.hasPrefix("unison") && $0.hasSuffix(".log") }
}

/// Check if a specific archive file exists.
func archiveFileExists(in store: FileLogStore, slot: Int) -> Bool {
    let url = store.directory.appendingPathComponent("unison.\(slot).log")
    return FileManager.default.fileExists(atPath: url.path)
}

/// String repeated `count` times. `String(repeating:count:)` is a
/// Foundation extension on `String` so we route through this helper
/// to keep the test file Foundation-free.
func repeated(_ char: String, _ count: Int) -> String {
    String(repeating: char, count: count)
}

/// Sentinel string for the shared-singleton probe test.
func makeSentinel() -> String {
    "FileLogStoreTests-sentinel-\(UUID().uuidString)"
}

/// Delete the live log file out from under the store — models a user (or
/// a cleaner) removing `unison.log` while the app runs. Lives here (not in
/// the test file) because the test file avoids `import Foundation` — see
/// the header note about the `_Testing_Foundation` overlay.
func deleteCurrentLogFile(of store: FileLogStore) throws {
    try FileManager.default.removeItem(at: store.currentFileURL)
}
