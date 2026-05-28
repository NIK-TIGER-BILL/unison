import Darwin
import Foundation

public final class CPUSampler: @unchecked Sendable {
    public private(set) var samples: [Double] = []
    private let queue = DispatchQueue(label: "tap-benchmark.cpu-sampler")
    private var timer: DispatchSourceTimer?
    private var lastSampleTime: UInt64 = 0
    private var lastCpuTimeNs: UInt64 = 0

    public init() {}

    public func start(intervalMs: Int = 100) {
        samples.removeAll(keepingCapacity: true)
        lastSampleTime = HostTimeClock.now()
        lastCpuTimeNs = currentProcessCpuNs()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(intervalMs),
                   repeating: .milliseconds(intervalMs))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func sample() {
        let now = HostTimeClock.now()
        let cpuNs = currentProcessCpuNs()
        let elapsedNs = HostTimeClock.nanoseconds(fromTicks: now - lastSampleTime)
        guard elapsedNs > 0 else { return }
        let cpuDelta = cpuNs >= lastCpuTimeNs ? cpuNs - lastCpuTimeNs : 0
        let pct = 100.0 * Double(cpuDelta) / Double(elapsedNs)
        samples.append(pct)
        lastSampleTime = now
        lastCpuTimeNs = cpuNs
    }

    private func currentProcessCpuNs() -> UInt64 {
        var info = task_thread_times_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.size /
                                            MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO),
                          $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.user_time.seconds) * 1_000_000_000
                 + UInt64(info.user_time.microseconds) * 1_000
        let sys  = UInt64(info.system_time.seconds) * 1_000_000_000
                 + UInt64(info.system_time.microseconds) * 1_000
        return user + sys
    }
}
