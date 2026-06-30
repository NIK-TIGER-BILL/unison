import Foundation
@testable import UnisonTranslation
import UnisonDomain

// Helpers in this file deliberately avoid `import Testing` so the
// `_Testing_Foundation` cross-import overlay (missing from the
// Command Line Tools `Testing.framework` install) is not triggered
// when test files only import `Testing`.

func encodeToJSONString<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    let data = try encoder.encode(value)
    return String(data: data, encoding: .utf8) ?? ""
}

func decodeServerEvent(_ json: String) throws -> RealtimeServerEvent {
    let data = json.data(using: .utf8)!
    return try JSONDecoder().decode(RealtimeServerEvent.self, from: data)
}

func bytes(_ values: [UInt8]) -> Data {
    Data(values)
}

/// Build a synthetic `NSError` matching what URLSession surfaces when a
/// `webSocketTask.send(...)` is cancelled mid-flight by the server's
/// close frame (the production "POSIX 89 / Operation canceled" race the
/// classifier-propagation fix targets). Kept here because the test file
/// that consumes it can't `import Foundation` directly — that triggers
/// the missing `_Testing_Foundation` cross-import overlay on Command
/// Line Tools-only setups (see top-of-file note).
func posixOperationCanceledError() -> Error {
    NSError(
        domain: NSPOSIXErrorDomain,
        code: 89,
        userInfo: [NSLocalizedDescriptionKey: "Operation canceled"]
    )
}

func decodeGeminiServerEvent(_ json: String) throws -> GeminiServerEvent {
    let data = json.data(using: .utf8)!
    return try JSONDecoder().decode(GeminiServerEvent.self, from: data)
}

/// Structural check on a Gemini setup payload: the transcription configs must
/// be TOP-LEVEL `setup` fields, NOT nested in `generationConfig` — the live
/// API rejects the nested form with a 1007 "Unknown name … at
/// 'setup.generation_config'" close.
func geminiSetupHasTranscriptionAtSetupLevel(_ json: String) -> Bool {
    guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
          let setup = obj["setup"] as? [String: Any] else { return false }
    let gc = setup["generationConfig"] as? [String: Any]
    return setup["inputAudioTranscription"] != nil
        && setup["outputAudioTranscription"] != nil
        && gc?["inputAudioTranscription"] == nil
        && gc?["outputAudioTranscription"] == nil
}

/// Structural check: `realtimeInputConfig` must be a TOP-LEVEL setup field
/// (sibling of model/generationConfig) carrying
/// `automaticActivityDetection.silenceDurationMs` — this is the VAD
/// turn-detection fix (the ~800 ms API default was the freeze source).
/// Misplacing it under generationConfig would 1007-reject like the
/// transcription fields did.
func geminiSetupHasVADConfig(_ json: String, silenceMs: Int) -> Bool {
    guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
          let setup = obj["setup"] as? [String: Any],
          let ric = setup["realtimeInputConfig"] as? [String: Any],
          let aad = ric["automaticActivityDetection"] as? [String: Any] else { return false }
    let gc = setup["generationConfig"] as? [String: Any]
    return gc?["realtimeInputConfig"] == nil
        && (aad["silenceDurationMs"] as? Int) == silenceMs
        && aad["endOfSpeechSensitivity"] != nil
}

struct GenericSendError: Error {}

/// Clock whose `sleep` parks forever (until `releaseAll`). Lets tests
/// prove a code path completes WITHOUT a timeout firing — a structural
/// assertion immune to machine load, unlike wall-clock budgets.
final class ParkedClock: UnisonDomain.Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var parked: [CheckedContinuation<Void, Error>] = []

    func now() -> Date { Date() }

    func sleep(for seconds: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock(); parked.append(c); lock.unlock()
        }
    }

    /// Resume every parked sleeper (used to unstick a failing test).
    func releaseAll() {
        lock.lock(); let ps = parked; parked = []; lock.unlock()
        ps.forEach { $0.resume() }
    }
}
