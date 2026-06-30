import Testing
@testable import UnisonDomain

@Suite struct TranslationModelTests {
    @Test func metadataPerModel() {
        #expect(TranslationModel.openAIRealtime.keychainAccount == "openai-api-key")
        #expect(TranslationModel.geminiLiveTranslate.keychainAccount == "gemini-api-key")
        #expect(TranslationModel.openAIRealtime.inputWireSampleRate == 24_000)
        #expect(TranslationModel.geminiLiveTranslate.inputWireSampleRate == 16_000)
        #expect(TranslationModel.openAIRealtime.acceptedKeyPrefixes == ["sk-"])
        #expect(TranslationModel.geminiLiveTranslate.acceptedKeyPrefixes.contains("AQ."))
        #expect(TranslationModel.geminiLiveTranslate.acceptedKeyPrefixes.contains("AIza"))
    }

    @Test func supportedTargetsPerModel() {
        #expect(TranslationModel.openAIRealtime.supportedTargets == Language.openAITargets)
        #expect(TranslationModel.geminiLiveTranslate.supportedTargets.contains(.pl))
    }

    @Test func coerceLeavesSupportedPairUntouched() {
        let pair = LanguagePair(mine: .ru, peer: .en)
        #expect(TranslationModel.openAIRealtime.coerced(pair) == pair)
    }

    @Test func coerceReplacesUnsupportedLanguage() {
        let pair = LanguagePair(mine: .pl, peer: .en)   // Polish is Gemini-only
        let fixed = TranslationModel.openAIRealtime.coerced(pair)
        #expect(TranslationModel.openAIRealtime.supportedTargets.contains(fixed.mine))
        #expect(fixed.peer == .en)
    }

    @Test func coerceAvoidsCollapsingToSameLanguage() {
        let pair = LanguagePair(mine: .pl, peer: .uk)   // both Gemini-only
        let fixed = TranslationModel.openAIRealtime.coerced(pair)
        #expect(fixed.mine != fixed.peer)
    }
}

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
