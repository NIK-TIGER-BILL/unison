/// Whether the Process Tap translates everything *except* the chosen apps
/// (blocklist) or *only* the chosen apps (allowlist). The two are mutually
/// exclusive and each keeps its own list (`Settings.excludedTapBundleIDs`
/// vs `Settings.includedTapBundleIDs`).
public enum TapScopeMode: String, CaseIterable, Codable, Sendable {
    /// Translate all system audio except the listed apps. Default.
    case allExcept
    /// Translate only the listed apps; everything else is untouched.
    case onlySelected
}
