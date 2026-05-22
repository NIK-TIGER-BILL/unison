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

    /// Diagnostic logger for the install flow. Mirrors to both unified
    /// logging (`log stream --predicate 'subsystem == "com.unison.app"'`)
    /// and `~/Library/Logs/Unison/unison.log` — see `UnisonLog`. Every
    /// step writes a line at `.info` (or `.error`), which lets the user
    /// or a maintainer pinpoint exactly where a silent failure happened.
    static let log = UnisonLog(category: "BlackHoleInstaller")

    /// Indirection so tests can swap in fixture JSON without hitting
    /// the network.
    public typealias DataFetcher = @Sendable (URL) async throws -> (Data, URLResponse)

    /// Indirection so tests can swap in a fake downloader.
    public typealias FileDownloader = @Sendable (URL, URL) async throws -> Void

    /// Tuple result from a `runProcess` invocation: exit status plus
    /// captured stdout / stderr text. We log all three so silent
    /// failures stop being silent — pkgutil and osascript both report
    /// useful diagnostics on stderr.
    public typealias ProcessResult = (status: Int32, stdout: String, stderr: String)

    /// Indirection so tests can stub out the `pkgutil --check-signature`
    /// + `osascript` invocations. The default implementation shells out
    /// for real and captures both streams.
    public typealias ProcessRunner = @Sendable (String, [String]) throws -> ProcessResult

    /// Indirection so tests can stub the post-install CoreAudio check.
    /// Returns `true` if both BlackHole devices are present. Production
    /// uses `hasDevice(named:)` against `kAudioHardwarePropertyDevices`;
    /// tests pass a closure that flips to `true` to simulate a
    /// successful install or stays `false` to exercise the
    /// `verificationFailed` path.
    public typealias DeviceVerifier = @Sendable () -> Bool

    private let fetchData: DataFetcher
    private let downloadFile: FileDownloader
    private let runProcess: ProcessRunner
    private let verifyInstalledOverride: DeviceVerifier?

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
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            do {
                try process.run()
                // `readDataToEndOfFile` blocks until the process closes
                // the pipe, which it does on exit. Reading before
                // `waitUntilExit` avoids the pipe-buffer-fills-and-
                // child-blocks deadlock (~64KB on Darwin) that the
                // previous implementation was vulnerable to. We then
                // call `waitUntilExit` to be sure `terminationStatus`
                // is final.
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                return (process.terminationStatus, stdout, stderr)
            } catch {
                throw BlackHoleInstallError.installFailed(error.localizedDescription)
            }
        }
        self.verifyInstalledOverride = nil
    }

    /// Test seam — accepts injected `fetchData` / `downloadFile` /
    /// `runProcess` closures. `verifyInstalled` defaults to `nil`
    /// (meaning: use the real CoreAudio probe); passing a closure lets
    /// the test simulate "drivers present" / "drivers missing"
    /// independent of the host machine's actual audio setup.
    init(
        fetchData: @escaping DataFetcher,
        downloadFile: @escaping FileDownloader,
        runProcess: @escaping ProcessRunner,
        verifyInstalled: DeviceVerifier? = nil
    ) {
        self.fetchData = fetchData
        self.downloadFile = downloadFile
        self.runProcess = runProcess
        self.verifyInstalledOverride = verifyInstalled
    }

    public func is2chInstalled() -> Bool { hasDevice(named: "BlackHole 2ch") }
    public func is16chInstalled() -> Bool { hasDevice(named: "BlackHole 16ch") }

    public func runBundledInstaller() async throws {
        Self.log.info("runBundledInstaller — start")

        // 1. Fetch latest release JSON.
        let release: GitHubRelease
        do {
            Self.log.info("Fetching latest release JSON from \(Self.latestReleaseURL)")
            let (data, response) = try await fetchData(Self.latestReleaseURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                Self.log.error("GitHub releases API returned HTTP \(http.statusCode)")
                throw BlackHoleInstallError.releaseFetchFailed(http.statusCode)
            }
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            Self.log.info("Latest BlackHole release tag: \(release.tagName)")
        } catch let error as BlackHoleInstallError {
            throw error
        } catch {
            Self.log.error("Release fetch transport error: \(error.localizedDescription)")
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
            Self.log.error("Failed to construct download URLs for version \(version)")
            throw BlackHoleInstallError.assetsNotFound
        }
        Self.log.info("Download URL 2ch: \(url2ch.absoluteString)")
        Self.log.info("Download URL 16ch: \(url16ch.absoluteString)")

        // 3. Download both to temp.
        let tmp = FileManager.default.temporaryDirectory
        let pkg2chURL = tmp.appendingPathComponent("Unison-BlackHole2ch.pkg")
        let pkg16chURL = tmp.appendingPathComponent("Unison-BlackHole16ch.pkg")

        do {
            Self.log.info("Downloading 2ch pkg to \(pkg2chURL.path)")
            try await downloadFile(url2ch, pkg2chURL)
            let size2ch = (try? FileManager.default.attributesOfItem(atPath: pkg2chURL.path)[.size] as? Int) ?? -1
            Self.log.info("2ch pkg downloaded: \(size2ch) bytes")

            Self.log.info("Downloading 16ch pkg to \(pkg16chURL.path)")
            try await downloadFile(url16ch, pkg16chURL)
            let size16ch = (try? FileManager.default.attributesOfItem(atPath: pkg16chURL.path)[.size] as? Int) ?? -1
            Self.log.info("16ch pkg downloaded: \(size16ch) bytes")
        } catch let error as BlackHoleInstallError {
            Self.log.error("Download failed: \(String(describing: error))")
            throw error
        } catch {
            Self.log.error("Download failed (untyped): \(error.localizedDescription)")
            throw BlackHoleInstallError.downloadFailed
        }

        // 4. Verify signatures.
        Self.log.info("Verifying 2ch pkg signature")
        try verifySignature(at: pkg2chURL)
        Self.log.info("Verifying 16ch pkg signature")
        try verifySignature(at: pkg16chURL)

        // 5. Install both under one admin prompt.
        do {
            Self.log.info("Invoking installer under osascript admin prompt")
            try runInstaller(pkgs: [pkg2chURL, pkg16chURL])
            Self.log.info("osascript installer call returned success")
        } catch {
            Self.log.error("Installer invocation failed: \(String(describing: error))")
            // Cleanup even on failure so we don't litter temp.
            try? FileManager.default.removeItem(at: pkg2chURL)
            try? FileManager.default.removeItem(at: pkg16chURL)
            throw error
        }

        // 6. Cleanup.
        try? FileManager.default.removeItem(at: pkg2chURL)
        try? FileManager.default.removeItem(at: pkg16chURL)

        // 7. Post-install verification.
        //
        // CRITICAL: even when `osascript ... with administrator privileges`
        // returns exit code 0, the underlying `installer(8)` call may
        // have completed without actually adding the audio drivers
        // (e.g., the pkg payload was malformed, or CoreAudio hadn't
        // refreshed device enumeration yet). Without this check, the
        // `OnboardingViewModel` would set status to `.done`, then its
        // `refresh()` would observe `is2chInstalled() == false` and
        // silently flip back to `.pending` — exactly the bug the user
        // reported.
        //
        // We poll for up to ~12 seconds because CoreAudio's
        // `kAudioHardwarePropertyDevices` list does not refresh
        // synchronously with the kext-load that BlackHole's installer
        // triggers; there's a brief window where `installer` has
        // exited but the device hasn't yet appeared in the property
        // list. Even after the kickstart/killall of coreaudiod the
        // daemon may take a few seconds to come back up and
        // re-enumerate plug-ins. 24 × 500 ms gives comfortable
        // headroom without making a happy-path install feel laggy
        // (most installs verify on the first or second poll).
        Self.log.info("Verifying BlackHole devices via CoreAudio")
        let verified = await verifyDevicesAppeared(maxAttempts: 24, delayMs: 500)
        if !verified {
            Self.log.error("Post-install verification FAILED — BlackHole devices not in CoreAudio enumeration")
            throw BlackHoleInstallError.verificationFailed
        }
        Self.log.info("Post-install verification OK — BlackHole 2ch + 16ch present")
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

    /// Bash-safe single-quote escaping. Wraps the input in `'...'`,
    /// replacing each embedded `'` with `'\''` (close, escape, reopen).
    /// Used by `runInstaller` to build `do shell script` commands that
    /// can survive unusual characters in the temp-pkg path.
    static func shellQuote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// AppleScript-safe quoting for the *outer* layer of `do shell script "..."`.
    /// AppleScript string literals use double quotes and escape `\` and
    /// `"` with backslashes. The osascript `-e` argument we pass is an
    /// AppleScript expression, so any `"` or `\` inside the shell
    /// command (e.g., from bash single-quote escaping above) needs to
    /// be re-escaped here.
    static func appleScriptQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - pkgutil / osascript helpers

    private func verifySignature(at url: URL) throws {
        let result: ProcessResult
        do {
            result = try runProcess("/usr/sbin/pkgutil", ["--check-signature", url.path])
        } catch {
            Self.log.error("pkgutil invocation threw: \(error.localizedDescription)")
            throw BlackHoleInstallError.signatureInvalid
        }
        if !result.stdout.isEmpty {
            Self.log.debug("pkgutil stdout: \(result.stdout)")
        }
        if !result.stderr.isEmpty {
            Self.log.debug("pkgutil stderr: \(result.stderr)")
        }
        if result.status != 0 {
            Self.log.error("pkgutil exited with status \(result.status) for \(url.lastPathComponent)")
            throw BlackHoleInstallError.signatureInvalid
        }
    }

    private func runInstaller(pkgs: [URL]) throws {
        // Single admin prompt covers both installs — `&&` chains them
        // inside one `do shell script`, which `osascript` runs as root
        // after one authentication.
        //
        // Paths are wrapped in bash-safe single quotes (each embedded
        // `'` becomes `'\''`) before being embedded in the AppleScript
        // string literal — defensive against weird tempdir paths even
        // though the standard `FileManager.default.temporaryDirectory`
        // path doesn't contain quotes.
        //
        // After installing both pkgs we **kickstart coreaudiod**.
        // BlackHole is a CoreAudio HAL plug-in installed under
        // /Library/Audio/Plug-Ins/HAL/. macOS' `installer` writes the
        // driver bundle to disk but does NOT relaunch coreaudiod, so the
        // device stays invisible until either the user reboots or the
        // audio daemon is restarted. The installer's own postinstall
        // even says "The install requires restarting now." We avoid the
        // restart by kickstarting the system daemon ourselves under the
        // same admin auth that we already have. This makes BlackHole
        // immediately discoverable by `system_profiler SPAudioDataType`
        // and our own `hasDevice(named:)` poll, without asking the user
        // to reboot.
        var commands = pkgs.map {
            "installer -pkg \(Self.shellQuote($0.path)) -target /"
        }
        // After installing both pkgs we kickstart coreaudiod so the new
        // CoreAudio HAL plug-in is immediately discoverable (otherwise
        // the daemon's cached device list hides BlackHole until reboot).
        // The kickstart is **best-effort**: wrapped in `( ... ) || true`
        // so a kickstart failure (different macOS version, sandbox
        // restriction, daemon state weirdness) does NOT abort the whole
        // `&&` chain after a successful install. Two fallbacks:
        //   1) launchctl kickstart (preferred — clean restart)
        //   2) killall coreaudiod (launchd respawns it automatically)
        // If both fail, post-install verification polls for ~10s during
        // which coreaudiod may pick up the new plug-in on its own.
        commands.append("( /bin/launchctl kickstart -k system/com.apple.audio.coreaudiod || /usr/bin/killall coreaudiod || true )")
        let installCmds = commands.joined(separator: " && ")
        let script = "do shell script \(Self.appleScriptQuote(installCmds)) with administrator privileges"
        Self.log.debug("osascript script: \(script)")

        let result: ProcessResult
        do {
            result = try runProcess("/usr/bin/osascript", ["-e", script])
        } catch let error as BlackHoleInstallError {
            throw error
        } catch {
            throw BlackHoleInstallError.installFailed(error.localizedDescription)
        }
        if !result.stdout.isEmpty {
            Self.log.info("osascript stdout: \(result.stdout)")
        }
        if !result.stderr.isEmpty {
            // osascript writes "User canceled." here when the auth
            // prompt is dismissed, and `installer`'s own progress lines
            // when authentication succeeded. We log at .info so QA can
            // distinguish the two.
            Self.log.info("osascript stderr: \(result.stderr)")
        }
        if result.status != 0 {
            Self.log.error("osascript exited with status \(result.status)")
            // Surface the captured stderr so the UI / Console can see
            // what `do shell script` was unhappy about.
            let detail = result.stderr.isEmpty
                ? "installer exited with status \(result.status)"
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BlackHoleInstallError.installFailed(detail)
        }
    }

    // MARK: - CoreAudio device check

    /// Poll CoreAudio until both BlackHole devices appear, or give up.
    /// CoreAudio's device list doesn't refresh synchronously when
    /// `installer(8)` finishes loading the kext, so we re-check a few
    /// times with a small sleep between attempts.
    ///
    /// When a `verifyInstalled` override is wired (test seam), the
    /// override fully replaces the per-device CoreAudio probe — useful
    /// for hermetic unit tests that don't want to depend on the host
    /// machine's audio device list.
    private func verifyDevicesAppeared(maxAttempts: Int, delayMs: UInt64) async -> Bool {
        for attempt in 1...maxAttempts {
            let installed: Bool
            if let override = verifyInstalledOverride {
                installed = override()
            } else {
                installed = is2chInstalled() && is16chInstalled()
            }
            Self.log.info("Verification attempt \(attempt)/\(maxAttempts): installed=\(installed)")
            if installed {
                return true
            }
            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }
        }
        return false
    }

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

// `BlackHoleInstallError` moved to `UnisonDomain` so the UI layer can
// pattern-match cases for localized copy without importing
// `UnisonSystem`. See `Sources/UnisonDomain/Protocols/BlackHoleInstaller.swift`.
