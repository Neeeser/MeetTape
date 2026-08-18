import AVFoundation
import Foundation
import MeetTapeCore

/// Reads one recorded track as a continuous signal at a chosen format.
///
/// Segments are recorded at whatever the hardware was doing at the time, so a
/// track can hold 48 kHz and 16 kHz files side by side. The reader resamples as it
/// goes and never materialises the whole meeting: two hours at 16 kHz float32
/// would be well over 400 MB.
///
/// The resampler is kept alive across segments that share a format, so a boundary
/// between two 30-second files costs nothing. It is only drained and rebuilt where
/// the format actually changes.
public final class TrackAudioReader {
    private let segments: [RecordedSegment]
    private let segmentsDirectory: URL
    public let targetFormat: AVAudioFormat

    private var segmentIndex = 0
    private var currentFile: AVAudioFile?
    private var currentSourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var inputBuffer: AVAudioPCMBuffer?
    private var isDrained = false
    /// Seconds of output produced so far, which is the position on the track.
    public private(set) var timelinePosition: Double = 0

    public init(segments: [RecordedSegment], segmentsDirectory: URL, targetFormat: AVAudioFormat) {
        self.segments = segments.sorted { $0.index < $1.index }
        self.segmentsDirectory = segmentsDirectory
        self.targetFormat = targetFormat
    }

    public var durationSeconds: Double { segments.reduce(0) { $0 + $1.seconds } }

    /// Skips forward to `offset` seconds by reading and discarding.
    public func seek(to offset: Double) throws {
        guard offset > timelinePosition else { return }
        let frames = AVAudioFrameCount(targetFormat.sampleRate * 0.5)
        while timelinePosition < offset {
            let remaining = offset - timelinePosition
            let request = min(AVAudioFrameCount(remaining * targetFormat.sampleRate) + 1, frames)
            guard let buffer = try read(frames: max(1, request)), buffer.frameLength > 0 else { return }
        }
    }

    /// Reads up to `frames` of output, or nil once the track is exhausted.
    public func read(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard frames > 0 else { return nil }
        while true {
            if converter == nil, !openNextSegmentGroup() { return nil }
            guard let converter, let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat, frameCapacity: frames
            ) else { return nil }

            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { [weak self] _, statusPointer in
                guard let self else {
                    statusPointer.pointee = .endOfStream
                    return nil
                }
                return nextInputBuffer(statusPointer)
            }

            if let conversionError {
                Log.processing.notice("resampler stopped: \(conversionError.code, privacy: .public)")
                self.converter = nil
                continue
            }
            switch status {
            case .haveData:
                timelinePosition += Double(output.frameLength) / targetFormat.sampleRate
                return output
            case .inputRanDry:
                if output.frameLength > 0 {
                    timelinePosition += Double(output.frameLength) / targetFormat.sampleRate
                    return output
                }
                continue
            case .endOfStream:
                if output.frameLength > 0 {
                    timelinePosition += Double(output.frameLength) / targetFormat.sampleRate
                    return output
                }
                self.converter = nil
                if segmentIndex >= segments.count { return nil }
                continue
            case .error:
                self.converter = nil
                continue
            @unknown default:
                return nil
            }
        }
    }

    /// Supplies the resampler with the next block of source audio, moving between
    /// segments that share a format without interrupting it.
    private func nextInputBuffer(
        _ statusPointer: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioPCMBuffer? {
        guard let sourceFormat = currentSourceFormat, let buffer = inputBuffer else {
            statusPointer.pointee = .endOfStream
            return nil
        }
        while true {
            guard let file = currentFile else {
                statusPointer.pointee = .endOfStream
                return nil
            }
            if file.framePosition < file.length {
                buffer.frameLength = 0
                do {
                    try file.read(into: buffer)
                } catch {
                    currentFile = nil
                    continue
                }
                if buffer.frameLength > 0 {
                    statusPointer.pointee = .haveData
                    return buffer
                }
                currentFile = nil
                continue
            }
            // Segment exhausted: continue into the next one if the format matches.
            guard let next = openSegment(at: segmentIndex, matching: sourceFormat) else {
                statusPointer.pointee = .endOfStream
                return nil
            }
            currentFile = next
            segmentIndex += 1
        }
    }

    /// Opens the next run of segments that share one source format.
    private func openNextSegmentGroup() -> Bool {
        guard !isDrained else { return false }
        while segmentIndex < segments.count {
            let segment = segments[segmentIndex]
            let url = segmentsDirectory.appendingPathComponent(segment.file)
            guard let file = try? AVAudioFile(forReading: url), file.length > 0 else {
                Log.processing.notice("skipping unreadable segment \(segment.file, privacy: .public)")
                segmentIndex += 1
                continue
            }
            segmentIndex += 1
            let sourceFormat = file.processingFormat
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                continue
            }
            converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            self.converter = converter
            currentSourceFormat = sourceFormat
            currentFile = file
            inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 16_384)
            return inputBuffer != nil
        }
        isDrained = true
        return false
    }

    private func openSegment(at index: Int, matching format: AVAudioFormat) -> AVAudioFile? {
        guard index < segments.count else { return nil }
        let segment = segments[index]
        guard segment.format.sampleRate == format.sampleRate,
              segment.format.channelCount == Int(format.channelCount)
        else { return nil }
        let url = segmentsDirectory.appendingPathComponent(segment.file)
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        return file
    }
}

