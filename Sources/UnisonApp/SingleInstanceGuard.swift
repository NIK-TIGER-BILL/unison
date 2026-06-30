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
    ///
    /// The wait is a bounded **main-thread stall** at launch (the caller
    /// runs in `applicationDidFinishLaunching`): in the common case the
    /// sibling catches `SIGTERM` and dies in well under one tick, but a
    /// wedged straggler freezes this launch for the full `waitBudget`.
    /// Keep the budget small.
    ///
    /// `Bundle.main.bundleIdentifier` is nil under `swift run` (no bundle);
    /// the literal fallback is then inert because such processes report a
    /// nil bundle identifier in `runningApplications` and the arbiter
    /// filters them out anyway.
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

        // `> 0` is guaranteed by the arbiter; re-assert it here because
        // `kill(-1/0, …)` would be catastrophic (whole session / process
        // group).
        for pid in victims where pid > 0 { kill(pid, SIGTERM) }
        waitForExit(of: victims, bundleIdentifier: bundleIdentifier, budget: waitBudget)
        return victims
    }

    /// Poll `kill(pid, 0)` (rc 0 ⇒ the process still exists — the same
    /// liveness probe `CrashReporter` uses) until every PID is gone or
    /// the budget expires, then `SIGKILL` anything still alive.
    ///
    /// Before the `SIGKILL` we re-confirm the PID still maps to *our*
    /// bundle id: the budget gives the kernel time to recycle a freed PID
    /// onto an unrelated new process, and a stray `SIGKILL` is
    /// unrecoverable.
    private static func waitForExit(of pids: [Int32], bundleIdentifier: String, budget: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: budget)
        while Date() < deadline, pids.contains(where: { $0 > 0 && kill($0, 0) == 0 }) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        for pid in pids where pid > 0 && kill(pid, 0) == 0 {
            guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleIdentifier else {
                continue  // PID recycled onto a different (or non-app) process — leave it alone.
            }
            kill(pid, SIGKILL)
        }
    }
}
