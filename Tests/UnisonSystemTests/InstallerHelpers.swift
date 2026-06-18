import Foundation
@testable import UnisonSystem
@testable import UnisonDomain

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

func makeReleaseJSON(
    tag: String = "v0.6.1",
    assets: [(name: String, url: String)] = []
) -> Data {
    let assetEntries = assets
        .map { #"{"name":"\#($0.name)","browser_download_url":"\#($0.url)"}"# }
        .joined(separator: ",")
    return #"{"tag_name":"\#(tag)","assets":[\#(assetEntries)]}"#.data(using: .utf8)!
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

/// Canonical `pkgutil --check-signature` stdout for a correctly signed
/// BlackHole pkg. The installer pins the `Developer ID Installer:
/// Existential Audio Inc.` certificate-chain line — a 0 exit status
/// alone is NOT enough (any Apple Developer ID pkg exits 0).
let pkgutilSignedByExistentialAudio = """
Package "Unison-BlackHole2ch.pkg":
   Status: signed by a developer certificate issued by Apple for distribution
   Signed with a trusted timestamp on: 2024-09-30 21:14:33 +0000
   Certificate Chain:
    1. Developer ID Installer: Existential Audio Inc. (Q5C99V536K)
       Expires: 2027-02-01 22:12:15 +0000
"""

/// Same shape, valid Apple signature — but a different vendor. Must be
/// rejected by the signer pin even though pkgutil exits 0.
let pkgutilSignedByOtherVendor = """
Package "Unison-BlackHole2ch.pkg":
   Status: signed by a developer certificate issued by Apple for distribution
   Certificate Chain:
    1. Developer ID Installer: Acme Audio LLC (ABCDE12345)
"""

/// Writes `contents` to a fresh temp file and returns the production
/// `sha256Hex` of it. Keeps `URL` / `Data` / `FileManager` out of the
/// Testing-importing test file.
func sha256HexOfTempFile(contents: String) throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sha-fixture-\(UUID().uuidString).bin")
    try Data(contents.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try BundledBlackHoleInstaller.sha256Hex(of: url)
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
///
/// `verifyInstalled` simulates the post-install CoreAudio probe.
/// Default is `{ true }` so happy-path tests don't trip the new
/// `verificationFailed` guard. Pre-existing failure-path tests can
/// leave it untouched because they short-circuit before verification.
struct FakeInstallerConfig {
    var fetchData: BundledBlackHoleInstaller.DataFetcher
    var downloadFile: BundledBlackHoleInstaller.FileDownloader
    var runProcess: BundledBlackHoleInstaller.ProcessRunner
    var verifyInstalled: BundledBlackHoleInstaller.DeviceVerifier = { true }
}

func makeFakeInstaller(_ config: FakeInstallerConfig) -> BundledBlackHoleInstaller {
    BundledBlackHoleInstaller(
        fetchData: config.fetchData,
        downloadFile: config.downloadFile,
        runProcess: config.runProcess,
        verifyInstalled: config.verifyInstalled
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
/// Stdout/stderr are empty by default; pass non-default values to
/// simulate captured streams.
func makeRunner(
    returningStatus status: Int32,
    stdout: String = "",
    stderr: String = ""
) -> FakeRunner {
    return { _, _ in (status, stdout, stderr) }
}

/// A `runProcess` fake that records each invocation as
/// `(executable, arguments)`. Returns `0` (success). Successful
/// `pkgutil` calls emit the pinned-signer stdout, mirroring a real
/// BlackHole pkg, so the signer pin in `verifySignature` passes.
func makeRecordingRunner(into sink: Mutex<[(String, [String])]>) -> FakeRunner {
    return { executable, arguments in
        sink.withLock { $0.append((executable, arguments)) }
        if executable.hasSuffix("pkgutil") {
            return (0, pkgutilSignedByExistentialAudio, "")
        }
        return (0, "", "")
    }
}

/// A `runProcess` fake whose exit code depends on the executable
/// path. Useful for tests that want `pkgutil` to succeed and
/// `osascript` to fail (or vice versa). A succeeding `pkgutil`
/// carries the pinned-signer stdout like the real BlackHole pkg.
func makeStatusByExecutable(
    pkgutil: Int32,
    osascript: Int32,
    otherwise: Int32 = 0
) -> FakeRunner {
    return { executable, _ in
        if executable.hasSuffix("pkgutil") {
            return (pkgutil, pkgutil == 0 ? pkgutilSignedByExistentialAudio : "", "")
        }
        if executable.hasSuffix("osascript") { return (osascript, "", "") }
        return (otherwise, "", "")
    }
}

/// A `runProcess` fake that records whether it was invoked. Returns
/// `0` on each call.
func makeForbiddenRunner(sink: Mutex<Bool>) -> FakeRunner {
    return { _, _ in
        sink.withLock { $0 = true }
        return (0, "", "")
    }
}
