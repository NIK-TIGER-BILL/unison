public protocol BlackHoleInstaller: Sendable {
    func is2chInstalled() -> Bool
    func is16chInstalled() -> Bool
    /// Runs the bundled .pkg installer with password prompt.
    /// After success, both `isXchInstalled()` should return true.
    func runBundledInstaller() async throws
}
