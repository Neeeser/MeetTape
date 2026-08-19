import AVFoundation
import Foundation
import MeetTapeCore

/// Writes a whole track as one uncompressed file for on-device processing.
///
/// The chunk exporter encodes AAC because the cloud endpoints charge by the
/// byte and cap the request body. Nothing here leaves the machine, so the audio
/// is handed over at 16 kHz mono linear PCM: the rate both the transcriber and
/// the diarizer resample to anyway, with no encoder in the path. A 60-minute
/// meeting lands at about 115 MB in a temporary file that is deleted when
/// processing finishes.
public struct TrackFileExporter: Sendable {
    public let sampleRate: Double

    public init(sampleRate: Double = 16_000) {
        self.sampleRate = sampleRate
    }

    public var readFormat: AudioFormatDescriptor {
        AudioFormatDescriptor(sampleRate: sampleRate, channelCount: 1)
    }

    /// Exports every segment of one track, in order, to `destination`.
    /// Returns the number of frames written.
    @discardableResult
    public func export(
        segments: [RecordedSegment], segmentsDirectory: URL, to destination: URL
    ) throws -> Int64 {
        let stream = TrackAudioStream(
            segments: segments, segmentsDirectory: segmentsDirectory, format: readFormat
        )
        let duration = stream.durationSeconds
        guard duration > 0 else { return 0 }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: destination, settings: settings)
        } catch {
            throw ProcessingError.audioUnreadable(path: destination.lastPathComponent)
        }

        var written: Int64 = 0
        try stream.forEachBuffer(from: 0, to: duration) { buffer, _ in
            try file.write(from: buffer)
            written += Int64(buffer.frameLength)
            return true
        }
        return written
    }
}

/// Decodes an audio file to the 16 kHz mono Float32 the speech models take.
public enum MonoAudioDecoder {
    public static func durationSeconds(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Full-file decode to 16 kHz mono Float32 in [-1, 1].
    public static func loadMono16k(_ url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ProcessingError.audioUnreadable(path: url.lastPathComponent)
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: file.processingFormat, to: outputFormat) else {
            throw ProcessingError.audioUnreadable(path: url.lastPathComponent)
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        var samples = [Float]()
        samples.reserveCapacity(
            Int(Double(file.length) / file.processingFormat.sampleRate * 16_000) + 16_000
        )
        let inputFrames: AVAudioFrameCount = 65_536
        let outputCapacity =
            AVAudioFrameCount(Double(inputFrames) * 16_000 / file.processingFormat.sampleRate) + 4_096
        var finished = false

        while !finished {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: outputCapacity
            ) else { throw ProcessingError.audioUnreadable(path: url.lastPathComponent) }
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: inputFrames
                ) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inputBuffer, frameCount: inputFrames)
                } catch {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }
            if conversionError != nil {
                throw ProcessingError.audioUnreadable(path: url.lastPathComponent)
            }
            if outputBuffer.frameLength > 0, let channel = outputBuffer.floatChannelData?[0] {
                samples.append(
                    contentsOf: UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength))
                )
            }
            if status == .endOfStream || status == .error { finished = true }
            if status == .inputRanDry, outputBuffer.frameLength == 0 { finished = true }
        }
        return samples
    }
}
