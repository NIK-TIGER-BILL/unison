import Testing
@testable import UnisonDomain

@Test func sessionMode_codableRoundTrip() throws {
    for mode in SessionMode.allCases {
        let decoded = try encodeDecode(mode)
        #expect(decoded == mode)
    }
}

@Test func sessionMode_requiresMic() {
    #expect(SessionMode.call.requiresMicrophone == true)
    #expect(SessionMode.listen.requiresMicrophone == false)
}

@Test func permissionKind_allCases() {
    #expect(PermissionKind.allCases == [.microphone])
}
