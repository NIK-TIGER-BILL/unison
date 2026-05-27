import Testing
import Foundation
@testable import UnisonAudio

@Test func runningAudioProcesses_returnsAlphabeticallySorted() {
    let processes = AudioProcessRegistry.runningAudioProcesses()
    // Cannot assert non-empty (clean test runs may have no audio processes
    // yet), but if any are present they must be sorted.
    let names = processes.map(\.name)
    let sorted = names.sorted { $0.localizedCompare($1) == .orderedAscending }
    #expect(names == sorted)
}

@Test func audioProcess_isHashable() {
    let a = AudioProcess(pid: 1, bundleID: "x", name: "X", bundlePath: nil, isProducingAudio: false)
    let b = AudioProcess(pid: 1, bundleID: "x", name: "X", bundlePath: nil, isProducingAudio: false)
    #expect(a == b)
    #expect(a.hashValue == b.hashValue)
}

@Test func processObjectID_unknownBundleReturnsNil() {
    let result = AudioProcessRegistry.processObjectID(forBundleID: "com.nonexistent.bundle.does.not.exist")
    #expect(result == nil)
}
