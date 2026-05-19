import Testing
@testable import UnisonDomain
@testable import UnisonUI

@MainActor
@Test func settingsVM_changeInputDevice_persists() {
    var saved: Settings?
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: MockAudioDeviceRegistry(),
        onChange: { s in saved = s }
    )
    vm.setInputDeviceUID("airpods-uid")
    #expect(saved?.inputDeviceUID == "airpods-uid")
}

@MainActor
@Test func settingsVM_originalMixVolume_clampedAndPersisted() {
    var saved: Settings?
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: MockAudioDeviceRegistry(),
        onChange: { s in saved = s }
    )
    vm.setOriginalMixVolume(0.5)
    #expect(saved?.originalMixVolume == 0.5)
    vm.setOriginalMixVolume(2.0)
    #expect(saved?.originalMixVolume == 1.0)
}
