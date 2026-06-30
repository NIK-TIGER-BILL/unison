import Foundation

/// Observes a `NotificationCenter` notification for one specific object and
/// invokes a debounced action.
///
/// Used for audio self-heal after a device change. Connecting/disconnecting an
/// audio device (e.g. Bluetooth headphones) makes the audio stack post a burst
/// of notifications — `AVAudioEngineConfigurationChange` for the AVAudioEngine
/// output engines, `AVCaptureSessionRuntimeError` for the AVCaptureSession mic —
/// and the owner must rebuild + restart its graph/session once per *settled*
/// change. Debouncing collapses the burst into a single action.
///
/// The action runs on a private serial queue (NOT the main queue — the self-heal
/// must fire even when the main thread is busy). The owner is responsible for
/// serializing the action against its own start/stop (e.g. a lifecycle lock).
final class DebouncedNotificationObserver: @unchecked Sendable {
    private let name: Notification.Name
    private let object: AnyObject?
    private let action: @Sendable () -> Void
    private let debounceMilliseconds: Int
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.unison.app.audio.debounced-observer")
    private var token: NSObjectProtocol?
    private var pending: DispatchWorkItem?

    init(name: Notification.Name,
         object: AnyObject?,
         debounceMilliseconds: Int = 250,
         action: @escaping @Sendable () -> Void) {
        self.name = name
        self.object = object
        self.action = action
        self.debounceMilliseconds = debounceMilliseconds
    }

    /// Begin observing. Idempotent — a second call while already observing is a
    /// no-op (the same object never needs two registrations).
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard token == nil else { return }
        token = NotificationCenter.default.addObserver(
            forName: name, object: object, queue: nil
        ) { [weak self] _ in
            self?.schedule()
        }
    }

    /// Stop observing and cancel any pending (debounced) action.
    func stop() {
        lock.lock()
        let t = token
        token = nil
        pending?.cancel()
        pending = nil
        lock.unlock()
        if let t { NotificationCenter.default.removeObserver(t) }
    }

    private func schedule() {
        let item = DispatchWorkItem { [weak self] in self?.action() }
        lock.lock()
        pending?.cancel()
        pending = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + .milliseconds(debounceMilliseconds), execute: item)
    }

    deinit { stop() }
}
