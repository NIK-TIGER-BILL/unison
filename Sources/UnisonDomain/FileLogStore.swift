import Foundation

/// Thread-safe, append-only sink for `UnisonLog` lines.
///
/// **Why this exists.** Unified logging (`log stream --predicate
/// 'subsystem == "com.unison.app"'`) is great for live debugging, but it
/// leaves nothing on disk after a session ends: the next contributor (or
/// the assistant) can't see what happened. `FileLogStore` mirrors every
/// `UnisonLog.info/error/debug` call into a plain text file at the
/// standard macOS user-logs location, so a complete history is always
/// reachable without re-running the app under `log stream`.
///
/// **Where files land.** `~/Library/Logs/Unison/unison.log` is the
/// current file; rotated copies are `unison.1.log` … `unison.5.log`
/// (oldest dropped). This is the canonical path for app-private logs on
/// macOS (Apple's own `os_log` lands in `~/Library/Logs/DiagnosticReports`
/// for crashes; per-app logs in `~/Library/Logs/<AppName>` is the
/// long-standing convention — Console.app picks them up automatically).
///
/// **Threading.** All I/O happens on a single private serial queue so
/// the call site never blocks the main thread on `write(2)`. Each line
/// is short (one log message) so a single `Data.write` per call is fine
/// — we don't need a buffer/flush dance.
///
/// **Rotation.** Triggered on the I/O queue every time the file grows
/// past `maxFileBytes`. We shift `unison.N.log → unison.N+1.log` for N
/// from `maxFiles-1` down to 0, then truncate the live file. Failures
/// are swallowed: a broken rotation never crashes the caller — we'd
/// rather lose a few log lines than the running app.
public final class FileLogStore: @unchecked Sendable {
    /// Process-wide singleton. Lazily creates the logs directory on
    /// first `write`. Initializer is private so tests/components can't
    /// build divergent instances pointed at random paths.
    public static let shared: FileLogStore = {
        // Standard macOS user-private logs location. Console.app picks
        // anything under `~/Library/Logs` up automatically.
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Unison", isDirectory: true)
        // Suppress the file sink under `swift test`: every static
        // `UnisonLog` (installer, WS stream, etc.) routes here, so a
        // test run would otherwise scribble fake lines (0-byte mock
        // installs, mock `invalid_api_key`, …) into the USER'S real
        // `~/Library/Logs/Unison/unison.log` — which then surfaces,
        // alarmingly and misleadingly, in a real crash report's log
        // tail. Unified logging (os.Logger) still flows; only the
        // shared file is muted. Test-constructed instances (temp dirs)
        // stay enabled.
        return FileLogStore(directory: dir, enabled: !isRunningUnderTests)
    }()

