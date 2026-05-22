import Testing
@testable import UnisonTranslation

@Test func encodes_sessionUpdate_withTargetLanguage() throws {
    let event = RealtimeClientEvent.sessionUpdate(.init(targetLanguage: "en"))
    let str = try encodeToJSONString(event)
    // GA shape: `{"type":"session.update","session":{"audio":{...}}}`
    #expect(str.contains("\"type\":\"session.update\""))
    // Target language lives under audio.output.language for the
    // translation model.
    #expect(str.contains("\"language\":\"en\""))
    // Input transcription + noise reduction config per cookbook.
    #expect(str.contains("\"gpt-realtime-whisper\""))
    #expect(str.contains("\"near_field\""))
}

@Test func encodes_sessionUpdate_doesNotIncludeBetaShape() throws {
    // The Beta API used `{"session":{"audio":{"output":{"language":"en"}}}}`
    // *only* — no input config and no transcription block. Our GA shape
    // must carry all three so make sure they're present and the legacy
    // shape isn't the *whole* payload.
    let event = RealtimeClientEvent.sessionUpdate(.init(targetLanguage: "es"))
    let str = try encodeToJSONString(event)
    #expect(str.contains("\"input\""))
    #expect(str.contains("\"output\""))
    #expect(str.contains("\"transcription\""))
    #expect(str.contains("\"noise_reduction\""))
}

@Test func encodes_inputAudioBufferAppend_asBase64() throws {
    let pcm = bytes([0x01, 0x02, 0x03, 0x04])
    let b64 = pcm.base64EncodedString()
    let event = RealtimeClientEvent.inputAudioBufferAppend(.init(audio: b64))
    let str = try encodeToJSONString(event)
    // GA event name has the `session.` prefix per OpenAI cookbook.
    #expect(str.contains("\"type\":\"session.input_audio_buffer.append\""))
    #expect(str.contains("\"audio\":\"\(b64)\""))
}

@Test func decodes_outputAudioDelta_GA() throws {
    // GA event name has the `session.` prefix per cookbook.
    let json = #"{"type":"session.output_audio.delta","delta":"AAECAw=="}"#
    let decoded = try decodeServerEvent(json)
    if case .outputAudioDelta(let payload) = decoded {
        #expect(payload.delta == "AAECAw==")
    } else {
        Issue.record("Expected .outputAudioDelta")
    }
}

@Test func decodes_outputTranscriptDelta_GA() throws {
    let json = #"{"type":"session.output_transcript.delta","delta":"Hello"}"#
    let decoded = try decodeServerEvent(json)
    if case .outputTranscriptDelta(let payload) = decoded {
        #expect(payload.delta == "Hello")
    } else {
        Issue.record("Expected .outputTranscriptDelta")
    }
}

@Test func decodes_betaEventNames_areTreatedAsUnknown() throws {
    // The Beta names (`output_audio.delta`, `output_transcript.delta`)
    // without the `session.` prefix should NOT match anymore — if the
    // server ever sends them we want to know via `.unknown` rather than
    // silently double-decode.
    let beta = #"{"type":"output_audio.delta","delta":"AAECAw=="}"#
    let decoded = try decodeServerEvent(beta)
    if case .unknown(let type) = decoded {
        #expect(type == "output_audio.delta")
    } else {
        Issue.record("Expected .unknown for Beta event name, got \(decoded)")
    }
}

@Test func decodes_sessionLifecycleEvents_fallToUnknown() throws {
    // `session.created`, `session.updated`, `session.input_transcript.delta`,
    // etc. are GA events we don't act on. They must decode cleanly as
    // `.unknown(type)` without throwing.
    let created = #"{"type":"session.created","event_id":"evt_1","session":{}}"#
    let updated = #"{"type":"session.updated","event_id":"evt_2","session":{}}"#
    let inputTr = #"{"type":"session.input_transcript.delta","delta":"привет"}"#

    if case .unknown(let t) = try decodeServerEvent(created) { #expect(t == "session.created") } else { Issue.record("session.created") }
    if case .unknown(let t) = try decodeServerEvent(updated) { #expect(t == "session.updated") } else { Issue.record("session.updated") }
    if case .unknown(let t) = try decodeServerEvent(inputTr) { #expect(t == "session.input_transcript.delta") } else { Issue.record("session.input_transcript.delta") }
}

@Test func decodes_unknownTypeFallsToUnknown() throws {
    let json = #"{"type":"some.future.event","payload":42}"#
    let decoded = try decodeServerEvent(json)
    if case .unknown(let type) = decoded {
        #expect(type == "some.future.event")
    } else {
        Issue.record("Expected .unknown")
    }
}

@Test func decodes_errorEvent() throws {
    let json = #"{"type":"error","error":{"code":"invalid_api_key","message":"Invalid"}}"#
    let decoded = try decodeServerEvent(json)
    if case .error(let e) = decoded {
        #expect(e.code == "invalid_api_key")
    } else {
        Issue.record("Expected .error")
    }
}

@Test func decodes_errorEvent_withoutCode_usesUnknown() throws {
    // GA `error` payloads sometimes ship without `code` (only `type`+`message`).
    // Decoder must tolerate that and surface a sentinel `"unknown"` code so
    // the close-reason classifier can still run.
    let json = #"{"type":"error","error":{"message":"Something went wrong","type":"server_error"}}"#
    let decoded = try decodeServerEvent(json)
    if case .error(let e) = decoded {
        #expect(e.code == "unknown")
        #expect(e.message == "Something went wrong")
    } else {
        Issue.record("Expected .error")
    }
}
