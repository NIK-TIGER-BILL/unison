# Архив встреч (Meeting History) — дизайн

- **Дата:** 2026-06-24
- **Статус:** дизайн утверждён пользователем; готов к плану реализации
- **Версия:** v1

## Проблема и цель

Unison выводит транскрипт встречи, но хранит его только в памяти:
`TranscriptStore.entries` живёт до следующего `start()`, который зовёт
`transcript.clear()` (`TranslationOrchestrator.swift:262`). После выхода из
приложения всё потеряно. Цель — дать пользователю **личный архив встреч с
поиском**: каждая сессия автоматически становится записью, которую можно
найти, перечитать, отредактировать и удалить.

## Основной сценарий

«Найти и перечитать момент из прошлого звонка/прослушивания.» Накопительная
память: по умолчанию сохраняем всё (в пределах лимита размера), главное —
быстрый поиск и чтение. Паттерн Mail/Notes: список слева, транскрипт справа.

## Не-цели (v1, осознанно)

- Аудио не храним (только текст).
- AI-саммари / умный автозаголовок → v2.
- Облако/синхронизация — нет.
- Шифрование сверх FileVault → v2 (хранение plaintext, как логи).
- Трекинг участников — нет.
- Шаринг — только через текстовый экспорт.
- Корзина с undo удаления → v2.

## Обзор архитектуры

```
TranslationOrchestrator.stop()
  └─ (если сохранять историю И mode≠.test И есть реплики)
       MeetingStore.save(record)  ──►  ~/Library/Application Support/com.unison.app/meetings/
                                          ├─ <uuid>.json   (полная запись)
                                          └─ index.json    (лёгкий индекс для списка)
                                          └─ enforceSizeLimit()  (size-ротация)

MeetingHistoryWindowController (UnisonApp, стеклянное окно)
  └─ MeetingHistoryView (UnisonUI, master-detail)
       └─ MeetingHistoryViewModel (список, поиск, выбор, правки, pin, экспорт)
            └─ MeetingStore (CRUD + поиск)
```

Слои следуют текущему расслоению проекта: домен/хранилище в `UnisonDomain`,
вьюмодель/вью в `UnisonUI`, окно и проводка в `UnisonApp`.

## Модель данных (`UnisonDomain`)

`TranscriptEntry` сейчас `Identifiable, Sendable, Equatable`, но **не
`Codable`**. Все его типы полей кодируемы (`UUID`, `Speaker: Codable`,
`String`, `Language: Codable`, `Date`, `Bool`) → добавляем `Codable`
(синтез) и поле `edited`.

```swift
public struct TranscriptEntry: Identifiable, Sendable, Equatable, Codable {
    // существующие поля без изменений …
    public var edited: Bool = false   // правил ли пользователь текст реплики
}
```

Новый файл `MeetingRecord.swift`:

```swift
public struct MeetingRecord: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public var title: String?            // nil → автозаголовок из mode+startedAt
    public let startedAt: Date
    public let endedAt: Date
    public let mode: SessionMode         // .call | .listen (.test не сохраняем)
    public let languagePair: LanguagePair
    public var entries: [TranscriptEntry]
    public var pinned: Bool
    public let schemaVersion: Int        // = 1, для будущих миграций

    public var displayTitle: String { /* title ?? "Звонок · 24 июня, 14:30" */ }
}

// Лёгкая строка индекса — то, что нужно списку без загрузки полной записи.
public struct MeetingSummary: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public var title: String?
    public let startedAt: Date
    public let durationSeconds: Int
    public let mode: SessionMode
    public let languagePair: LanguagePair
    public var lineCount: Int
    public var preview: String           // первые ~80 симв. translatedText первой реплики
    public var pinned: Bool
    public var sizeBytes: Int            // размер <uuid>.json на момент записи
}
```

Автозаголовок: `"<Звонок|Прослушивание> · <d MMMM, HH:mm>"` от `mode` и
`startedAt`. Архив хранит **полный** список реплик, а не урезанное
recency-окно живого транскрипта (окно — чисто вью-слой через `lastActivityAt`).

