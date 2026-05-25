import Foundation
import Observation
import UnisonDomain

/// View model for the floating transcript window. Mirrors the JS demo in
/// `design/transcript-final/index.html`:
///
/// - exposes a flat list of `BubbleGroup`s derived from `TranscriptStore`
///   entries via `TranscriptGrouping.group(...)`;
/// - drives the bubble-size slider (XS … XL) and the original-track volume
///   slider in the settings popover;
/// - tracks "hidden" (transcript collapsed → only pill visible) and the
///   stop-confirmation modal state;
/// - finalises a live (typing-dots) bubble after `liveFinalizeDelaySeconds`
///   of inactivity, matching the JS `liveTimer` behaviour.
///
/// The view layer reads:
/// - `bubbleGroups` for the bubble list;
/// - `elapsedSecondsString` (driven by the host's TimelineView refresh) for
///   the pill timer;
/// - `sizeLabel` / `bubbleScale` / `originalVolume` for the popover;
/// - `isHidden` / `showStopConfirmation` for visibility / modal.
@MainActor
@Observable
public final class TranscriptViewModel {
    public let store: TranscriptStore
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

    /// Discrete size label shown in the settings popover.
    public var sizeLabel: String {
        Self.sizeLabel(forSizeIndex: sizeIndex)
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

    /// The entry currently in "live" state (renders typing dots on its last
    /// bubble). `nil` when no live entry is being tracked.
    public private(set) var activeLiveEntryId: UUID?

    private var liveFinalizeTask: Task<Void, Never>?

    public init(
        store: TranscriptStore,
        orchestrator: TranslationOrchestrator? = nil
    ) {
        self.store = store
        self.orchestrator = orchestrator
    }

    // MARK: - Derived data

    public var entries: [TranscriptEntry] { store.entries }

    /// Grouped bubbles for the view layer. Mirrors the JS algorithm:
    /// continuous-speaker runs collapse, long entries split on sentence
    /// boundaries, and the very last bubble carries the live flag when the
    /// last entry matches `activeLiveEntryId`.
    public var bubbleGroups: [BubbleGroup] {
        TranscriptGrouping.group(
            entries: store.entries,
            liveEntryId: activeLiveEntryId
        )
    }

    public func exportAsText() -> String { store.exportAsText() }

    /// Seconds since the orchestrator transitioned to `.translating`. Zero
    /// while idle / connecting / errored. In snapshot/preview mode the VM
    /// is constructed without an orchestrator; callers can set
    /// `previewElapsedSeconds` to drive the pill timer artificially.
    public var elapsedSeconds: TimeInterval {
        if let override = previewElapsedSeconds { return override }
        guard let orch = orchestrator,
              case .translating(_, let startedAt) = orch.state else {
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

    // MARK: - Mutations

    public func updateSizeIndex(_ value: Double) {
        sizeIndex = max(0.0, min(4.0, value))
    }

    public func updateBubbleScale(_ value: Double) {
        // Inverse of `bubbleScale(forSizeIndex:)` so callers can write
        // either side of the conversion. Internally we always store the
        // slider index because the popover binds to it.
        let clamped = max(0.75, min(1.30, value))
        sizeIndex = (clamped - 0.75) / (1.30 - 0.75) * 4.0
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

    /// Mark a transcript entry as the active "live" bubble — its last
    /// chunk renders the pulsing typing dots. The schedule runs on the
    /// MainActor; arriving content (new entry or extended text on the
    /// current entry) within `liveFinalizeDelaySeconds` resets the timer
    /// via `extendLive(entryId:)`.
    public func setLive(entryId: UUID?) {
        guard let entryId else {
            finalizeLive()
            return
        }
        activeLiveEntryId = entryId
        rescheduleFinalize()
    }

    /// Call after applying a delta to the same `entryId`: resets the live
    /// timer so a stream of partial deltas keeps the dots showing. If the
    /// id changed, the previous live entry is finalised and the new one
    /// becomes live.
    public func extendLive(entryId: UUID) {
        if activeLiveEntryId == entryId {
            rescheduleFinalize()
        } else {
            setLive(entryId: entryId)
        }
    }

    /// Drop the live state immediately (clear typing dots).
    public func finalizeLive() {
        activeLiveEntryId = nil
        liveFinalizeTask?.cancel()
        liveFinalizeTask = nil
    }

    private func rescheduleFinalize() {
        liveFinalizeTask?.cancel()
        let delay = Self.liveFinalizeDelaySeconds
        liveFinalizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run { self?.finalizeLive() }
        }
    }

    // MARK: - Pure helpers (tested without an instance)

    /// Map the slider's `0 ... 4` index to a discrete XS/S/M/L/XL label.
    public nonisolated static func sizeLabel(forSizeIndex index: Double) -> String {
        let idx = max(0, min(4, Int(index.rounded())))
        return ["XS", "S", "M", "L", "XL"][idx]
    }

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
