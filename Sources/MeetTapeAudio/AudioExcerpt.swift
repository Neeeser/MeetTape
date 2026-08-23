import AVFoundation
import Foundation
import MeetTapeCore

/// Cuts a span out of a recording.
///
/// A benchmark case names a window on a published recording rather than
/// shipping the audio, so the harness has to produce that window itself. The
/// output is mono at the source rate, which is what an import expects.
public struct AudioExcerptCutter: Sendable {
    public init() {}

    /// Writes `[startSeconds, startSeconds + seconds)` of `source` to
    /// `destination` as a WAV file, and returns how many seconds were written.
    ///
    /// A window running past the end of the recording is truncated rather than
    /// refused: the caller learns what it got from the return value.
    @discardableResult
    public func cut(
        source: URL, startSeconds: Double, seconds: Double, to destination: URL
    ) throws -> Double {
        guard let input = try? AVAudioFile(forReading: source) else {
            throw ProcessingError.audioUnreadable(path: source.lastPathComponent)
        }
        let sourceFormat = input.processingFormat
        guard sourceFormat.sampleRate > 0 else {
            throw ProcessingError.audioUnreadable(path: source.lastPathComponent)
        }
        guard let monoFormat = AVAudioFormat(
            standardFormatWithSampleRate: sourceFormat.sampleRate, channels: 1
        ) else {
            throw ProcessingError.audioUnreadable(path: source.lastPathComponent)
        }

        let first = AVAudioFramePosition(max(0, startSeconds) * sourceFormat.sampleRate)
        guard first < input.length else { return 0 }
        let wanted = AVAudioFrameCount(
            min(Double(input.length - first), max(0, seconds) * sourceFormat.sampleRate)
        )
        guard wanted > 0 else { return 0 }
        input.framePosition = first

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)
        let output = try AVAudioFile(
            forWriting: destination,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sourceFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        guard let converter = AVAudioConverter(from: sourceFormat, to: monoFormat),
              let readBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 16_384),
              let writeBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 16_384)
        else {
            throw ProcessingError.audioUnreadable(path: source.lastPathComponent)
        }

        var remaining = wanted
        var written: AVAudioFrameCount = 0
        while remaining > 0 {
            let request = min(remaining, readBuffer.frameCapacity)
            try input.read(into: readBuffer, frameCount: request)
            guard readBuffer.frameLength > 0 else { break }
            remaining -= readBuffer.frameLength

            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: writeBuffer, error: &conversionError) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return readBuffer
            }
            if let conversionError { throw conversionError }
            guard status != .error, writeBuffer.frameLength > 0 else { continue }
            try output.write(from: writeBuffer)
            written += writeBuffer.frameLength
        }
        return Double(written) / sourceFormat.sampleRate
    }
}