## Хранилище (`MeetingStore.swift`, `UnisonDomain`)

```swift
public protocol MeetingStore: Sendable {
    func list() -> [MeetingSummary]            // pinned сверху, затем startedAt desc
    func load(_ id: UUID) throws -> MeetingRecord
    func save(_ record: MeetingRecord) throws  // пишет файл, апдейтит индекс, гонит ротацию
    func delete(_ id: UUID) throws
    func rename(_ id: UUID, title: String?) throws
    func setPinned(_ id: UUID, _ pinned: Bool) throws
    func search(_ query: String) -> [MeetingSummary]
    func totalSizeBytes() -> Int
    func clearAll() throws
}
```

Реализация `FileMeetingStore`:

- Каталог: `~/Library/Application Support/com.unison.app/meetings/` (App Support
  сейчас не используется — заводим). Bundle id `com.unison.app`.
- `<uuid>.json` — одна запись; **атомарная** запись (temp-файл + rename).
- `index.json` — `{ schemaVersion, meetings: [MeetingSummary] }`. Список и
  размер считаются из индекса мгновенно, без обхода диска.
- **Самовосстановление индекса:** при старте/ошибке — если `index.json` битый
  или отсутствует, перестраиваем из файлов записей; осиротевшие файлы (есть
  файл, нет в индексе) подхватываем; записи без файла выкидываем из индекса.
- **Поиск:** по заголовку/превью — мгновенно из индекса. Полнотекстовый — ленивым
  проходом по файлам записей на фоне (для личных объёмов ок; полнотекстовый
  индекс — оптимизация v2). Регистронезависимо, с debounce на UI.
- Вся I/O — на отдельной serial queue (как `FileLogStore`).
- За пределами `UnisonDomain` инжектится через протокол (DI как у остальных
  сервисов в `Composition`).

## Поток сохранения (интеграция в `stop()`)

`stop()` (`TranslationOrchestrator.swift:1328`) сейчас: teardown → `state = .idle`
→ закрытие дампов. `transcript.clear()` здесь **не** вызывается (он в `start()`).

Изменение:

1. В самом начале `stop()`, **до** `state = .idle`, снять метаданные сессии:
   `let mode = state.activeMode`, `let startedAt = state.sessionStartedAt`.
2. После teardown (когда сессия фактически завершена) собрать запись и сохранить,
   **не очищая** транскрипт (живой транскрипт остаётся на экране до следующего
   `start()` — текущее поведение сохраняем):

```swift
// currentSettings уже хранится оркестратором (присвоен в start(), стр. 261).
if currentSettings.saveHistoryEnabled,
   let mode, mode != .test,                 // .test не архивируем
   let startedAt,
   !transcript.entries.isEmpty {            // пустые сессии пропускаем
    let record = MeetingRecord(
        id: UUID(), title: nil,
        startedAt: startedAt, endedAt: clock.now(),
        mode: mode,
        languagePair: transcript.currentLanguagePair ?? .default,
        entries: transcript.entries,
        pinned: false, schemaVersion: 1)
    meetingStore.save(record)               // на фоне, не блокирует UI стопа
}
```

- **Защита от двойного сохранения:** повторный `stop()` уже в `.idle` даёт
  `activeMode == nil` → запись пропускается. Естественно, без флагов.
- **Завершение при выходе:** убедиться, что `stop()` отрабатывает на терминации
  приложения, иначе активная-но-не-остановленная сессия не попадёт в архив
  (проверить `applicationWillTerminate` в `AppDelegate`).
- `meetingStore` инжектится в оркестратор через `Composition`.

## Size-ротация

Триггеры: после `save()` и при запуске приложения. Алгоритм:

