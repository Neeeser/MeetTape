import Foundation

/// The format a segment was actually recorded at. Recorded per segment because a
/// Bluetooth profile switch changes the rate mid-meeting (48 kHz to 16 kHz was
/// measured), and every duration calculation has to respect that.
public struct AudioFormatDescriptor: Codable, Sendable, Equatable {
    public let sampleRate: Double
    public let channelCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    /// A device mid-teardown reports zero channels at zero hertz. Capture must
    /// never be rebuilt against that state.
    public var isUsable: Bool { sampleRate > 0 && channelCount > 0 }

    public var description: String { "\(channelCount)ch/\(Int(sampleRate))Hz" }
}
