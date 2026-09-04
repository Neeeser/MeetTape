import Foundation
import PipitAudio
import PipitCore

/// One track, read a stretch at a time, shifted onto whichever timeline the
/// caller is working on.
///
/// The two tracks do not begin at the same instant, and every comparison made
/// between them is between the same moment on both. The offset is what puts
/// them there. Where a track needs to start later than the timeline does, the
/// seconds before it started recording are handed back as the silence they
/// were; where it needs to start earlier, that much of it is read and thrown
/// away.
final class TimelineTrackReader {
    private let reader: TrackAudioReader
    private var silenceRemaining: Int
    private var skipRemaining: Int
    private var pending: [Float] = []
    private var exhausted = false

    /// - Parameter offsetSeconds: positive pads that many seconds of zeros
    ///   before the track, negative skips that many seconds of it.
    init?(location: TrackAudioLocation, format: AudioFormatDescriptor, offsetSeconds: Double) {
        let stream = TrackAudioStream(
            segments: location.segments, segmentsDirectory: location.directory, format: format
        )
        guard let reader = stream.makeReader() else { return nil }
        self.reader = reader
        let frames = Int((abs(offsetSeconds) * format.sampleRate).rounded())
        silenceRemaining = offsetSeconds > 0 ? frames : 0
        skipRemaining = offsetSeconds < 0 ? frames : 0
    }

    /// The next `count` samples, or fewer where the track has run out.
    func next(count: Int) throws -> [Float] {
        try skipToStart()
        var out: [Float] = []
        out.reserveCapacity(count)
        if silenceRemaining > 0 {
            let take = min(silenceRemaining, count)
            out.append(contentsOf: repeatElement(0, count: take))
            silenceRemaining -= take
        }
        while out.count < count {
            if pending.isEmpty {
                guard !exhausted, let block = try read() else {
                    exhausted = true
                    break
                }
                pending = block
            }
            let take = min(count - out.count, pending.count)
            out.append(contentsOf: pending[..<take])
            pending.removeFirst(take)
        }
        return out
    }

    /// Reads and discards a negative offset. Done here rather than in the
    /// initialiser because decoding throws and an initialiser that can only
    /// return nil would report a damaged file as a missing one.
    private func skipToStart() throws {
        while skipRemaining > 0 {
            if pending.isEmpty {
                guard !exhausted, let block = try read() else {
                    exhausted = true
                    skipRemaining = 0
                    return
                }
                pending = block
            }
            let take = min(skipRemaining, pending.count)
            pending.removeFirst(take)
            skipRemaining -= take
        }
    }

    private func read() throws -> [Float]? {
        while true {
            guard let buffer = try reader.read(frames: 16_384), buffer.frameLength > 0 else {
                return nil
            }
            guard let channel = buffer.floatChannelData?[0] else { continue }
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
    }
}
