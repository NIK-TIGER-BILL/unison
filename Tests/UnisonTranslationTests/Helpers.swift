import Foundation
@testable import UnisonTranslation
import UnisonDomain

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
