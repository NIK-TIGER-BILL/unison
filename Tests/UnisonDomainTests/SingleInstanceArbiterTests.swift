import Testing
@testable import UnisonDomain

private let bundleID = "com.unison.app"

private func instance(_ pid: Int32, _ bundle: String?) -> SingleInstanceArbiter.Instance {
    SingleInstanceArbiter.Instance(processIdentifier: pid, bundleIdentifier: bundle)
}

@Test func instancesToReplace_onlySelfRunning_returnsEmpty() {
    let result = SingleInstanceArbiter.instancesToReplace(
        myProcessIdentifier: 100,
        myBundleIdentifier: bundleID,
        running: [instance(100, bundleID)]
    )
    #expect(result.isEmpty)
}

@Test func instancesToReplace_onePriorInstance_returnsItsPID() {
    let result = SingleInstanceArbiter.instancesToReplace(
        myProcessIdentifier: 100,
        myBundleIdentifier: bundleID,
        running: [instance(100, bundleID), instance(42, bundleID)]
    )
    #expect(result == [42])
}

@Test func instancesToReplace_ignoresForeignAndNilBundleIDs() {
    // The full NSWorkspace roster is mostly other apps (Finder, Dock,
    // …) and helper processes with a nil bundle identifier. None of
    // those are ours, so none may be terminated.
    let result = SingleInstanceArbiter.instancesToReplace(
        myProcessIdentifier: 100,
        myBundleIdentifier: bundleID,
        running: [
            instance(100, bundleID),
            instance(7, "com.apple.finder"),
            instance(8, nil)
        ]
    )
    #expect(result.isEmpty)
}

@Test func instancesToReplace_multiplePriorInstances_returnsAll() {
    let result = SingleInstanceArbiter.instancesToReplace(
        myProcessIdentifier: 100,
        myBundleIdentifier: bundleID,
        running: [instance(100, bundleID), instance(42, bundleID), instance(43, bundleID)]
    )
    #expect(Set(result) == [42, 43])
}

@Test func instancesToReplace_excludesNonPositivePIDs() {
    // `NSRunningApplication.processIdentifier` is -1 for an app that has
    // terminated or has not finished launching. A same-bundle-id sibling
    // in that state must NEVER become a victim: `kill(-1, …)` signals
    // every process the user can signal and `kill(0, …)` signals our
    // whole process group. The guard exists to race exactly such
    // launching/dying siblings, so this is not hypothetical.
    let result = SingleInstanceArbiter.instancesToReplace(
        myProcessIdentifier: 100,
        myBundleIdentifier: bundleID,
        running: [
            instance(100, bundleID),
            instance(-1, bundleID),
            instance(0, bundleID),
            instance(42, bundleID)
        ]
    )
    #expect(result == [42])
}

@Test func instancesToReplace_neverIncludesOwnPID() {
    // Defensive: even if our own PID appears more than once in the
    // snapshot, the new instance must never target itself.
    let result = SingleInstanceArbiter.instancesToReplace(
        myProcessIdentifier: 100,
        myBundleIdentifier: bundleID,
        running: [instance(100, bundleID), instance(100, bundleID)]
    )
    #expect(result.isEmpty)
}
