import Foundation
import CoreAudio
import UnisonDomain

/// Installer that fetches the **latest** BlackHole release from GitHub
/// at runtime, downloads the `2ch` and `16ch` `.pkg` payloads into the
/// temporary directory, verifies their signatures via `pkgutil`, and
/// invokes the system installer under a single `osascript` admin-auth
/// prompt.
///
/// The name is kept for backwards compatibility (call sites, tests, and
/// the `BlackHoleInstaller` protocol's `runBundledInstaller()` method
/// name still describe the *user-facing* gesture — clicking
/// "Установить" in onboarding). Nothing is bundled in the `.app`
/// anymore.
public final class BundledBlackHoleInstaller: BlackHoleInstaller, @unchecked Sendable {
    /// GitHub API endpoint that returns the JSON for the most recent
    /// non-draft, non-prerelease BlackHole release.
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/ExistentialAudio/BlackHole/releases/latest"
    )!

    /// Indirection so tests can swap in fixture JSON without hitting
    /// the network.
    public typealias DataFetcher = @Sendable (URL) async throws -> (Data, URLResponse)

    /// Indirection so tests can swap in a fake downloader.
    public typealias FileDownloader = @Sendable (URL, URL) async throws -> Void

    /// Indirection so tests can stub out the `pkgutil --check-signature`
    /// + `osascript` invocations. The default implementation shells out
    /// for real.
    public typealias ProcessRunner = @Sendable (String, [String]) throws -> Int32

    private let fetchData: DataFetcher
    private let downloadFile: FileDownloader
    private let runProcess: ProcessRunner

    public init() {
        self.fetchData = { url in try await URLSession.shared.data(from: url) }
        self.downloadFile = { url, dest in
            let (tempURL, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw BlackHoleInstallError.downloadFailed
            }
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)
        }
        self.runProcess = { executable, arguments in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let stderr = Pipe()
            process.standardError = stderr
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            } catch {
                throw BlackHoleInstallError.installFailed(error.localizedDescription)
            }
        }
    }

    /// Test seam — accepts injected `fetchData` / `downloadFile` /
    /// `runProcess` closures.
    init(
        fetchData: @escaping DataFetcher,
        downloadFile: @escaping FileDownloader,
        runProcess: @escaping ProcessRunner
    ) {
        self.fetchData = fetchData
        self.downloadFile = downloadFile
        self.runProcess = runProcess
    }

    public func is2chInstalled() -> Bool { hasDevice(named: "BlackHole 2ch") }
    public func is16chInstalled() -> Bool { hasDevice(named: "BlackHole 16ch") }

    public func runBundledInstaller() async throws {
        // 1. Fetch latest release JSON.
        let release: GitHubRelease
        do {
            let (data, response) = try await fetchData(Self.latestReleaseURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw BlackHoleInstallError.releaseFetchFailed(http.statusCode)
            }
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch let error as BlackHoleInstallError {
            throw error
        } catch {
            throw BlackHoleInstallError.releaseFetchFailed(-1)
        }

        // 2. Build download URLs from the release tag.
        //
        // BlackHole upstream stopped attaching .pkg files to GitHub releases
        // since v0.6.0 — `release.assets` is empty. Instead, the maintainer
        // hosts pkgs directly on existential.audio CDN at a predictable
        // URL pattern (the same one Homebrew Cask uses):
        //
        //   https://existential.audio/downloads/BlackHole2ch-{version}.pkg
        //   https://existential.audio/downloads/BlackHole16ch-{version}.pkg
        //
        // We read `tag_name` from the GitHub API ("v0.6.1") and strip the
        // "v" prefix to build the version segment.
        let version = Self.normalizeVersion(release.tagName)
        guard
            let url2ch = URL(string: "https://existential.audio/downloads/BlackHole2ch-\(version).pkg"),
            let url16ch = URL(string: "https://existential.audio/downloads/BlackHole16ch-\(version).pkg")
        else {
            throw BlackHoleInstallError.assetsNotFound
        }

        // 3. Download both to temp.
        let tmp = FileManager.default.temporaryDirectory
        let pkg2chURL = tmp.appendingPathComponent("Unison-BlackHole2ch.pkg")
        let pkg16chURL = tmp.appendingPathComponent("Unison-BlackHole16ch.pkg")

        do {
            try await downloadFile(url2ch, pkg2chURL)
            try await downloadFile(url16ch, pkg16chURL)
        } catch let error as BlackHoleInstallError {
            throw error
        } catch {
            throw BlackHoleInstallError.downloadFailed
        }

        // 4. Verify signatures.
        try verifySignature(at: pkg2chURL)
        try verifySignature(at: pkg16chURL)

        // 5. Install both under one admin prompt.
        do {
            try runInstaller(pkgs: [pkg2chURL, pkg16chURL])
        } catch {
            // Cleanup even on failure so we don't litter temp.
            try? FileManager.default.removeItem(at: pkg2chURL)
            try? FileManager.default.removeItem(at: pkg16chURL)
            throw error
        }

        // 6. Cleanup.
        try? FileManager.default.removeItem(at: pkg2chURL)
        try? FileManager.default.removeItem(at: pkg16chURL)
    }

    // MARK: - Asset selection

    /// Picks the `2ch` and `16ch` `.pkg` assets out of a release. Matches
    /// names like `BlackHole2ch.v0.6.0.pkg` or `BlackHole16ch.pkg`. The
    /// "2ch" lookup explicitly excludes "16ch" (otherwise `contains("2ch")`
    /// would also match `BlackHole16ch`).
    static func selectAssets(from assets: [GitHubRelease.Asset]) -> (two: GitHubRelease.Asset, sixteen: GitHubRelease.Asset)? {
        let pkgs = assets.filter { $0.name.lowercased().hasSuffix(".pkg") }
        let twoCh = pkgs.first { asset in
            let lower = asset.name.lowercased()
            return lower.contains("2ch") && !lower.contains("16ch")
        }
        let sixteenCh = pkgs.first { asset in
            asset.name.lowercased().contains("16ch")
        }
        guard let twoCh, let sixteenCh else { return nil }
        return (twoCh, sixteenCh)
    }

    /// Strips a leading "v" from a release tag and returns the bare
    /// version segment. `"v0.6.1"` → `"0.6.1"`, `"0.6.1"` → `"0.6.1"`.
    /// Used to build existential.audio download URLs.
    static func normalizeVersion(_ tag: String) -> String {
        guard tag.hasPrefix("v") else { return tag }
        return String(tag.dropFirst())
    }

    // MARK: - pkgutil / osascript helpers

    private func verifySignature(at url: URL) throws {
        let status: Int32
        do {
            status = try runProcess("/usr/sbin/pkgutil", ["--check-signature", url.path])
        } catch {
            throw BlackHoleInstallError.signatureInvalid
        }
        if status != 0 {
            throw BlackHoleInstallError.signatureInvalid
        }
    }

    private func runInstaller(pkgs: [URL]) throws {
        // Single admin prompt covers both installs — `&&` chains them
        // inside one `do shell script`, which `osascript` runs as root
        // after one authentication.
        let installCmds = pkgs
            .map { "installer -pkg '\($0.path)' -target /" }
            .joined(separator: " && ")
        let script = "do shell script \"\(installCmds)\" with administrator privileges"

        let status: Int32
        do {
            status = try runProcess("/usr/bin/osascript", ["-e", script])
        } catch let error as BlackHoleInstallError {
            throw error
        } catch {
            throw BlackHoleInstallError.installFailed(error.localizedDescription)
        }
        if status != 0 {
            throw BlackHoleInstallError.installFailed("installer exited with status \(status)")
        }
    }

    // MARK: - CoreAudio device check

    private func hasDevice(named name: String) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return false }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        for id in ids {
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            var cfStr: CFString?
            let status = withUnsafeMutablePointer(to: &cfStr) { ptr in
                AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, ptr)
            }
            if status == noErr, let s = cfStr as String?, s.lowercased() == name.lowercased() {
                return true
            }
        }
        return false
    }
}

// MARK: - GitHub release JSON model

struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }

    struct Asset: Decodable, Equatable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

// MARK: - Errors

public enum BlackHoleInstallError: Error, Equatable {
    /// The GitHub API call failed (non-200 or transport error). The
    /// associated value is the HTTP status when available, `-1`
    /// otherwise.
    case releaseFetchFailed(Int)
    /// The latest release does not expose a 2ch + 16ch `.pkg` pair.
    /// Upstream has been known to remove `.pkg` assets from GitHub
    /// releases (https://existential.audio/blackhole/).
    case assetsNotFound
    /// Downloading one of the `.pkg` files failed.
    case downloadFailed
    /// `pkgutil --check-signature` rejected one of the downloaded
    /// installers.
    case signatureInvalid
    /// `installer` (run via `osascript`) returned a non-zero status, or
    /// the user dismissed the admin auth prompt.
    case installFailed(String)
}
