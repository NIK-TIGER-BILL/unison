import Foundation
import Testing
@testable import UnisonDomain
@testable import UnisonUI

@MainActor
@Test func settingsVM_setSaveHistoryEnabled_persistsViaOnChange() {
    var saved: Settings?
    let vm = SettingsViewModel(initial: .default, deviceRegistry: MockAudioDeviceRegistry(),
                               onChange: { saved = $0 })
    vm.setSaveHistoryEnabled(false)
    #expect(vm.settings.saveHistoryEnabled == false)
    #expect(saved?.saveHistoryEnabled == false)
}

@MainActor
@Test func settingsVM_setHistorySizeLimit_persistsViaOnChange() {
    var saved: Settings?
    let vm = SettingsViewModel(initial: .default, deviceRegistry: MockAudioDeviceRegistry(),
                               onChange: { saved = $0 })
    vm.setHistorySizeLimitMB(250)
    #expect(vm.settings.historySizeLimitMB == 250)
    #expect(saved?.historySizeLimitMB == 250)
}

@MainActor
@Test func settingsVM_historyUsage_readsStore() {
    let store = InMemoryMeetingStore()
    store.save(recordAt(daysAgo: 1, entries: [sampleEntry()]))
    store.save(recordAt(daysAgo: 2, entries: [sampleEntry()]))
    let vm = SettingsViewModel(initial: .default, deviceRegistry: MockAudioDeviceRegistry(),
                               onChange: { _ in }, meetingStore: store)
    vm.refreshHistoryUsage()
    #expect(vm.historyMeetingCount == 2)
    #expect(vm.historyTotalBytes > 0)
}

@MainActor
@Test func settingsVM_clearHistory_emptiesStoreAndUsage() {
    let store = InMemoryMeetingStore()
    store.save(recordAt(daysAgo: 1, entries: [sampleEntry()]))
    let vm = SettingsViewModel(initial: .default, deviceRegistry: MockAudioDeviceRegistry(),
                               onChange: { _ in }, meetingStore: store)
    vm.clearHistory()
    #expect(vm.historyMeetingCount == 0)
    #expect(store.list().isEmpty)
}
