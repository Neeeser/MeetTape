import Foundation

/// Wall-clock and monotonic time, injected so timing policy is testable without
/// sleeping. `monotonicSeconds` is the mach host clock: it never jumps and is the
/// same base the audio stack stamps buffers with.
public protocol Clock: Sendable {
    var now: Date { get }
    var monotonicSeconds: Double { get }
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
    public var monotonicSeconds: Double { HostTime.seconds(mach_absolute_time()) }
}

/// Converts mach host time to seconds. Every capture source stamps its buffers
/// with this, which is what lets the microphone and remote tracks be aligned
/// without resampling.
public enum HostTime {
    private nonisolated(unsafe) static var timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func seconds(_ hostTime: UInt64) -> Double {
        Double(hostTime) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    public static var now: Double { seconds(mach_absolute_time()) }
}

/// Test clock. Time only advances when a test advances it, so debounce and grace
/// windows are exercised exactly rather than approximately.
public final class ManualClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var _monotonic: Double
    private var _now: Date

    public init(monotonic: Double = 1_000, now: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self._monotonic = monotonic
        self._now = now
    }

    public var monotonicSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return _monotonic
    }

    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return _now
    }

    public func advance(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        _monotonic += seconds
        _now = _now.addingTimeInterval(seconds)
    }
}
