import Foundation

public enum SessionState: Equatable, Sendable {
    case idle
    case connecting(mode: SessionMode)
    case translating(mode: SessionMode, startedAt: Date)
    case reconnecting(mode: SessionMode, since: Date)
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
        case .connecting(let m), .translating(let m, _), .reconnecting(let m, _): m
        case .idle, .error: nil
        }
    }

    public var errorValue: TranslationError? {
        if case .error(let e) = self { return e } else { return nil }
    }
}
