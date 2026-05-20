import AppKit
import Observation
import SwiftUI
import UnisonDomain
import UnisonUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public let composition = Composition()

    public var statusItem: StatusItemController!
    public var transcriptWindow: TranscriptWindowController!
    public var onboardingWindow: OnboardingWindowController!
    public var settingsWindow: SettingsWindowController!
    public var hotkeyService: HotkeyService!

    private var lastActive = false

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let hotkeys = HotkeyService()
        self.hotkeyService = hotkeys

        // Build the Settings window controller first so we can hand its
        // `show()` method to the popover gear button.
        settingsWindow = SettingsWindowController(
            viewModel: composition.settingsVM,
            onRecordHotkey: { [weak self] kind in
                self?.beginHotkeyRecording(kind)
            },
            onOpenURL: { url in
                NSWorkspace.shared.open(url)
            }
        )

        statusItem = StatusItemController(
            popoverVM: composition.popoverVM,
            onOpenSettings: { [weak self] in
                self?.settingsWindow.show()
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
    }

    public func applicationWillTerminate(_ notification: Notification) {
        hotkeyService?.stop()
        let orch = composition.orchestrator
        Task { @MainActor in await orch.stop() }
    }

    private func observeOrchestratorState() {
        withObservationTracking {
            applyActiveState(composition.orchestrator.state.isActive)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeOrchestratorState() }
        }
    }

    private func applyActiveState(_ isActive: Bool) {
        guard isActive != lastActive else { return }
        lastActive = isActive
        if isActive {
            transcriptWindow.show()
            statusItem.setActiveIcon(true)
        } else {
            transcriptWindow.hide()
            statusItem.setActiveIcon(false)
        }
    }

    // MARK: - Hotkey actions

    /// Toggles the translation session globally. Bound to the
    /// configurable "Старт / стоп" hotkey (default `⌃⌥U`).
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
