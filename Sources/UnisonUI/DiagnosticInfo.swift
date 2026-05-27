import Foundation
import UnisonDomain

/// Snapshot of everything we want a user to be able to send when they
/// file a bug. Built by `DiagnosticCollector` (in `UnisonApp`) and rendered
/// by `DiagnosticSheet`.
///
/// Privacy contract:
/// - **Never** include the actual OpenAI API key — only its presence + length.
/// - **Never** include user identifiers (email, hostname, anything that
///   could deanonymize the user).
/// - Recent log lines come from `OSLogStore` filtered to subsystem
///   `com.unison.app` only — system-wide logs are explicitly out of scope.
public struct DiagnosticInfo: Sendable, Equatable {
    /// e.g. `"1.0.0 (build 42)"`.
    public let appVersion: String
    /// e.g. `"14.5 (23F79)"`.
    public let macOSVersion: String
    /// Hardware model identifier — e.g. `"MacBookPro18,3"`.
    public let device: String
    /// String describing the current `SessionState` — e.g.
    /// `"error(.networkLost)"`.
    public let sessionState: String
    /// Currently-selected microphone device name, if any.
    public let micDevice: String?
    /// Currently-selected speaker / output device name, if any.
    public let speakerDevice: String?
    /// `"present"` or `"missing"`.
    public let blackHole2ch: String
    /// `"present"` or `"missing"`.
    public let blackHole16ch: String
    /// e.g. `"present (length 51)"` or `"empty"` — never the key value.
    public let openAIKeyStatus: String
    /// Aggregate connectivity health across streams.
    public let connectivityHealth: ConnectivityHealth
    /// Per-stream health for the "me" (user's audio) stream. Nil if not active
    /// (e.g. in .listen mode).
    public let meStreamHealth: ConnectivityHealth?
    /// Per-stream health for the "peer" (other participant's audio) stream. Nil
    /// if not active (e.g. in .test mode).
    public let peerStreamHealth: ConnectivityHealth?
    /// Most-recent few `SessionState` error transitions, with timestamps.
    /// Empty array is fine — represents "no errors seen recently".
    public let recentErrors: [String]
    /// Last ~60 seconds of log lines from subsystem `com.unison.app`.
    public let recentLogLines: [String]
    /// Stamped at collection time so the resulting plain-text dump has a
    /// stable "collected at" header.
    public let collectedAt: Date

    public init(
        appVersion: String,
        macOSVersion: String,
        device: String,
        sessionState: String,
        micDevice: String? = nil,
        speakerDevice: String? = nil,
        blackHole2ch: String,
        blackHole16ch: String,
        openAIKeyStatus: String,
        connectivityHealth: ConnectivityHealth = .healthy,
        meStreamHealth: ConnectivityHealth? = nil,
        peerStreamHealth: ConnectivityHealth? = nil,
        recentErrors: [String] = [],
        recentLogLines: [String] = [],
        collectedAt: Date = Date()
    ) {
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
        self.device = device
        self.sessionState = sessionState
        self.micDevice = micDevice
        self.speakerDevice = speakerDevice
        self.blackHole2ch = blackHole2ch
        self.blackHole16ch = blackHole16ch
        self.openAIKeyStatus = openAIKeyStatus
        self.connectivityHealth = connectivityHealth
        self.meStreamHealth = meStreamHealth
        self.peerStreamHealth = peerStreamHealth
        self.recentErrors = recentErrors
        self.recentLogLines = recentLogLines
        self.collectedAt = collectedAt
    }

    // MARK: - View helpers

    /// Russian-language one-liners for the "Состояние" section. Pure
    /// projection of properties — `DiagnosticSheet` renders these
    /// without any further translation.
    public var statusLines: [String] {
        [
            "Сессия: \(sessionState)",
            "Микрофон: \(micDevice ?? "по умолчанию")",
            "Аудио-выход: \(speakerDevice ?? "по умолчанию")",
            "BlackHole 2ch: \(blackHole2ch)",
            "BlackHole 16ch: \(blackHole16ch)",
            "OpenAI ключ: \(openAIKeyStatus)"
        ]
    }

    /// Russian-language one-liners for the "Система" section.
    public var systemLines: [String] {
        [
            "Версия: \(appVersion)",
            "macOS: \(macOSVersion)",
            "Устройство: \(device)"
        ]
    }

    // MARK: - Plain-text serialization

    /// Render the full diagnostic snapshot as a plain-text block suitable
    /// for copy/paste into a bug report. Stable structure across versions
    /// — adding fields appends, never reorders.
    public var asPlainText: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let stamp = f.string(from: collectedAt)
        var out: [String] = []
        out.append("Unison Diagnostic — \(stamp)")
        out.append("")
        out.append("System")
        for line in systemLines { out.append("  \(line)") }
        out.append("")
        out.append("State")
        for line in statusLines { out.append("  \(line)") }
        if !recentErrors.isEmpty {
            out.append("")
            out.append("Recent errors")
            for line in recentErrors { out.append("  \(line)") }
        }
        out.append("")
        out.append("Logs (subsystem com.unison.app, last 60s)")
        if recentLogLines.isEmpty {
            out.append("  (нет записей)")
        } else {
            for line in recentLogLines { out.append("  \(line)") }
        }
        return out.joined(separator: "\n")
    }
}
