import Foundation
import Testing
@testable import UnisonSystem

@Test func mockNetworkMonitor_publishesStatusUpdates() async {
    let monitor = MockNetworkPathMonitor(initial: .satisfied)
    var observed: [NetworkPathStatus] = []
    let task = Task {
        for await status in monitor.statusStream {
            observed.append(status)
            if observed.count == 3 { break }
        }
    }
    // First yield is the initial status.
    try? await Task.sleep(nanoseconds: 50_000_000)
    monitor.simulate(.unsatisfied)
    monitor.simulate(.satisfied)
    _ = await task.value
    #expect(observed == [.satisfied, .unsatisfied, .satisfied])
}

@Test func mockNetworkMonitor_currentStatusReflectsLatest() {
    let monitor = MockNetworkPathMonitor(initial: .satisfied)
    #expect(monitor.currentStatus == .satisfied)
    monitor.simulate(.unsatisfied)
    #expect(monitor.currentStatus == .unsatisfied)
}
