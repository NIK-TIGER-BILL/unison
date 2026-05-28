import Darwin
import Foundation

public enum HostTimeClock {
    public static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func now() -> UInt64 {
        mach_absolute_time()
    }

    public static func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    public static func ticks(forMilliseconds ms: Double) -> UInt64 {
        let ns = UInt64(ms * 1_000_000)
        return ns * UInt64(timebase.denom) / UInt64(timebase.numer)
    }

    public static func milliseconds(from a: UInt64, to b: UInt64) -> Double {
        if b >= a {
            return Double(nanoseconds(fromTicks: b - a)) / 1_000_000.0
        } else {
            return -Double(nanoseconds(fromTicks: a - b)) / 1_000_000.0
        }
    }
}
