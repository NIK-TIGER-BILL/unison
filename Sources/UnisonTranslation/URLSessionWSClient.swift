import Foundation

public final class URLSessionWSClient: WSClient, @unchecked Sendable {
    private var task: URLSessionWebSocketTask?
    private let session: URLSession

    private var receiveContinuation: AsyncStream<WSMessage>.Continuation?
    private var closeContinuation: AsyncStream<WSCloseReason>.Continuation?
    private let receiveStreamRef: AsyncStream<WSMessage>
    private let closeReasonStreamRef: AsyncStream<WSCloseReason>

    public init(session: URLSession = .shared) {
        self.session = session
        var rc: AsyncStream<WSMessage>.Continuation!
        var cc: AsyncStream<WSCloseReason>.Continuation!
        self.receiveStreamRef = AsyncStream { rc = $0 }
        self.closeReasonStreamRef = AsyncStream { cc = $0 }
        self.receiveContinuation = rc
        self.closeContinuation = cc
    }

    public func connect(url: URL, headers: [String: String]) async throws {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let task = session.webSocketTask(with: req)
        self.task = task
        task.resume()
        startReceiveLoop()
    }

    public func send(_ message: WSMessage) async throws {
        guard let task else { throw URLError(.notConnectedToInternet) }
        let m: URLSessionWebSocketTask.Message
        switch message {
        case .text(let s): m = .string(s)
        case .data(let d): m = .data(d)
        }
        try await task.send(m)
    }

    public func receive() -> AsyncStream<WSMessage> { receiveStreamRef }
    public func closeStream() -> AsyncStream<WSCloseReason> { closeReasonStreamRef }

    public func close() async {
        task?.cancel(with: .normalClosure, reason: nil)
        receiveContinuation?.finish()
        closeContinuation?.yield(.normal)
        closeContinuation?.finish()
    }

    private func startReceiveLoop() {
        Task { [weak self] in
            while let task = self?.task, task.state == .running {
                do {
                    let msg = try await task.receive()
                    switch msg {
                    case .string(let s): self?.receiveContinuation?.yield(.text(s))
                    case .data(let d): self?.receiveContinuation?.yield(.data(d))
                    @unknown default: break
                    }
                } catch {
                    let ns = error as NSError
                    self?.closeContinuation?.yield(.error(ns))
                    self?.receiveContinuation?.finish()
                    break
                }
            }
        }
    }
}
