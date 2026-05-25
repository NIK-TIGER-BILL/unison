public protocol BlackHoleInstaller: Sendable {
    func is2chInstalled() -> Bool
    func is16chInstalled() -> Bool
    /// Fetches the latest BlackHole release from GitHub, downloads the
    /// 2ch + 16ch `.pkg` payloads, and runs the system installer under a
    /// single admin-auth prompt. The method name is historical — nothing
    /// is bundled in the `.app` anymore; the download happens at install
    /// time when the user clicks "Установить" in onboarding.
    ///
    /// Implementations MUST perform a post-install verification step:
    /// after `installer(8)` exits, re-check `is2chInstalled()` /
    /// `is16chInstalled()` (which read CoreAudio's device list) and
    /// throw `BlackHoleInstallError.verificationFailed` if the devices
    /// did not appear. Without this contract, a silent install failure
    /// would surface as a status-flip back to `.pending` in the
    /// onboarding UI — exactly the bug that motivated splitting this
    /// error out.
    func runBundledInstaller() async throws
}

/// Errors thrown by `BlackHoleInstaller` implementations. Lives in
/// `UnisonDomain` (not `UnisonSystem`) so the UI layer can pattern-match
/// on specific cases to render Russian copy without taking on a
/// transitive system-layer dependency.
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
    /// the user dismissed the admin auth prompt. The associated value
    /// is captured stderr — useful for diagnostics. Typical contents
    /// are `"User canceled."` (auth dismissed) or `installer(8)`'s own
    /// error output.
    case installFailed(String)
    /// `installer` reported success (osascript exit 0) but the BlackHole
    /// devices never appeared in CoreAudio's device list. This is the
    /// "silent failure" path — without this case, the ViewModel would
    /// see no error and flip the step back to `.pending`. Now we throw
    /// so the UI shows the user something actionable.
    case verificationFailed
}
