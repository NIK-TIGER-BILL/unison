public protocol BlackHoleInstaller: Sendable {
    func is2chInstalled() -> Bool
    func is16chInstalled() -> Bool
    /// Fetches the latest BlackHole release from GitHub, downloads the
    /// 2ch + 16ch `.pkg` payloads, and runs the system installer under a
    /// single admin-auth prompt. The method name is historical — nothing
    /// is bundled in the `.app` anymore; the download happens at install
    /// time when the user clicks "Установить" in onboarding.
    /// After success, both `isXchInstalled()` should return true.
    func runBundledInstaller() async throws
}
