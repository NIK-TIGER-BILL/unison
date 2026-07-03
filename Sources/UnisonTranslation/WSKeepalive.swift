import Foundation

/// Периодический WS ping + детект мёртвого пира.
///
/// **Зачем.** Полуоткрытый TCP не даёт НИКАКОГО сигнала: после сна Mac,
/// NAT/прокси-таймаута или тихо умершего сервера `receive()` просто молчит,
/// а `send()` буферируется в никуда. Ни receive-ошибки, ни close-фрейма —
/// сессия выглядит живой и вечно молчит (зомби). Единственный надёжный
/// детект на этом уровне — ping/pong: pong обязателен по RFC 6455 и
/// отвечается транспортом пира без участия его приложения.
///
/// **Транспортно-нейтрален и детерминированно тестируем**: `sendPing`
/// (продакшн — `URLSessionWebSocketTask.sendPing`) и `sleeper` (продакшн —
/// `Task.sleep`) инжектируются. Один пропущенный pong прощается
/// (транзиентный затык планировщика/сети); `maxMissedPongs` подряд →
/// `onDead()` ровно один раз. Владелец (`URLSessionWSClient`) переводит
/// `onDead` в стандартное close-событие, дальше работает обычный
/// reconnect-путь оркестратора.
final class WSKeepalive: @unchecked Sendable {
    private let pingInterval: TimeInterval
    private let pongTimeout: TimeInterval
    private let maxMissedPongs: Int
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let sendPing: @Sendable (@escaping @Sendable (Error?) -> Void) -> Void
    private let onDead: @Sendable () -> Void
    private var task: Task<Void, Never>?

    init(
        pingInterval: TimeInterval = 15,
        pongTimeout: TimeInterval = 10,
        maxMissedPongs: Int = 2,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void,
        sendPing: @escaping @Sendable (@escaping @Sendable (Error?) -> Void) -> Void,
        onDead: @escaping @Sendable () -> Void
    ) {
        self.pingInterval = pingInterval
        self.pongTimeout = pongTimeout
        self.maxMissedPongs = maxMissedPongs
        self.sleeper = sleeper
        self.sendPing = sendPing
        self.onDead = onDead
    }

    func start() {
        stop()
        task = Task { [pingInterval, pongTimeout, maxMissedPongs, sleeper, sendPing, onDead] in
            var missed = 0
            while !Task.isCancelled {
                do { try await sleeper(pingInterval) } catch { return }
                if Task.isCancelled { return }
                let pongReceived = await Self.pingOnce(
                    sendPing: sendPing, timeout: pongTimeout, sleeper: sleeper)
                if Task.isCancelled { return }
                missed = pongReceived ? 0 : missed + 1
                if missed >= maxMissedPongs {
                    onDead()
                    return
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Один ping: гонка pong-хендлера против таймаута, fire-once — тот же
    /// Decision-паттерн, что в `TranslationOrchestrator.teardownFinished`
    /// (проигравший resume — no-op, continuation не утекает).
    private static func pingOnce(
        sendPing: @Sendable (@escaping @Sendable (Error?) -> Void) -> Void,
        timeout: TimeInterval,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void
    ) async -> Bool {
        final class Decision: @unchecked Sendable {
            private let lock = NSLock()
            private var settled = false
            func claim() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if settled { return false }
                settled = true
                return true
            }
        }
        let decision = Decision()
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            sendPing { error in
                if decision.claim() { cont.resume(returning: error == nil) }
            }
            Task {
                try? await sleeper(timeout)
                if decision.claim() { cont.resume(returning: false) }
            }
        }
    }
}
