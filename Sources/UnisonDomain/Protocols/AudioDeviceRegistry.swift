public protocol AudioDeviceRegistry: Sendable {
    func availableInputDevices() -> [AudioDevice]
    func availableOutputDevices() -> [AudioDevice]
    func findBlackHole2ch() -> AudioDevice?
    var deviceChanges: AsyncStream<Void> { get }
}
