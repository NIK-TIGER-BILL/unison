import Foundation

public protocol MicrophoneCapture: Sendable {
    /// `deviceUID == nil` means system default.
    func start(deviceUID: String?) -> AsyncStream<AudioFrame>
    func stop()
}
