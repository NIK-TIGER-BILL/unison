import Foundation
import Observation
import UnisonDomain

/// View model for the floating transcript window. Mirrors the JS demo in
/// `design/transcript-final/index.html`:
///
/// - exposes a flat list of `BubbleGroup`s mapped from the orchestrator's
///   `TranscriptModel` bubbles, windowed by the `TranscriptFeed`;
/// - drives the bubble-size slider (XS … XL) and the original-track volume
///   slider in the settings popover;
/// - tracks "hidden" (transcript collapsed → only pill visible) and the
///   stop-confirmation modal state.
///
/// The view layer reads:
/// - `bubbleGroups` for the bubble list;
/// - `elapsedSecondsString` (driven by the host's TimelineView refresh) for
///   the pill timer;
/// - `bubbleScale` / `originalVolume` for the popover (the XS…XL label
///   lives in `TranscriptSettingsPopover`);
/// - `isHidden` / `showStopConfirmation` for visibility / modal.
@MainActor
@Observable
public final class TranscriptViewModel {
    /// Live source of truth: sentence/pause-paired bubbles from the new
    /// `TranscriptModel` (the orchestrator ticks it; this VM only reads).
    public let model: TranscriptModel
    /// Optional orchestrator used for both `elapsedSecondsString` (reads
    /// `state`) and `updateOriginalVolume(...)` (calls the mixer). Optional
    /// so unit tests can construct the VM without spinning up the full
    /// audio stack.
    public let orchestrator: TranslationOrchestrator?

    /// Slider position `0 ... 4` (continuous). Mirrors `<input type="range"
    /// step="any">` in the HTML. Use `sizeLabel` for the discrete XS/S/M/L/XL
    /// label and `bubbleScale` for the continuous 0.75…1.30 multiplier.
    public var sizeIndex: Double = 2.0

    /// Continuous bubble-scale multiplier (`0.75 … 1.30`). Derived from
    /// `sizeIndex` so the slider's "step=any" thumb moves smoothly.
    public var bubbleScale: Double {
        Self.bubbleScale(forSizeIndex: sizeIndex)
    }

    /// Original-track volume `0 ... 100`. The orchestrator's mixer expects
    /// `0.0 ... 1.0` — `updateOriginalVolume(_:)` performs the conversion.
    public var originalVolume: Int = 20

    /// Whether the transcript bubbles are collapsed (only the pill is
    /// visible). Bound to the pill's "Скрыть"/"Показать" button.
    public var isHidden: Bool = false

    /// Drives the destructive stop modal in `TranscriptView`.
    public var showStopConfirmation: Bool = false

    /// Override clock for elapsed-time tests. Production callers leave this
    /// alone so the view's TimelineView ticks against the real clock.
    public var nowProvider: @MainActor () -> Date = { Date() }

    /// Stop callback invoked by `confirmStop()`. Host (AppDelegate / a
    /// future composition layer) typically wires this to
    /// `await orchestrator.stop()` so the session actually ends.
    public var onStopRequested: @MainActor () -> Void = {}

    /// Optional callback fired whenever the user drags the volume slider in
    /// the transcript settings popover. Composition wires this to the
    /// `SettingsViewModel` so the value persists across launches. Float in
    /// `0.0 ... 1.0` to match the storage encoding.
    @ObservationIgnored
    public var onOriginalVolumeChanged: ((Float) -> Void)?

    /// Delay before a live (typing-dots) bubble auto-finalises. Mirrors the
    /// JS `liveTimer` constant (`2500ms`).
    public static let liveFinalizeDelaySeconds: TimeInterval = 2.5

    /// Recency window: a bubble is visible only if its source entry's
    /// last activity was within this many seconds of "now". Older
    /// bubbles dissolve; after this long of silence the transcript is
    /// empty.
    public static let windowSeconds: TimeInterval = 30

    /// Hard cap on how many bubbles are visible at once, even within the
    /// time window. Counts individual bubbles — a long split message can
    /// crowd out older ones. Bumped from 4 to 6 alongside coalescing:
    /// bubbles now arrive as whole sentences (far less often), so a little
    /// more retained history reads as calm context rather than churn.
    public static let maxVisibleBubbles: Int = 6

    /// When `false`, the recency window is bypassed and the full
    /// transcript renders (legacy behaviour). `seedTranscriptDemo` sets
    /// this `false` so the screenshot harness shows all seeded bubbles
    /// and doesn't empty out `windowSeconds` after launch.
    public var windowingEnabled: Bool = true

    /// The "commit and freeze" feed: derives immutable frozen bubbles + one
    /// live tail from the store, and owns each bubble's whole-unit lifetime.
    private let feed = TranscriptFeed(config: TranscriptFeed.Config(
        finalizeAfter: TranscriptViewModel.liveFinalizeDelaySeconds,
        window: TranscriptViewModel.windowSeconds,
        maxBubbles: TranscriptViewModel.maxVisibleBubbles
    ))

