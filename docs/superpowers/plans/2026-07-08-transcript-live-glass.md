# Живое стекло транскрипта — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Транскриптные стеклянные поверхности (баблы, контрол-пилл, поповер настроек, стоп-модалка) непрерывно пересэмплируют фон под окном, а не застывают на первом кадре.

**Architecture:** Новый примитив `LiquidGlassLive` вешает композитор-управляемый `NSGlassEffectView` (тот же механизм, что у окон онбординга/настроек/диагностики — обновляется каждый кадр) фоном под SwiftUI-контент через `NSViewRepresentable`. Форма поверхности (в т.ч. хвост бабла) держится `CAShapeLayer`-маской по пути SwiftUI-`Shape`. Под Reduce Transparency модификатор делегирует на существующий статичный `.liquidGlass` (наследует `.identity`-фолбэк). Меняем 4 точки вызова с `.liquidGlass` на `.liquidGlassLive`.

**Tech Stack:** Swift 6.2 (lang mode v5), SwiftUI + AppKit (`NSGlassEffectView`, `NSViewRepresentable`, `CAShapeLayer`), Swift Testing, macOS 26 Tahoe.

## Global Constraints

- Платформа: macOS 26 (Tahoe) baseline; таргет `UnisonUI` собирается в Swift language mode v5 (`langModeV5`).
- Lint: `scripts/lint.sh swiftlint` (`swiftlint lint --strict`) должен быть чист — без force-unwrap (кроме `fatalError("init(coder:) not used")` как в существующих representable), длина строки ≤ 120.
- Радиусы/формы должны совпадать с текущими: бабл — `UnevenRoundedRectangle` (18pt база + 5pt хвост × `scale`); пилл — `Capsule`; поповер — `RoundedRectangle(14)`; стоп-модалка — `RoundedRectangle(18)`.
- Тинты не трогаем — переиспользуем существующие значения (opacities ≤ 0.25) как есть.
- UI-копия — русская, без изменений (кода-копи в этой задаче нет).
- Тесты гоняем через `scripts/test.sh` (резолвит `Testing.framework` на CLT-only). Юнит-таргет здесь — `UnisonUITests`.
- Доступность: паритет с текущим по Reduce Transparency (`accessibilityReduceTransparency`) и Increase Contrast (`colorSchemeContrast == .increased` → 1.5pt хайрлайн).

---

## File Structure

- **Create** `Sources/UnisonUI/Design/LiquidGlassLive.swift` — примитив: `LiquidGlassContainerView` (тестируемый `NSView`), `LiquidGlassLive` (representable), `LiquidGlassLivePanel` + `.liquidGlassLive(...)` (модификатор, зеркалит `LiquidGlassPanel`/`.liquidGlass`).
- **Create** `Tests/UnisonUITests/LiquidGlassLiveTests.swift` — юнит-тесты на `LiquidGlassContainerView` (hit-test-прозрачность, вложенный `NSGlassEffectView`, маска по пути, форвардинг тинта).
- **Modify** `Sources/UnisonUI/Components/Bubble.swift:80` — `.liquidGlass(...)` → `.liquidGlassLive(...)`.
- **Modify** `Sources/UnisonUI/Components/ControlPill.swift:116` — `.liquidGlass(shape: Capsule())` → `.liquidGlassLive(shape: Capsule())`.
- **Modify** `Sources/UnisonUI/Components/TranscriptSettingsPopover.swift:45` — `.liquidGlass(cornerRadius: 14)` → `.liquidGlassLive(cornerRadius: 14)`.
- **Modify** `Sources/UnisonUI/Views/TranscriptView.swift:176` — стоп-модалка `.liquidGlass(cornerRadius: 18)` → `.liquidGlassLive(cornerRadius: 18)`.
- **Modify** `CLAUDE.md` — обновить раздел про два бэкенда стекла: транскриптные поверхности теперь на живом AppKit-пути через `.liquidGlassLive`.