```
let limitMB = settings.historySizeLimitMB      // 0 → «Без лимита», ротации нет
guard limitMB > 0 else { return }
let limit = limitMB * 1024 * 1024
var total = totalSizeBytes()
guard total > limit else { return }

let newestId = summaries.max(by: startedAt)?.id      // только что сохранённую не трогаем
var candidates = summaries
    .filter { !$0.pinned && $0.id != newestId }       // pinned и свежую — исключаем
    .sorted { $0.startedAt < $1.startedAt }           // старые первыми

for c in candidates where total > limit {
    delete(c.id); total -= c.sizeBytes
}
// если остались только pinned/свежая и всё ещё > limit — оставляем как есть,
// индикатор размера в Настройках это покажет.
```

Правила (важные, чтобы не всплыли потом):

- Меряем суммарный размер файлов записей (из `sizeBytes` индекса).
- Удаляем **целые** записи, старые первыми. Внутри встречи ничего не режем.
- **Только что сохранённую запись не удаляем никогда** (иначе можно снести то,
  что прямо сейчас записал).
- **Одна встреча больше лимита** — оставляем как есть, не дробим.
- **Закреплённые (pinned) не вытесняются.**
- Удаление — hard delete (корзина → v2).

Контраст с логами: логи одноразовые → жёсткий cap (5×2 МБ); встречи —
пользовательский контент → лимит настраиваемый, pin защищает, расход виден.

## Закрепление (pin)

- Поле `pinned` в `MeetingRecord` и `MeetingSummary`.
- В списке закреплённые — сверху (отдельная секция «Закреплённые» или просто
  наверху со звёздочкой), дальше по дате.
- Ротация закреплённые пропускает.
- UI: звёздочка-toggle в шапке деталки и в контекстном меню строки списка
  (`store.setPinned`).

## Редактирование

Деталка работает с загруженным `MeetingRecord` в `MeetingHistoryViewModel`.
Все правки сохраняются сразу (autosave при потере фокуса/«Готово»), не копятся:

- **Переименовать** → `store.rename(id, title)`.
- **Удалить реплику** → убрать `TranscriptEntry` из массива → `store.save`
  (обновит `lineCount`, `preview`, `sizeBytes` в индексе).
- **Править текст** → меняем `translatedText` (отображаемый текст) выбранной
  реплики, ставим `entry.edited = true`, `store.save`. `originalText` —
  read-only (правка перевода — это то, что человек читает; оригинал трогать
  незачем в v1).

## Окно «Архив встреч» (UI)

- `MeetingHistoryWindowController` (`UnisonApp`): стеклянное окно по образцу
  Settings (`.titled`, `fullSizeContentView`, `GlassHostingViewController`).
  Один инстанс, переоткрывается.
- `MeetingHistoryView` (`UnisonUI`): master-detail (см. согласованный макет) —
  sidebar (поиск + список, pinned сверху) и detail (шапка: заголовок+карандаш,
  мета `дата · длительность · режим · языковая пара`, кнопки экспорт / pin /
  удалить; транскрипт с inline-правкой реплик и ховер-кнопками «изменить» /
  «удалить»). Переиспользуем компоненты бабблов (`Bubble`/`BubbleGroupView`) в
  read-режиме; для правки — отдельный inline-editor стейт.
- `MeetingHistoryViewModel` (`UnisonUI`): `summaries`, `query` → отфильтрованный
  список, `selection`, загруженный `selectedRecord`, действия
  (rename/delete/pin/editLine/deleteLine/export). Debounce поиска.
- **Пустое состояние:** «Пока нет сохранённых встреч», когда архив пуст.
- **Доступ:** пункт «История…» в контекстном меню `StatusItemController`
  (после «Показать транскрипт», рядом с Settings/Diagnostic — паттерн
  `onShowHistory` closure + `@objc menuShowHistory` + проводка в
  `Composition`/`AppDelegate`) и горячая клавиша через `HotkeyService`.

## Настройки

Новый раздел «История» в `SettingsView` (+ поля в `Settings`, который —
`Codable` с кастомными `CodingKeys` и `decodeIfPresent` для forward-compat;
новые поля добавляем тем же паттерном с дефолтами):