    /// Snapshot-only override: when set, these bubbles render directly,
    /// bypassing the live model + recency window. Seeded via
    /// `seedPreviewBubbles(_:)` (public, for the composition demo) or set
    /// directly by `@testable` snapshot tests. Internal, not public, because
    /// `DisplayBubble` is a UnisonUI-internal type; mirrors the
    /// `previewState` / `previewElapsedSeconds` override pattern.
    var previewBubbles: [DisplayBubble]?

    /// Snapshot-only: seed fixed demo bubbles (screenshot harness), bypassing
    /// the live model + recency window. Each sample becomes one frozen bubble.
    public func seedPreviewBubbles(
        _ samples: [(speaker: Speaker, original: String, translated: String)]
    ) {
        let now = Date()
        previewBubbles = samples.map { sample in
            DisplayBubble(
                id: UUID(), speaker: sample.speaker,
                primaryText: sample.speaker == .me ? sample.original : sample.translated,
                secondaryText: sample.speaker == .me ? sample.translated : sample.original,
                isLive: false, translationLost: false, lastActivityAt: now)
        }
    }

    public init(
        model: TranscriptModel,
        orchestrator: TranslationOrchestrator? = nil
    ) {
        self.model = model
        self.orchestrator = orchestrator
    }

    // MARK: - Derived data

    /// Grouped bubbles for the view layer: consecutive same-speaker
    /// utterances collapse into a group, and the current (still-forming)
    /// utterance of the last group carries the live flag.
    public var bubbleGroups: [BubbleGroup] {
        visibleBubbleGroups(at: nowProvider())
    }

    /// The windowed slice of bubble groups at the given instant. A PURE
    /// projection over `model.bubbles` — it never mutates (the orchestrator's
    /// heartbeat drives `model.tick`), so reading it from a SwiftUI body can't
    /// trigger "modifying state during view update". The view passes a
    /// `TimelineView` clock so bubbles expire on schedule during silence.
    public func visibleBubbleGroups(at now: Date) -> [BubbleGroup] {
        if let preview = previewBubbles {
            return TranscriptGrouping.groupDisplayBubbles(preview)
        }
        let display = model.bubbles.map(Self.displayBubble(from:))
        // `windowingEnabled == false` (no expiry / no cap) is the snapshot
        // path; production keeps the recency window + count cap.
        let visible = windowingEnabled ? feed.visible(display, now: now) : display
        return TranscriptGrouping.groupDisplayBubbles(visible)
    }

    /// `.me` shows the original bold (primary); `.peer` shows the translation
    /// bold — the source language sits underneath as the secondary line.
    private static func displayBubble(from bubble: TranscriptBubble) -> DisplayBubble {
        DisplayBubble(
            id: bubble.id, speaker: bubble.speaker,
            primaryText: bubble.speaker == .me ? bubble.source : bubble.translation,
            secondaryText: bubble.speaker == .me ? bubble.translation : bubble.source,
            isLive: bubble.isLive, translationLost: bubble.translationLost,
            lastActivityAt: bubble.committedAt)
    }

    /// Seconds since the orchestrator first entered `.translating`. The
    /// timer keeps ticking across `.paused` and `.reconnecting` because
    /// the orchestrator preserves `sessionStartedAt` across those
    /// transitions on purpose — snapping to 00:00 on every WS flap
    /// looks like the session got dropped (review finding #6 — the
    /// pill timer contradicted the popover header's running counter).
    /// Zero while idle / connecting / errored. In snapshot/preview
    /// mode the VM is constructed without an orchestrator; callers
    /// can set `previewElapsedSeconds` to drive the pill timer
    /// artificially.
    public var elapsedSeconds: TimeInterval {
        if let override = previewElapsedSeconds { return override }
        guard let orch = orchestrator,
              let startedAt = orch.state.sessionStartedAt else {
            return 0
        }
        return nowProvider().timeIntervalSince(startedAt)
    }

    /// Snapshot-only override for the pill's elapsed-seconds label.
    /// Bypassed entirely in production — the orchestrator's
    /// `.translating(_, startedAt)` always wins.
    public var previewElapsedSeconds: TimeInterval?

    /// `mm:ss` formatted version of `elapsedSeconds`. Hosts typically wrap
    /// this in `TimelineView(.periodic(...))` so the label ticks without
    /// the VM owning a timer.
    public var elapsedSecondsString: String {
        Self.formatElapsed(elapsedSeconds)
    }

