import Foundation
import os
import OSLog
import UnisonDomain
import UnisonUI

/// Builds a `DiagnosticInfo` snapshot at the moment the user opens the
/// diagnostic dialog. Everything here is one-shot — there's no background
/// streaming. The expensive part (`OSLogStore.getEntries(...)`) typically
/// takes 100–400 ms on a recent Mac for a 60-second window.
///
/// Privacy contract enforced here:
/// - The OpenAI key is read from the keychain but **never** included in
///   the returned snapshot — only its presence + length.
/// - Log entries are filtered to subsystem `com.unison.app` so we don't
///   accidentally include other apps' logs (mail, calendar, etc.).
@MainActor
public final class DiagnosticCollector {
    private let composition: Composition
    /// Window of unified log to capture, anchored to the present moment.
    private let lookbackSeconds: TimeInterval

    public init(composition: Composition, lookbackSeconds: TimeInterval = 60) {
        self.composition = composition
        self.lookbackSeconds = lookbackSeconds
    }

    /// Build a fresh snapshot. Synchronous because it's quick and the
    /// dialog blocks input anyway.
    public func collect() -> DiagnosticInfo {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let appVersion = "\(shortVersion) (build \(build))"

        let macOSVersion = Self.macOSVersionString()
        let device = Self.hardwareModel()
        let sessionState = String(describing: composition.orchestrator.state)
        let registry = composition.registry
        let popVM = composition.popoverVM
        let micDevice = Self.deviceName(uid: popVM.settings.inputDeviceUID,
                                        candidates: registry.availableInputDevices())
        let speakerDevice = Self.deviceName(uid: popVM.settings.outputDeviceUID,
                                            candidates: registry.availableOutputDevices())
        let bh2 = registry.findBlackHole2ch() != nil ? "present" : "missing"

        // Presence + length only — never the key itself.
        // Use the active model from popoverVM.settings (the last-persisted
        // settings are mirrored onto the popover VM by SettingsViewModel.onChange).
        let openAIKeyStatus: String = {
            let activeModel = composition.popoverVM.settings.translationModel
            if let k = composition.keychain.loadAPIKey(for: activeModel), !k.isEmpty {
                return "\(activeModel.rawValue) present (length \(k.count))"
            }
            return "\(activeModel.rawValue) empty"
        }()

        let allLines = Self.readRecentLogLines(lookback: lookbackSeconds)
        let recentErrors = allLines.filter { Self.looksLikeError($0) }.suffix(20).map { $0 }

        return DiagnosticInfo(
            appVersion: appVersion,
            macOSVersion: macOSVersion,
            device: device,
            sessionState: sessionState,
            micDevice: micDevice,
            speakerDevice: speakerDevice,
            blackHole2ch: bh2,
            openAIKeyStatus: openAIKeyStatus,
            connectivityHealth: composition.orchestrator.connectivityHealth,
            meStreamHealth: composition.orchestrator.streamHealth(for: .me),
            peerStreamHealth: composition.orchestrator.streamHealth(for: .peer),
            recentErrors: Array(recentErrors),
            recentLogLines: allLines,
            collectedAt: Date()
        )
    }

    // MARK: - Helpers

    /// `"14.5 (23F79)"` from `ProcessInfo`.
    static func macOSVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        // `operatingSystemVersionString` is human-readable ("Version
        // 14.5 (Build 23F79)"); we slice the build number from it.
        let raw = ProcessInfo.processInfo.operatingSystemVersionString
        // Try to extract the "(Build XXX)" portion
        if let openParen = raw.firstIndex(of: "("),
           let closeParen = raw.lastIndex(of: ")") {
            let inside = raw[raw.index(after: openParen)..<closeParen]
                .replacingOccurrences(of: "Build ", with: "")
            return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion) (\(inside))"
        }
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Read the `hw.model` sysctl value (e.g. `"MacBookPro18,3"`).
    /// Falls back to `"unknown"` on any failure.
    static func hardwareModel() -> String {
        var size: Int = 0
        if sysctlbyname("hw.model", nil, &size, nil, 0) != 0 || size == 0 {
            return "unknown"
        }
        var buf = [UInt8](repeating: 0, count: size)
        if sysctlbyname("hw.model", &buf, &size, nil, 0) != 0 {
            return "unknown"
        }
        // Trim the trailing null terminator before decoding so the
        // resulting String doesn't end with a literal NUL byte.
        if let nullIdx = buf.firstIndex(of: 0) {
            buf.removeSubrange(nullIdx..<buf.count)
        }
        return String(decoding: buf, as: UTF8.self)
    }

    /// Look up the friendly name of an audio device by UID. Returns
    /// `nil` for "system default" (no UID stored).
    static func deviceName(uid: String?, candidates: [AudioDevice]) -> String? {
        guard let uid else { return nil }
        return candidates.first(where: { $0.uid == uid })?.name ?? "<\(uid)>"
    }

    /// Pull entries from the unified log store filtered to subsystem
    /// `com.unison.app` over the last `lookback` seconds. Returns an
    /// array of `"HH:MM:SS.mmm  [category] message"` strings.
    ///
    /// Never throws upward — if `OSLogStore` can't be opened (sandboxed
    /// builds without `com.apple.developer.diagnostic-store` would hit
    /// this), we return an empty array and let the dialog show the
    /// "no entries" placeholder.
    static func readRecentLogLines(lookback: TimeInterval) -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let cutoff = Date().addingTimeInterval(-lookback)
            let position = store.position(date: cutoff)
            let entries = try store.getEntries(at: position)

            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss.SSS"
            df.locale = Locale(identifier: "en_US_POSIX")

            var lines: [String] = []
            for entry in entries {
                guard let log = entry as? OSLogEntryLog else { continue }
                // Strict subsystem filter — never include other apps'
                // logs in a snapshot we're handing the user to paste.
                guard log.subsystem == "com.unison.app" else { continue }
                let stamp = df.string(from: log.date)
                let category = log.category.isEmpty ? "" : "[\(log.category)] "
                lines.append("\(stamp)  \(category)\(log.composedMessage)")
            }
            // Cap so a long-running session with thousands of log lines
            // doesn't push the dialog past its 60s window of usefulness.
            return Array(lines.suffix(400))
        } catch {
            return []
        }
    }

    /// Heuristic — pick out log lines that look like errors so we can
    /// surface them in the "Recent errors" section. Anything with the
    /// word `error`, `failed`, or `→ .error(` is fair game.
    static func looksLikeError(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.contains("error")
            || l.contains("failed")
            || l.contains("→ .error(")
            || l.contains("handlestreamfailure")
    }
}
