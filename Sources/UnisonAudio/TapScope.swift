/// What the Process Tap should capture, resolved from `Settings` at session
/// start. `.allExcept` taps everything but the listed bundle IDs (plus
/// Unison itself); `.onlySelected` taps only the listed bundle IDs.
public enum TapScope: Sendable, Equatable {
    case allExcept([String])
    case onlySelected([String])

    /// The user-chosen bundle IDs, regardless of mode. Empty means "no user
    /// selection" (for `.allExcept` that's tap-all; for `.onlySelected` the
    /// start gate prevents reaching this).
    public var bundleIDs: [String] {
        switch self {
        case .allExcept(let ids), .onlySelected(let ids): return ids
        }
    }
}
