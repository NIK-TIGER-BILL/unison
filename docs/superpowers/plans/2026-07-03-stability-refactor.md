# Stability Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Устранить оставшиеся классы отказов стабильности: гонки start/stop, зависание в `.connecting`, обрыв долгих Gemini-сессий на `goAway`, зомби-сессии после сна/NAT-таймаутов, HAL-блокировки MainActor на старте сессии.

**Architecture:** Все фиксы ложатся в существующую машинерию: state-guard'ы и вотчдоги в `TranslationOrchestrator` (по образцу `resumeStreams`), новый `PauseReason.systemSleep` поверх существующего pause/resume, keepalive внутри `URLSessionWSClient` (сигнал уходит в существующий closeStream → reconnect), bring-up аудио-компонентов уводится на их собственные serial-очереди (симметрично уже сделанному teardown).

**Tech Stack:** Swift 6 / swift-testing (`@Test`, `#expect`), SwiftPM, моки в `Tests/UnisonDomainTests/Mocks`, `FakeClock`/`ManualClock`/`InstantClock`.

**Диагноз (карта дефектов, доказательства):**
| # | Дефект | Файл | Сценарий отказа |
|---|--------|------|-----------------|
| D1 | `start()` не перепроверяет state после await'ов | TranslationOrchestrator.swift:314-458 | Stop во время connect → `.translating`-зомби или `.error` поверх юзерского `.idle` |
| D2 | Нет бюджета на фазу `.connecting` | там же | Мёртвая сеть/зависший HAL → UI навсегда в «connecting» (Start мёртв: guard `.idle`) |
| D3 | Gemini `goAway` игнорируется | GeminiLiveTranslateStream.swift:233 | Лимит сессии Live API → обрыв, реконнект только после разрыва + 1s backoff |
| D4 | Нет WS keepalive / liveness | URLSessionWSClient.swift | Полуоткрытый сокет (сон, NAT) → зомби-сессия: молчит, но выглядит живой |
| D5 | Нет обработки sleep/wake | AppDelegate.swift (нет NSWorkspace observers) | Mac уснул при активной сессии → после пробуждения сокеты мертвы |
| D6 | HAL bring-up на MainActor | AVAudioOutputMixer.start, ProcessTapCapture.start, AVAudioEngineMicrophone.start | Занятый/заклинивший coreaudiod на старте → фриз всего UI (teardown уже уведён, setup — нет) |
| D7 | FileLogStore: open/close FileHandle на каждую строку | FileLogStore.swift:203-218 | Долгие сессии: десятки тысяч лишних syscalls/час на серийной очереди |

---

### Task 1: start() reentrancy guards (D1)

**Files:**
- Modify: `Sources/UnisonDomain/TranslationOrchestrator.swift:314-458` (`start()`)
- Modify: `Tests/UnisonDomainTests/Mocks/MockTranslationStream.swift` (добавить gate)
- Test: `Tests/UnisonDomainTests/TranslationOrchestratorTests.swift`

- [ ] **Step 1: Расширить мок гейтом для подвешивания connect()**

```swift
// MockTranslationStream: добавить поля + логика в connect()
/// Если true, connect() подвешивается до releaseConnect().
public var gateConnect = false
private var connectGate: CheckedContinuation<Void, Never>?

public func connect(target: Language) async throws {
    if gateConnect {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            connectGate = c
        }
    }
    if let err = connectError { throw err }
    connectedTo = target
    connectionContinuation?.yield(.connected)
}

/// Отпустить подвешенный connect().
public func releaseConnect() {
    connectGate?.resume()
    connectGate = nil
}
```

- [ ] **Step 2: Написать падающие тесты**

