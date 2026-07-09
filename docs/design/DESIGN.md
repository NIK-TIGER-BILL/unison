# Unison — Design System

Дата: 2026-05-20
Статус: эволюционирует с дизайн-итерациями. Каждый новый компонент следует здешним правилам.

Этот документ — единая точка правды по визуальному и UX-языку приложения. Все решения зафиксированы из 8 раундов итерации popover'а. Для следующих окон (onboarding, settings, transcript) — отталкиваться отсюда.

---

## 1. Эстетика: Aurora Liquid Glass

Базовая визуальная идея: **полупрозрачные стеклянные панели поверх живых градиентов с световой рефракцией**. Источник вдохновения — Apple Liquid Glass (macOS Tahoe 26 / iOS 26), но более «дышащий» и тёплый.

### 1.1 Фон (desktop / background)

Дальний слой — тёмный фиолетово-синий с пятнами цветной авроры:

```css
.desktop {
  background:
    radial-gradient(ellipse 60% 50% at 80% 30%, rgba(100, 230, 255, 0.45), transparent 60%),
    radial-gradient(ellipse 70% 60% at 25% 70%, rgba(255, 110, 200, 0.40), transparent 60%),
    radial-gradient(ellipse 50% 40% at 60% 90%, rgba(150, 100, 255, 0.30), transparent 60%),
    linear-gradient(180deg, #0a0820 0%, #100c2e 50%, #1a1142 100%);
}
```

Пятна: голубое (тек.) / маджента / лавандовое — позиции варьируются для разных окон чтобы не было монотонности.

### 1.2 Liquid Glass материал

SVG-фильтр для рефракции (включается через `backdrop-filter: ... url(#liquidGlass)`):

```svg
<filter id="liquidGlass" x="-10%" y="-10%" width="120%" height="120%">
  <feTurbulence type="fractalNoise" baseFrequency="0.012 0.018" numOctaves="2" seed="9" result="noise"/>
  <feGaussianBlur in="noise" stdDeviation="3" result="blurredNoise"/>
  <feDisplacementMap in="SourceGraphic" in2="blurredNoise" scale="14" xChannelSelector="R" yChannelSelector="G"/>
</filter>
```

Применение:

```css
.panel {
  background: linear-gradient(180deg, rgba(255,255,255,0.08), rgba(255,255,255,0.02));
  backdrop-filter: blur(20px) saturate(160%) url(#liquidGlass);
  -webkit-backdrop-filter: blur(20px) saturate(160%);
  border-radius: 24px;
  box-shadow:
    0 32px 80px -8px rgba(0,0,0,0.55),
    inset 0 1px 0 rgba(255,255,255,0.20),
    inset 0 -1px 0 rgba(0,0,0,0.4),
    inset 1px 0 0 rgba(255,255,255,0.06),
    inset -1px 0 0 rgba(255,255,255,0.06);
}
```

Размытие: `blur(20px)` — основные панели, `blur(36px)` — оверлеи/дропдауны (для большей изоляции от фона).

### 1.3 Decorative layers на стекле

Два псевдо-элемента дают живость стеклу:

**Specular highlight** (верхняя «капля» света):

```css
.panel::before {
  content: "";
  position: absolute;
  top: 0; left: 0; right: 0;
  height: 60%;
  background:
    linear-gradient(180deg, rgba(255,255,255,0.16) 0%, transparent 35%),
    radial-gradient(ellipse 100% 60% at 30% 0%, rgba(255,255,255,0.22), transparent 70%);
  border-radius: 24px 24px 50% 50% / 24px 24px 30% 30%;
  pointer-events: none;
  mix-blend-mode: screen;
}
```

**Conic rim** (переливающийся периметр):

```css
.panel::after {
  content: "";
  position: absolute;
  inset: 0;
  border-radius: 24px;
  padding: 1px;
  background: conic-gradient(from 135deg at 50% 50%,
    rgba(255,255,255,0.4), rgba(255,255,255,0.05) 25%,
    rgba(255,255,255,0.4) 50%, rgba(255,255,255,0.05) 75%, rgba(255,255,255,0.4));
  -webkit-mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0);
  -webkit-mask-composite: xor;
  mask-composite: exclude;
  pointer-events: none;
  opacity: 0.55;
}
```

### 1.4 `.glass` — общий примитив

Чтобы все стеклянные элементы (pill, popover, dropdown) выглядели **одинаково**, базовый материал вынесен в один класс. Форма (radius, padding, layout) задаётся уже специфичным классом.

```css
.glass {
  position: relative;
  background: rgba(20, 22, 30, 0.55);
  backdrop-filter: blur(36px) saturate(200%) url(#liquidGlassSubtle);
  -webkit-backdrop-filter: blur(36px) saturate(200%);
  border: 0.5px solid rgba(255,255,255,0.13);
  box-shadow:
    0 16px 36px rgba(0,0,0,0.5),
    inset 0 1px 0 rgba(255,255,255,0.16);
}
.glass::after {
  /* conic rim, border-radius: inherit от формы-класса */
  content: ""; position: absolute; inset: 0;
  border-radius: inherit; padding: 1px;
  background: conic-gradient(from 120deg at 50% 50%,
    rgba(255,255,255,0.45), rgba(255,255,255,0.05) 25%,
    rgba(255,255,255,0.35) 50%, rgba(255,255,255,0.05) 75%, rgba(255,255,255,0.45));
  -webkit-mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0);
  -webkit-mask-composite: xor; mask-composite: exclude;
  pointer-events: none; opacity: 0.5;
}
```

Применение:

```html
<div class="glass control-pill">…</div>
<div class="glass settings-popover">…</div>
<div class="glass lang-dropdown">…</div>
```

Форма-класс держит **только** свои отличия: `border-radius`, `padding`, `display`, transitions, поведение. Никаких дублирующих `background` / `backdrop-filter` / `border` / `box-shadow`.

> Это правило критично для консистентности. Если стеклу нужен другой материал (modal: ярче, светлее) — создаём `.glass-raised`, не дублируем свойства в form-классе.

---

## 2. Типографика

### 2.1 Шрифты

