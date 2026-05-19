import Foundation
@testable import UnisonDomain

/// Round-trip a Codable value through JSON encode + decode.
///
/// Lives in this file (no `import Testing`) to avoid pulling in the
/// `_Testing_Foundation` cross-import overlay, which is missing from
/// the Command Line Tools `Testing.framework` install.
func encodeDecode<T: Codable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
}