Тесты транскрипта (`Tests/UnisonUITests/TranscriptViewSnapshotTests.swift`) — **smoke-only** (`snapSmoke`, без пиксельных эталонов): проверяют, что вью строится, раскладывается в нужный размер и рендерит непустой буфер. Пиксельных эталонов на меняемые поверхности нет (пилл/бабл/поповер/модалка живут только внутри `TranscriptView`, а он smoke-only), поэтому эталоны ломаться не должны — но smoke-тесты обязаны проходить после свапа.

---

## Task 1: Примитив `LiquidGlassLive` + юнит-тесты

**Files:**
- Create: `Sources/UnisonUI/Design/LiquidGlassLive.swift`
- Test: `Tests/UnisonUITests/LiquidGlassLiveTests.swift`

**Interfaces:**
- Produces:
  - `final class LiquidGlassContainerView: NSView` — `init(frame:)`; свойства `var pathProvider: (CGRect) -> CGPath`, `var glassTint: NSColor?`; `override func hitTest(_:) -> NSView?` (всегда `nil`); хостит один `NSGlassEffectView`, клипует его `CAShapeLayer`-маской в `layout()`.
  - `struct LiquidGlassLive<S: Shape>: NSViewRepresentable` — `init(shape: S, tint: Color?)`.
  - `func liquidGlassLive<S: InsettableShape>(shape: S, tint: Color? = nil, highContrastHairline: Bool = true) -> some View`
  - `func liquidGlassLive(cornerRadius: CGFloat = 14, tint: Color? = nil, highContrastHairline: Bool = true) -> some View`
- Consumes: `UnisonColors.whiteAlpha(_:)` (в `UnisonUIKit.swift`), существующий `.liquidGlass(...)` (в `LiquidGlassPanel.swift`).

- [ ] **Step 1: Написать падающие тесты**

Create `Tests/UnisonUITests/LiquidGlassLiveTests.swift`:

```swift
import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import UnisonUI

@MainActor
struct LiquidGlassLiveTests {

    @Test func containerHostsGlassAndIsHitTestTransparent() {
        let v = LiquidGlassContainerView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        // Хостит ровно один NSGlassEffectView.
        #expect(v.subviews.contains { $0 is NSGlassEffectView })
        // Чистая декорация — никогда не перехватывает указатель.
        #expect(v.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }

    @Test func glassFillsBoundsAfterLayout() {
        let v = LiquidGlassContainerView(frame: NSRect(x: 0, y: 0, width: 120, height: 50))
        v.needsLayout = true
        v.layoutSubtreeIfNeeded()
        let glass = v.subviews.first { $0 is NSGlassEffectView }
        #expect(glass?.frame == v.bounds)
    }

    @Test func maskTracksShapePath() {
        let v = LiquidGlassContainerView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        v.pathProvider = { RoundedRectangle(cornerRadius: 18, style: .continuous).path(in: $0).cgPath }
        v.needsLayout = true
        v.layoutSubtreeIfNeeded()
        let mask = v.layer?.mask as? CAShapeLayer
        #expect(mask != nil)
        // Путь покрывает прямоугольник вью (flip по Y сохраняет bbox).
        let bbox = mask?.path?.boundingBoxOfPath ?? .zero
        #expect(abs(bbox.width - 200) < 1.0)
        #expect(abs(bbox.height - 60) < 1.0)
    }

    @Test func tintForwardsToGlass() {
        let v = LiquidGlassContainerView(frame: .zero)
        let c = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.25)
        v.glassTint = c
        let glass = v.subviews.first { $0 is NSGlassEffectView } as? NSGlassEffectView
        #expect(glass?.tintColor == c)
    }
}
```

- [ ] **Step 2: Запустить — убедиться, что не компилится/падает**

Run: `scripts/test.sh --filter LiquidGlassLiveTests 2>&1 | tail -20`
Expected: FAIL — компиляция падает на `cannot find 'LiquidGlassContainerView' in scope` (тип ещё не создан).

- [ ] **Step 3: Создать примитив**

