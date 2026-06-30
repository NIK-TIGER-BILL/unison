import Testing
import Foundation
@testable import UnisonSystem
import UnisonDomain

@Test func keychain_saveAndLoadRoundTrip() throws {
    let kc = MacKeychain(service: "com.unison.test.\(UUID().uuidString)")
    try kc.deleteAPIKey(for: .openAIRealtime)
    try kc.saveAPIKey("sk-test-abc123", for: .openAIRealtime)
    #expect(kc.loadAPIKey(for: .openAIRealtime) == "sk-test-abc123")
    try kc.deleteAPIKey(for: .openAIRealtime)
    #expect(kc.loadAPIKey(for: .openAIRealtime) == nil)
}

@Test func keychain_overwriteExisting() throws {
    let kc = MacKeychain(service: "com.unison.test.\(UUID().uuidString)")
    try kc.deleteAPIKey(for: .openAIRealtime)
    try kc.saveAPIKey("old", for: .openAIRealtime)
    try kc.saveAPIKey("new", for: .openAIRealtime)
    #expect(kc.loadAPIKey(for: .openAIRealtime) == "new")
    try kc.deleteAPIKey(for: .openAIRealtime)
}

@Test func storesKeysPerModelIndependently() throws {
    let kc = MacKeychain(service: "com.unison.test.\(UUID().uuidString)")
    try? kc.deleteAPIKey(for: .openAIRealtime)
    try? kc.deleteAPIKey(for: .geminiLiveTranslate)

    try kc.saveAPIKey("sk-openai-123", for: .openAIRealtime)
    try kc.saveAPIKey("AQ.gemini-456", for: .geminiLiveTranslate)
    #expect(kc.loadAPIKey(for: .openAIRealtime) == "sk-openai-123")
    #expect(kc.loadAPIKey(for: .geminiLiveTranslate) == "AQ.gemini-456")

    try kc.saveAPIKey("sk-openai-789", for: .openAIRealtime)
    #expect(kc.loadAPIKey(for: .geminiLiveTranslate) == "AQ.gemini-456")

    try kc.deleteAPIKey(for: .openAIRealtime)
    #expect(kc.loadAPIKey(for: .openAIRealtime) == nil)
    #expect(kc.loadAPIKey(for: .geminiLiveTranslate) == "AQ.gemini-456")

    try kc.deleteAPIKey(for: .geminiLiveTranslate)
}
