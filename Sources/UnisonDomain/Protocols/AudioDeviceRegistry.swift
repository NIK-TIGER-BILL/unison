public protocol AudioDeviceRegistry: Sendable {
    func availableInputDevices() -> [AudioDevice]
    func availableOutputDevices() -> [AudioDevice]
    func findBlackHole2ch() -> AudioDevice?
    func findBlackHole16ch() -> AudioDevice?
    var deviceChanges: AsyncStream<Void> { get }
}
