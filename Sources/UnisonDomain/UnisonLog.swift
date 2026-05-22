import Foundation
import os

/// Thin wrapper around `os.Logger` that mirrors every call into
/// `FileLogStore.shared`.
///
/// **Why a wrapper instead of `os.Logger` directly?** Unified logging
/// vanishes once the process exits and is awkward to read after the
/// fact — you need `log stream` (live) or `log show --info` with a
/// predicate, and those tools omit messages whose `privacy` level isn't
/// `.public` by default. `UnisonLog` keeps the convenient `os.Logger`
/// behaviour (Console.app integration, structured `subsystem`/`category`)
/// while also persisting a flat text file at
/// `~/Library/Logs/Unison/unison.log`. That file is what the assistant /
/// reviewer / VM integration test reads — no manual `log stream` step.
///
/// **API contract.** Drop-in for the previous
/// `static let log = Logger(subsystem:category:)` pattern. Migration is
/// purely mechanical:
///
/// ```swift
/// // before
/// private static let log = Logger(subsystem: "com.unison.app", category: "Foo")
/// Self.log.info("frob \(x, privacy: .public)")
///
/// // after
/// private static let log = UnisonLog(category: "Foo")
/// Self.log.info("frob \(x)")
/// ```
///
/// The wrapper exposes `info` / `error` / `debug` (the three levels the
/// app actually uses). Callers pass a fully-resolved `String` — no
/// `OSLogMessage` interpolation. Privacy is implicitly `.public` for
/// both sinks; we never log credentials or PII.
///
/// **Sendability.** `os.Logger` is `Sendable`; `String` is `Sendable`.
/// The struct holds those two values plus the category name → safe to
/// pass between actors.
public struct UnisonLog: Sendable {
    /// Underlying `os.Logger` so messages still flow into unified
    /// logging (Console.app, `log stream`, sysdiagnose).
    private let logger: Logger
    /// The category name. Captured separately so we can format the
    /// `[category:level]` prefix in the file sink without parsing it
    /// back out of `Logger`.
    public let category: String

    /// Shared subsystem name. Every call site picks the same value
    /// (matches the historical `Logger(subsystem:)` value) so the
    /// `log stream` predicate doesn't need to change.
    public static let subsystem: String = "com.unison.app"

    public init(category: String) {
        self.logger = Logger(subsystem: Self.subsystem, category: category)
        self.category = category
    }

    public func info(_ message: String) {
        // os.Logger requires the privacy modifier on interpolations; passing
        // a fully-formed `String` is treated as static-public by the runtime.
        logger.info("\(message, privacy: .public)")
        FileLogStore.shared.write(category: category, level: "info", message: message)
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        FileLogStore.shared.write(category: category, level: "error", message: message)
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        FileLogStore.shared.write(category: category, level: "debug", message: message)
    }
}
