import Foundation
import Observation
import UnisonDomain

@MainActor
@Observable
public final class SettingsViewModel {
    public var settings: Settings
    private let deviceRegistry: any AudioDeviceRegistry
    private let onChange: (Settings) -> Void

    public init(
        initial: Settings,
        deviceRegistry: any AudioDeviceRegistry,
        onChange: @escaping (Settings) -> Void
    ) {
        self.settings = initial
        self.deviceRegistry = deviceRegistry
        self.onChange = onChange
    }

    public var availableInputs: [AudioDevice] {
        deviceRegistry.availableInputDevices().filter {
            !$0.name.lowercased().contains("blackhole")
        }
    }

    public var availableOutputs: [AudioDevice] {
        deviceRegistry.availableOutputDevices().filter {
            !$0.name.lowercased().contains("blackhole")
        }
    }

    public func setLanguagePair(_ pair: LanguagePair) {
        settings.languagePair = pair
        onChange(settings)
    }

    public func setSessionMode(_ mode: SessionMode) {
        settings.sessionMode = mode
        onChange(settings)
    }

    public func setInputDeviceUID(_ uid: String?) {
        settings.inputDeviceUID = uid
        onChange(settings)
    }

    public func setOutputDeviceUID(_ uid: String?) {
        settings.outputDeviceUID = uid
        onChange(settings)
    }

    public func setOriginalMixVolume(_ v: Float) {
        settings.originalMixVolume = v
        onChange(settings)
    }
}