Create `Sources/UnisonUI/Design/LiquidGlassLive.swift`:

```swift
import AppKit
import QuartzCore
import SwiftUI

/// Живое, композитор-управляемое Liquid Glass для SwiftUI-поверхностей —
/// AppKit-двойник `LiquidGlassPanel` (`.glassEffect`). В отличие от
/// SwiftUI-стекла (статичного между перерисовками view-tree), этот путь
/// пересэмплирует фон каждый кадр, поэтому поверхность продолжает
/// подстраиваться, пока контент за окном движется. См. CLAUDE.md.
///
/// Вешается по-поверхностно как `.background`, hit-test-прозрачно — чтобы
/// не перехватывать мышь у drag-хэндла пилла и контролов поверх.

// MARK: - AppKit-контейнер (юнит-тестируемый, без SwiftUI Context)

/// Хостит `NSGlassEffectView`, клипованный произвольным путём формы.
/// Вынесен из representable, чтобы конструироваться и проверяться прямо
/// в тестах (`NSViewRepresentable.Context` вне SwiftUI не синтезируется).
final class LiquidGlassContainerView: NSView {
    private let glass = NSGlassEffectView()
    private let maskLayer = CAShapeLayer()

    /// bounds → путь клипа, в top-left системе SwiftUI (flip в `layout()`).
    var pathProvider: (CGRect) -> CGPath = { CGPath(rect: $0, transform: nil) } {
        didSet { needsLayout = true }
    }

    /// Тинт стекла (рефрагируется материалом, как `Glass.tint`).
    var glassTint: NSColor? {
        didSet { glass.tintColor = glassTint }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glass.style = .regular
        // Uniform cornerRadius = 0: клип делает маска формы, чтобы
        // сохранять неровный хвост бабла.
        glass.cornerRadius = 0
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        layer?.mask = maskLayer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // Чистая декорация: никогда не перехватываем указатель, чтобы
    // WindowDragHandle / слайдеры / кнопки поверх сохранили события.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        glass.frame = bounds
        // Пути SwiftUI — top-left origin; маски CALayer — bottom-left.
        // Flip по Y, чтобы верхне-тяжёлый хвост бабла лёг на верный край.
        let raw = pathProvider(bounds)
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
        maskLayer.path = raw.copy(using: &flip) ?? raw
    }
}

// MARK: - SwiftUI-мост

struct LiquidGlassLive<S: Shape>: NSViewRepresentable {
    let shape: S
    let tint: Color?

    func makeNSView(context: Context) -> LiquidGlassContainerView {
        let view = LiquidGlassContainerView(frame: .zero)
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: LiquidGlassContainerView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: LiquidGlassContainerView) {
        let shape = self.shape
        view.pathProvider = { rect in shape.path(in: rect).cgPath }
        view.glassTint = tint.map { NSColor($0) }
    }
}

// MARK: - Модификатор + сахар (зеркалит LiquidGlassPanel / .liquidGlass)

struct LiquidGlassLivePanel<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let highContrastHairline: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            // Reduce Transparency → делегируем на статичный путь: он даёт
            // `.identity`-стекло, так что a11y-паритет достаётся бесплатно.
            content.liquidGlass(shape: shape, tint: tint, highContrastHairline: highContrastHairline)
        } else {
            content
                .background { LiquidGlassLive(shape: shape, tint: tint) }
                .overlay {
                    if highContrastHairline && contrast == .increased {
                        shape.strokeBorder(UnisonColors.whiteAlpha(0.30), lineWidth: 1.5)
                    }
                }
        }
    }
}

extension View {
    /// Живое Liquid Glass с произвольной формой. Параметры зеркалят
    /// `.liquidGlass`; `highContrastHairline: false`, когда вызывающий
    /// рисует свой бордер (Bubble).
    func liquidGlassLive<S: InsettableShape>(
        shape: S,
        tint: Color? = nil,
        highContrastHairline: Bool = true
    ) -> some View {
        modifier(LiquidGlassLivePanel(
            shape: shape,
            tint: tint,
            highContrastHairline: highContrastHairline
        ))
    }

    /// Rounded-rectangle сокращение.
    func liquidGlassLive(
        cornerRadius: CGFloat = 14,
        tint: Color? = nil,
        highContrastHairline: Bool = true
    ) -> some View {
        liquidGlassLive(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            tint: tint,
            highContrastHairline: highContrastHairline
        )
    }
}
```

