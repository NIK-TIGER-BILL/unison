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
