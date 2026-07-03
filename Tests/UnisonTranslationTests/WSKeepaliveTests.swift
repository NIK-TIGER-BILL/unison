import Foundation
import Testing
@testable import UnisonTranslation

/// Ручной async-слипер для keepalive-тестов: `sleep` паркует continuation
/// с виртуальным дедлайном, `advance(by:)` двигает время и отпускает
/// созревшие. `advance` сперва дожидается (yield-циклом), пока хоть один
/// sleep реально запаркуется — иначе тест гонялся бы с планировщиком.
private final class TestSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var now: TimeInterval = 0
    private var parked: [(deadline: TimeInterval, cont: CheckedContinuation<Void, Error>)] = []

    @Sendable func sleep(_ seconds: TimeInterval) async throws {
        let deadline: TimeInterval
        lock.lock()
        deadline = now + seconds
        lock.unlock()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            parked.append((deadline, c))
            lock.unlock()
        }
    }

    func advance(by seconds: TimeInterval) async {
        // Дождаться, пока keepalive-цикл дойдёт до следующего sleep.
        for _ in 0..<1000 {
            lock.lock()
            let anyParked = !parked.isEmpty
            lock.unlock()
            if anyParked { break }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        lock.lock()
        now += seconds
        let due = parked.filter { $0.deadline <= now }
        parked.removeAll { $0.deadline <= now }
        lock.unlock()
        for d in due { d.cont.resume() }
        // Дать отпущенным продолжениям исполниться.
        for _ in 0..<50 { await Task.yield() }
    }

    /// Отпустить всё запаркованное (иначе CheckedContinuation ругается
    /// на утечку при деаллокации в конце теста).
    func drain() {
        lock.lock()
        let all = parked
        parked.removeAll()
        lock.unlock()
        for d in all { d.cont.resume(throwing: CancellationError()) }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@Suite struct WSKeepaliveTests {
    // Пинг с мгновенным pong'ом: соединение живое, onDead не зовётся.
    @Test func pongKeepsConnectionAlive() async throws {
        let clock = TestSleeper()
        let dead = Counter()
        let ka = WSKeepalive(
            pingInterval: 15, pongTimeout: 10, maxMissedPongs: 2,
            sleeper: clock.sleep,
            sendPing: { done in done(nil) },
            onDead: { dead.increment() })
        ka.start()
        await clock.advance(by: 15)
        await clock.advance(by: 15)
        await clock.advance(by: 15)
        #expect(dead.value == 0)
        ka.stop()
        clock.drain()
    }

    // Полуоткрытый сокет: pong'и не приходят; после maxMissedPongs
    // подряд keepalive объявляет соединение мёртвым — ровно один раз.
    @Test func missedPongs_fireOnDeadOnce() async throws {
        let clock = TestSleeper()
        let dead = Counter()
        let ka = WSKeepalive(
            pingInterval: 15, pongTimeout: 10, maxMissedPongs: 2,
            sleeper: clock.sleep,
            sendPing: { _ in /* pong никогда не придёт */ },
            onDead: { dead.increment() })
        ka.start()
        await clock.advance(by: 15)   // ping #1
        await clock.advance(by: 10)   // timeout #1 → missed=1
        #expect(dead.value == 0)
        await clock.advance(by: 15)   // ping #2
        await clock.advance(by: 10)   // timeout #2 → missed=2 → dead
        for _ in 0..<200 where dead.value == 0 { await Task.yield() }
        #expect(dead.value == 1)
        ka.stop()
        clock.drain()
    }

    // Одиночный пропуск pong'а (транзиентный затык) прощается: следующий
    // успешный pong сбрасывает счётчик, onDead не зовётся.
    @Test func singleMissedPong_recoversOnNextPong() async throws {
        let clock = TestSleeper()
        let dead = Counter()
        let failFirst = Counter()
        let ka = WSKeepalive(
            pingInterval: 15, pongTimeout: 10, maxMissedPongs: 2,
            sleeper: clock.sleep,
            sendPing: { done in
                failFirst.increment()
                if failFirst.value > 1 { done(nil) }   // pong со второго пинга
            },
            onDead: { dead.increment() })
        ka.start()
        await clock.advance(by: 15)   // ping #1 — без ответа
        await clock.advance(by: 10)   // timeout #1 → missed=1
        await clock.advance(by: 15)   // ping #2 — мгновенный pong → missed=0
        await clock.advance(by: 15)   // ping #3 — pong
        await clock.advance(by: 15)   // ping #4 — pong
        #expect(dead.value == 0, "одиночный пропуск pong не должен убивать соединение")
        ka.stop()
        clock.drain()
    }

    // stop() до дедлайна: onDead не зовётся даже если pong'и пропали.
    @Test func stop_cancelsPendingDetection() async throws {
        let clock = TestSleeper()
        let dead = Counter()
        let ka = WSKeepalive(
            pingInterval: 15, pongTimeout: 10, maxMissedPongs: 2,
            sleeper: clock.sleep,
            sendPing: { _ in },
            onDead: { dead.increment() })
        ka.start()
        await clock.advance(by: 15)   // ping #1 — без ответа
        ka.stop()
        clock.drain()
        for _ in 0..<100 { await Task.yield() }
        #expect(dead.value == 0)
    }
}
