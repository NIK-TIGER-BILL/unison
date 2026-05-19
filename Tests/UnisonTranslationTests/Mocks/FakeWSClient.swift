import Foundation
@testable import UnisonTranslation

public final class FakeWSClient: WSClient, @unchecked Sendable {
    public var connectCalls: [(URL, [String: String])] = []
    public var sentMessages: [WSMessage] = []
    public var connectShouldThrow: Error?
    public var closeCalls = 0

    private var receiveContinuation: AsyncStream<WSMessage>.Continuation?
    private var closeContinuation: AsyncStream<WSCloseReason>.Continuation?
    public let receiveStreamRef: AsyncStream<WSMessage>
    public let closeReasonStreamRef: AsyncStream<WSCloseReason>

    public init() {
        var rc: AsyncStream<WSMessage>.Continuation!
        var cc: AsyncStream<WSCloseReason>.Continuation!
        receiveStreamRef = AsyncStream { rc = $0 }
        closeReasonStreamRef = AsyncStream { cc = $0 }
        receiveContinuation = rc
        closeContinuation = cc
    }

    public func connect(url: URL, headers: [String: String]) async throws {
        connectCalls.append((url, headers))
        if let e = connectShouldThrow { throw e }
    }
    public func send(_ message: WSMessage) async throws { sentMessages.append(message) }
    public func receive() -> AsyncStream<WSMessage> { receiveStreamRef }
    public func closeStream() -> AsyncStream<WSCloseReason> { closeReasonStreamRef }
    public func close() async { closeCalls += 1 }

    public func push(_ message: WSMessage) { receiveContinuation?.yield(message) }
    public func pushClose(_ reason: WSCloseReason) { closeContinuation?.yield(reason) }
}
