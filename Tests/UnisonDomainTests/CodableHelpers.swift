import Foundation
@testable import UnisonDomain

// Helpers in this file deliberately avoid `import Testing` so the
// `_Testing_Foundation` cross-import overlay (missing from the
// Command Line Tools `Testing.framework` install) is not triggered
// when test files only import `Testing`.

/// Round-trip a Codable value through JSON encode + decode.
func encodeDecode<T: Codable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
}

/// Construct a zero-filled `Data` of the given byte count.
func zeroData(count: Int) -> Data {
    Data(repeating: 0, count: count)
}

/// Construct a `Date` at the given Unix epoch seconds. Lets test files
/// avoid `import Foundation` (which conflicts with `import Testing` on
/// this CLT install).
func epochDate(_ seconds: TimeInterval = 0) -> Date {
    Date(timeIntervalSince1970: seconds)
}

/// Construct a fresh `UUID`. Lets test files avoid `import Foundation`.
func freshUUID() -> UUID {
    UUID()
}
