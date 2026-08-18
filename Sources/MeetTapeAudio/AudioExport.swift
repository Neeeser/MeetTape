import AVFoundation
import Foundation
import MeetTapeCore

/// Writes request-sized audio files for the transcription API.
///
/// AAC in an M4A container, mono, 16 kHz: a 20-minute chunk lands around 5 MB,
/// comfortably under the 25 MiB request-body limit, and 16 kHz is the rate the
/// transcription models work at internally.
public struct ChunkExporter: Sendable {
    public struct Settings: Sendable, Equatable {
        public var sampleRate: Double
        public var channelCount: Int
        public var bitRate: Int

        public init(sampleRate: Double = 16_000, channelCount: Int = 1, bitRate: Int = 32_000) {
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.bitRate = bitRate
        }

        public static let transcription = Settings()
    }

    public let settings: Settings

    public init(settings: Settings = .transcription) {
        self.settings = settings
    }

    /// The format chunks are read at before encoding.
    public var readFormat: AudioFormatDescriptor {
        AudioFormatDescriptor(
            sampleRate: settings.sampleRate, channelCount: settings.channelCount
        )
    }

    /// Exports `[plan.start, plan.end)` of a track to `destination`.
    @discardableResult
    public func export(
        plan: ChunkPlan,
        segments: [RecordedSegment],
        segmentsDirectory: URL,
        to destination: URL
    ) throws -> Int64 {
        let stream = TrackAudioStream(
            segments: segments, segmentsDirectory: segmentsDirectory, format: readFormat
        )
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: settings.sampleRate,
            AVNumberOfChannelsKey: settings.channelCount,
            AVEncoderBitRateKey: settings.bitRate,
        ]
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: destination, settings: outputSettings)
        } catch {
            throw ProcessingError.audioUnreadable(path: destination.lastPathComponent)
        }

        var written: Int64 = 0
        try stream.forEachBuffer(from: plan.start, to: plan.end) { buffer, _ in
            try file.write(from: buffer)
            written += Int64(buffer.frameLength)
            return true
        }
        return written
    }
}

/// Produces `mixed.caf`, the single-file version of a meeting for listening.
///
/// Derived and safe to delete: the two source tracks stay untouched. Alignment
/// uses the host timestamps both sources stamped their first frame with, which is
/// what keeps them together without resampling either one.
public struct AudioMixer: Sendable {
    public let sampleRate: Double

    public init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
    }

    public func mix(timeline: RecordingTimeline, segmentsDirectory: URL, to destination: URL) throws {
        let micSegments = timeline.segments(track: .mic)
        let remoteSegments = timeline.segments(track: .remote)
        guard !micSegments.isEmpty || !remoteSegments.isEmpty else { return }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw ProcessingError.audioUnreadable(path: destination.lastPathComponent)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        try? FileManager.default.removeItem(at: destination)
        let output = try AVAudioFile(forWriting: destination, settings: settings)

        let micReader = micSegments.isEmpty ? nil : TrackAudioReader(
            segments: micSegments, segmentsDirectory: segmentsDirectory, targetFormat: format
        )
        let remoteReader = remoteSegments.isEmpty ? nil : TrackAudioReader(
            segments: remoteSegments, segmentsDirectory: segmentsDirectory, targetFormat: format
        )

        // Whichever source started later is delayed by the difference between the
        // host times each stamped its first frame with.
        let micStart = micSegments.compactMap(\.resolvedFirstFrameHostTime).first
        let remoteStart = remoteSegments.compactMap(\.resolvedFirstFrameHostTime).first
        var micLeadIn: Double = 0
        var remoteLeadIn: Double = 0
        if let micStart, let remoteStart {
            if micStart > remoteStart {
                micLeadIn = micStart - remoteStart
            } else {
                remoteLeadIn = remoteStart - micStart
            }
        }

        let blockFrames = AVAudioFrameCount(sampleRate * 0.5)
        var sources: [MixSource] = []
        if let micReader {
            sources.append(MixSource(reader: micReader, silenceFrames: Int(micLeadIn * sampleRate)))
        }
        if let remoteReader {
            sources.append(MixSource(reader: remoteReader, silenceFrames: Int(remoteLeadIn * sampleRate)))
        }

        while sources.contains(where: { !$0.isFinished }) {
            guard let mixed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames),
                  let mixedData = mixed.floatChannelData
            else { break }
            for frame in 0..<Int(blockFrames) { mixedData[0][frame] = 0 }
            var producedFrames = 0

            for source in sources where !source.isFinished {
                var offset = 0
                if source.silenceFrames > 0 {
                    let padding = min(source.silenceFrames, Int(blockFrames))
                    source.silenceFrames -= padding
                    offset = padding
                    producedFrames = max(producedFrames, padding)
                    if offset == Int(blockFrames) { continue }
                }
                let request = AVAudioFrameCount(Int(blockFrames) - offset)
                guard let buffer = try source.reader.read(frames: request), buffer.frameLength > 0,
                      let channelData = buffer.floatChannelData
                else {
                    source.isFinished = true
                    continue
                }
                let count = Int(buffer.frameLength)
                for frame in 0..<count {
                    mixedData[0][offset + frame] += channelData[0][frame]
                }
                producedFrames = max(producedFrames, offset + count)
            }

            guard producedFrames > 0 else { break }
            mixed.frameLength = AVAudioFrameCount(producedFrames)
            // Two summed sources can exceed full scale; scale rather than clip.
            for frame in 0..<producedFrames {
                mixedData[0][frame] = max(-1, min(1, mixedData[0][frame] * 0.8))
            }
            try output.write(from: mixed)
        }
    }
}

/// One track being folded into the mix, with the lead-in silence that aligns it
/// against the other track's first frame.
private final class MixSource {
    let reader: TrackAudioReader
    var silenceFrames: Int
    var isFinished = false

    init(reader: TrackAudioReader, silenceFrames: Int) {
        self.reader = reader
        self.silenceFrames = silenceFrames
    }
}
