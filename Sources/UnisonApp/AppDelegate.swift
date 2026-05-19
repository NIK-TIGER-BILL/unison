import AppKit
import SwiftUI
import UnisonDomain
import UnisonUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public let composition = Composition()

    public var statusItem: StatusItemController!
    public var transcriptWindow: TranscriptWindowController!
    public var onboardingWindow: OnboardingWindowController!

    private var stateObserveTask: Task<Void, Never>?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(popoverVM: composition.popoverVM)
        transcriptWindow = TranscriptWindowController(viewModel: composition.transcriptVM)
        onboardingWindow = OnboardingWindowController(viewModel: composition.onboardingVM)

        if !composition.onboardingVM.allDone {
            onboardingWindow.show()
        }

        let orch = composition.orchestrator
        let transcript = transcriptWindow!
        let status = statusItem!
        stateObserveTask = Task { @MainActor in
            var lastActive = false
            while !Task.isCancelled {
                let isActive = orch.state.isActive
                if isActive != lastActive {
                    if isActive {
                        transcript.show()
                        status.setActiveIcon(true)
                    } else {
                        transcript.hide()
                        status.setActiveIcon(false)
                    }
                    lastActive = isActive
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        stateObserveTask?.cancel()
        let orch = composition.orchestrator
        Task { @MainActor in await orch.stop() }
    }
}
