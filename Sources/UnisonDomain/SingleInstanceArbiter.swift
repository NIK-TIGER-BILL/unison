/// Decides which already-running instances a freshly-launched instance
/// should replace. Pure policy — no AppKit — so the "new replaces old"
/// rule is unit-tested independently of `NSRunningApplication`.
///
/// **Why a guard is needed.** Unison is `LSUIElement` (menubar-only, no
/// Dock tile), and dev builds are launched by exec'ing the binary
/// directly — which bypasses Launch Services' usual one-instance
/// coalescing. So a rebuild-and-run otherwise leaves the previous build
/// running beside the new one: two menubar icons. The AppKit shim
/// (`SingleInstanceGuard`) maps `NSWorkspace.runningApplications` into
/// `Instance` values, asks this arbiter which to terminate, and kills
/// them — "new replaces old".
public enum SingleInstanceArbiter {
    /// One running application, reduced to just what the policy needs.
    public struct Instance: Equatable, Sendable {
        public let processIdentifier: Int32
        public let bundleIdentifier: String?

        public init(processIdentifier: Int32, bundleIdentifier: String?) {
            self.processIdentifier = processIdentifier
            self.bundleIdentifier = bundleIdentifier
        }
    }

    /// Every *other* running instance that shares our bundle identifier
    /// is a stale copy to terminate. Our own process (matched by PID) is
    /// never included, and apps with a different — or absent — bundle
    /// identifier are left alone.
    public static func instancesToReplace(
        myProcessIdentifier: Int32,
        myBundleIdentifier: String,
        running: [Instance]
    ) -> [Int32] {
        running
            .filter { $0.bundleIdentifier == myBundleIdentifier && $0.processIdentifier != myProcessIdentifier }
            .map(\.processIdentifier)
    }
}
