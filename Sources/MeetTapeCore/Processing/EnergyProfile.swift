import Foundation

/// Root-mean-square energy sampled on a fixed grid.
///
/// Used to place chunk boundaries in a natural pause instead of mid-sentence. A
/// simple energy floor is enough here; no model is involved.
public struct EnergyProfile: Sendable, Equatable {
    public let windowSeconds: Double
    public let values: [Float]

    public init(windowSeconds: Double, values: [Float]) {
        self.windowSeconds = windowSeconds
        self.values = values
    }

    public var durationSeconds: Double { Double(values.count) * windowSeconds }

    public func value(atSecond second: Double) -> Float {
        let index = Int(second / windowSeconds)
        guard index >= 0, index < values.count else { return 0 }
        return values[index]
    }

    /// Mean energy over a span, used to score candidate boundaries.
    public func meanEnergy(from start: Double, to end: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let first = max(0, Int(start / windowSeconds))
        let last = min(values.count - 1, Int(end / windowSeconds))
        guard first <= last else { return 0 }
        var total: Float = 0
        for index in first...last { total += values[index] }
        return total / Float(last - first + 1)
    }

    public static let empty = EnergyProfile(windowSeconds: 0.1, values: [])
}