| Назначение | Шрифт | Вес | Где |
|---|---|---|---|
| UI body + заголовки окон | **DM Sans** | 200 / 300 / 400 / 500 / 600 / 700 | Все UI, включая h1/h2 в окнах приложения |
| Mono / data | **IBM Plex Mono** | 300 / 400 | Caps-лейблы, timestamps, числовые данные, code-style accents |
| Native (только меню-бар) | system-ui / SF Pro | regular / semibold | Имитация macOS menu bar |

> **Изменение от R1:** Fraunces (serif) убран из заголовков. Слишком формальный/тяжёлый при больших размерах. DM Sans 300 в больших размерах (24–30px) даёт лёгкое и современное звучание без классических засечек.

> Fraunces в design-page header'ах (мета-страницы для дизайнерского просмотра) допустим — это не production UI. Но во всех окнах приложения используется только DM Sans.

Подключение Google Fonts:

```html
<link href="https://fonts.googleapis.com/css2?family=DM+Sans:opsz,wght@9..40,200;9..40,300;9..40,400;9..40,500;9..40,600;9..40,700&family=IBM+Plex+Mono:wght@300;400&display=swap" rel="stylesheet">
```

### 2.2 Размеры и трекинг

| Роль | Размер | Шрифт + вес | Трекинг |
|---|---|---|---|
| Window title (h1) | 24–30px | DM Sans 300 | -0.03em |
| H3 sub-section | 11px | IBM Plex Mono 400 | +0.12em UPPER |
| Body | 13–14px | DM Sans 500 | -0.005em |
| Brand text | 13px | DM Sans 600 | -0.02em |
| Lang value | 15px | DM Sans 500 | -0.01em |
| Card title | 14.5px | DM Sans 500 | -0.01em |
| Mini-label (caps) | 9.5px | DM Sans 500 | +0.13em UPPER |
| Mono caption | 10–11.5px | IBM Plex Mono 400 | +0.04em |
| Hint / secondary | 12–13px | DM Sans 400 | -0.005em |

---

## 3. Цветовая палитра

```css
:root {
  /* Page level */
  --page-bg:   #08080a;  /* base, для design-страниц */
  --page-fg:   #f5f5f7;  /* primary text */
  --page-mute: #8e8e93;  /* secondary text */

  /* Семантика (только) */
  --ready:     #58e09a;  /* зелёный — ready / OK / toggle on */
  --active:    #5ac8fa;  /* голубой — translating, pulse, menubar active icon */
  --warn:      #ffc060;  /* янтарный — validation warnings */
  --stop:      #ff6e82;  /* коралловый — stop / destructive / error */
}
```

> **Нет accent-цвета.** UI Unison использует только нейтральную палитру (белый разной прозрачности на тёмном) + семантика (ready/active/warn/stop). Никакого зарезервированного «акцентного» цвета для selected / focus / chevron / hover — все эти состояния обозначаются прозрачностью белого, толщиной шрифта, или толщиной линии. Это снимает визуальный шум, не привязывает приложение к одному оттенку, и сохраняет фокус на контенте.

### 3.1 Использование

- **Нейтральная палитра** — состояния выделения (selected, hover, focus, open) обозначаются rgba(255,255,255, opacity) и/или `font-weight`. Например, selected lang option = `color: #fff; font-weight: 600;` на фоне обычного `rgba(255,255,255,0.85)`.
- **Семантика** — точечно: статус-точка (ready / active / warn / error), warn-row, stop-button gradient, menubar active state (pulse cyan).
- **Текст** — три уровня: primary (`#f5f5f7`), muted (`#8e8e93`), faded (`rgba(255,255,255,0.4)`).

### 3.2 Avoid