    /// True when the orchestrator is running a `.test` self-test session
    /// (started via `PopoverViewModel.startTest()`). The transcript view
    /// uses this to switch the status dot and bubble tint to a yellow
    /// palette so the user can visually tell a calibration test apart
    /// from a real translation session. Reads `effectiveState` so the
    /// `previewState` override works like its sibling properties.
    public var isTestMode: Bool {
        effectiveState.activeMode == .test
    }

    // MARK: - Preview / snapshot overrides

    /// Snapshot-only override for `effectiveState`. Production callers
    /// leave this `nil` so the orchestrator's `state` is the source of
    /// truth. Mirrors `PopoverViewModel.previewState` (T11).
    public var previewState: SessionState?

    /// Snapshot-only override for `connectivityHealth`. Production
    /// callers leave this at `.healthy`; the orchestrator's value wins
    /// whenever one is wired. Mirrors `PopoverViewModel`.
    public var previewConnectivityHealth: ConnectivityHealth = .healthy

    /// State the control pill should reflect — `previewState` if set
    /// (snapshot tests), otherwise the orchestrator's `state`, falling
    /// back to `.idle` when no orchestrator is wired.
    public var effectiveState: SessionState {
        previewState ?? orchestrator?.state ?? .idle
    }

    /// Aggregate connectivity health — orchestrator's value when
    /// wired, otherwise the preview override.
    public var connectivityHealth: ConnectivityHealth {
        orchestrator?.connectivityHealth ?? previewConnectivityHealth
    }

    // MARK: - Control pill status surface

    /// Russian secondary label rendered next to the pill timer. Empty
    /// string means "no label" — the view collapses the slot entirely
    /// so we don't reserve horizontal space for nothing.
    ///
    /// Wording is shorter than `PopoverViewModel.statusText` because
    /// the control pill is space-constrained:
    /// - `.paused(.networkLost)` → "Пауза" (popover says
    ///   "Нет интернета. Ждём…")
    /// - `.translating + .recovering` → "" (popover flashes
    ///   "Связь восстановлена"; the pill omits to avoid flicker)
    public var pillStatusText: String {
        switch effectiveState {
        case .reconnecting:
            return "Переподключение…"
        case .paused(_, _, _, .networkLost), .paused(_, _, _, .systemSleep):
            return "Пауза"
        case .paused(_, _, _, .awaitingNetwork):
            return "Возобновляем…"
        case .translating:
            switch connectivityHealth {
            case .slow: return "Медленная сеть"
            case .recovering: return ""
            case .healthy: return ""
            }
        case .idle, .connecting, .error:
            return ""
        }
    }

    /// Status-dot kind for the control pill. Mirrors
    /// `PopoverViewModel.statusDotState` (T11): `.translating` cross-
    /// references `connectivityHealth` so a slow stream surfaces as a
    /// warning dot without resetting the elapsed timer.
    public var pillDotState: StatusDot.State {
        switch effectiveState {
        case .idle: return .ready
        case .connecting: return .active
        case .reconnecting: return .warn
        case .paused: return .paused
        case .error: return .error
        case .translating:
            switch connectivityHealth {
            case .slow: return .warn
            case .recovering: return .recovering
            case .healthy: return .active
            }
        }
    }

    // MARK: - Mutations

    public func updateSizeIndex(_ value: Double) {
        sizeIndex = max(0.0, min(4.0, value))
    }

    /// Update the original-track volume (0-100). Propagates the change to
    /// the orchestrator's mixer as `Float` in `0.0 ... 1.0`, and forwards
    /// the same value to `onOriginalVolumeChanged` so the host can persist
    /// it in `Settings`.
    public func updateOriginalVolume(_ value: Int) {
        let clamped = max(0, min(100, value))
        originalVolume = clamped
        let floatValue = Float(clamped) / 100.0
        orchestrator?.updateOriginalMixVolume(floatValue)
        onOriginalVolumeChanged?(floatValue)
    }

    public func toggleHidden() {
        isHidden.toggle()
    }

    public func requestStop() {
        showStopConfirmation = true
    }

    public func cancelStop() {
        showStopConfirmation = false
    }

    public func confirmStop() {
        showStopConfirmation = false
        onStopRequested()
    }

    // MARK: - Pure helpers (tested without an instance)

    /// Map the slider's `0 ... 4` index to a continuous bubble-scale
    /// multiplier in `0.75 ... 1.30`. Mirrors the JS interpolation
    /// `SIZE_MIN + (v / 4) * (SIZE_MAX - SIZE_MIN)`.
    public nonisolated static func bubbleScale(forSizeIndex index: Double) -> Double {
        let clamped = max(0.0, min(4.0, index))
        return 0.75 + (clamped / 4.0) * (1.30 - 0.75)
    }

    /// `mm:ss` formatter, identical to `PopoverViewModel.formatElapsed`.
    public nonisolated static func formatElapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let mm = s / 60
        let ss = s % 60
        return String(format: "%02d:%02d", mm, ss)
    }
}
