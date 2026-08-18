import Foundation

/// A mutex around a value the compiler cannot prove `Sendable`.
///
/// CoreAudio and AVFoundation objects are safe to use from one thread at a time
/// but carry no `Sendable` annotation, so `Mutex` refuses to hold them. This box
/// makes the guarantee explicit: the value is only ever read or written inside
/// `withLock`, and no reference to it escapes that closure.
public final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) { self.value = value }

    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