- [ ] **Step 4: Запустить тесты — убедиться, что зелёные**

Run: `scripts/test.sh --filter LiquidGlassLiveTests 2>&1 | tail -20`
Expected: PASS — 4 теста зелёные.

- [ ] **Step 5: Lint**

Run: `scripts/lint.sh swiftlint 2>&1 | tail -5`
Expected: `Lint clean.`

- [ ] **Step 6: Commit**

```bash
git add Sources/UnisonUI/Design/LiquidGlassLive.swift Tests/UnisonUITests/LiquidGlassLiveTests.swift docs/superpowers/specs/2026-07-08-transcript-live-glass-design.md docs/superpowers/plans/2026-07-08-transcript-live-glass.md
git commit -m "feat(ui): add LiquidGlassLive — live compositor glass primitive"
```

---

## Task 2: Свап бабла + VM-гейт живого сэмплинга (критический go/no-go)

Первую поверхность меняем отдельно, потому что это проверка ключевого риска: видит ли вложенное в прозрачную панель `NSGlassEffectView` фон за окном так же, как полноэкранное стекло онбординга.

**Files:**
- Modify: `Sources/UnisonUI/Components/Bubble.swift:80`

**Interfaces:**
- Consumes: `.liquidGlassLive(shape:tint:highContrastHairline:)` из Task 1.

- [ ] **Step 1: Заменить бэкенд стекла у бабла**

В `Sources/UnisonUI/Components/Bubble.swift`, в `body`, строка:

```swift
        .liquidGlass(shape: shape, tint: tintColor, highContrastHairline: false)
```

заменить на:

```swift
        .liquidGlassLive(shape: shape, tint: tintColor, highContrastHairline: false)
```

(`.overlay(shape.strokeBorder(...))` ниже и всё остальное — без изменений.)

- [ ] **Step 2: Smoke-тесты транскрипта проходят**

Run: `scripts/test.sh --filter TranscriptViewSnapshotTests 2>&1 | tail -20`
Expected: PASS — все `transcript_*` кейсы рендерят непустой буфер нужного размера (вложенный `NSGlassEffectView` не роняет offscreen-рендер `cacheDisplay`).

- [ ] **Step 3: Lint**

Run: `scripts/lint.sh swiftlint 2>&1 | tail -5`
Expected: `Lint clean.`

- [ ] **Step 4: Собрать бандл для VM**

Run: `make build 2>&1 | tail -5`
Expected: сборка успешна → `build/Unison.app`.

- [ ] **Step 5: VM-скриншот транскрипта над цветным фоном**

Run: `bash scripts/vm-screenshot.sh transcript 2>&1 | tail -20`
Expected: `vm-screenshots/transcript.png` создан. Открыть PNG и проверить глазами: **стекло бабла подхватывает цвет/текстуру фона за панелью** (не плоско-серое). Это доказывает, что вложенное `NSGlassEffectView` сэмплит backdrop; непрерывность («живость») тогда следует из того же композитор-механизма, что уже гарантированно живой в окне онбординга.

> **GO / NO-GO:** если стекло бабла явно отражает фон → механизм рабочий, продолжаем Task 3. Если стекло рендерится плоским независимо от фона → вложенный сэмплинг не работает; **стоп**, переходим к фолбэку (см. ниже) и не свапаем остальные 3 поверхности.

> **Фолбэк (только если гейт провален):** хостить каждую поверхность ровно как окна онбординга/настроек — `NSGlassEffectView` как верхний слой с SwiftUI внутри `contentView` (паттерн `GlassHostingViewController`), т.е. дочерние glass-панели/хосты, позиционируемые под каждый бабл. Детализируется отдельным под-планом, если понадобится.

