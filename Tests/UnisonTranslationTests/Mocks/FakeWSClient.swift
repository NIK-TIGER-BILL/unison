import Foundation
@testable import UnisonTranslation

public final class FakeWSClient: WSClient, @unchecked Sendable {
    public var connectCalls: [(URL, [String: String])] = []
    public var sentMessages: [WSMessage] = []
    public var connectShouldThrow: Error?
    /// When set, the next `send(_:)` call throws this error (then resets
    /// to nil). Lets a test reproduce the URLSession POSIX-89 race
    /// described in the OpenAIRealtimeStream classifier docs.
    public var nextSendShouldThrow: Error?
    /// Hook fired BEFORE the send error is thrown, so a test can push
    /// a close-reason / receive message into the streams before the
    /// classifier check inside `connect()` runs. Allows reproducing
    /// the exact ordering the production transport produces.
    public var beforeSendThrow: (@Sendable () -> Void)?
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
    public func send(_ message: WSMessage) async throws {
        if let err = nextSendShouldThrow {
            nextSendShouldThrow = nil
            beforeSendThrow?()
            // Tiny yield to let the close-monitor task that consumed the
            // pushClose run on the actor before the throw propagates —
            // mirrors the real-world racy ordering.
            await Task.yield()
            throw err
        }
        sentMessages.append(message)
    }
    public func receive() -> AsyncStream<WSMessage> { receiveStreamRef }
    public func closeStream() -> AsyncStream<WSCloseReason> { closeReasonStreamRef }
    public func close() async { closeCalls += 1 }

    public func push(_ message: WSMessage) { receiveContinuation?.yield(message) }
    public func pushClose(_ reason: WSCloseReason) { closeContinuation?.yield(reason) }
}
