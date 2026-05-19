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
    let s = SessionState.reconnecting(mode: .call, since: epochDate(0))
    #expect(s.isActive)
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