/// Push-style access to a track, for callers that just want every buffer in order.
public struct TrackAudioStream: Sendable {
    public let segments: [RecordedSegment]
    public let segmentsDirectory: URL
    public let targetFormat: AVAudioFormat

    public init(segments: [RecordedSegment], segmentsDirectory: URL, targetFormat: AVAudioFormat) {
        self.segments = segments
        self.segmentsDirectory = segmentsDirectory
        self.targetFormat = targetFormat
    }

    public var durationSeconds: Double { segments.reduce(0) { $0 + $1.seconds } }

    public func makeReader() -> TrackAudioReader {
        TrackAudioReader(
            segments: segments, segmentsDirectory: segmentsDirectory, targetFormat: targetFormat
        )
    }

    /// Walks the track from `startOffset` to `endOffset`. Returning false stops.
    public func forEachBuffer(
        from startOffset: Double = 0,
        to endOffset: Double = .greatestFiniteMagnitude,
        bufferFrames: AVAudioFrameCount = 8_192,
        body: (AVAudioPCMBuffer, Double) throws -> Bool
    ) throws {
        let reader = makeReader()
        try reader.seek(to: startOffset)
        while true {
            let position = reader.timelinePosition
            if position >= endOffset { return }
            guard let buffer = try reader.read(frames: bufferFrames), buffer.frameLength > 0 else { return }
            if try !body(buffer, position) { return }
        }
    }
}

/// Computes an energy profile by streaming a recorded track once.
public extension EnergyProfile {
    static func compute(stream: TrackAudioStream, windowSeconds: Double = 0.1) throws -> EnergyProfile {
        let samplesPerWindow = Int(windowSeconds * stream.targetFormat.sampleRate)
        guard samplesPerWindow > 0 else { return EnergyProfile(windowSeconds: windowSeconds, values: []) }

        var values: [Float] = []
        var accumulator: Double = 0
        var count = 0

        try stream.forEachBuffer { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return true }
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            for frame in 0..<frames {
                var sample: Float = 0
                for channel in 0..<channels { sample += channelData[channel][frame] }
                sample /= Float(max(1, channels))
                accumulator += Double(sample * sample)
                count += 1
                if count == samplesPerWindow {
                    values.append(Float((accumulator / Double(count)).squareRoot()))
                    accumulator = 0
                    count = 0
                }
            }
            return true
        }
        if count > 0 {
            values.append(Float((accumulator / Double(count)).squareRoot()))
        }
        return EnergyProfile(windowSeconds: windowSeconds, values: values)
    }
}