- [ ] **Step 6: Commit**

```bash
git add Sources/UnisonUI/Components/Bubble.swift
git commit -m "feat(ui): bubbles use live glass (verified samples backdrop in VM)"
```

---

## Task 3: Свап остальных поверхностей (пилл, поповер, стоп-модалка)

Выполнять **только** если Task 2 прошёл GO-гейт.

**Files:**
- Modify: `Sources/UnisonUI/Components/ControlPill.swift:116`
- Modify: `Sources/UnisonUI/Components/TranscriptSettingsPopover.swift:45`
- Modify: `Sources/UnisonUI/Views/TranscriptView.swift:176`

**Interfaces:**
- Consumes: `.liquidGlassLive(shape:...)` и `.liquidGlassLive(cornerRadius:...)` из Task 1.

- [ ] **Step 1: Контрол-пилл**

В `Sources/UnisonUI/Components/ControlPill.swift`, в `body`, строка:

```swift
        .liquidGlass(shape: Capsule())
```

заменить на:

```swift
        .liquidGlassLive(shape: Capsule())
```

(`.background(WindowDragHandle())` выше остаётся: живое стекло hit-test-прозрачно и стоит позади drag-хэндла, так что перетаскивание панели сохраняется.)

- [ ] **Step 2: Поповер настроек**

В `Sources/UnisonUI/Components/TranscriptSettingsPopover.swift`, в `body`, строка:

```swift
        .liquidGlass(cornerRadius: 14)
```

заменить на:

```swift
        .liquidGlassLive(cornerRadius: 14)
```

- [ ] **Step 3: Стоп-модалка**

В `Sources/UnisonUI/Views/TranscriptView.swift`, в `stopModal`, строка:

```swift
            .liquidGlass(cornerRadius: 18)
```

заменить на:

```swift
            .liquidGlassLive(cornerRadius: 18)
```

(Две стеклянные кнопки внутри модалки — `.buttonStyle(.glass)`/`.glassProminent` — **не трогаем**: это интерактивные SwiftUI-контролы, вне охвата.)

- [ ] **Step 4: Smoke-тесты транскрипта проходят**

Run: `scripts/test.sh --filter TranscriptViewSnapshotTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Lint**

Run: `scripts/lint.sh swiftlint 2>&1 | tail -5`
Expected: `Lint clean.`

- [ ] **Step 6: Commit**

```bash
git add Sources/UnisonUI/Components/ControlPill.swift Sources/UnisonUI/Components/TranscriptSettingsPopover.swift Sources/UnisonUI/Views/TranscriptView.swift
git commit -m "feat(ui): pill, settings popover, stop modal use live glass"
```

---

## Task 4: Полная верификация + обновление доков

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Полный UI-сьют (серийно)**

Run: `scripts/test.sh --filter UnisonUITests --no-parallel 2>&1 | tail -30`
Expected: PASS — весь `UnisonUITests` зелёный (snapshot-эталоны опаковых карточек не тронуты; транскриптные smoke-кейсы рендерятся; новые `LiquidGlassLiveTests` зелёные).

- [ ] **Step 2: Полный lint (swiftlint + periphery)**

Run: `scripts/lint.sh 2>&1 | tail -15`
Expected: `Lint clean.` (SwiftLint strict без нарушений; Periphery информационно — новый API используется из 4 точек, «unused» не должно быть).

- [ ] **Step 3: Сборка бандла**

Run: `make build 2>&1 | tail -5`
Expected: успех → `build/Unison.app`.

- [ ] **Step 4: VM — все поверхности + режимы доступности**

Run: `bash scripts/vm-screenshot.sh transcript 2>&1 | tail -10`
Expected: `vm-screenshots/transcript.png`. Проверить глазами:
- Бабл(ы), контрол-пилл — стекло отражает фон.
- (Если харнесс умеет) открыть настройки/стоп-модалку — те же поверхности живые.
- Drag панели за пилл работает; слайдеры поповера двигаются; кнопки модалки нажимаются (интерактивная проверка `bash scripts/vm-screenshot.sh --keep-running transcript`, затем вручную в графическом VM).
- Reduce Transparency (Системные настройки → Универсальный доступ) → стекло уходит в статичный `.identity`-фолбэк без краша.
- Increase Contrast → 1.5pt хайрлайн присутствует на пилле/поповере/модалке.

- [ ] **Step 5: Обновить CLAUDE.md**

В `CLAUDE.md`, в разделе «Liquid Glass — two backends behind one API», обновить описание SwiftUI-пути: транскриптные поверхности (баблы, пилл, поповер, стоп-модалка) больше **не** статичны — они переведены на живой AppKit-путь через `.liquidGlassLive` (`NSGlassEffectView` под SwiftUI-контентом), а статичный `.liquidGlass` остаётся для не-транскриптных SwiftUI-поверхностей и как Reduce-Transparency-фолбэк. Обновить строку про то, что «transcript window is the only one without panel-level glass» — уточнить, что теперь каждый бабл/пилл/поповер/модалка красит своё **живое** стекло.

Точный дифф (заменить абзац про SwiftUI-бэкенд):

```markdown
- **SwiftUI views** (non-transcript glass: primary button, menubar
  popover): go through `.liquidGlass(...)` → `LiquidGlassPanel` →
  `.glassEffect(in:)`. **Static between view-tree redraws.**
