import Foundation
import Testing
@testable import UnisonDomain

@Test func health_aggregate_allHealthy_isHealthy() {
    #expect(ConnectivityHealth.aggregate(.healthy, .healthy) == .healthy)
}

@Test func health_aggregate_anySlow_isSlow() {
    #expect(ConnectivityHealth.aggregate(.healthy, .slow) == .slow)
    #expect(ConnectivityHealth.aggregate(.slow, .healthy) == .slow)
    #expect(ConnectivityHealth.aggregate(.slow, .slow) == .slow)
}

@Test func health_aggregate_recoveringWithHealthy_isRecovering() {
    // Recovering wins over healthy — UI surfaces the flash even if
    // one side is already steady.
    #expect(ConnectivityHealth.aggregate(.recovering, .healthy) == .recovering)
    #expect(ConnectivityHealth.aggregate(.healthy, .recovering) == .recovering)
}

@Test func health_aggregate_slowBeatsRecovering() {
    // Slow is the worse signal — keep it visible even if one side
    // recently came back.
    #expect(ConnectivityHealth.aggregate(.slow, .recovering) == .slow)
}

@Test func health_aggregateSingleton_returnsInput() {
    #expect(ConnectivityHealth.aggregate(.healthy) == .healthy)
    #expect(ConnectivityHealth.aggregate(.slow) == .slow)
    #expect(ConnectivityHealth.aggregate(.recovering) == .recovering)
}
