import Testing
@testable import UnisonTranslation

@Test func encodes_sessionUpdate_withTargetLanguage() throws {
    let event = RealtimeClientEvent.sessionUpdate(.init(targetLanguage: "en"))
    let str = try encodeToJSONString(event)
    #expect(str.contains("\"type\":\"session.update\""))
    #expect(str.contains("\"language\":\"en\""))
}

@Test func encodes_inputAudioBufferAppend_asBase64() throws {
    let pcm = bytes([0x01, 0x02, 0x03, 0x04])
    let b64 = pcm.base64EncodedString()
    let event = RealtimeClientEvent.inputAudioBufferAppend(.init(audio: b64))
    let str = try encodeToJSONString(event)
    #expect(str.contains("\"type\":\"input_audio_buffer.append\""))
    #expect(str.contains("\"audio\":\"\(b64)\""))
}

@Test func decodes_outputAudioDelta() throws {
    let json = #"{"type":"output_audio.delta","delta":"AAECAw=="}"#
    let decoded = try decodeServerEvent(json)
    if case .outputAudioDelta(let payload) = decoded {
        #expect(payload.delta == "AAECAw==")
    } else {
        Issue.record("Expected .outputAudioDelta")
    }
}

@Test func decodes_outputTranscriptDelta() throws {
    let json = #"{"type":"output_transcript.delta","delta":"Hello"}"#
    let decoded = try decodeServerEvent(json)
    if case .outputTranscriptDelta(let payload) = decoded {
        #expect(payload.delta == "Hello")
    } else {
        Issue.record("Expected .outputTranscriptDelta")
    }
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
