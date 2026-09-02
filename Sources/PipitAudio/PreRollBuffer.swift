import AVFoundation
import Foundation
import PipitCore

/// A bounded in-memory ring of recent audio.
///
/// Capture starts the moment a call becomes a candidate, but nothing is written to
/// disk until the call is confirmed. The ring is what makes that affordable:
/// appending a callback costs roughly a microsecond, so the first sentence is
/// never lost and an abandoned prejoin leaves nothing behind.
///
/// Bounded by seconds, not bytes, so its size follows the device. 15 seconds of
/// 48 kHz float32 is about 2.7 MiB per channel: 5.5 MiB for a stereo interface,
/// 25 MiB for the nine-channel input one of the development machines exposes.
/// The microphone tap runs at the device's own format, so that is the figure
/// to expect on such a machine.
public final class PreRollBuffer: Sendable {
    private struct State {
        var packets: [AudioBufferPacket] = []
        var bufferedSeconds: Double = 0
    }

    private let state = LockedBox(State())
    public let capacitySeconds: Double

    public init(capacitySeconds: Double = 15) {
        self.capacitySeconds = capacitySeconds
    }

    public var bufferedSeconds: Double { state.withLock { $0.bufferedSeconds } }
    public var packetCount: Int { state.withLock { $0.packets.count } }
    public var earliestHostTime: Double? { state.withLock { $0.packets.first?.hostTime } }

    /// Appends a packet, evicting from the front to stay inside the window.
    public func append(_ packet: AudioBufferPacket) {
        state.withLock { state in
            state.packets.append(packet)
            state.bufferedSeconds += packet.seconds
            while state.bufferedSeconds > capacitySeconds, let first = state.packets.first {
                state.packets.removeFirst()
                state.bufferedSeconds -= first.seconds
            }
        }
    }

    /// Removes and returns everything buffered, oldest first.
    public func drain() -> [AudioBufferPacket] {
        state.withLock { state in
            let packets = state.packets
            state.packets = []
            state.bufferedSeconds = 0
            return packets
        }
    }

    /// Throws away buffered audio for a candidate that was rejected.
    public func discard() {
        state.withLock { state in
            state.packets = []
            state.bufferedSeconds = 0
        }
    }
}
