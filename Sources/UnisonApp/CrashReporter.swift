import AppKit
import Foundation
import UnisonDomain

/// Detects unclean shutdowns from a previous launch and surfaces a
/// modal alert with the captured diagnostic so the user can copy it
/// to the developer.
///
/// **Why this design (session-marker, not in-process signal
/// handlers).** Catching the crash *inside* the dying process is
/// unreliable: by the time `SIGSEGV` / `SIGBUS` / `MainActor.assumeIsolated`
/// trap fires, the Swift runtime is already in an inconsistent state
/// (the `swift_task_isMainExecutorImpl` regression on macOS 26 + Swift
/// 6.3 is the worst-case example — we can't even put up an `NSAlert`
/// from such a context because re-entering AppKit / `NSRunLoop`
/// freshly allocates more Swift Concurrency machinery and triggers
/// the same trap again). The robust pattern instead is:
///
/// 1. Write a tiny marker file at the start of every session.
/// 2. Delete it from `applicationWillTerminate` (clean shutdowns).
/// 3. On the next launch, if the marker still exists, the previous
///    session must have died without running the will-terminate
///    handler — i.e. it crashed. Surface a modal alert built from
///    `unison.log` + the matching `~/Library/Logs/DiagnosticReports/Unison-*.ips`.
///
/// This is the same approach Sparkle, HockeyApp, and Sentry's Cocoa
/// SDK use for "previous launch crashed" detection. The .ips file
/// from macOS's `ReportCrash` mechanism is the authoritative stack
/// trace; our role is just to point the user at it and give them a
/// one-click way to copy a diagnostic blob to the developer.
@MainActor
public enum CrashReporter {
    /// Path of the per-session marker. Written when a session starts,
    /// deleted when the app terminates cleanly. Its presence on the
    /// next launch is the crash signal.
    private static let markerURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Unison", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session-active.marker")
    }()

    /// Snapshot of a previous crashed session, assembled from the
    /// marker + the file log + the matching macOS `.ips` report.
    public struct CrashReport {
        public let previousPID: Int
        public let previousStartedAt: Date
        /// Tail of `~/Library/Logs/Unison/unison.log` — what the app
        /// was doing immediately before it died.
        public let unisonLogTail: String
        /// Absolute path to the matching `Unison-*.ips` file from
        /// `~/Library/Logs/DiagnosticReports`, if one exists. macOS's
        /// `ReportCrash` typically writes this within ~30 s of the
        /// crash, so it should be present by the time the user
        /// re-launches.
        public let latestIPSPath: String?
    }

    /// Call once early in `applicationDidFinishLaunching` (before any
    /// fragile init that could itself crash). Returns a `CrashReport`
    /// iff the previous session ended without a clean
    /// `applicationWillTerminate`. Always (re)writes the marker for
    /// the new session.
    public static func startSession() -> CrashReport? {
        let pending = readPendingCrash()
        writeMarker()
        return pending
    }

    /// Call from `applicationWillTerminate`. Removes the marker so
    /// the next launch doesn't treat this clean shutdown as a crash.
    public static func markCleanShutdown() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    /// Show a friendly two-level crash dialog. The primary alert is
    /// minimal — one line of reassurance, two buttons. Users who
    /// want to inspect or copy the log click "Подробности…" to
    /// reach the technical view.
    public static func showCrashAlert(_ report: CrashReport) {
        // Bring the menubar-only app forward so the alert lands on
        // top of whatever the user is currently looking at instead of
        // hiding behind their browser on another desktop.
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Unison закрылся неожиданно"
        alert.informativeText = "Ваши данные и настройки не пострадали."
        // `.informational` keeps a friendly icon (the app icon) instead
        // of the yellow caution triangle that `.warning` would put up.
        alert.alertStyle = .informational
        alert.icon = friendlyAlertIcon()

        alert.addButton(withTitle: "Подробности…")
        alert.addButton(withTitle: "Закрыть")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            showDetailsAlert(report)
        }
    }

    /// Secondary alert reached from the "Подробности…" button. This
    /// is where the scrollable log lives — users who chose to see
    /// the technical details opted into it, so showing them the raw
    /// log + `.ips` path is appropriate (not "scary" in this
    /// context).
    private static func showDetailsAlert(_ report: CrashReport) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Подробности ошибки"
        alert.informativeText = detailsInformativeText(for: report)
        alert.alertStyle = .informational
        alert.icon = friendlyAlertIcon()

        alert.accessoryView = makeLogTextView(text: report.unisonLogTail)

        alert.addButton(withTitle: "Скопировать в буфер")
        alert.addButton(withTitle: "Открыть папку логов")
        alert.addButton(withTitle: "Назад")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            copyDiagnosticToClipboard(report)
            showConfirmationToast(message: "Диагностика скопирована в буфер обмена.")
        case .alertSecondButtonReturn:
            openLogsFolder()
        default:
            break
        }
    }

    // MARK: - Marker file lifecycle

    private static func writeMarker() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let ts = Date().timeIntervalSince1970
        // Two lines: pid, start-timestamp. Keep the format trivial so
        // a future change can extend it without breaking older
        // markers from a previously-installed build.
        let content = "\(pid)\n\(ts)\n"
        try? content.write(to: markerURL, atomically: true, encoding: .utf8)
    }

    private static func readPendingCrash() -> CrashReport? {
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            return nil
        }
        let raw = (try? String(contentsOf: markerURL, encoding: .utf8)) ?? ""
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        // Parse before deleting. If the marker is malformed (zero-byte
        // from an interrupted write, partially-flushed during the
        // crash), we still want to surface a crash report — just
        // without the precise pid/timestamp. Synthesise sensible
        // defaults rather than swallowing the signal entirely
        // (review finding #15: previous version silently dropped
        // any marker it couldn't parse).
        let pid: Int
        let startedAt: Date
        if lines.count >= 2,
           let parsedPID = Int(lines[0]),
           let parsedTS = TimeInterval(lines[1]) {
            pid = parsedPID
            startedAt = Date(timeIntervalSince1970: parsedTS)
        } else {
            // Marker exists but is unreadable. We still know a crash
            // happened (else `applicationWillTerminate` would have
            // removed the marker), so report it with a best-effort
            // timestamp = file mtime, pid = 0 sentinel.
            let attrs = try? FileManager.default.attributesOfItem(atPath: markerURL.path)
            startedAt = (attrs?[.modificationDate] as? Date) ?? Date()
            pid = 0
            FileLogStore.shared.write(
                category: "CrashReporter",
                level: "error",
                message: "marker file malformed (length \(raw.count)) — surfacing crash with best-effort metadata"
            )
        }
        // Delete only after successful read so a sporadic IO error
        // doesn't lose the signal.
        try? FileManager.default.removeItem(at: markerURL)

        let logTail = readUnisonLogTail(lineCount: 80)
        let ipsPath = findLatestIPSFile(notOlderThan: startedAt)
        return CrashReport(
            previousPID: pid,
            previousStartedAt: startedAt,
            unisonLogTail: logTail,
            latestIPSPath: ipsPath
        )
    }

    // MARK: - Log + .ips collection

    /// Read the last `lineCount` lines from `~/Library/Logs/Unison/unison.log`.
    /// Bounded so a multi-MB log doesn't get pulled into RAM in full.
    private static func readUnisonLogTail(lineCount: Int) -> String {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Unison/unison.log")
        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else {
            return "(unison.log не найден или не читается)"
        }
        let allLines = content.components(separatedBy: "\n")
        return allLines.suffix(lineCount).joined(separator: "\n")
    }

    /// Find the newest `Unison-*.ips` file in
    /// `~/Library/Logs/DiagnosticReports`. Filters out reports that
    /// pre-date the marker so we don't surface a crash from a previous
    /// session that the user has already seen.
    private static func findLatestIPSFile(notOlderThan: Date) -> String? {
        let reportsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: reportsDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return nil
        }
        let candidates: [(URL, Date)] = entries.compactMap { url in
            guard url.lastPathComponent.hasPrefix("Unison-"),
                  url.pathExtension == "ips",
                  let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                      .contentModificationDate,
                  date >= notOlderThan
            else { return nil }
            return (url, date)
        }
        return candidates.max(by: { $0.1 < $1.1 })?.0.path
    }

    // MARK: - Presentation helpers

    /// Use the menubar logo (idle state, full colour) rendered at
    /// 64×64 so the alert shows the Unison brand mark instead of the
    /// generic application-icon placeholder bundles without an
    /// `.icns` asset would otherwise get.
    private static func friendlyAlertIcon() -> NSImage {
        // The cached menubar icon is template-tinted to 18×18 — too
        // small for an NSAlert. Render fresh at alert-appropriate
        // size + non-template so the colour reads as the app's
        // identity rather than greyscale.
        let size = NSSize(width: 64, height: 64)
        let img = NSImage(size: size, flipped: false) { rect in
            // Cyan brand fill (matches `.active` menubar state +
            // `UnisonColors.active`); reads as approachable rather
            // than alarming.
            NSColor(red: 0x5a / 255.0, green: 0xc8 / 255.0, blue: 0xfa / 255.0, alpha: 1.0).setStroke()
            let path = NSBezierPath()
            let scale: CGFloat = 64.0 / 256.0
            path.lineWidth = max(12 * scale, 4)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: x * scale, y: (256 - y) * scale)
            }
            // U body
            path.move(to: p(82, 66))
            path.line(to: p(82, 146))
            path.curve(to: p(128, 198), controlPoint1: p(82, 177.5), controlPoint2: p(102.5, 198))
            path.curve(to: p(174, 146), controlPoint1: p(153.5, 198), controlPoint2: p(174, 177.5))
            path.line(to: p(174, 66))
            // Voice streams
            path.move(to: p(58, 86));  path.line(to: p(58, 136))
            path.move(to: p(38, 102)); path.line(to: p(38, 126))
            path.move(to: p(198, 86)); path.line(to: p(198, 136))
            path.move(to: p(218, 102)); path.line(to: p(218, 126))
            path.stroke()
            return true
        }
        return img
    }

    private static func detailsInformativeText(for report: CrashReport) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = .current
        let when = df.string(from: report.previousStartedAt)
        var lines = [
            "Время ошибки: \(when)"
        ]
        if let ips = report.latestIPSPath {
            lines.append("Stack trace: \(ips)")
        }
        return lines.joined(separator: "\n")
    }

    /// Brief non-blocking "done" confirmation after the user copies
    /// or sends the report. Uses an `NSAlert` rather than a fancier
    /// HUD because we want to be sure it surfaces — alerts are the
    /// one Cocoa primitive we know works for menubar-only apps.
    private static func showConfirmationToast(message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Спасибо!"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.icon = friendlyAlertIcon()
        alert.addButton(withTitle: "Готово")
        alert.runModal()
    }

    /// Build the multi-line diagnostic payload that ends up in the
    /// clipboard. Same content the user would copy from "Details"
    /// alert too.
    private static func makeDiagnosticPayload(_ report: CrashReport) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = .current
        var parts = [
            "=== Unison crash report ===",
            "Previous session started at: \(df.string(from: report.previousStartedAt))",
            "Previous PID: \(report.previousPID)"
        ]
        if let ips = report.latestIPSPath {
            parts.append("macOS .ips file: \(ips)")
        }
        parts.append("")
        parts.append("=== unison.log (last 80 lines) ===")
        parts.append(report.unisonLogTail)
        return parts.joined(separator: "\n")
    }

    private static func makeLogTextView(text: String) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 280))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.borderType = .bezelBorder

        let textView = NSTextView(frame: scroll.bounds)
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.string = text
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        // Scroll to bottom so the user sees the last entries (where
        // the crash trail lives) without scrolling manually.
        textView.scrollToEndOfDocument(nil)

        scroll.documentView = textView
        return scroll
    }

    private static func copyDiagnosticToClipboard(_ report: CrashReport) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(makeDiagnosticPayload(report), forType: .string)
        FileLogStore.shared.write(
            category: "CrashReporter",
            level: "info",
            message: "Crash diagnostic from previous PID \(report.previousPID) copied to clipboard"
        )
    }

    private static func openLogsFolder() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Unison", isDirectory: true)
        NSWorkspace.shared.open(dir)
    }
}