```swift
// Регрессия D1: stop() во время подвешенного connect() не должен быть
// перезатёрт продолжением start() (ни в .translating, ни в .error).
@Test @MainActor func orchestrator_stopDuringConnect_staysIdle() async throws {
    let factory = MockTranslationStreamFactory()
    factory.gateNextConnect = true
    let o = makeOrchestrator(factory: factory)
    let startTask = Task { await o.start(mode: .listen, languages: .default) }
    // Дождаться, пока start() дойдёт до подвешенного connect.
    try await waitUntil { factory.streams[.peer]?.gateConnect == true }
    await o.stop()
    #expect(o.state == .idle)
    factory.streams[.peer]?.releaseConnect()
    await startTask.value
    #expect(o.state == .idle, "start() продолжился после stop() и перезаписал state")
}

@Test @MainActor func orchestrator_stopDuringConnect_thenConnectFails_staysIdle() async throws {
    let factory = MockTranslationStreamFactory()
    factory.gateNextConnect = true
    let o = makeOrchestrator(factory: factory)
    let startTask = Task { await o.start(mode: .listen, languages: .default) }
    try await waitUntil { factory.streams[.peer]?.gateConnect == true }
    await o.stop()
    factory.streams[.peer]?.connectError = TranslationError.networkLost
    factory.streams[.peer]?.releaseConnect()
    await startTask.value
    #expect(o.state == .idle, "поздний фейл connect() перетёр .idle на .error")
}
```

`gateNextConnect` — новое поле на фабрике: `make()` выставляет `s.gateConnect = true` один раз. `waitUntil` — маленький хелпер поллинга (если его нет в тестах — добавить рядом):

```swift
@MainActor
func waitUntil(timeout: TimeInterval = 2, _ cond: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !cond() {
        if Date() > deadline { throw NSError(domain: "waitUntil", code: 1) }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}
```

- [ ] **Step 3: Прогнать — убедиться, что падают** (`swift test --filter stopDuringConnect`)

- [ ] **Step 4: Реализовать guard'ы в start()**

После каждого await (permissions.request, outputMixer.start, peer.connect, me.connect) и перед финальным `state = .translating`:

```swift
guard case .connecting = state else {
    Self.log.info("start() — state changed during <шаг> (\(String(describing: state))); aborting start")
    await stopAllStreams()   // прибрать то, что успели поднять; state не трогаем
    return
}
```

В catch-ветках peer.connect/me.connect — то же самое ПЕРЕД `state = .error(mapped)`: если state уже не `.connecting`, только `stopAllStreams()` и return.

- [ ] **Step 5: Тесты зелёные + вся сюита** (`swift test`)

- [ ] **Step 6: Commit** `fix(orchestrator): start() re-checks state after every await — Stop during connect wins`

---

### Task 2: connect-stage watchdog (D2)

**Files:**
- Modify: `Sources/UnisonDomain/TranslationOrchestrator.swift`
- Test: `Tests/UnisonDomainTests/TranslationOrchestratorTests.swift`

- [ ] **Step 1: Падающий тест**

```swift
// Регрессия D2: подвешенный connect() не должен держать .connecting вечно.
@Test @MainActor func orchestrator_connectWatchdog_failsSessionAfterBudget() async throws {
    let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
    let factory = MockTranslationStreamFactory()
    factory.gateNextConnect = true
    let o = makeOrchestrator(factory: factory, clock: clock)
    let startTask = Task { await o.start(mode: .listen, languages: .default) }
    try await waitUntil { factory.streams[.peer]?.gateConnect == true }
    clock.advance(by: 31)          // connectWatchdogSeconds = 30
    try await waitUntil { o.state.errorValue == .networkLost }
    factory.streams[.peer]?.releaseConnect()
    await startTask.value
    #expect(o.state.errorValue == .networkLost)
}
```

- [ ] **Step 2: Реализация**

```swift
private var connectWatchdogTask: Task<Void, Never>?
private static let connectWatchdogSeconds: TimeInterval = 30

private func armConnectWatchdog() {
    connectWatchdogTask?.cancel()
    let clock = self.clock
    connectWatchdogTask = Task { @MainActor [weak self] in
        try? await clock.sleep(for: Self.connectWatchdogSeconds)
        guard let self, !Task.isCancelled else { return }
        if case .connecting = self.state {
            Self.log.error("connect watchdog fired after \(Self.connectWatchdogSeconds)s — session stuck in .connecting; forcing .error(.networkLost)")
            await self.stopAllStreams()
            self.state = .error(.networkLost)
        }
    }
}
private func cancelConnectWatchdog() {
    connectWatchdogTask?.cancel()
    connectWatchdogTask = nil
}
```