- `saveHistoryEnabled: Bool = true` — тумблер «Сохранять историю встреч».
- `historySizeLimitMB: Int = 50` — дропдаун лимита: `25 · 50 · 100 · 250 · 500
  МБ · Без лимита` (0 = без лимита).
- Индикатор «N встреч · X / Y МБ» (из `MeetingStore`).
- Кнопка «Очистить всю историю» (`store.clearAll`, с подтверждением).
- (опц.) «Показать в Finder».

Persist через существующий `SettingsStore` (UserDefaults JSON, ключ
`com.unison.settings.v1`).

## Приватность

- Локально, без облака. Plaintext JSON (консистентно с логами; шифрование на
  диске покрывает FileVault). Полноценное шифрование — осознанно v2.
- Выключаемо тумблером; полная очистка одним действием.
- `.test`-сессии не сохраняются.

## Новые / изменённые файлы

**Новые:**
- `Sources/UnisonDomain/MeetingRecord.swift` — `MeetingRecord`, `MeetingSummary`.
- `Sources/UnisonDomain/MeetingStore.swift` — протокол + `FileMeetingStore`.
- `Sources/UnisonUI/ViewModels/MeetingHistoryViewModel.swift`.
- `Sources/UnisonUI/Views/MeetingHistoryView.swift`.
- `Sources/UnisonApp/MeetingHistoryWindowController.swift`.

**Изменённые:**
- `Sources/UnisonDomain/TranscriptEntry.swift` → `+ Codable`, `+ edited`.
- `Sources/UnisonDomain/Settings.swift` → `saveHistoryEnabled`,
  `historySizeLimitMB` (+ CodingKeys + decodeIfPresent).
- `Sources/UnisonDomain/TranslationOrchestrator.swift` → save-в-`stop()`
  (snapshot до `.idle`, без `clear`); инжект `meetingStore`; `enforceSizeLimit`
  при старте.
- `Sources/UnisonApp/Composition.swift` → собрать `FileMeetingStore`, прокинуть
  в оркестратор и в history VM/окно.
- `Sources/UnisonApp/StatusItemController.swift` → пункт меню «История…».
- `Sources/UnisonApp/AppDelegate.swift` → создать/показать окно истории,
  hotkey, `enforceSizeLimit` при старте, save-on-terminate проверка.
- `Sources/UnisonUI/Views/SettingsView.swift` + `SettingsViewModel.swift` →
  раздел «История».
- `HotkeyService` — новая клавиша для окна истории.

## Тестирование

- **Unit `FileMeetingStore`:** CRUD; самовосстановление индекса (битый/нет/
  осиротевшие/висячие); атомарность записи.
- **Ротация:** вытеснение oldest-first; защита самой свежей; pinned exempt;
  `historySizeLimitMB = 0` → без ротации; одна встреча > лимита остаётся.
- **Save flow:** `stop()` сохраняет `.call`/`.listen` с ≥1 репликой; пропускает
  `.test` и пустые; двойной `stop()` не дублирует; транскрипт не очищается.
- **Codable:** round-trip `TranscriptEntry`/`MeetingRecord`; декод старого JSON
  без новых полей (`edited`, `pinned`) с дефолтами; `schemaVersion`.
- **Автозаголовок** из mode+startedAt; **поиск** по заголовку/превью/полному
  тексту.
- **UI smoke** через `UNISON_FORCE_STATE` (опц. добавить `history-demo` для
  преднаполнения архива синтетикой).

## Открытые вопросы / v2

- AI-саммари и умный автозаголовок по смыслу встречи.
- Шифрование записей на диске.
- Корзина на 30 дней (undo удаления).
- Экспорт в Markdown/файл (в v1 — базовый txt через расширенный
  `exportAsText()`).
- Полнотекстовый поисковый индекс при больших объёмах.
- Правка `originalText` (в v1 read-only).
