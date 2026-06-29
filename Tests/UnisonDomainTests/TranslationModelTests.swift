import Testing
@testable import UnisonDomain

@Suite struct LanguageExpansionTests {
    @Test func newGeminiLanguagesExist() {
        #expect(Language(rawValue: "pl") == .pl)
        #expect(Language(rawValue: "uk") == .uk)
        #expect(Language(rawValue: "ar") == .ar)
        #expect(Language.pl.displayName == "Polski")
        #expect(Language.uk.displayName == "Українська")
    }

    @Test func openAITargetsAreTheCanonicalThirteen() {
        #expect(Language.openAITargets.count == 13)
        #expect(Language.openAITargets.contains(.ru))
        #expect(!Language.openAITargets.contains(.pl))
    }

    @Test func geminiTargetsSupersetOfOpenAI() {
        for lang in Language.openAITargets {
            #expect(Language.geminiTargets.contains(lang))
        }
        #expect(Language.geminiTargets.count > Language.openAITargets.count)
        #expect(Language.geminiTargets.contains(.pl))
    }
}
