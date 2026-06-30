import AppKit
import Darwin
import Foundation
import UnisonDomain

/// Enforces "one live Unison" at launch, using the `SingleInstanceArbiter`
/// policy. See that type for *why* this is needed (LSUIElement +
/// direct-binary dev launches bypass Launch Services' instance
/// coalescing, so a rebuild-and-run leaves two menubar icons).
@MainActor
enum SingleInstanceGuard {
    /// Terminate every other running instance that shares our bundle
    /// identifier and wait (bounded) for it to exit, so the new process
    /// becomes the sole menubar presence. Returns the PIDs it asked to
    /// terminate (empty when we're already the only instance).
    ///
    /// We signal the old instances with `kill(2)` rather than
    /// `NSRunningApplication.terminate()`: the latter sends a "quit"
    /// Apple event that requires Automation (TCC) permission a local dev
    /// build doesn't have, so it silently no-ops (verified in the Tahoe
    /// VM — `terminate()`/`forceTerminate()` left the old instance alive).
    ///
    /// `SIGTERM` first: the old instance's signal handler
    /// (`AppDelegate.installSignalHandlers`) turns it into
    /// `NSApp.terminate(_:)`, so it shuts down gracefully (audio teardown
    /// + crash-marker cleanup). A wedged straggler — e.g. stuck in
    /// CoreAudio HAL teardown — gets `SIGKILL` once the wait budget
    /// expires, so a hung old build can't keep its icon on screen.
    @discardableResult
    static func replaceOtherInstances(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.unison.app",
        waitBudget: TimeInterval = 2.0
    ) -> [Int32] {
        let snapshot = NSWorkspace.shared.runningApplications.map {
            SingleInstanceArbiter.Instance(
                processIdentifier: $0.processIdentifier,
                bundleIdentifier: $0.bundleIdentifier
            )
        }
        let victims = SingleInstanceArbiter.instancesToReplace(
            myProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            myBundleIdentifier: bundleIdentifier,
            running: snapshot
        )
        guard !victims.isEmpty else { return [] }

        for pid in victims { kill(pid, SIGTERM) }
        waitForExit(of: victims, budget: waitBudget)
        return victims
    }

    /// Poll `kill(pid, 0)` (rc 0 ⇒ the process still exists — the same
    /// liveness probe `CrashReporter` uses) until every PID is gone or
    /// the budget expires, then `SIGKILL` anything still alive.
    private static func waitForExit(of pids: [Int32], budget: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: budget)
        while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        for pid in pids where kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
    }
}
