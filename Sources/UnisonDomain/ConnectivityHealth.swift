import Foundation

/// Orthogonal "quality of service" dimension that the orchestrator
/// publishes alongside `SessionState`. Only meaningful when
/// `SessionState == .translating`; the UI ignores it in any other
/// state (`.paused` / `.reconnecting` / `.error` already speak for
/// themselves).
///
/// Computed per outgoing WS stream (me / peer) and aggregated via
/// `aggregate(_:_:)` for the main popover + control-pill indicator.
/// The diagnostic dialog reads the per-stream value directly so
/// asymmetric failures ("me-stream healthy, peer-stream slow") stay
/// debuggable.
public enum ConnectivityHealth: Sendable, Equatable {
    /// Deltas are flowing, nothing to surface.
    case healthy
    /// User is speaking (mic RMS > 0.001 in the last second) but the
    /// server hasn't returned any delta in ≥3 s. WS is still open —
    /// this is "slow", not "dead".
    case slow
    /// Stream just reconnected. UI shows a brief "Связь восстановлена"
    /// flash for 2 s before reverting to `.healthy` on the next delta
    /// (or the timer expiring, whichever comes first).
    case recovering

    /// Aggregate per-stream health into one overall value for UI.
    /// `slow` dominates (worst signal wins); `recovering` beats
    /// `healthy` so the flash is visible even if one side is steady.
    public static func aggregate(_ a: ConnectivityHealth, _ b: ConnectivityHealth) -> ConnectivityHealth {
        if a == .slow || b == .slow { return .slow }
        if a == .recovering || b == .recovering { return .recovering }
        return .healthy
    }

    /// Single-stream pass-through, used in `.test` / `.listen` modes
    /// where only one of the two pipelines is active.
    public static func aggregate(_ a: ConnectivityHealth) -> ConnectivityHealth {
        a
    }
}
