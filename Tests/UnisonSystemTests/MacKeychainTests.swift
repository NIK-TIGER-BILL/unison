import Testing
@testable import UnisonSystem

@Test func keychain_saveAndLoadRoundTrip() throws {
    let kc = MacKeychain(service: "com.unison.test", account: "test-key")
    try kc.deleteAPIKey()
    try kc.saveAPIKey("sk-test-abc123")
    #expect(kc.loadAPIKey() == "sk-test-abc123")
    try kc.deleteAPIKey()
    #expect(kc.loadAPIKey() == nil)
}

@Test func keychain_overwriteExisting() throws {
    let kc = MacKeychain(service: "com.unison.test", account: "test-key-2")
    try kc.deleteAPIKey()
    try kc.saveAPIKey("old")
    try kc.saveAPIKey("new")
    #expect(kc.loadAPIKey() == "new")
    try kc.deleteAPIKey()
}
