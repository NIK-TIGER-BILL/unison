import Foundation

public enum SessionState: Equatable, Sendable {
    case idle
    case connecting(mode: SessionMode)
    case translating(mode: SessionMode, startedAt: Date)
    /// Network-level pause. WS streams are closed, mic + peer captures
    /// are stopped, and we're waiting for the path to come back. Set
    /// by the orchestrator in response to `NWPathMonitor` reporting
    /// `unsatisfied`; cleared by the same monitor reporting
    /// `satisfied`. `.reconnecting` is reserved for WS-level flap
    /// inside an otherwise-healthy network.
    case paused(mode: SessionMode, since: Date, startedAt: Date, reason: PauseReason)
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
        case .connecting, .translating, .paused, .reconnecting: true
        case .idle, .error: false
        }
    }

    public var activeMode: SessionMode? {
        switch self {
        case .connecting(let m), .translating(let m, _), .paused(let m, _, _, _), .reconnecting(let m, _, _): m
        case .idle, .error: nil
        }
    }

    /// Wall-clock start time of the active session, preserved across
    /// reconnects and pauses. `nil` outside of `.translating` / `.paused` /
    /// `.reconnecting` (i.e. `.idle`, `.connecting`, `.error`).
    public var sessionStartedAt: Date? {
        switch self {
        case .translating(_, let t): t
        case .paused(_, _, let t, _): t
        case .reconnecting(_, _, let t): t
        case .idle, .connecting, .error: nil
        }
    }

    public var errorValue: TranslationError? {
        if case .error(let e) = self { return e } else { return nil }
    }
}

/// Reason the orchestrator entered `.paused`. Distinct from
/// `TranslationError` because `.paused` is recoverable — the session
/// is still alive and will auto-resume when the network returns.
public enum PauseReason: Sendable, Equatable {
    /// `NWPathMonitor` reported `.unsatisfied`. WS streams torn down,
    /// captures halted. UI shows "Нет интернета. Ждём…".
    case networkLost
    /// Network returned (`NWPathMonitor` → `.satisfied`) and we're in
    /// the middle of re-establishing streams. Brief transitional
    /// state; UI shows "Возобновляем…".
    case awaitingNetwork
    /// The Mac is going to sleep (`NSWorkspace.willSleepNotification`).
    /// WS streams are closed and captures stopped BEFORE the sockets
    /// die under us — otherwise wake-up leaves a zombie session that
    /// looks alive but never hears the server again. `systemDidWake`
    /// resumes (directly when the network is already up, or via the
    /// regular network pause when it isn't). No recovery watchdog runs
    /// while asleep — a night-long nap is not a failure.
    case systemSleep
}
