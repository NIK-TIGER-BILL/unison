import Testing
@testable import UnisonDomain

@Test func sessionState_initialIsIdle() {
    let s = SessionState.idle
    #expect(s.isIdle)
    #expect(s.isActive == false)
}

@Test func sessionState_translatingIsActive() {
    let s = SessionState.translating(mode: .call, startedAt: epochDate(0))
    #expect(s.isActive)
    #expect(s.isIdle == false)
}

@Test func sessionState_reconnectingIsActive() {
    let s = SessionState.reconnecting(mode: .call, since: epochDate(0), startedAt: epochDate(0))
    #expect(s.isActive)
}

@Test func sessionState_reconnecting_preservesStartedAt() {
    // The popover timer reads `sessionStartedAt` so it counts from the
    // user's click instead of resetting on each reconnect.
    let started = epochDate(100)
    let s = SessionState.reconnecting(mode: .call, since: epochDate(125), startedAt: started)
    #expect(s.sessionStartedAt == started)
}

@Test func sessionState_translating_exposesStartedAt() {
    let started = epochDate(42)
    let s = SessionState.translating(mode: .call, startedAt: started)
    #expect(s.sessionStartedAt == started)
}

@Test func sessionState_idle_hasNoStartedAt() {
    #expect(SessionState.idle.sessionStartedAt == nil)
    #expect(SessionState.connecting(mode: .call).sessionStartedAt == nil)
    #expect(SessionState.error(.networkLost).sessionStartedAt == nil)
}

@Test func sessionState_errorIsTerminal() {
    let s = SessionState.error(.networkLost)
    #expect(s.isActive == false)
    #expect(s.errorValue == .networkLost)
}

@Test func sessionState_modeAccessor() {
    #expect(SessionState.idle.activeMode == nil)
    #expect(SessionState.translating(mode: .listen, startedAt: epochDate(0)).activeMode == .listen)
}

@Test func sessionState_pausedNetworkLost_isActive() {
    let started = epochDate(0)
    let state = SessionState.paused(
        mode: .call, since: epochDate(10), startedAt: started, reason: .networkLost
    )
    #expect(state.isActive == true)
    #expect(state.activeMode == .call)
    #expect(state.sessionStartedAt == started)
}

@Test func sessionState_pausedAwaitingNetwork_carriesStartedAt() {
    let started = epochDate(-30)
    let state = SessionState.paused(
        mode: .listen, since: epochDate(0), startedAt: started, reason: .awaitingNetwork
    )
    #expect(state.activeMode == .listen)
    #expect(state.sessionStartedAt == started)
}

@Test func pauseReason_equatable() {
    #expect(PauseReason.networkLost == PauseReason.networkLost)
    #expect(PauseReason.networkLost != PauseReason.awaitingNetwork)
}
