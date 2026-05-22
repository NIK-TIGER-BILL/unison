import Foundation
@testable import UnisonSystem

// Helpers in this file deliberately avoid `import Testing` so the
// `_Testing_Foundation` cross-import overlay (missing from the
// Command Line Tools `Testing.framework` install) is not triggered
// when test files only import `Testing`. See the matching helpers in
// UnisonTranslationTests for the same pattern.

func makeAsset(name: String, url: String) -> GitHubRelease.Asset {
    GitHubRelease.Asset(
        name: name,
        browserDownloadURL: URL(string: url)!
    )
}

func makeReleaseJSON(assets: [(name: String, url: String)]) -> Data {
    let assetEntries = assets
        .map { #"{"name":"\#($0.name)","browser_download_url":"\#($0.url)"}"# }
        .joined(separator: ",")
    return #"{"assets":[\#(assetEntries)]}"#.data(using: .utf8)!
}

func makeHTTPResponse(url: URL, status: Int) -> URLResponse {
    HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    )!
}

func latestReleaseURL() -> URL {
    BundledBlackHoleInstaller.latestReleaseURL
}

/// `NSLock`-backed mutex so tests can capture values from inside
/// `@Sendable` closures without paying the cost of an actor or
/// `DispatchQueue`.
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// Builds an installer wired with fake closures. Kept in a
/// no-Testing helper so the `URL` / `URLResponse` types live outside
/// any `#expect(...)` macro context.
struct FakeInstallerConfig {
    var fetchData: BundledBlackHoleInstaller.DataFetcher
    var downloadFile: BundledBlackHoleInstaller.FileDownloader
    var runProcess: BundledBlackHoleInstaller.ProcessRunner
}

func makeFakeInstaller(_ config: FakeInstallerConfig) -> BundledBlackHoleInstaller {
    BundledBlackHoleInstaller(
        fetchData: config.fetchData,
        downloadFile: config.downloadFile,
        runProcess: config.runProcess
    )
}

/// Convenience JSON decoder that doesn't drag `Testing` into the
/// caller's file.
func decodeRelease(_ data: Data) throws -> GitHubRelease {
    try JSONDecoder().decode(GitHubRelease.self, from: data)
}

/// `URL` is a Foundation type. Returning it from a helper keeps it
/// out of the `Testing`-importing test file (otherwise the
/// `_Testing_Foundation` cross-import overlay would activate).
typealias FakeFetcher = BundledBlackHoleInstaller.DataFetcher
typealias FakeDownloader = BundledBlackHoleInstaller.FileDownloader
typealias FakeRunner = BundledBlackHoleInstaller.ProcessRunner

/// Touch-style helper: writes an empty file at the destination so
/// subsequent steps (signature check, install) see *something*
/// there. Used in `downloadFile` fakes.
func touchEmptyFile(at dest: URL) {
    FileManager.default.createFile(atPath: dest.path, contents: Data())
}

/// `(Data(), HTTPURLResponse(status))` tuple — convenience for fakes
/// that just want to signal "404, empty body".
func emptyResponse(url: URL, status: Int) -> (Data, URLResponse) {
    (Data(), makeHTTPResponse(url: url, status: status))
}

/// Convenience wrappers so the test file can build a fake without
/// touching `Data` directly. Each takes the response builder out of
/// the `Testing`-importing call site.
func makeFetcher(returning json: Data, status: Int = 200) -> FakeFetcher {
    return { url in (json, makeHTTPResponse(url: url, status: status)) }
}

func makeFetcher(returningStatus status: Int) -> FakeFetcher {
    return { url in (Data(), makeHTTPResponse(url: url, status: status)) }
}

func makeFetcher(throwing error: Error) -> FakeFetcher {
    return { _ in throw error }
}

/// A `downloadFile` fake that records each source URL (as string) and
/// touches an empty file at the destination.
func makeRecordingDownloader(into sink: Mutex<[String]>) -> FakeDownloader {
    return { src, dest in
        sink.withLock { $0.append(src.absoluteString) }
        touchEmptyFile(at: dest)
    }
}

/// A `downloadFile` fake that simply touches an empty file.
func makeNoOpDownloader() -> FakeDownloader {
    return { _, dest in touchEmptyFile(at: dest) }
}

/// A `downloadFile` fake that throws an error.
func makeThrowingDownloader(error: Error) -> FakeDownloader {
    return { _, _ in throw error }
}

/// A `downloadFile` fake that should never be invoked. Caller passes
/// in a sink that, on inspection, has remained empty.
func makeForbiddenDownloader(sink: Mutex<Bool>) -> FakeDownloader {
    return { _, _ in sink.withLock { $0 = true } }
}

/// A `runProcess` fake that always returns the given exit code.
func makeRunner(returningStatus status: Int32) -> FakeRunner {
    return { _, _ in status }
}

/// A `runProcess` fake that records each invocation as
/// `(executable, arguments)`. Returns `0` (success).
func makeRecordingRunner(into sink: Mutex<[(String, [String])]>) -> FakeRunner {
    return { executable, arguments in
        sink.withLock { $0.append((executable, arguments)) }
        return 0
    }
}

/// A `runProcess` fake whose exit code depends on the executable
/// path. Useful for tests that want `pkgutil` to succeed and
/// `osascript` to fail (or vice versa).
func makeStatusByExecutable(
    pkgutil: Int32,
    osascript: Int32,
    otherwise: Int32 = 0
) -> FakeRunner {
    return { executable, _ in
        if executable.hasSuffix("pkgutil") { return pkgutil }
        if executable.hasSuffix("osascript") { return osascript }
        return otherwise
    }
}

/// A `runProcess` fake that records whether it was invoked. Returns
/// `0` on each call.
func makeForbiddenRunner(sink: Mutex<Bool>) -> FakeRunner {
    return { _, _ in sink.withLock { $0 = true }; return 0 }
}
