import SwiftUI
import Testing
@testable import UnisonUI

/// Visual snapshot of the `DiagnosticSheet`. Locks in the layout of the
/// dialog the user opens via "Подробности…" / context-menu "Диагностика…".
@MainActor
struct DiagnosticSheetSnapshotTests {

    private func sampleInfo() -> DiagnosticInfo {
        DiagnosticInfo(
            appVersion: "1.0.0 (build 42)",
            macOSVersion: "26.0 (25A111)",
            device: "MacBookPro18,3",
            sessionState: "error(.networkLost)",
            micDevice: "AirPods Pro Max",
            speakerDevice: "AirPods Pro Max",
            blackHole2ch: "present",
            openAIKeyStatus: "present (length 51)",
            recentErrors: [
                "12:37:27.708  [Orchestrator] handleStreamFailure speaker=peer error=networkLost",
                "12:37:28.981  [Orchestrator] handleStreamFailure speaker=me error=networkLost",
            ],
            recentLogLines: [
                "12:37:26.453  [PopoverVM] start() — mode=call, pair=ru→en",
                "12:37:26.700  [Orchestrator] state .idle → .connecting(mode: call)",
                "12:37:27.653  [Orchestrator] peer stream connected",
                "12:37:27.702  [Orchestrator] connecting me stream (target=en)",
                "12:37:27.708  [Orchestrator] handleStreamFailure speaker=peer error=networkLost",
                "12:37:28.891  [Orchestrator] me stream connected",
                "12:37:28.974  [Orchestrator] state .connecting → .translating",
                "12:37:28.981  [Orchestrator] handleStreamFailure speaker=me error=networkLost",
            ],
            collectedAt: Date(timeIntervalSince1970: 1_716_374_257)
        )
    }

    /// Dark backdrop to mimic the borderless window background — the
    /// glass material needs something dark behind it to register.
    private func darkFloor<V: View>(_ view: V, size: CGSize) -> some View {
        ZStack {
            Color.black
            view
        }
        .frame(width: size.width, height: size.height)
    }

    @Test func diagnosticSheet_default() throws {
        let size = CGSize(width: 640, height: 640)
        let sheet = DiagnosticSheet(
            info: sampleInfo(),
            onCopy: {},
            onClose: {}
        )
        snap(darkFloor(sheet, size: size), size: size)
    }

    @Test func diagnosticSheet_emptyLogs() throws {
        let size = CGSize(width: 640, height: 640)
        let info = DiagnosticInfo(
            appVersion: "1.0.0 (build 42)",
            macOSVersion: "26.0 (25A111)",
            device: "MacBookPro18,3",
            sessionState: "idle",
            micDevice: nil,
            speakerDevice: nil,
            blackHole2ch: "present",
            openAIKeyStatus: "empty",
            recentErrors: [],
            recentLogLines: [],
            collectedAt: Date(timeIntervalSince1970: 1_716_374_257)
        )
        let sheet = DiagnosticSheet(info: info, onCopy: {}, onClose: {})
        snap(darkFloor(sheet, size: size), size: size)
    }
}

/// Unit-level checks of `DiagnosticInfo`. These don't render any view —
/// they verify the plain-text dump is shaped how the bug-report flow
/// expects.
@MainActor
struct DiagnosticInfoTests {
    @Test func plainText_includesEveryField() {
        let info = DiagnosticInfo(
            appVersion: "1.0.0 (build 42)",
            macOSVersion: "26.0 (25A111)",
            device: "MacBookPro18,3",
            sessionState: "error(.apiKeyInvalid)",
            micDevice: "AirPods",
            speakerDevice: "MacBook Pro Speakers",
            blackHole2ch: "present",
            openAIKeyStatus: "present (length 51)",
            recentErrors: ["12:37:27 boom"],
            recentLogLines: ["12:37:27 hello"]
        )
        let txt = info.asPlainText
        #expect(txt.contains("1.0.0 (build 42)"))
        #expect(txt.contains("MacBookPro18,3"))
        #expect(txt.contains("error(.apiKeyInvalid)"))
        #expect(txt.contains("AirPods"))
        #expect(txt.contains("BlackHole 2ch: present"))
        #expect(txt.contains("present (length 51)"))
        #expect(txt.contains("12:37:27 boom"))
        #expect(txt.contains("12:37:27 hello"))
    }

    @Test func plainText_neverContainsActualKey() {
        let info = DiagnosticInfo(
            appVersion: "1.0.0 (build 42)",
            macOSVersion: "26.0",
            device: "Mac",
            sessionState: "idle",
            blackHole2ch: "present",
            openAIKeyStatus: "present (length 51)"
        )
        let txt = info.asPlainText
        // Any "sk-" prefix is a strong signal someone leaked a key into
        // the dump. The status string explicitly avoids that — this
        // catches a regression where the key value would slip in.
        #expect(!txt.contains("sk-"))
    }

    @Test func plainText_emptyLogsRendersPlaceholder() {
        let info = DiagnosticInfo(
            appVersion: "1.0.0",
            macOSVersion: "26.0",
            device: "Mac",
            sessionState: "idle",
            blackHole2ch: "present",
            openAIKeyStatus: "empty",
            recentLogLines: []
        )
        let txt = info.asPlainText
        #expect(txt.contains("(нет записей)"))
    }
}
