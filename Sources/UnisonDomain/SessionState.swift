import Foundation

public enum SessionState: Equatable, Sendable {
    case idle
    case connecting(mode: SessionMode)
    case translating(mode: SessionMode, startedAt: Date)
    /// `since` is when the current reconnect attempt began (used by the
    /// status icon for backoff-aware diagnostics). `startedAt` is the
    /// original session start time — preserved across reconnects so the
    /// popover timer keeps counting from the user's click instead of
    /// resetting to 00:00 every time a stream flaps.
    case reconnecting(mode: SessionMode, since: Date, startedAt: Date)
    case error(TranslationError)

    public var isIdle: Bool { if case .idle = self { true } else { false } }

    public var isActive: Bool {
        switch self {
        case .connecting, .translating, .reconnecting: true
        case .idle, .error: false
        }
    }

    public var activeMode: SessionMode? {
        switch self {
        case .connecting(let m), .translating(let m, _), .reconnecting(let m, _, _): m
        case .idle, .error: nil
        }
    }

    /// Wall-clock start time of the active session, preserved across
    /// reconnects. `nil` outside of `.translating` / `.reconnecting`
    /// (i.e. `.idle`, `.connecting`, `.error`).
    public var sessionStartedAt: Date? {
        switch self {
        case .translating(_, let t): t
        case .reconnecting(_, _, let t): t
        case .idle, .connecting, .error: nil
        }
    }

    public var errorValue: TranslationError? {
        if case .error(let e) = self { return e } else { return nil }
    }
}
