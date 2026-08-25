import AVFoundation
import Foundation
import PipitCore

/// Brings an existing recording into the archive.
///
/// The original file is copied in untouched and kept. The decoded copy is written
/// as ordinary CAF segments with a manifest, so an imported meeting travels the
/// same pipeline as a captured one and nothing downstream needs a special case.
public struct AudioImporter: Sendable {
    public struct Result: Sendable, Equatable {
        public let durationSeconds: Double
        public let originalFilename: String
        public let segmentCount: Int
    }

    public let segmentSeconds: Double
    private let clock: any Clock

    public init(segmentSeconds: Double = 30, clock: any Clock = SystemClock()) {
        self.segmentSeconds = segmentSeconds
        self.clock = clock
    }

    public func `import`(
        source: URL, into store: MeetingStore, meetingID: String
    ) throws -> Result {
        try store.createDirectories()
        try FileManager.default.createDirectory(
            at: store.layout.originals, withIntermediateDirectories: true
        )

        let preserved = store.layout.originals.appendingPathComponent(source.lastPathComponent)
        if !FileManager.default.fileExists(atPath: preserved.path) {
            do {
                try FileManager.default.copyItem(at: source, to: preserved)
            } catch {
                throw StorageError.fileWriteFailed(path: preserved.path, underlying: "\(error)")
            }
        }

        guard let input = try? AVAudioFile(forReading: preserved) else {
            throw ProcessingError.audioUnreadable(path: source.lastPathComponent)
        }
        let sourceFormat = input.processingFormat
        guard sourceFormat.sampleRate > 0 else {
            throw ProcessingError.audioUnreadable(path: source.lastPathComponent)
        }
        // Imported audio is written mono: an imported recording has no separate
        // local speaker, so the whole file is diarized as one track.
        guard let targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: sourceFormat.sampleRate, channels: 1
        ) else {
            throw ProcessingError.audioUnreadable(path: source.lastPathComponent)
        }

        let manifest = try ManifestWriter(url: store.layout.manifest)
        defer { manifest.close() }
        manifest.append(
            .sessionStart(.init(
                meetingID: meetingID, source: .imported, segmentSeconds: segmentSeconds,
                appVersion: PipitVersion.current,
                processID: ProcessInfo.processInfo.processIdentifier
            )),
            hostTime: clock.monotonicSeconds, wallClock: clock.now
        )

        let writer = SegmentWriter(
            track: .mic, layout: store.layout, manifest: manifest, format: targetFormat,
            segmentSeconds: segmentSeconds, clock: clock
        )

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let readBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 16_384)
        else {
            throw ProcessingError.audioUnreadable(path: source.lastPathComponent)
        }
        // More than two channels with no surround layout has no mixdown matrix,
        // and the converter would produce silence.
        if sourceFormat.channelCount > 2 {
            converter.channelMap = (0..<Int(targetFormat.channelCount)).map { NSNumber(value: $0) }
        }

        var producedFrames: Int64 = 0
        var hostTime = clock.monotonicSeconds
        while input.framePosition < input.length {
            readBuffer.frameLength = 0
            do {
                try input.read(into: readBuffer)
            } catch {
                break
            }
            guard readBuffer.frameLength > 0 else { break }

            let capacity = AVAudioFrameCount(
                Double(readBuffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate + 1_024
            )
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { break }
            var consumed = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, statusPointer in
                if consumed {
                    statusPointer.pointee = .noDataNow
                    return nil
                }
                consumed = true
                statusPointer.pointee = .haveData
                return readBuffer
            }
            if status == .error { break }
            guard output.frameLength > 0 else { continue }

            writer.enqueueSynchronously(AudioBufferPacket(buffer: output, hostTime: hostTime))
            producedFrames += Int64(output.frameLength)
            hostTime += Double(output.frameLength) / targetFormat.sampleRate
        }

        writer.finish(reason: "import_complete")
        let stats = writer.stats
        manifest.append(
            .sessionEnd(.init(reason: "import_complete", micSeconds: stats.totalSeconds, remoteSeconds: 0)),
            hostTime: clock.monotonicSeconds, wallClock: clock.now
        )

        return Result(
            durationSeconds: stats.totalSeconds,
            originalFilename: source.lastPathComponent,
            segmentCount: stats.segmentCount
        )
    }
}