- Жёсткие чистые цвета (#FF0000, #00FF00) — только мягкие, чуть притушенные
- Зелёный для CTA — это семантически "ready/OK", не "primary action"
- Голубой для primary action — слишком "Apple Settings"; primary action — белая стеклянная

---

## 4. Spacing & sizing

### 4.1 Padding / gap скейл (4-base)

`4 · 6 · 8 · 10 · 12 · 14 · 16 · 20 · 24 · 28 · 32 · 48 · 56 · 64`

Этот скейл покрывает 95% случаев. Не делать `9px`, `13px` — округлять.

### 4.2 Радиусы

| Элемент | Радиус |
|---|---|
| Главная панель (popover, окно) | 22–26px |
| Внутренние блоки (lang-bar, dropdown) | 12–13px |
| Кнопки крупные (Start) | 12–13px |
| Кнопки маленькие (gear, mode-seg) | 7–8px |
| Pills (search S3, status badge) | 99px |
| Lang-option, search row | 8px |

### 4.3 Размеры popover-like окон

- Popover (menu-bar): **340px** ширина (точно `340` — не больше, не меньше)
- Floating window (transcript): TBD (будет в next раунде)
- Onboarding: ~460-540px (single-page)
- Settings: ~460px

---

## 5. Компоненты

### 5.1 Главная стеклянная панель

См. §1.2–1.3. Это `.popover` в финальном popover'е.

### 5.2 Кнопка primary (Start-style)

```css
.start-btn {
  display: flex; align-items: center; justify-content: center; gap: 8px;
  width: 100%;
  background: linear-gradient(180deg, rgba(255,255,255,0.22), rgba(255,255,255,0.08));
  border: 0.5px solid rgba(255,255,255,0.22);
  color: #fff;
  padding: 13px;
  border-radius: 13px;
  font-weight: 600;
  font-size: 14px;
  cursor: pointer;
  box-shadow:
    inset 0 1px 0 rgba(255,255,255,0.28),
    inset 0 -1px 0 rgba(0,0,0,0.15),
    0 4px 12px rgba(0,0,0,0.28);
  text-shadow: 0 1px 1px rgba(0,0,0,0.25);
  transition: background 0.16s, transform 0.08s, box-shadow 0.16s, opacity 0.16s;
}
.start-btn:hover  { background: linear-gradient(180deg, rgba(255,255,255,0.30), rgba(255,255,255,0.12)); }
.start-btn:active { background: linear-gradient(180deg, rgba(255,255,255,0.14), rgba(255,255,255,0.04)); transform: scale(0.98); }
.start-btn:disabled {
  background: linear-gradient(180deg, rgba(255,255,255,0.06), rgba(255,255,255,0.02));
  color: rgba(255,255,255,0.4);
  cursor: not-allowed;
  border-color: rgba(255,255,255,0.10);
  box-shadow: inset 0 1px 0 rgba(255,255,255,0.06);
  transform: none;
}
```

Destructive вариант (stop):

```css
.start-btn.destructive {
  background: linear-gradient(180deg, rgba(255, 110, 130, 0.42), rgba(220, 60, 90, 0.28));
  border-color: rgba(255, 110, 130, 0.4);
  box-shadow:
    inset 0 1px 0 rgba(255,255,255,0.22),
    inset 0 -1px 0 rgba(0,0,0,0.2),
    0 4px 14px rgba(220, 60, 90, 0.32);
}
```

### 5.3 Кнопка iconic (gear, mode-seg)

```css
.icon-btn {
  width: 28px; height: 28px;
  display: inline-flex; align-items: center; justify-content: center;
  color: rgba(255,255,255,0.55);
  border-radius: 7px;
  transition: background-color 0.15s, color 0.15s, transform 0.1s;
}
.icon-btn:hover  { color: #fff; background: rgba(255,255,255,0.10); }
.icon-btn:active { transform: scale(0.94); background: rgba(255,255,255,0.06); }
```

### 5.4 Segmented control (mode toggle Call/Listen)

A single **selection chip slides** between the two halves rather than each
segment lighting its own background. In the app the chip is live Liquid
Glass (`NSGlassEffectView` via `.liquidGlassLive`) with a low white tint
(≤ 0.16 — higher flattens the material) plus a top-lit rim; it is
positioned with `matchedGeometryEffect` (not a `GeometryReader`, which can
crash the popover's auto-sizing host). The slide uses the web reference's
`cubic-bezier(0.16, 1, 0.3, 1)` @ 300ms (`UnisonAnimations.segmentSlide`).
Under Reduce Transparency the glass resolves to `.identity`, so the chip
swaps in a solid fallback fill; under Increase Contrast it gains a
hairline border. The CSS below approximates the look (the sliding tint +
rim); it can't reproduce the live refraction.

```css
.segmented {
  position: relative;
  display: grid; grid-template-columns: 1fr 1fr;
  padding: 3px;
  background: rgba(0,0,0,0.22);
  border-radius: 11px;
  box-shadow: inset 0 0 0 0.5px rgba(0,0,0,0.25);
}
/* Sliding selection chip — one tile that springs between the halves. */
.segmented::after {
  content: "";
  position: absolute; top: 3px; bottom: 3px; left: 3px;
  width: calc(50% - 3px);
  border-radius: 8px;
  background: rgba(255,255,255,0.14);            /* the glass tint */
  box-shadow: inset 0 0.6px 0 rgba(255,255,255,0.38),   /* top-lit rim */
              inset 0 -0.6px 0 rgba(255,255,255,0.10);
  transition: transform 0.3s cubic-bezier(0.16, 1, 0.3, 1);
}
.segmented[data-mode="listen"]::after { transform: translateX(100%); }
.segmented .seg {
  position: relative; z-index: 1;
  padding: 8px 0; text-align: center;
  font-size: 12.5px; font-weight: 500;
  color: rgba(255,255,255,0.6);                  /* inactive */
}
.segmented .seg.on {
  color: #fff;                                   /* active */
  text-shadow: 0 1px 0 rgba(0,0,0,0.25);
}
```

### 5.5 Status dot

Цвет ↔ состояние:

| Цвет | Состояние | Особенность |
|---|---|---|
| `#58e09a` (зелёный) | Ready / idle | Glow 8px |
| `#5ac8fa` (голубой) | Translating | + анимация pulse 1.6s |
| `#ffc060` (янтарный) | Warning (валидация) | Glow 8px |
| `#ff6e82` (коралл) | Error | (TBD, ещё не использовалось) |

```css
.dot {
  width: 7px; height: 7px;
  border-radius: 50%;
  background: #58e09a;
  box-shadow: 0 0 8px rgba(88, 224, 154, 0.65);
  transition: background-color 0.3s, box-shadow 0.3s;
}
```

### 5.6 Inline label-pair (key/value)

Шаблон для «Я говорю / Русский»:

```html
<div class="lang-side">
  <div class="lang-lbl">Я говорю</div>
  <div class="lang-val"><span class="flag">🇷🇺</span> Русский</div>
</div>
```

```css
.lang-lbl {
  font-size: 9.5px;
  color: rgba(255,255,255,0.45);
  text-transform: uppercase;
  letter-spacing: 0.13em;
  font-weight: 500;
  margin-bottom: 4px;
}
.lang-val {
  font-size: 15px;
  font-weight: 500;
  letter-spacing: -0.01em;
}
```

### 5.7 Dropdown (portal pattern)

Dropdown ВСЕГДА вынесен из своего «anchor» элемента (для backdrop-filter работал корректно над всем что внутри родителя).

Структура: dropdown — sibling главной панели в parent-wrap'е, не child anchor'а.

Стили:

```css
.dropdown {
  position: absolute;  /* координаты через JS на open */
  width: 200px;
  background: rgba(20, 20, 30, 0.62);
  backdrop-filter: blur(36px) saturate(200%);
  -webkit-backdrop-filter: blur(36px) saturate(200%);
  border-radius: 13px;
  padding: 5px;
  border: 0.5px solid rgba(255,255,255,0.12);
  box-shadow:
    0 18px 44px rgba(0,0,0,0.6),
    inset 0 1px 0 rgba(255,255,255,0.12),
    inset 0 -1px 0 rgba(0,0,0,0.3);

  opacity: 0;
  transform: translateY(-4px) scale(0.96);
  pointer-events: none;
  transition: opacity 0.16s, transform 0.16s;
}
.dropdown.open {
  opacity: 1;
  transform: translateY(0) scale(1);
  pointer-events: auto;
}
```

### 5.8 Search input (ghost underline / S1)

Без фона. Только нижняя полоска, которая на focus становится розовой.

```css
.search-row {
  display: flex; align-items: center; gap: 7px;
  padding: 8px 10px 7px;
  border-bottom: 0.5px solid rgba(255,255,255,0.12);
  margin: 0 2px 6px;
  transition: border-color 0.16s;
}
.search-row:focus-within { border-color: rgba(255, 255, 255, 0.32); }
.search-row .search-icon { width: 11px; height: 11px; color: rgba(255,255,255,0.35); transition: color 0.16s; }
.search-row:focus-within .search-icon { color: rgba(255,255,255,0.78); }
.search-input {
  flex: 1; background: transparent; border: none; outline: none;
  color: rgba(255,255,255,0.95);
  font-family: inherit;
  font-size: 12.5px;
}
.search-input::placeholder { color: rgba(255,255,255,0.35); }
```

### 5.9 Warning row (валидация)

```css
.warn-row {
  display: flex; align-items: center; gap: 6px;
  padding: 8px 12px;
  background: rgba(255, 192, 96, 0.10);
  border: 0.5px solid rgba(255, 192, 96, 0.28);
  border-radius: 9px;
  font-size: 11.5px;
  color: rgba(255, 220, 170, 0.95);
  animation: warnFade 0.2s ease-out;
}
.warn-row .warn-icon { width: 12px; height: 12px; color: var(--warn); flex-shrink: 0; }
```

### 5.10 Error state (cards / steps)

Применяется к карточкам или блокам которые могут failed (BlackHole install, mic permission, key validation, etc.).

```css
.step-card.error {
  background: rgba(255, 122, 140, 0.05);
  border-color: rgba(255, 122, 140, 0.28);
}
.step-card.error .icon {
  color: var(--error);  /* #ff7a8c */
  background: rgba(255, 122, 140, 0.12);
  border-color: rgba(255, 122, 140, 0.32);
}

.error-row {
  display: flex; align-items: flex-start; gap: 8px;
  padding: 10px 12px;
  background: rgba(255, 122, 140, 0.08);
  border: 0.5px solid rgba(255, 122, 140, 0.22);
  border-radius: 9px;
  margin-top: 12px;
  animation: errFade 0.22s ease-out;
}
.error-row .err-icon { width: 13px; height: 13px; color: var(--error); flex-shrink: 0; margin-top: 1px; }
.error-row .err-text {
  flex: 1;
  font-size: 12px;
  color: rgba(255, 200, 210, 0.95);
  line-height: 1.45;
}
.error-row .err-text strong { color: #fff; font-weight: 500; display: block; margin-bottom: 1px; }
.error-row .err-action {
  padding: 4px 9px;
  font-size: 11.5px;
  color: var(--error);
  background: rgba(255, 122, 140, 0.08);
  border: 0.5px solid rgba(255, 122, 140, 0.2);
  border-radius: 6px;
  transition: background 0.15s;
}
.error-row .err-action:hover { background: rgba(255, 122, 140, 0.16); color: #fff; }
```

**Структура** error-row: `[⚠ icon] [<strong>заголовок</strong> · детали] [контекстная-кнопка]`

**Контекстные кнопки:**
- «Повторить» — для retryable ошибок (install failed, network)
- «Открыть Настройки ↗» — для permissions denied (с `icon-external`)
- Inline-валидация без кнопки — для form-input ошибок (исправь и сохрани заново)

### 5.11 Secret/password input + toggle

```html
<div class="key-input-wrap">
  <input type="password" class="key-input" placeholder="sk-proj-...">
  <button class="toggle-text">Показать</button>
</div>
```

```css
.toggle-text {
  font-size: 11px;
  color: rgba(255,255,255,0.5);
  padding: 4px 8px;
  border-radius: 5px;
  font-weight: 500;
  white-space: nowrap;
  cursor: pointer;
  transition: color 0.15s, background 0.15s;
}
.toggle-text:hover { color: rgba(255,255,255,0.95); background: rgba(255,255,255,0.06); }
```

> **Не использовать иконку глаза.** Текст «Показать»/«Скрыть» — лучше для accessibility (screen readers) и более явный по интенту. На малых размерах icon-eye становится нечитаемым.

### 5.12 Inline link

Для ссылок которые встречаются под формами / в hint-зонах.

```css
.link-muted {
  color: rgba(255,255,255,0.5);
  text-decoration: none;
  display: inline-flex; align-items: center; gap: 4px;
  padding: 2px 6px;
  margin-left: -6px;
  border-radius: 5px;
  font-size: 11.5px;
  transition: color 0.15s, background 0.15s;
}
.link-muted:hover { color: rgba(255,255,255,0.95); background: rgba(255,255,255,0.06); }
.link-muted svg { width: 10px; height: 10px; opacity: 0.7; }
```

> **Цвет ссылки — нейтральный muted.** В UI Unison нет «акцентного» цвета — все состояния (selected, focus, link, hover) выражаются прозрачностью белого и font-weight. Ссылки и подсказки используют `rgba(255,255,255,0.5)`, активный selected — `#fff; font-weight: 600`. Это сохраняет фокус на контенте и не привязывает приложение к конкретному оттенку.

### 5.13 Slider (T2 · Vertical handle, neutral)

Кастомный `<input type="range">` — все слайдеры в Unison имеют одну форму, нейтральная палитра.

```css
.slider {
  -webkit-appearance: none; appearance: none;
  height: 6px; border-radius: 3px;
  --val: 50%;
  --val-opacity: 0.55;
  background: linear-gradient(to right,
    rgba(255,255,255, var(--val-opacity)) 0%,
    rgba(255,255,255, var(--val-opacity)) var(--val),
    rgba(255,255,255, 0.10) var(--val),
    rgba(255,255,255, 0.10) 100%);
  outline: none; cursor: pointer;
}
.slider::-webkit-slider-thumb {
  -webkit-appearance: none; appearance: none;
  width: 4px; height: 18px;
  background: linear-gradient(180deg, #fff, #ddd);
  border-radius: 2px; cursor: grab;
  box-shadow: 0 2px 6px rgba(0,0,0,0.5);
  transition: height 140ms ease, box-shadow 140ms ease;
}
.slider:hover::-webkit-slider-thumb { height: 20px; box-shadow: 0 3px 9px rgba(0,0,0,0.55); }
```

Плавность за счёт `@property`:
```css
@property --val { syntax: '<percentage>'; inherits: false; initial-value: 50%; }
@property --val-opacity { syntax: '<number>'; inherits: false; initial-value: 0.55; }
```

JS обновляет `--val` (позиция fill) и `--val-opacity` (яркость fill: `0.12 → 0.85` по value). Без transition — fill следует за thumb мгновенно.

Для дискретных пресетов (XS/S/M/L/XL) — `step="any"` + label через `Math.round(value)`. Это даёт плавное движение thumb, дискретные подписи, и плавную интерполяцию применяемого эффекта (например `--bubble-scale`).

### 5.14 Transcript bubble (T1 · corner-tail + B3 inverted hierarchy)

**Базовая форма:**
- `border-radius: 18px × scale` на всех углах, кроме одного — со стороны говорящего (`bubble-{left|right}-radius: 5px × scale`). Это «хвостик» — визуальный sender indicator.
- `.me` — слева (`align-self: flex-start`, tail bottom-left, голубоватый tint)
- `.peer` — справа (`align-self: flex-end`, tail bottom-right, нейтрально-белый tint)
- Stage: `backdrop-filter: blur(30px) saturate(190%) url(#liquidGlassSubtle)`, soft inset highlight + shadow

**Иерархия текста (B3 inverted):**
- `.primary` (большой, weight 500) — **«мой» язык** (выбранный в popover как «Я говорю»)
- `.secondary` (italic, 11px × scale, 52% opacity) — параллельный язык
- Для `.me` bubble: `primary = .o (оригинал)`, `secondary = .t (перевод)`
- Для `.peer` bubble: `primary = .t (перевод)`, `secondary = .o (оригинал)`
- Логика: я всегда читаю primary на родном языке; secondary остаётся как «фон внимания»

**Группировка (один говорящий = одна группа):**
- Пока говорит один человек — новые bubble получают класс `.continued`, gap уменьшается с `14px × scale` до `3px × scale`, верхний corner со стороны tail смягчается до `8px × scale`
- Tail (`5px × scale`) остаётся только у **последнего** bubble в группе; у промежуточных — класс `.no-tail` (corner возвращается к `18px × scale`)
- При смене говорящего — группа закрывается, новая открывается с противоположной стороны

**Split длинных реплик:**
- Порог `SPLIT_THRESHOLD = 240 символов`
- При превышении — текст режется на чанки по границам предложений (`/[^.!?]+[.!?]+\s*/`) и каждый чанк становится отдельным continuous bubble той же группы
- Это сохраняет читаемость (не «простыни»), не ломает live-стриминг и работает с авто-pruning

**Live state (человек ещё говорит):**
- Класс `.live` на последнем bubble активной группы
- В конце `.primary` — `<span class="typing-dots">` из 3 пульсирующих точек (animation `typingPulse 1.2s`)
- Финализация: через 2.5s после последнего фрагмента ИЛИ при смене говорящего ИЛИ при stop. Точки удаляются, класс снимается.

**Pruning по группам:**
- `VISIBLE_LIMIT = 3` — лимит групп (а не bubble!), чтобы длинная split-реплика не вытесняла собеседника
- Старые группы получают `.fade-out` (`opacity → 0`, `max-height → 0` за 0.7s) и удаляются из DOM
- Группа определяется так: bubble без `.continued` = начало группы, последующие `.continued` присоединяются к ней

```css
.bubble.continued { /* верхний tail-corner смягчён */ }
.bubble.no-tail { /* нижний tail-corner полный (18×scale) — для промежуточных в группе */ }
.bubble.live .typing-dots { /* 3 пульсирующих dot */ }
.bubbles-list .bubble + .bubble { margin-top: calc(14px * var(--bubble-scale)); }
.bubbles-list .bubble + .bubble.continued { margin-top: calc(3px * var(--bubble-scale)); }
```

**Масштаб (`--bubble-scale`):**
- Глобальная CSS-переменная на `:root`, регулируется слайдером «Размер транскрипта»
- Влияет на: font-size primary/secondary, padding, border-radius, margin-top secondary, gap между группами, размер typing dots
- Шкала: `0.75 (XS) → 1.3 (XL)`, интерполируется linearly при движении слайдера

### 5.15 Toggle (pill switch)

Бинарное состояние on/off. По форме — `34×19px` pill с круглой ручкой `14×14`.

```css
.toggle {
  width: 34px; height: 19px;
  background: rgba(255,255,255,0.10);
  border-radius: 10px;
  position: relative; cursor: pointer;
  border: 0.5px solid rgba(255,255,255,0.12);
  transition: background 0.18s, border-color 0.18s;
}
.toggle::after {
  content: ""; position: absolute;
  top: 1.5px; left: 1.5px;
  width: 14px; height: 14px;
  background: linear-gradient(180deg, #fff, #d8d8da);
  border-radius: 50%;
  box-shadow: 0 1px 3px rgba(0,0,0,0.4);
  transition: left 0.18s cubic-bezier(0.32, 0.94, 0.6, 1);
}
.toggle.on {
  background: rgba(88, 224, 154, 0.32);
  border-color: rgba(88, 224, 154, 0.55);
}
.toggle.on::after { left: 17px; }
```

> **Цвет on-state — `--ready` (зелёный).** Toggle сигнализирует «активный/готовый» state — это семантическая семья со status-dot ready.

### 5.16 Secret input (API key, токены, пароли)

Текстовое поле с переключением «password ↔ text» через текст-toggle «Показать / Скрыть».

```css
.secret-input {
  display: flex; align-items: center; gap: 8px;
  background: rgba(255,255,255,0.06);
  border: 0.5px solid rgba(255,255,255,0.10);
  padding: 4px 6px 4px 9px;
  border-radius: 7px;
}
.secret-input input {
  background: none; border: none; outline: none;
  font-family: 'IBM Plex Mono', monospace;
  font-size: 11.5px;
  letter-spacing: 0.04em;
  color: rgba(255,255,255,0.85);
  flex: 1; min-width: 0;
}
.secret-input .toggle-text {
  font-size: 10.5px;
  color: rgba(255,255,255,0.5);
  cursor: pointer;
  padding: 2px 4px;
  border-radius: 4px;
}
.secret-input .toggle-text:hover {
  color: rgba(255,255,255,0.85);
  background: rgba(255,255,255,0.06);
}
```

- IBM Plex Mono для значения — это идентификатор, моноширинная читаемость нужна
- Default `type="password"` — точки маскированы браузером
- Toggle text — НЕ иконка глаза (отвергнуто после трёх итераций — нечитаемо при мелком размере)

### 5.17 Hotkey recorder

Маленькая «клавиша», которая при клике начинает захват модификатора+клавиши с клавиатуры.

```css
.kbd-recorder {
  font-family: 'IBM Plex Mono', monospace;
  background: rgba(255,255,255,0.06);
  border: 0.5px solid rgba(255,255,255,0.10);
  padding: 3px 8px;
  border-radius: 5px;
  font-size: 11px;
  letter-spacing: 0.06em;
  color: rgba(255,255,255,0.85);
  cursor: pointer;
  min-width: 60px; text-align: center;
}
.kbd-recorder.recording {
  background: rgba(255,255,255,0.14);
  border-color: rgba(255,255,255,0.32);
  color: #fff;
  animation: pulseKbd 1.2s ease-in-out infinite;
}
@keyframes pulseKbd { 0%, 100% { opacity: 1; } 50% { opacity: 0.55; } }
```

**Поведение:**
- Click → текст меняется на «нажмите…», recording state включается (pulsing white)
- Keydown: формируем строку модификаторов (`⌘ ⌃ ⌥ ⇧`) + клавиша
- **Обязательно хотя бы один модификатор** — иначе игнорируем (защита от случайного захвата `A`)
- `Escape` или click outside → отменяем, восстанавливаем старое значение
- Successful capture → text обновляется, recording state выключается, save indicator

**Символы клавиатуры (Unicode glyphs):**
- `⌘` Cmd, `⌃` Ctrl, `⌥` Option, `⇧` Shift
- `↑ ↓ ← →` стрелки, `␣` space, `↵` Enter, `⇥` Tab, `⌫` Backspace, `esc` Escape
- Буквы — uppercase: `A`, `U`, `T`

### 5.18 Save indicator (auto-save)

Маленькая надпись «✓ сохранено» в тайтлбаре — появляется через 0.25s opacity-transition на любое изменение state, исчезает через 1.6s.

```css
.save-indicator {
  display: inline-flex; align-items: center; gap: 5px;
  font-size: 10.5px;
  font-family: 'IBM Plex Mono', monospace;
  color: rgba(255,255,255,0.4);
  letter-spacing: 0.04em;
  opacity: 0;
  transition: opacity 0.25s;
}
.save-indicator.shown { opacity: 1; }
.save-indicator svg { width: 10px; height: 10px; color: var(--ready); }
```

> **Принцип auto-save без явной кнопки.** Settings не имеет «Save» / «Apply» — изменения применяются мгновенно. Save indicator — мягкая обратная связь, что изменение зафиксировано. Это снимает беспокойство «не пропали ли мои настройки?» и убирает один шаг из UX.

### 5.19 Section header (внутри окон)

Подзаголовок секции в форме / списке. Crystal-clear hierarchy без bold заголовков.

```css
.section-head {
  padding: 18px 16px 6px;
  font-family: 'IBM Plex Mono', monospace;
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 0.14em;
  color: rgba(255,255,255,0.42);
  font-weight: 400;
}
```

- IBM Plex Mono + small caps + spaced letters — «технический» feel
- Цвет приглушённый, чтобы не конкурировать со значениями в строках
- Применение: «АУДИО», «ЯЗЫКИ ПО УМОЛЧАНИЮ», «OPENAI», «HOTKEYS», «BLACKHOLE», «ПОВЕДЕНИЕ», «О ПРИЛОЖЕНИИ»

### 5.20 Status dot (ready / warn / error)

Маленькая точка с цветным glow, обозначает state системы / компонента.

```css
.status-dot {
  display: inline-block; width: 6px; height: 6px;
  border-radius: 50%;
  background: var(--ready);
  box-shadow: 0 0 6px rgba(88, 224, 154, 0.6);
}
.status-dot.warn { background: var(--warn); box-shadow: 0 0 6px rgba(255, 180, 84, 0.55); }
.status-dot.error { background: var(--error); box-shadow: 0 0 6px rgba(255, 122, 140, 0.55); }
```

Применения: BlackHole status в Settings, OpenAI ready/error, network connectivity в pill.

### 5.21 Logo · `#logo-unison`

Финальный логотип Unison — буква **U** с двумя боковыми штрихами по обеим сторонам. Семантика:

- **Боковые штрихи** = два голосовых потока / два участника звонка
- **U-форма** = соединение, синхронизация, перевод в реальном времени

```svg
<svg viewBox="0 0 256 256" fill="none">
  <g stroke="currentColor" stroke-width="12" stroke-linecap="round" stroke-linejoin="round">
    <!-- Letter U -->
    <path d="M82 66 V146 C82 177.5 102.5 198 128 198 C153.5 198 174 177.5 174 146 V 66"/>
    <!-- Two voice streams · left -->
    <path d="M58 86 V136"/>
    <path d="M38 102 V126"/>
    <!-- Two voice streams · right -->
    <path d="M198 86 V136"/>
    <path d="M218 102 V126"/>
  </g>
</svg>
```

**Технические свойства:**
- `viewBox="0 0 256 256"`, `stroke-width="12"`, `currentColor` — масштабируется без потерь, наследует цвет
- Stroke-only, симметричен по горизонтали, читается на любом размере
- Минимальный читаемый размер: `18×18px` (menubar)
- В app icon — занимает ~77% squircle (124px из 160px)

**Применения:**
- Menubar item (см. §5.22)
- App icon (Dock, Spotlight, Finder, About)
- Onboarding header (32×32, в плашке 56×56 с rounded glass)
- About modal (44×44 на Aurora plate 72×72)
- Compact status popover

### 5.22 Menubar item — состояния

Иконка приложения в верхней строке macOS. Используется `#logo-unison` в `currentColor`. Размер `22×22` (с внутренним padding `2px` → визуальный контент 18×18).

| Состояние | Color | Иконка | Анимация | Badge |
|---|---|---|---|---|
| **idle** | `rgba(255,255,255,0.88)` | полный логотип | — | — |
| **active** | `var(--active)` (cyan) | полный логотип | `pulseLogo 1.6s` (scale + opacity) | — |
| **paused** | `rgba(255,255,255,0.40)` | **без боковых штрихов** (только U) | — | — |
| **error** | `var(--error)` (coral) | полный логотип | — | dot `7×7` top-right corner |

> **Семантика paused-варианта:** четыре штриха-голоса исчезают, остаётся только U. «Связь установлена, но звуки замолчали».

```css
.menubar-icon { color: rgba(255,255,255,0.88); }
.menubar-icon.active { color: var(--active); animation: pulseLogo 1.6s ease-in-out infinite; }
.menubar-icon.paused { color: rgba(255,255,255,0.40); }
.menubar-icon.error { color: var(--error); position: relative; }
.menubar-icon.error::after {
  content: ""; position: absolute;
  top: 0; right: 0;
  width: 7px; height: 7px;
  background: var(--error);
  border-radius: 50%;
  box-shadow: 0 0 5px var(--error);
}
@keyframes pulseLogo {
  0%, 100% { opacity: 1; transform: scale(1); }
  50% { opacity: 0.7; transform: scale(1.05); }
}
```

**Поведение:**
- **Click** → toggle popover (popover-final): открывается под иконкой, закрывается повторным кликом или click outside
- **Right-click / Cmd+click** → context menu: Start/Stop, Show transcript, Settings…, About, Quit
- Popover позиционируется с учётом расстояния до края экрана (auto-flip если не помещается справа)

---

## 6. Иконки

### 6.1 Стиль

- ViewBox `16×16`
- Stroke 1.3–1.4px, round caps + joins
- Размер в UI: 14×14 (gear, mode-seg), 11×11 (внутри input), 12×12 (warn), 18×18 (icon-spec demos)
- Filled icons (play, stop, call) — solid currentColor
- Outline icons (chevron, headphones, sliders, search) — fine strokes

### 6.2 Используемые

| Иконка | id | Стиль | Где |
|---|---|---|---|
| Settings (sliders) | `icon-gear` | outline | Header popover, везде где "настройки" |
| Play (start) | `icon-play` | filled | Start button |
| Stop | `icon-stop` | filled | Stop button во время сессии |
| Call (phone) | `icon-call` | filled | Mode-toggle: Call |
| Listen (headphones) | `icon-listen` | mixed | Mode-toggle: Listen |
| Chevron down | `icon-chevron` | outline | Lang dropdown indicator |
| Check | `icon-check` | outline | Selected option mark |
| Search | `icon-search` | outline | Search input |
| Warning triangle | `icon-warning` | filled | Warn row |
| Arrow bidirectional | `arrow-a` | outline | Между lang-sides |

### 6.3 НЕ использовать

- ⌘, или другие keyboard hint'ы как замена иконки
- Эмодзи как UI иконки (только флаги для языков)
- Иконку микрофона для Call — Call это про общение людей, не про техническое устройство. Микрофон ассоциируется с "запись" / "звукорежим"

---

## 7. UX-копирайтинг

### 7.1 Принципы

- **Минимализм**: короткие, читаемые с одного взгляда фразы
- **Один экран — одна мысль**: не комбинировать причину + решение + кнопку в один параграф
- **Без слов-наполнителей**: «Пожалуйста», «Будь добр», «Обращаем внимание»
- **Глагол первым в CTA**: «Начать», не «Нажмите чтобы начать»
- **Read-aloud test**: если глаз цепляется при чтении — переписать

### 7.2 Терминология

| Используем | Не используем | Почему |
|---|---|---|
| «Начать перевод» | «Запустить перевод» | Запустить = техническое |
| «Остановить» | «Остановить перевод» | Контекст уже задан |
| «Я говорю» | «Мой язык» | Антропоморфизация, читаемее |
| «Слушаю» | «Собеседник» / «Их язык» | Глагол — приложение действует, не описывает абстрактного "собеседника" |
| «Поиск» | «Найти язык» | Меньше — лучше |
| «Выбран одинаковый язык» | «Ошибка: языки должны быть разными» | Без слова «ошибка» |
| «Нужен пароль системы.» | «BlackHole 2ch + 16ch установятся одной командой. Потребуется пароль администратора.» | Не нагружать техническими деталями |
| «macOS попросит подтверждение.» | «macOS попросит подтверждение в системном диалоге.» | «В системном диалоге» — лишнее |
| «Получить ключ ↗» | «Получить ключ OpenAI на platform.openai.com/api-keys» | Cтрелка ↗ показывает что внешняя ссылка |
| «Показать» / «Скрыть» | «👁» / «👁‍🗨» (или icon-eye) | Text > icon для toggle visibility — accessibility и clarity |

### 7.3 Длина

- **Hint / caption под полем** — целиться в ≤ 30 символов, максимум 50
- **Заголовок окна** — 1–2 слова или короткая фраза (≤ 20 символов)
- **CTA-кнопка** — 1 слово в идеале («Установить», «Разрешить», «Сохранить»)
- **Error-сообщение** — заголовок ≤ 25 символов, детализация — одна короткая строка
- **Subtitle под заголовком** — часто можно вообще убрать. Если заголовок ясный, подзаголовок — лишний шум.

### 7.4 Состояния

- **Ready**: ничего не пишем (статус-точка + общее состояние говорят сами)
- **Translating**: timer `mm:ss`, опционально метка состояния
- **Reconnecting**: `Соединение...` (TBD: precise copy)
- **Error**: короткая фраза причины (`Нет соединения`, `Неверный API ключ`)

---

## 8. Состояния и анимации

### 8.1 Длительности

| Тип | Длительность | Easing |
|---|---|---|
| Hover | 150ms | ease |
| Active press | 80–100ms | ease |
| Dropdown open/close | 160ms | ease |
| State change (warn/translating) | 200–300ms | ease |
| Pulse animations | 1.6–3.2s | ease-in-out infinite |

### 8.2 Transform на active

```css
.btn-iconic:active     { transform: scale(0.94); }
.btn-primary:active    { transform: scale(0.98); }
.lang-side:active      { transform: scale(0.98); }
.mode-seg:active       { transform: scale(0.97); }
```

### 8.3 Pulse animations

```css
@keyframes dotPulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }
@keyframes warnFade { from { opacity: 0; transform: translateY(-3px); } to { opacity: 1; transform: translateY(0); } }
@keyframes errFade { from { opacity: 0; transform: translateY(-3px); } to { opacity: 1; transform: translateY(0); } }
@keyframes spin { to { transform: rotate(360deg); } }
```

### 8.4 Loading spinner

Inline spinner для async-операций (install in progress, permission request, save):

```html
<svg viewBox="0 0 16 16" class="spinning" width="11" height="11">
  <g fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round">
    <path d="M8 2 A6 6 0 0 1 14 8" opacity="0.95"/>
    <path d="M14 8 A6 6 0 0 1 8 14" opacity="0.4"/>
    <path d="M8 14 A6 6 0 0 1 2 8" opacity="0.15"/>
  </g>
</svg>
```

```css
.spinning { animation: spin 0.9s linear infinite; }
```

Используется на месте play/install/save иконки во время выполнения. Кнопка остаётся, но: `disabled = true`, label меняется на «Установка...», иконка — spinner.

---

## 9. Клавиатура и accessibility

### 9.1 Базовые

- Все интерактивные элементы — `<button>` или `<input>` (не `<div onclick>`)
- `:focus-visible` с outline `1.5px rgba(255,255,255,0.45)`, offset 1px
- Чёткий tab-order, не нужно настраивать `tabindex` если HTML логичен

### 9.2 Dropdown navigation

| Клавиша | Действие |
|---|---|
| `↓` / `↑` | По списку (с autoScrollIntoView) |
| `Enter` | Выбрать выделенный |
| `Esc` | Закрыть dropdown |
| `Tab` | Стандартный tab-флоу |

### 9.3 Цветовой контраст

- Primary текст на стекле: WCAG AA OK при достаточном blur'е
- Muted текст (#8e8e93 на тёмном) — на грани, использовать только для secondary info
- Никогда не размещать текст < 13.5px без проверки контраста на реальном фоне

---

## 10. Технические тонкости

### 10.1 Portal pattern для оверлеев

**Проблема**: `backdrop-filter` внутри родителя с `backdrop-filter` НЕ блюрит контент того же родителя — стэкстинговые контексты изолируются.

**Решение**: оверлеи (dropdown'ы, тултипы, popover'ы) ВЫНОСИТЬ из «anchor»-элемента в parent-wrap. Координаты вычислять JS'ом через `getBoundingClientRect`.

В Swift/macOS эквивалент:
- macOS: отдельный `NSWindow` (или `NSPopover`) поверх главного окна
- iOS: `UIViewController.present(_:animated:)` с popover/sheet style

### 10.2 SVG `<symbol>` для иконок

Один `<svg style="position:absolute" width="0" height="0">` в начале body с `<defs>` где определяются все `<symbol id="icon-...">`. Использование:

```html
<svg><use href="#icon-gear"/></svg>
```

Иконки наследуют `currentColor`, что упрощает темизацию.

### 10.3 Cross-browser caveats

- SVG `feDisplacementMap` как `backdrop-filter` — **только Chromium-based** (Chrome, Edge, Arc). В Safari работает обычный blur без рефракции — graceful fallback.
- `-webkit-backdrop-filter` дублирующий — обязателен для Safari.

### 10.4 Performance

- `feDisplacementMap` CPU-intensive — применять только к небольшим элементам (popover, dropdown), не к фоновым крупным панелям
- Анимации `transform` и `opacity` — GPU. Не анимировать `box-shadow`, `width`, `height`
- `backdrop-filter` дорог — не более 3-4 одновременно на экране

---

## 11. Что НЕ делать (anti-patterns)

- ❌ Использовать generic шрифты (Inter, Roboto, Arial, system fonts) — есть Fraunces + DM Sans
- ❌ Purple gradients on white backgrounds — клише AI-дизайна
- ❌ Solid bright fills — нет места в Liquid Glass эстетике
- ❌ Любые акцентные цвета (pink, purple, blue) — UI Unison строго нейтральный (белый + прозрачность). Цветной — только семантика (ready/active/warn/stop)
- ❌ Длинные UX-фразы — каждое слово должно платить за себя
- ❌ Эмодзи в functional UI элементах — только для флагов
- ❌ Полностью непрозрачные оверлеи — теряется ощущение глубины
- ❌ Толстые тени `rgba(0,0,0,0.8)` — слишком тяжело; держать ниже 0.6
- ❌ Анимации > 300ms на UI feedback — кажутся тормозными
- ❌ Backdrop-filter на огромных областях — производительность

---

## 12. Применение к следующим окнам

### 12.1 Onboarding

- Окно single-page (без wizard'а)
- Тот же фон + тот же стеклянный материал
- Использовать паттерны: panel, list rows (как lang-options), primary button, status dots
- Закрывается само когда все шаги done

### 12.2 Settings — РЕАЛИЗОВАНО

См. `design/settings-final/` и §5.13 (sliders), §5.15–5.20 (toggle, secret input, hotkey, save indicator, section head, status dot).

- Form-style single-column scrollable. Ширина окна `560px`, max-height `540px` (с scroll)
- Секции: «АУДИО», «ЯЗЫКИ ПО УМОЛЧАНИЮ», «OPENAI», «HOTKEYS», «BLACKHOLE», «ПОВЕДЕНИЕ», «О ПРИЛОЖЕНИИ»
- Все pickers (микрофон, динамик, языки) — один dropdown компонент (см. §5.7) с поиском (S1)
- Slider — T2 vertical handle (см. §5.13)
- Toggle, Secret input, Hotkey recorder — см. §5.15, 5.16, 5.17
- Auto-save indicator в тайтлбаре (см. §5.18) — изменения применяются мгновенно, кнопка «Save» отсутствует
- BlackHole reinstall — кнопка с прогресс-состоянием (warn dots → ready dots)

### 12.3 Transcript window — РЕАЛИЗОВАНО

См. `design/transcript-final/` и §5.14 (Transcript bubble pattern).

- Floating NSPanel, всегда поверх, нижний центр экрана (60% width, 520–720px range)
- Control pill — `.glass` (см. §1.4) с timer + settings (⚙) + Скрыть/Показать + Stop
- Settings popover — `.glass` с двумя слайдерами T2 (см. §5.13): размер транскрипта, громкость оригинала
- Bubble pattern — T1 corner-tail + B3 inverted hierarchy (см. §5.14)
- UX-правила: один говорящий = одна группа, split при 240+ символах, live state с typing dots, pruning по группам (3 видимых)

### 12.4 Менеджмент состояний

Все окна следуют той же state-семантике как popover:
- Status dot цветом отражает текущее состояние
- Primary button меняется (Start / Stop / Disabled)
- Warning rows для inline-валидации
- Errors как тосты или inline

---

## 13. Источники

- WWDC 2025: Apple Liquid Glass announcement
- macOS Tahoe 26 design specs
- 8 раундов итерации popover'а — см. `design/popover-round-{1..8}/`, `design/popover-final/`

Документ живой. Обновляется после каждого нового окна с новыми компонентами/паттернами.
