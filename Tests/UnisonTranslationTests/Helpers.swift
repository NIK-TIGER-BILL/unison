import Foundation
@testable import UnisonTranslation

// Helpers in this file deliberately avoid `import Testing` so the
// `_Testing_Foundation` cross-import overlay (missing from the
// Command Line Tools `Testing.framework` install) is not triggered
// when test files only import `Testing`.

func encodeToJSONString<T: Encodable>(_ value: T) throws -> String {
    let data = try JSONEncoder().encode(value)
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

struct GenericSendError: Error {}