Вызовы: `armConnectWatchdog()` сразу после `state = .connecting(mode:)`; `cancelConnectWatchdog()` в `stopAllStreams()` (рядом с прочими cancel'ами) и перед `state = .translating` в `start()`. Взаимодействие с Task 1: watchdog зовёт `stopAllStreams()` → подвешенный connect бросает → catch в start() видит state ≠ .connecting → не перетирает `.error`.

- [ ] **Step 3: Тест зелёный + сюита; Commit** `feat(orchestrator): 30s watchdog on .connecting — a hung connect can no longer wedge the session`

---

### Task 3: Gemini goAway → проактивный мгновенный реконнект (D3)

**Files:**
- Modify: `Sources/UnisonDomain/TranslationError.swift` (новый case `.serverGoingAway`)
- Modify: `Sources/UnisonTranslation/GeminiLiveTranslateStream.swift:233`
- Modify: `Sources/UnisonDomain/TranslationOrchestrator.swift` (`handleStreamFailure`, `runReconnectLoop`)
- Modify: `Sources/UnisonUI/ViewModels/PopoverViewModel.swift` (`userMessage` exhaustive)
- Test: `Tests/UnisonTranslationTests/GeminiLiveTranslateStreamTests.swift`, `Tests/UnisonDomainTests/TranslationOrchestratorTests.swift`

- [ ] **Step 1: Падающий тест стрима** (по образцу существующих в GeminiLiveTranslateStreamTests с FakeWSClient)

```swift
@Test func gemini_goAway_yieldsServerGoingAwayFailure() async throws {
    let ws = FakeWSClient()
    let stream = GeminiLiveTranslateStream(apiKey: "k", client: ws, clock: SystemClock())
    try await stream.connect(target: .en)
    var states: [ConnectionState] = []
    let collector = Task { for await s in stream.connectionState { states.append(s); if case .failed = s { break } } }
    ws.receive(text: #"{"goAway":{"timeLeft":"10s"}}"#)   // точный API FakeWSClient сверить по соседним тестам
    await collector.value
    #expect(states.contains { if case .failed(.serverGoingAway, _) = $0 { true } else { false } })
}
```

- [ ] **Step 2: TranslationError + стрим**

```swift
// TranslationError: новый case + shortMessage
case serverGoingAway
...
case .serverGoingAway: "Сервер закрыл сессию"
```

```swift
// GeminiLiveTranslateStream.handle, case .goAway:
case .goAway:
    Self.log.info("\(String(describing: speaker)) goAway — server will close soon; proactive reconnect")
    connectionContinuation.yield(.failed(.serverGoingAway, receivedAnyData: receivedAnyData))
```

`PopoverViewModel.userMessage`: `case .serverGoingAway: return "Сервер закрыл сессию. Начните перевод заново."` (терминально почти не всплывает — исчерпание ретраев даёт .networkLost).

- [ ] **Step 3: Падающие тесты оркестратора**

```swift
// serverGoingAway реконнектится БЕЗ backoff-сна (immediate swap).
@Test @MainActor func orchestrator_serverGoingAway_reconnectsWithoutBackoff() async throws {
    let clock = ManualClock()   // sleep подвешивается — если реконнект просит сон, тест не пройдёт
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(factory: factory, clock: clock)
    await o.start(mode: .listen, languages: .default)
    let first = try #require(factory.streams[.peer])
    first.emitConnectionState(.failed(.serverGoingAway, receivedAnyData: true))
    // Без advance(by:) реконнект должен дойти до .translating (delay 0).
    try await waitUntil { if case .translating = o.state { true } else { false } }
    #expect(factory.streams[.peer] !== first, "новый стрим не создан")
}

// goAway ДО первых данных не эскалируется в .apiKeyInvalid.
@Test @MainActor func orchestrator_serverGoingAwayWithoutData_notApiKeyInvalid() async throws {
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(factory: factory, clock: InstantClock())
    await o.start(mode: .listen, languages: .default)
    factory.streams[.peer]?.emitConnectionState(.failed(.serverGoingAway, receivedAnyData: false))
    try await waitUntil { if case .translating = o.state { true } else { false } }
    #expect(o.state.errorValue == nil)
}
```

- [ ] **Step 4: Реализация в оркестраторе**

`handleStreamFailure`: в empty-close эскалации добавить исключение:

```swift
if !receivedAnyData && error != .serverGoingAway {
    ... существующая эскалация ...
}
```

`runReconnectLoop`: первый attempt без сна:

```swift
let delay: TimeInterval
if firstAttempt, case .rateLimited(let retryAfter) = error {
    delay = retryAfter
} else if firstAttempt, error == .serverGoingAway {
    delay = 0   // сервер сам предупредил — переподключаемся немедленно
} else {
    delay = backoff.nextDelay()
}
if delay > 0 {
    do { try await clock.sleep(for: delay) } catch { return }
}
```

(обратить внимание: `clock.sleep(for: 0)` у ManualClock подвесится — поэтому обходим сон при delay == 0).

- [ ] **Step 5: Сюита зелёная; Commit** `feat: Gemini goAway triggers immediate stream swap instead of dying with the socket`

---

### Task 4: sleep/wake pause-resume (D5)

**Files:**
- Modify: `Sources/UnisonDomain/SessionState.swift` (`PauseReason.systemSleep`)
- Modify: `Sources/UnisonDomain/TranslationOrchestrator.swift` (`systemWillSleep()`, `systemDidWake()`, обобщение pause/resume)
- Modify: `Sources/UnisonApp/AppDelegate.swift` (NSWorkspace observers)
- Modify: `Sources/UnisonUI/ViewModels/PopoverViewModel.swift`, `Sources/UnisonUI/ViewModels/TranscriptViewModel.swift` (+ прочие exhaustive-switch места — компилятор укажет)
- Test: `Tests/UnisonDomainTests/TranslationOrchestratorTests.swift`

- [ ] **Step 1: Падающие тесты**

```swift
@Test @MainActor func orchestrator_systemSleep_pausesActiveSession() async throws {
    let mic = MockMicrophoneCapture()
    let o = makeOrchestrator(mic: mic)
    await o.start(mode: .call, languages: .default)
    o.systemWillSleep()
    try await waitUntil { if case .paused(_, _, _, .systemSleep) = o.state { true } else { false } }
    #expect(mic.stopCalls >= 1)
}

@Test @MainActor func orchestrator_wakeWithNetwork_resumesSession() async throws {
    let net = MockNetworkPathMonitor(initial: .satisfied)
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(factory: factory, networkMonitor: net)
    await o.start(mode: .listen, languages: .default)
    let startedAt = o.state.sessionStartedAt
    o.systemWillSleep()
    o.systemDidWake()
    try await waitUntil { if case .translating = o.state { true } else { false } }
    #expect(o.state.sessionStartedAt == startedAt, "таймер сессии сбросился")
}

@Test @MainActor func orchestrator_wakeWithoutNetwork_waitsForNetworkThenResumes() async throws {
    let net = MockNetworkPathMonitor(initial: .satisfied)
    let o = makeOrchestrator(networkMonitor: net)
    await o.start(mode: .listen, languages: .default)
    o.systemWillSleep()
    net.simulate(.unsatisfied)
    o.systemDidWake()
    try await waitUntil { if case .paused(_, _, _, .networkLost) = o.state { true } else { false } }
    net.simulate(.satisfied)
    try await waitUntil { if case .translating = o.state { true } else { false } }
}

@Test @MainActor func orchestrator_systemSleepWhileIdle_noop() async {
    let o = makeOrchestrator()
    o.systemWillSleep()
    #expect(o.state == .idle)
}
```

- [ ] **Step 2: Реализация**

`SessionState.PauseReason`: добавить `case systemSleep` (док-коммент: «Mac засыпает; возобновляемся на didWake»).

Оркестратор — обобщить существующий `enterNetworkPause` (переименовать в `enterPause(reason:mode:)`; сетевой путь зовёт с `.networkLost` и по-прежнему армит recovery watchdog; sleep-путь — с `.systemSleep` и БЕЗ вотчдога, Mac может спать часами):

```swift
public func systemWillSleep() {
    switch state {
    case .translating(let mode, _), .reconnecting(let mode, _, _):
        Self.log.info("systemWillSleep — pausing active session")
        enterPause(reason: .systemSleep, mode: mode)
    default:
        break   // idle/connecting/error/уже paused — нечего делать
    }
}

public func systemDidWake() {
    guard case .paused(let mode, _, _, .systemSleep) = state else { return }
    Self.log.info("systemDidWake — network=\(String(describing: networkMonitor.currentStatus))")
    if networkMonitor.currentStatus == .satisfied {
        resumeFromPause(mode: mode, languages: currentLanguages)
    } else {
        // Сеть ещё не поднялась: переходим в сетевую паузу — существующий
        // network-observer возобновит на .satisfied, watchdog ограничит ожидание.
        guard let startedAt = sessionStartedAt else { return }
        state = .paused(mode: mode, since: clock.now(), startedAt: startedAt, reason: .networkLost)
        armPauseRecoveryWatchdog()
    }
}
```

`resumeFromNetworkPause` → обобщить в `resumeFromPause` (guard принимает `.networkLost` И `.systemSleep`; сетевой observer-путь не меняется). `handleNetworkStatusChange(.satisfied)` — оставить резюм только из `.networkLost` (во сне сетевые события не приходят, а ложный резюм во время сна вреден).

AppDelegate (в `applicationDidFinishLaunching`):

```swift
let workspaceNC = NSWorkspace.shared.notificationCenter
workspaceNC.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
    MainActor.assumeIsolated { self?.composition.orchestrator.systemWillSleep() }
}
workspaceNC.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
    MainActor.assumeIsolated { self?.composition.orchestrator.systemDidWake() }
}
```

(токены сохранить в свойство, снять в `applicationWillTerminate` — симметрично hotkeyService.)

UI-копия: `PopoverViewModel.statusText` → `case .paused(_, _, _, .systemSleep): return "Пауза: Mac спал"`; `statusDotState` → `.paused`. `TranscriptViewModel.pillStatusText` — аналогично (компилятор покажет все exhaustive-места).

- [ ] **Step 3: Сюита зелёная; Commit** `feat: pause session on system sleep, resume on wake — no more zombie sessions after the Mac napped`

---

### Task 5: WS keepalive + dead-peer detection (D4)

**Files:**
- Create: `Sources/UnisonTranslation/WSKeepalive.swift`
- Modify: `Sources/UnisonTranslation/URLSessionWSClient.swift`
- Test: `Tests/UnisonTranslationTests/WSKeepaliveTests.swift` (новый)

- [ ] **Step 1: Падающие тесты чистой логики**

```swift
import Testing
import Foundation
@testable import UnisonTranslation

/// sendPing инжектируется; тест управляет pong'ами и временем.
@Test func keepalive_pongKeepsConnectionAlive() async throws {
    let clock = TestSleeper()   // см. ниже — минимальный async-слипер на continuation'ах
    var deadCount = 0
    let ka = WSKeepalive(pingInterval: 15, pongTimeout: 10, maxMissedPongs: 2,
                         sleeper: clock.sleep,
                         sendPing: { done in done(nil) },     // мгновенный pong
                         onDead: { deadCount += 1 })
    ka.start()
    await clock.advance(by: 15); await clock.advance(by: 15); await clock.advance(by: 15)
    #expect(deadCount == 0)
    ka.stop()
}

@Test func keepalive_twoMissedPongs_firesOnDead() async throws {
    let clock = TestSleeper()
    var deadCount = 0
    let ka = WSKeepalive(pingInterval: 15, pongTimeout: 10, maxMissedPongs: 2,
                         sleeper: clock.sleep,
                         sendPing: { _ in /* pong никогда не приходит */ },
                         onDead: { deadCount += 1 })
    ka.start()
    await clock.advance(by: 15); await clock.advance(by: 10)   // ping1 + timeout1
    await clock.advance(by: 15); await clock.advance(by: 10)   // ping2 + timeout2
    #expect(deadCount == 1)
    ka.stop()
}
```

- [ ] **Step 2: Реализация WSKeepalive**

```swift
import Foundation

/// Периодический WS-ping + детект мёртвого пира. Транспортно-нейтральный:
/// `sendPing` инжектируется (продакшн — URLSessionWebSocketTask.sendPing),
/// `sleeper` инжектируется для детерминированных тестов. Полуоткрытый
/// TCP (сон Mac, NAT-таймаут, тихо умерший сервер) не даёт ни receive-ошибки,
/// ни close-фрейма — единственный надёжный детект это ping/pong.
final class WSKeepalive: @unchecked Sendable {
    private let pingInterval: TimeInterval
    private let pongTimeout: TimeInterval
    private let maxMissedPongs: Int
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let sendPing: @Sendable (@escaping @Sendable (Error?) -> Void) -> Void
    private let onDead: @Sendable () -> Void
    private var task: Task<Void, Never>?

    init(pingInterval: TimeInterval = 15, pongTimeout: TimeInterval = 10, maxMissedPongs: Int = 2,
         sleeper: @escaping @Sendable (TimeInterval) async throws -> Void,
         sendPing: @escaping @Sendable (@escaping @Sendable (Error?) -> Void) -> Void,
         onDead: @escaping @Sendable () -> Void) { ... }

    func start() {
        task = Task { [pingInterval, pongTimeout, maxMissedPongs, sleeper, sendPing, onDead] in
            var missed = 0
            while !Task.isCancelled {
                do { try await sleeper(pingInterval) } catch { return }
                if Task.isCancelled { return }
                let ok = await Self.pingOnce(sendPing: sendPing, timeout: pongTimeout, sleeper: sleeper)
                missed = ok ? 0 : missed + 1
                if missed >= maxMissedPongs { onDead(); return }
            }
        }
    }
    func stop() { task?.cancel(); task = nil }

    private static func pingOnce(...) async -> Bool {
        // fire-once гонка pong-хендлера против таймаута — паттерн Decision
        // из TranslationOrchestrator.teardownFinished.
    }
}
```

`TestSleeper` в тестах — как ManualClock, но локальный для UnisonTranslationTests (sleep паркует continuation, advance отпускает).

- [ ] **Step 3: Интеграция в URLSessionWSClient**

```swift
// connect(): после startReceiveLoop()
keepalive = WSKeepalive(
    sleeper: { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
    sendPing: { [weak task] done in
        guard let task, task.state == .running else { done(URLError(.networkConnectionLost)); return }
        task.sendPing { done($0) }
    },
    onDead: { [weak self] in self?.handleKeepaliveDeath() }
)
keepalive?.start()

private func handleKeepaliveDeath() {
    Self.log.error("keepalive — \(missed) pongs missed; declaring the socket dead (half-open TCP after sleep/NAT-timeout)")
    if tryMarkCloseEmitted() {
        closeContinuation?.yield(.error(NSError(
            domain: "com.unison.app.ws", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "keepalive timeout — no pong from server"])))
    }
    receiveContinuation?.finish()
    task?.cancel(with: .goingAway, reason: nil)
}
// close(): keepalive?.stop() первым делом.
```

Сигнал уходит стандартным путём: `.error` → `handleClose` → `.failed(.networkLost)` → реконнект оркестратора.

- [ ] **Step 4: Сюита зелёная; Commit** `feat(ws): ping keepalive detects half-open sockets — zombie sessions reconnect instead of hanging silently`

---

### Task 6: HAL bring-up off MainActor (D6)

**Files:**
- Modify: `Sources/UnisonAudio/AVAudioOutputMixer.swift:187-193` (`start` → detached)
- Modify: `Sources/UnisonAudio/ProcessTapCapture.swift:38-91` (bring-up на serial-очередь)
- Modify: `Sources/UnisonAudio/AVAudioEngineMicrophone.swift:79-135` (то же)
- Test: существующая сюита + VM-скрипты (`scripts/vm-repro-devicechange.sh`, `scripts/vm-repro-teardown.sh`)

- [ ] **Step 1: AVAudioOutputMixer.start — увести с вызывающего актора**

```swift
public func start(deviceUID: String?) async throws {
    Self.log.info("start(deviceUID=\(deviceUID ?? "<system default>"))")
    // HAL-вызовы (bind устройства, engine.start) — IPC в coreaudiod: на BT
    // 0.3–0.7 c в реальных логах, при заклинившем coreaudiod — навсегда.
    // Teardown уже уведён с MainActor (stopAllStreams); bring-up симметрично.
    // engineLock сериализует с config-change self-heal и stop().
    try await Task.detached(priority: .userInitiated) { [self] in
        try startLocked(deviceUID: deviceUID)
    }.value
}
```

- [ ] **Step 2: ProcessTapCapture — serial workQueue**

```swift
private let workQueue = DispatchQueue(label: "com.unison.app.ProcessTapCapture.lifecycle", qos: .userInitiated)

public func start() -> AsyncStream<AudioFrame> {
    AsyncStream { [weak self] c in
        guard let self else { c.finish(); return }
        // Bring-up на выделенной серийной очереди: создание tap + aggregate =
        // синхронный IPC в coreaudiod; на MainActor это фризило весь UI при
        // занятом/заклинившем HAL. Серийная очередь сохраняет FIFO-порядок
        // start/stop (в отличие от Task.detached), т.е. семантику прежнего
        // синхронного кода, минус блокировка главного потока.
        self.workQueue.async { [weak self] in
            guard let self else { c.finish(); return }
            if self.started { self.stopOnQueue() }
            self.continuation = c
            do {
                ... тот же код bring-up ...
            } catch { ... c.finish(); self.teardown() ... }
        }
    }
}

public func stop() {
    workQueue.sync { [weak self] in self?.stopOnQueue() }   // teardown-таск уже off-main
}
private func stopOnQueue() { /* прежнее тело stop() */ }
// deinit: workQueue.sync { teardown(); continuation?.finish() }
```

ВНИМАНИЕ: `stop()` зовётся с detached teardown-таска оркестратора; `workQueue.sync` там безопасен (не main). Проверить, что `stop()` нигде не зовётся с самого workQueue (deadlock) — не зовётся: IOProc не вызывает stop.

- [ ] **Step 3: AVAudioEngineMicrophone — то же**

`start()`: тело AsyncStream-билдера (configure + startRunning + observer) обернуть в `workQueue.async`. `stop()` → `workQueue.sync`. `lifecycleLock` внутри остаётся (сериализует с handleRuntimeError на observer-очереди). `session.startRunning()` — Apple прямо рекомендует звать не с main.

- [ ] **Step 4: Вся сюита + аудио-тесты** (`swift test`) — поведенческих изменений нет, только поток исполнения.

- [ ] **Step 5: Commit** `perf(audio): move HAL bring-up off the MainActor — a busy coreaudiod can no longer freeze the UI at session start`

---

### Task 7: FileLogStore — кэшированный FileHandle (D7)

**Files:**
- Modify: `Sources/UnisonDomain/FileLogStore.swift:203-218`
- Test: `Tests/UnisonDomainTests/FileLogStoreTests.swift`

- [ ] **Step 1: Тест** (если существующие не покрывают): запись N строк → ротация → запись ещё M строк → обе пачки в правильных файлах.

- [ ] **Step 2: Реализация**

```swift
private var writeHandle: FileHandle?   // только на I/O-очереди

private func appendLineRaw(_ line: String) {
    guard let data = line.data(using: .utf8) else { return }
    if writeHandle == nil {
        if !FileManager.default.fileExists(atPath: currentFileURL.path) {
            FileManager.default.createFile(atPath: currentFileURL.path, contents: nil)
        }
        writeHandle = try? FileHandle(forWritingTo: currentFileURL)
        _ = try? writeHandle?.seekToEnd()
    }
    do { try writeHandle?.write(contentsOf: data) }
    catch { try? writeHandle?.close(); writeHandle = nil }   // след. строка переоткроет
}

private func rotateLocked() {
    try? writeHandle?.close(); writeHandle = nil   // до move
    ... прежнее тело ...
}
```

- [ ] **Step 3: Сюита; Commit** `perf(log): keep the log FileHandle open across writes (was open/close per line)`

---

### Task 8: Документация + полная верификация + PR

- [ ] Обновить `docs/audio-pipeline.md`: раздел «Session lifecycle & resilience» (connect-watchdog, sleep/wake, keepalive, goAway-swap; открытые TODO: Gemini sessionResumption, make-before-break, peer-conceal).
- [ ] `swift test` полная сюита; `bash scripts/lint.sh`.
- [ ] VM: `scripts/vm-integration-test.sh` (или минимум `vm-screenshot.sh` + `vm-repro-devicechange.sh`) — прогнать, если VM доступна.
- [ ] Сверить main tip через `gh api` (memory: unison_worktree_git_fetch), PR в main.

## Self-Review

- D1–D7 все покрыты задачами 1–7; D2 (`.connecting`-hang) дополнительно смягчён Task 6 (без него watchdog не сработал бы при блокированном MainActor).
- Типы согласованы: `PauseReason.systemSleep` (T4) используется только внутри T4; `TranslationError.serverGoingAway` (T3) — в стриме, оркестраторе, UI-switch'ах.
- Код тестов опирается на существующие моки; новые: gate в MockTranslationStream (T1), TestSleeper (T5).
- Плейсхолдеров нет; `...` в T5-реализации разворачивается по паттерну Decision из `teardownFinished` (точная ссылка дана).
