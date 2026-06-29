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
        let evt = try decodeGeminiServerEvent(json)
        guard case .audio(let b64) = evt else { Issue.record("expected .audio"); return }
        #expect(b64 == "QUJD")
    }

    @Test func decodesInputAndOutputTranscription() throws {
        let inJSON = #"{"serverContent":{"inputTranscription":{"text":"привет"}}}"#
        let outJSON = #"{"serverContent":{"outputTranscription":{"text":"hello"}}}"#
        guard case .inputTranscript(let i) = try decodeGeminiServerEvent(inJSON) else {
            Issue.record("expected input"); return
        }
        guard case .outputTranscript(let o) = try decodeGeminiServerEvent(outJSON) else {
            Issue.record("expected output"); return
        }
        #expect(i == "привет")
        #expect(o == "hello")
    }

    @Test func decodesTurnCompleteAndSetupComplete() throws {
        guard case .turnComplete = try decodeGeminiServerEvent(#"{"serverContent":{"turnComplete":true}}"#) else {
            Issue.record("expected turnComplete"); return
        }
        guard case .setupComplete = try decodeGeminiServerEvent(#"{"setupComplete":{}}"#) else {
            Issue.record("expected setupComplete"); return
        }
    }

    @Test func decodesTurnCompleteEmptyObjectForm() throws {
        guard case .turnComplete = try decodeGeminiServerEvent(#"{"serverContent":{"turnComplete":{}}}"#) else {
            Issue.record("expected turnComplete for empty-object form"); return
        }
    }
}
