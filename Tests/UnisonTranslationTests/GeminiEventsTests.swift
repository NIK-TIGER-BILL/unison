import Testing
@testable import UnisonTranslation

@Suite struct GeminiEventsTests {
    @Test func setupEncodesModelAndTargetLanguage() throws {
        let evt = GeminiClientEvent.setup(.init(targetLanguage: "ru"))
        let json = try encodeToJSONString(evt)
        #expect(json.contains("\"setup\""))
        #expect(json.contains("models/gemini-3.5-live-translate-preview"))
        #expect(json.contains("\"targetLanguageCode\":\"ru\""))
        #expect(json.contains("\"responseModalities\":[\"AUDIO\"]"))
        #expect(json.contains("inputAudioTranscription"))
        #expect(json.contains("outputAudioTranscription"))
    }

    @Test func setupPlacesTranscriptionAtSetupLevelNotInGenerationConfig() throws {
        // Regression: the live API rejects inputAudioTranscription /
        // outputAudioTranscription nested in generationConfig (1007 close).
        let json = try encodeToJSONString(GeminiClientEvent.setup(.init(targetLanguage: "ru")))
        #expect(geminiSetupHasTranscriptionAtSetupLevel(json))
    }

    @Test func setupConfiguresVADTurnDetectionAtSetupLevel() throws {
        // Root-cause fix: realtimeInputConfig.automaticActivityDetection must
        // be a top-level setup field, and silenceDurationMs must be the tuned
        // value (default 300ms) — NOT the API's ~800ms default that made the
        // model sit through clause-boundary pauses (the audible freeze).
        let json = try encodeToJSONString(GeminiClientEvent.setup(.init(targetLanguage: "ru")))
        #expect(json.contains("realtimeInputConfig"))
        #expect(json.contains("automaticActivityDetection"))
        #expect(json.contains("END_SENSITIVITY_HIGH"))
        #expect(geminiSetupHasVADConfig(json, silenceMs: GeminiSetupPayload.silenceDurationMs))
        // And the tuned window must be well under the ~800ms default.
        #expect(GeminiSetupPayload.silenceDurationMs < 800)
    }

    @Test func realtimeAudioEncodes16kMime() throws {
        let evt = GeminiClientEvent.realtimeAudio(base64: "QUJD")
        let json = try encodeToJSONString(evt)
        #expect(json.contains("\"realtimeInput\""))
        #expect(json.contains("\"data\":\"QUJD\""))
        #expect(json.contains("audio/pcm;rate=16000"))
    }

    @Test func decodesAudioInlineData() throws {
        let json = """
        {"serverContent":{"modelTurn":{"parts":[{"inlineData":{"data":"QUJD","mimeType":"audio/pcm;rate=24000"}}]}}}
        """
        #expect(try decodeGeminiFrame(json) == [.audio(base64: "QUJD")])
    }

    @Test func decodesInputAndOutputTranscription() throws {
        #expect(try decodeGeminiFrame(#"{"serverContent":{"inputTranscription":{"text":"привет"}}}"#)
            == [.inputTranscript("привет", nil)])
        #expect(try decodeGeminiFrame(#"{"serverContent":{"outputTranscription":{"text":"hello"}}}"#)
            == [.outputTranscript("hello", nil)])
    }

    @Test func decodesTranscriptLanguageCode() throws {
        #expect(try decodeGeminiFrame(#"{"serverContent":{"inputTranscription":{"text":"hi","languageCode":"en"}}}"#)
                == [.inputTranscript("hi", "en")])
        #expect(try decodeGeminiFrame(#"{"serverContent":{"outputTranscription":{"text":"привет","languageCode":"ru"}}}"#)
                == [.outputTranscript("привет", "ru")])
    }

    @Test func decodesTurnCompleteAndSetupComplete() throws {
        #expect(try decodeGeminiFrame(#"{"serverContent":{"turnComplete":true}}"#) == [.turnComplete])
        #expect(try decodeGeminiFrame(#"{"setupComplete":{}}"#) == [.setupComplete])
    }

    @Test func decodesTurnCompleteEmptyObjectForm() throws {
        #expect(try decodeGeminiFrame(#"{"serverContent":{"turnComplete":{}}}"#) == [.turnComplete])
    }

    // Regression (field log 2026-07-07): Gemini bundles `turnComplete` into the
    // SAME serverContent as the final content chunk. The single-event decoder
    // returned only the content and dropped the boundary (0 turnComplete in the
    // whole log) → the pairing FIFO never popped → crossed original↔translation.
    // A frame must surface the final content AND the boundary, in that order.
    @Test func decodesBundledTurnCompleteWithTranscript() throws {
        #expect(try decodeGeminiFrame(#"{"serverContent":{"outputTranscription":{"text":"Привет."},"turnComplete":true}}"#)
            == [.outputTranscript("Привет.", nil), .turnComplete])
    }

    @Test func decodesBundledTurnCompleteWithAudio() throws {
        let json = #"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"data":"QUJD"}}]},"turnComplete":true}}"#
        #expect(try decodeGeminiFrame(json) == [.audio(base64: "QUJD"), .turnComplete])
    }
}
