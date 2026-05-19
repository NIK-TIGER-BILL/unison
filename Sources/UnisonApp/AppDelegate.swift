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

    private var lastActive = false

    public func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(popoverVM: composition.popoverVM)
        transcriptWindow = TranscriptWindowController(viewModel: composition.transcriptVM)
        onboardingWindow = OnboardingWindowController(viewModel: composition.onboardingVM)

        if !composition.onboardingVM.allDone {
            onboardingWindow.show()
        }

        observeOrchestratorState()
    }

    public func applicationWillTerminate(_ notification: Notification) {
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
}
