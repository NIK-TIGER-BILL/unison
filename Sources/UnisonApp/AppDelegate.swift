import AppKit
import Darwin
import Dispatch
import Observation
import SwiftUI
import UnisonAudio
import UnisonDomain
import UnisonUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public let composition = Composition()

    public var statusItem: StatusItemController!
    public var transcriptWindow: TranscriptWindowController!
    public var onboardingWindow: OnboardingWindowController!
    public var settingsWindow: SettingsWindowController!
    public var helpWindow: HelpWindowController!
    public var diagnosticWindow: DiagnosticWindowController!
    public var historyWindow: MeetingHistoryWindowController!
    public var hotkeyService: HotkeyService!

    /// The last `MenubarState` we pushed to the status item. Cached so
    /// the observer doesn't reapply the same image on every change of
    /// some other observable property in the orchestrator.
    private var lastMenubarState: MenubarState = .idle

    /// Dispatch sources for SIGINT/SIGTERM so the runloop can route the
    /// signal through `NSApp.terminate` (which fires
    /// `applicationWillTerminate`, which calls `orchestrator.stop()`,
    /// which patches the WAV dump header sizes). Without this, `pkill
    /// -INT Unison` just `exit(0)`s the process and the dump file ends
    /// up with placeholder 0xFFFFFFFF sizes — still readable by the
    /// integration test, but malformed for normal players.
    private var signalSources: [DispatchSourceSignal] = []

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Touch the file-log singleton so the boot banner is written
        // before any other component logs. The integration test greps
        // for the banner to confirm the binary it launched is the new
        // one (vs. an SCP-stale copy). All other components pick up
        // the same singleton implicitly through their `UnisonLog` use.
        FileLogStore.shared.write(
            category: "AppDelegate",
            level: "info",
            message: "applicationDidFinishLaunching — pid=\(ProcessInfo.processInfo.processIdentifier)"
        )

        // Crash detection: writes a session marker and surfaces a
        // modal alert if the previous session's marker is still
        // present (i.e. the previous run didn't reach
        // `applicationWillTerminate`). Runs BEFORE any other init so
        // the user can copy diagnostics even if the rest of launch
        // also crashes. See `CrashReporter` for the design.
        let pendingCrash = CrashReporter.startSession()

        installSignalHandlers()

        let hotkeys = HotkeyService()
        self.hotkeyService = hotkeys

        // Build the Settings window controller first so we can hand its
        // `show()` method to the popover gear button.
        settingsWindow = SettingsWindowController(
            viewModel: composition.settingsVM,
            onRecordHotkey: { [weak self] kind in
                self?.beginHotkeyRecording(kind)
            },
            onCancelRecordHotkey: { [weak self] in
                // Clicking the recording chip again cancels — tear the
                // NSEvent monitor down, not just the VM's UI flag.
                self?.hotkeyService.endRecording()
            },
            onOpenURL: { url in
                NSWorkspace.shared.open(url)
            }
        )
        // Closing Settings mid-recording must cancel the recording —
        // otherwise the local monitor keeps swallowing plain typing
        // app-wide and the next combo pressed anywhere silently
        // becomes the new hotkey.
        settingsWindow.onClose = { [weak self] in
            guard let self else { return }
            self.hotkeyService.endRecording()
            self.composition.settingsVM.cancelRecordingHotkey()
        }

        // Help window — same chromeless-glass design as Settings.
        helpWindow = HelpWindowController()

        // Diagnostic window — built before StatusItemController so the
        // context-menu callback can capture it. The collector pulls
        // OSLog entries + device state at the moment `show()` is called,
        // so there's no per-event recomputation cost at init time.
        diagnosticWindow = DiagnosticWindowController(
            collector: DiagnosticCollector(composition: composition)
        )
        historyWindow = MeetingHistoryWindowController(viewModel: composition.meetingHistoryVM)

        statusItem = StatusItemController(
            popoverVM: composition.popoverVM,
            onOpenSettings: { [weak self] in
                self?.settingsWindow.show()
            },
            onShowHelp: { [weak self] in
                self?.helpWindow.show()
            },
            onStartStop: { [weak self] in
                self?.toggleSession()
            },
            onShowTranscript: { [weak self] in
                self?.transcriptWindow.show()
            },
            onShowDiagnostic: { [weak self] in
                self?.diagnosticWindow.show()
            },
            onShowHistory: { [weak self] in
                self?.historyWindow.show()
            },
            onShowAbout: { [weak self] in
                self?.showAbout()
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )

        transcriptWindow = TranscriptWindowController(viewModel: composition.transcriptVM)
        onboardingWindow = OnboardingWindowController(viewModel: composition.onboardingVM)

        // Initial hotkey registration + start listening.
        composition.settingsVM.onHotkeysChanged = { [weak self] start, transcript in
            self?.hotkeyService.updateHotkeys(startStop: start, showTranscript: transcript)
        }
        hotkeys.updateHotkeys(
            startStop: composition.settingsVM.hotkeyStartStop,
            showTranscript: composition.settingsVM.hotkeyShowTranscript
        )
        hotkeys.onStartStop = { [weak self] in
            self?.toggleSession()
        }
        hotkeys.onShowTranscript = { [weak self] in
            self?.transcriptWindow.show()
        }
        hotkeys.start()

        if !composition.onboardingVM.allDone {
            onboardingWindow.show()
        }

        observeOrchestratorState()

        // `UNISON_FORCE_STATE` overrides for the Tart VM screenshot
        // harness. Production launches never set this env var.
        applyForceStateOverrides()

        // Defer the previous-crash alert to the next runloop tick so
        // it surfaces AFTER the windows + status item have rendered
        // (alerts attached to a not-yet-visible app can land behind
        // other windows). Launch finishes uninterrupted; the alert
        // then runs modal inside the async block on that later tick.
        if let report = pendingCrash {
            FileLogStore.shared.write(
                category: "AppDelegate",
                level: "error",
                message: "previous session crashed (pid=\(report.previousPID), started=\(report.previousStartedAt)) — showing crash alert"
            )
            DispatchQueue.main.async {
                CrashReporter.showCrashAlert(report)
            }
        }
    }

    /// Honor `UNISON_FORCE_STATE` so the screenshot harness can land
    /// the app on a specific surface without driving the UI manually:
    /// - `transcript-demo` → pop the transcript window forward (the
    ///   composition layer has already seeded the bubbles).
    /// - `settings-open` → open the Settings window immediately.
    /// - `popover-open` → programmatically expand the menubar popover
    ///   (avoids the fragile AppleScript click path that needs
    ///   Accessibility permission and traverses a non-obvious AX
    ///   hierarchy on notched displays).
    /// - `onboarding-done` → no extra work here; the onboarding gate
    ///   is already cleared by the composition factories.
    private func applyForceStateOverrides() {
        guard let force = UnisonForceState.current else { return }
        switch force {
        case .transcriptDemo:
            transcriptWindow.show()
        case .settingsOpen:
            settingsWindow.show()
        case .popoverOpen:
            // Activate the app first so the popover renders above
            // anything the harness left in front (e.g. a Terminal
            // window from the SSH session host). Defer the actual
            // `showPopover()` by 0.5 s: at this point in
            // `applicationDidFinishLaunching` the status-item button
            // hasn't had its frame laid out yet, and
            // `StatusItemController.showPopover` anchors the panel
            // below `button.bounds` — calling it immediately places
            // the panel at (0,0) on some hosts. A fixed delay (rather
            // than a single async hop) gives AppKit time to position
            // the button even on slow VM hosts.
            NSApp.activate(ignoringOtherApps: true)
            let item = statusItem!
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                item.showPopover()
            }
        case .startTranslation:
            // Integration-test entry point. Defer the start by ~2 s so
            // every subsystem has a chance to wire up (the orchestrator
            // observation tracker is one runloop hop late, the BlackHole
            // 2ch player needs the engine warmed up, etc.). After the
            // delay we tap the same path the popover's "Начать перевод"
            // button hits — modulo the user click — so we exercise the
            // production codepath end-to-end.
            FileLogStore.shared.write(
                category: "AppDelegate",
                level: "info",
                message: "UNISON_FORCE_STATE=start-translation — will auto-start translation in 2s"
            )
            let vm = composition.popoverVM
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                Task { @MainActor in
                    FileLogStore.shared.write(
                        category: "AppDelegate",
                        level: "info",
                        message: "auto-start: invoking popoverVM.start()"
                    )
                    await vm.start()
                }
            }
        case .startStopStart:
            // Lifecycle scenario: full stop-restart cycle. The interesting
            // failure modes this catches:
            //   - Audio engine that didn't release BlackHole 2ch device,
            //     so the second start() can't bind to it.
            //   - WS that wasn't fully closed, so the second connect
            //     races against the lingering one.
            //   - Tasks from session #1 that survive into session #2 and
            //     interfere with the new pipeline (e.g. old micCapture
            //     iterator still draining into the closed-but-not-nil
            //     stream).
            //   - WAV dump file: confirm it captures audio from BOTH
            //     sessions (the dump is re-opened on each first frame
            //     and appended; the file is closed on app terminate, so
            //     the WAV should span both translation bursts).
            FileLogStore.shared.write(
                category: "AppDelegate",
                level: "info",
                message: "UNISON_FORCE_STATE=start-stop-start — start@2s, stop@10s, start@14s"
            )
            scheduleAutoStart(at: 2.0, tag: "start#1")
            scheduleAutoStop(at: 10.0, tag: "stop#1")
            scheduleAutoStart(at: 14.0, tag: "start#2")
        case .onboardingDone:
            break
        }
    }

    /// Helper for force-state lifecycle scenarios. Logs at fire time so
    /// the integration test's assertion regex can grep for the tag.
    private func scheduleAutoStart(at delay: TimeInterval, tag: String) {
        let vm = composition.popoverVM
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Task { @MainActor in
                FileLogStore.shared.write(
                    category: "AppDelegate",
                    level: "info",
                    message: "auto-start [\(tag)]: invoking popoverVM.start()"
                )
                await vm.start()
            }
        }
    }

    private func scheduleAutoStop(at delay: TimeInterval, tag: String) {
        let vm = composition.popoverVM
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Task { @MainActor in
                FileLogStore.shared.write(
                    category: "AppDelegate",
                    level: "info",
                    message: "auto-stop [\(tag)]: invoking popoverVM.stop()"
                )
                await vm.stop()
            }
        }
    }

    /// Re-probe environment state every time the app comes forward.
    /// Catches the case where the user task-switched out to System
    /// Settings (to grant mic permission or install something),
    /// granted it, and switched back — the on-screen windows stayed
    /// open the whole time, so neither `show()` (only called on
    /// initial open) nor the CoreAudio listener (no event for TCC
    /// grants) fires. Without this the onboarding card keeps showing
    /// "Микрофон не разрешён" until the user clicks somewhere that
    /// triggers a refresh.
    public func applicationDidBecomeActive(_ notification: Notification) {
        composition.onboardingVM.refresh()
        composition.popoverVM.refreshEnvironment()
        composition.settingsVM.refreshDeviceList()
        composition.settingsVM.refreshBlackHoleStatus()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        FileLogStore.shared.write(
            category: "AppDelegate",
            level: "info",
            message: "applicationWillTerminate — graceful shutdown"
        )
        hotkeyService?.stop()

        // Archive an active-at-quit session synchronously — applicationWillTerminate
        // intentionally skips the async orchestrator.stop() (deadlock), so the
        // Part 1 stop()-archive hook never fires on quit.
        composition.orchestrator.archiveActiveSession()

        // Synchronous audio teardown FIRST — this is what patches the
        // WAV dump header sizes (if `UNISON_DUMP_OUTPUT_WAV` was set).
        // We deliberately call the player + mixer directly instead of
        // going through `await orchestrator.stop()`: applicationWillTerminate
        // is synchronous on the main actor, and a `Task { @MainActor in
        // await orch.stop() }` deadlocks because semaphore.wait blocks
        // main while the Task waits for main to free up.
        composition.virtualMicPlayer.stop()
        composition.outputMixer.stop()
        // The orchestrator-side WireDumpers (UNISON_DUMP_WIRE_WAV /
        // UNISON_DUMP_SENT_WAV) are closed by `orchestrator.stop()`,
        // but we skip that here for the deadlock reason above. Close
        // them directly so quit-during-session leaves the WAV header
        // patched (data chunk size at 0xFFFF_FFFF wraps badly in some
        // players). No-op when env vars aren't set.
        WireDumper.shared.close()
        WireDumper.sent.close()

        // Drop the crash marker as the LAST thing so a partial
        // teardown that itself crashes is still surfaced on the next
        // launch (the marker is only removed when shutdown is truly
        // complete). See `CrashReporter` for the design rationale.
        CrashReporter.markCleanShutdown()
    }

    /// Routes SIGINT / SIGTERM through `NSApp.terminate(_:)` so the full
    /// shutdown chain runs (applicationWillTerminate → orchestrator.stop
    /// → BlackHole2chPlayer.stop → WAV header patch). Default behaviour
    /// of SIGINT in a Cocoa app is `exit(0)` from the kernel signal
    /// handler — no Swift code runs.
    private func installSignalHandlers() {
        // Ignore the default disposition so the kernel doesn't kill us
        // before the dispatch source picks up the signal.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        for sig in [SIGINT, SIGTERM] {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                FileLogStore.shared.write(
                    category: "AppDelegate",
                    level: "info",
                    message: "received signal \(sig) — invoking NSApp.terminate"
                )
                NSApp.terminate(nil)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: - Orchestrator → menubar state

    /// Re-entrant tracker for `withObservationTracking`. Re-arms itself
    /// after each emission so the menubar icon + transcript window stay
    /// in sync with `SessionState` transitions.
    private func observeOrchestratorState() {
        withObservationTracking {
            let state = composition.orchestrator.state
            applyOrchestratorState(state)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeOrchestratorState() }
        }
    }

    /// Map `SessionState` → `MenubarState` and side-effects (show/hide
    /// the transcript window when starting/stopping).
    private func applyOrchestratorState(_ state: SessionState) {
        let target: MenubarState
        switch state {
        case .idle:
            target = .idle
        case .connecting, .translating:
            target = .active
        case .paused:
            // Network-level pause: audio is actually stopped, so show
            // the muted U-only icon + "на паузе" status instead of
            // pretending the session is live.
            target = .paused
        case .reconnecting:
            // Treat reconnect as a degraded active for v1 — the design
            // doesn't define a distinct "warn" status icon and the
            // pulsing logo communicates the right "still working" vibe.
            target = .active
        case .error:
            target = .error
        }

        // Transcript visibility tracks `isActive`. Only act on
        // transitions to avoid flickering when other observed state
        // changes without flipping active. `.paused` counts as active
        // here (`SessionState.paused.isActive == true`) so the window
        // doesn't churn on pause/resume.
        let wasActive = lastMenubarState == .active || lastMenubarState == .paused
        let isActive = state.isActive
        if isActive != wasActive {
            if isActive {
                transcriptWindow.show()
            } else {
                transcriptWindow.hide()
            }
            // «Скрывать меню при старте сессии»: drop the menubar icon
            // while a session runs (hotkeys + transcript pill keep the
            // session controllable), restore it the moment the session
            // ends. The toggle used to be a persisted no-op.
            if composition.settingsVM.hideMenuOnSession {
                statusItem.setStatusItemVisible(!isActive)
            } else if !isActive {
                // Defensive: if the toggle was flipped off mid-session,
                // never leave the icon hidden after the session ends.
                statusItem.setStatusItemVisible(true)
            }
        }

        // Push the icon update (the controller diffs internally).
        statusItem.state = target
        lastMenubarState = target
    }

    // MARK: - Context menu callbacks

    /// Toggles the translation session globally. Bound to the
    /// configurable "Старт / стоп" hotkey (default `⌃⌥U`) and to the
    /// context-menu "Начать перевод" / "Остановить перевод" item.
    private func toggleSession() {
        let vm = composition.popoverVM
        Task { @MainActor in
            if vm.state.isActive {
                await vm.stop()
            } else if vm.canStartStrict {
                await vm.start()
            }
        }
    }

    /// Minimal "About" sheet. Uses a stock `NSAlert` rather than a
    /// custom NSWindow — the design ships an About mock but it's listed
    /// as out-of-scope in `docs/superpowers/plans/2026-05-20-ui-integration.md`
    /// §4 "Out of Scope". We still want a working entry point from the
    /// context menu, so this gives users version info and a stable
    /// fallback. Replace with a glass About window when scope allows.
    private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Unison"
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        alert.informativeText = """
        Версия \(shortVersion) · сборка \(build)

        Перевод речи в реальном времени для звонков и встреч.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Готово")
        // Bring app forward so the modal isn't lost behind a meeting
        // window when launched from the menubar.
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Entry point invoked by `SettingsView` (via the controller's
    /// `onRecordHotkey` closure). Starts a local-event monitor that
    /// captures the next valid combo and writes it back to the VM.
    private func beginHotkeyRecording(_ kind: HotkeyKind) {
        let vm = composition.settingsVM
        hotkeyService.beginRecording(
            onCapture: { hotkey in
                vm.updateHotkey(kind, hotkey)
            },
            onCancel: {
                vm.cancelRecordingHotkey()
            }
        )
    }
}