    /// `true` when the process is a `swift test` / XCTest run, detected
    /// from the host executable: SwiftPM's swift-testing runner is
    /// `swiftpm-testing-helper`, and an XCTest bundle runs under
    /// `xctest` / a `*.xctest` bundle. (The XCTest env var and runtime
    /// class are NOT present for a pure swift-testing run — verified —
    /// so checking the executable path is the portable signal.) The
    /// real app's executable is `Unison`, so this is `false` in
    /// production and file logging is never disabled there. The
    /// `UNISON_DISABLE_FILE_LOG=1` override is a manual escape hatch.
    public static let isRunningUnderTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["UNISON_DISABLE_FILE_LOG"] == "1" { return true }
        let exe = (Bundle.main.executablePath ?? "").lowercased()
        if exe.contains("swiftpm-testing-helper") || exe.contains("xctest") { return true }
        let proc = ProcessInfo.processInfo.processName.lowercased()
        if proc == "swiftpm-testing-helper" || proc.contains("xctest") { return true }
        return false
    }()

    /// Directory that holds `unison.log` + rotated copies. Resolved
    /// once at init; callers shouldn't expect re-resolution on change.
    public let directory: URL
    /// Path to the *live* file (the one being written to right now).
    public var currentFileURL: URL { directory.appendingPathComponent("unison.log") }

    /// Rotation threshold. Hitting this on a write triggers a rotate.
    /// Sized so the live file stays small enough that a `tail -f` over
    /// SSH or a `cat` for the integration test pulls quickly, and so
    /// the I/O cost of the rotate itself stays bounded.
    public let maxFileBytes: Int
    /// How many rotated archives to keep IN ADDITION to the live file
    /// (the rotation test codifies `maxFiles + 1` files on disk). With
    /// `5 × 2MB` archives plus the live file we retain up to ~12 MB of
    /// activity — enough for several start/stop cycles plus a long
    /// meeting.
    public let maxFiles: Int

    /// I/O serial queue. Marked `userInitiated` so log writes don't
    /// stall behind background work, but never sticks the main thread.
    private let queue: DispatchQueue
    /// Whether we've successfully created the directory + initial file.
    /// Used as a soft latch to skip `FileManager` calls on the hot path.
    private var bootstrapped = false
    /// `true` once the singleton has emitted its boot banner. Keeps
    /// the integration test seeing a deterministic first line at every
    /// app launch.
    private var bannerEmitted = false
    /// When `false`, `write` is a no-op (unified logging still happens
    /// via `UnisonLog`'s `os.Logger`). The shared singleton sets this
    /// off under `swift test` so incidental logging doesn't pollute the
    /// user's real log file.
    private let enabled: Bool

    /// Visible for tests. Production code uses `FileLogStore.shared`.
    public init(directory: URL, maxFileBytes: Int = 2 * 1024 * 1024, maxFiles: Int = 5, enabled: Bool = true) {
        self.directory = directory
        self.maxFileBytes = maxFileBytes
        self.maxFiles = maxFiles
        self.enabled = enabled
        self.queue = DispatchQueue(label: "com.unison.app.FileLogStore", qos: .userInitiated)
    }

    /// Format: `2026-05-22 14:23:45.678 [Orchestrator:info] message`.
    /// `Date.ISO8601FormatStyle` rounds to seconds; we want millis so a
    /// stop/start of the same operation has different timestamps.
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    /// Emit one structured line. Fire-and-forget — the caller never
    /// blocks on file I/O. Used by `UnisonLog`; direct callers are
    /// the rare path (e.g. `Composition.swift` writing the launch
    /// banner before any UnisonLog has been instantiated).
    public func write(category: String, level: String, message: String) {
        guard enabled else { return }
        // Capture the wall-clock NOW cheaply on the caller (a bare `Date()`
        // is a lock-free time snapshot), then move EVERYTHING expensive — the
        // shared `DateFormatter` (an internal ObjC lock + ICU/locale work,
        // NOT thread-safe) and the line interpolation — onto the serial I/O
        // queue. This is load-bearing, not cosmetic: `write` is called from
        // the CoreAudio render thread, both detached audio pumps, the WS
        // receive loop and the MainActor, often concurrently and at high
        // volume. Formatting the timestamp here would serialize all those hot
        // threads on the one `DateFormatter` lock — a real-time-audio
        // violation that hitches the render thread and stutters playback.
        // Formatting on the single-consumer queue keeps the formatter
        // effectively single-threaded and the caller non-blocking.
        //
        // Trade-off (accepted): the timestamp is captured on the caller but the
        // line is appended later on the queue, so under heavy concurrency two
        // near-simultaneous callers can land in the file in the opposite order
        // to their captured timestamps — i.e. a line's timestamp may be a hair
        // out of order vs its file position. No consumer sorts by timestamp
        // (they grep for presence or tail in file order), so this is cosmetic;
        // the alternative (formatting on the caller to keep order) is exactly
        // the hot-path stall this fix removes.
        let now = Date()
        queue.async { [weak self] in
            guard let self else { return }
            let timestamp = Self.timestampFormatter.string(from: now)
            let line = "\(timestamp) [\(category):\(level)] \(message)\n"
            self.appendLine(line)
        }
    }

    /// Read the current file as UTF-8. Convenience for tests and the
    /// diagnostic dump panel. Returns empty if the file doesn't exist.
    public func readAll() -> String {
        let url = currentFileURL
        guard let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /// Force a rotation right now. Visible for tests so they can verify
    /// rotation without writing 2 MB of payload. Returns synchronously
    /// after dispatching to the I/O queue.
    public func rotateNow() {
        queue.sync { [weak self] in
            self?.rotateLocked()
        }
    }

    /// One-shot bootstrap line written the first time a process writes
    /// anything. Cheap signal in the integration test's grep that the
    /// new logger is actually wired (and not someone's stale file).
    private func emitBannerIfNeeded() {
        guard !bannerEmitted else { return }
        bannerEmitted = true
        let timestamp = Self.timestampFormatter.string(from: Date())
        let pid = ProcessInfo.processInfo.processIdentifier
        let line = "\(timestamp) [FileLogStore:info] === Unison log file opened (pid=\(pid)) ===\n"
        appendLineRaw(line)
    }

    // MARK: - I/O queue internals (must run on `queue`)

    private func appendLine(_ line: String) {
        bootstrapIfNeeded()
        emitBannerIfNeeded()
        appendLineRaw(line)
        rotateIfNeededLocked()
    }

    /// Append without bootstrap/banner/rotation logic. Used by the
    /// banner emitter to avoid recursion.
    private func appendLineRaw(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let url = currentFileURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            // `seekToEnd()` returns the new offset; we don't need it.
            // The explicit `_ =` silences the "result of 'try?' is
            // unused" warning while keeping the failure tolerance
            // (broken seeks don't crash the log path).
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // First write to a non-existent file. Create it.
            try? data.write(to: url, options: .atomic)
        }
    }

    private func bootstrapIfNeeded() {
        guard !bootstrapped else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: currentFileURL.path) {
                fm.createFile(atPath: currentFileURL.path, contents: nil)
            }
            bootstrapped = true
        } catch {
            // Don't crash the app over a log directory we couldn't make.
            // Subsequent writes will silently no-op via the same fall-through.
        }
    }

    private func rotateIfNeededLocked() {
        let url = currentFileURL
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size > maxFileBytes else { return }
        rotateLocked()
    }

    private func rotateLocked() {
        let fm = FileManager.default
        // Shift unison.{maxFiles-1}.log out of the way (delete the oldest),
        // then walk back to 0 renaming each into N+1. Numbered copies use
        // `unison.N.log` so they sort naturally and never collide with
        // the live `unison.log` name.
        for n in stride(from: maxFiles - 1, through: 1, by: -1) {
            let src = directory.appendingPathComponent("unison.\(n).log")
            let dst = directory.appendingPathComponent("unison.\(n + 1).log")
            if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
            if fm.fileExists(atPath: src.path) { try? fm.moveItem(at: src, to: dst) }
        }
        // The youngest archival slot — `unison.1.log` — receives the
        // current live file's contents. Then create a fresh live file.
        let liveSrc = currentFileURL
        let firstArchive = directory.appendingPathComponent("unison.1.log")
        if fm.fileExists(atPath: firstArchive.path) { try? fm.removeItem(at: firstArchive) }
        if fm.fileExists(atPath: liveSrc.path) { try? fm.moveItem(at: liveSrc, to: firstArchive) }
        fm.createFile(atPath: liveSrc.path, contents: nil)
        // Drop anything past the keep-window (e.g. when `maxFiles`
        // changes between builds, the older archives may linger).
        for n in (maxFiles + 1)..<(maxFiles + 10) {
            let stale = directory.appendingPathComponent("unison.\(n).log")
            try? fm.removeItem(at: stale)
        }
    }
}
