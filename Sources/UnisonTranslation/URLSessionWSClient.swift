import Foundation
import UnisonDomain

/// Production `WSClient` backed by `URLSession.webSocketTask`.
///
/// `URLSessionWebSocketTask` exposes the WS close code + server `reason`
/// payload only via the `URLSessionWebSocketDelegate.didCloseWith` callback
/// — `task.receive()` just throws a generic `NSURLError` once the close
/// is processed, with the actual code lost. So this client wires up a
/// delegate just to surface those values to `closeStream()`.
public final class URLSessionWSClient: NSObject, WSClient, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// Diagnostic logger for close-code mapping decisions. Mirrors to
    /// `~/Library/Logs/Unison/unison.log` and unified logging — see
    /// `UnisonLog`. The user's diagnostic copy pulls from the file.
    private static let log = UnisonLog(category: "URLSessionWSClient")

    private var task: URLSessionWebSocketTask?
    /// Lazily-built `URLSession` so we can install `self` as the delegate.
    /// Stored once and reused; the constructor never receives a session.
    private var session: URLSession!
    /// Pinned to the queue the delegate fires on. Defaults to a serial
    /// queue so callbacks don't race with the receive loop.
    private let delegateQueue: OperationQueue

    private var receiveContinuation: AsyncStream<WSMessage>.Continuation?
    private var closeContinuation: AsyncStream<WSCloseReason>.Continuation?
    private let receiveStreamRef: AsyncStream<WSMessage>
    private let closeReasonStreamRef: AsyncStream<WSCloseReason>

    /// Set after the delegate fires `didCloseWith:` so the receive loop
    /// knows the close arrived through the delegate path and doesn't
    /// also emit a duplicate `.error(...)` for the same disconnect.
    private var closedByDelegate = false

    public override init() {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "com.unison.app.URLSessionWSClient.delegate"
        self.delegateQueue = q

        var rc: AsyncStream<WSMessage>.Continuation!
        var cc: AsyncStream<WSCloseReason>.Continuation!
        self.receiveStreamRef = AsyncStream { rc = $0 }
        self.closeReasonStreamRef = AsyncStream { cc = $0 }
        self.receiveContinuation = rc
        self.closeContinuation = cc

        super.init()

        // Build the session *after* `super.init` because the delegate is
        // `self`. A default-config session is plenty — we don't need
        // any caching or cookies for the realtime WS endpoint.
        self.session = URLSession(
            configuration: .default,
            delegate: self,
            delegateQueue: q
        )
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
                    // If the delegate already reported the close, skip the
                    // duplicate `.error(...)` emission — the consumer already
                    // saw the typed `.abnormal(code:reason:)` and acted on it.
                    if self?.closedByDelegate == true {
                        self?.receiveContinuation?.finish()
                        break
                    }
                    let ns = error as NSError
                    Self.log.error("receive loop error: domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
                    self?.closeContinuation?.yield(.error(ns))
                    self?.receiveContinuation?.finish()
                    break
                }
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Self.log.info("WS open — protocol=\(`protocol` ?? "<none>")")
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        closedByDelegate = true
        // Decode the server-provided reason payload as UTF-8. OpenAI
        // realtime returns a JSON error message (e.g.
        // `{"error":{"type":"invalid_request_error",...}}`) — we
        // surface the raw string upstream and let the consumer parse.
        let reasonString: String? = {
            guard let data = reason, !data.isEmpty else { return nil }
            return String(data: data, encoding: .utf8)
        }()
        let code = closeCode.rawValue
        // Log level mirrors the close semantics: code 1000 (normal
        // closure) is what we ourselves trigger via stop(), so emitting
        // it at .error makes log scans noisy and misleads operators
        // ("oh look, every stop is errored"). Abnormal closes — auth
        // failures, server-initiated tears, transport drops — stay at
        // .error so they stand out.
        if closeCode == .normalClosure {
            Self.log.info("WS close — code=\(code) reason=\(reasonString ?? "<nil>") (normal)")
            closeContinuation?.yield(.normal)
        } else {
            Self.log.error("WS close — code=\(code) reason=\(reasonString ?? "<nil>")")
            closeContinuation?.yield(.abnormal(code: code, reason: reasonString))
        }
    }
}