- **Transcript surfaces** (bubbles, control pill, settings popover, stop
  modal): go through `.liquidGlassLive(...)` → `LiquidGlassLive` →
  `NSGlassEffectView` behind the SwiftUI content. **Compositor-managed
  and live** — re-samples the backdrop every frame, so bubbles keep
  adapting as call content moves under them. Falls back to the static
  `.liquidGlass` path under Reduce Transparency.
```

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: transcript surfaces now use live glass (.liquidGlassLive)"
```

---

## Self-Review

**1. Spec coverage:**
- Примитив `LiquidGlassLive` + модификатор `.liquidGlassLive` — Task 1. ✓
- 4 точки подключения (Bubble, ControlPill, TranscriptSettingsPopover, стоп-модалка) — Task 2 (бабл) + Task 3 (остальные). ✓
- Форма/хвост через маску — Task 1 (`layout()` + `pathProvider` + flip), тест `maskTracksShapePath`. ✓
- Тинт → `NSGlassEffectView.tintColor` — Task 1, тест `tintForwardsToGlass`. ✓
- hit-test-прозрачность (drag пилла, слайдеры) — Task 1, тест `containerHostsGlassAndIsHitTestTransparent`; проверка drag — Task 4. ✓
- Reduce Transparency → делегация на статичный путь — Task 1 (`LiquidGlassLivePanel.body`); проверка — Task 4. ✓
- Increase Contrast хайрлайн — Task 1 (overlay); проверка — Task 4. ✓
- Вне охвата (стеклянные кнопки модалки) — зафиксировано в Task 3 Step 3. ✓
- Ключевой риск (вложенный сэмплинг) + фолбэк — Task 2 Step 5 (go/no-go гейт). ✓
- Тестовый порядок (сьют + swiftlint + VM-скриншот, затем ручное) — Task 4. ✓

**2. Placeholder scan:** плейсхолдеров нет; фолбэк-под-план сознательно отложен до провала гейта (в самом плане кода фолбэка нет, потому что при GO он не нужен) — это не заглушка в основном потоке.

**3. Type consistency:** `LiquidGlassContainerView` / `pathProvider` / `glassTint` / `LiquidGlassLive(shape:tint:)` / `.liquidGlassLive(shape:tint:highContrastHairline:)` / `.liquidGlassLive(cornerRadius:tint:highContrastHairline:)` — имена совпадают между Task 1 (определение + тесты) и Task 2–3 (вызовы). ✓
