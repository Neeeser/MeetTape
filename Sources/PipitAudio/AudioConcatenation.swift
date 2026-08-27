import AVFoundation
import Foundation
import PipitCore

/// Why several recordings could not be made into one.
public enum AudioConcatenationError: Error, Equatable {
    case nothingToJoin
    /// The takes were recorded at different formats, which happens when the
    /// input device changes between them.
    case formatMismatch
}

/// Joins recordings into one file.
///
/// For a person who read part of a script, was told they were short, and read
/// some more: the takes are one reading with a pause in the middle, and what
/// judges the reading needs to see them that way.
public enum AudioConcatenation {
    /// Writes `files` end to end into `destination`, in the order given.
    ///
    /// Every file has to carry the same format. They come from one capture
    /// session a few seconds apart, so they do unless the input device changed
    /// underneath the reader, and that is a mismatch rather than something to
    /// resample silently.
    public static func join(_ files: [URL], into destination: URL) throws {
        guard let first = files.first else { throw AudioConcatenationError.nothingToJoin }
        let readers = try files.map { try AVAudioFile(forReading: $0) }
        let format = try AVAudioFile(forReading: first).processingFormat
        guard readers.allSatisfy({
            $0.processingFormat.sampleRate == format.sampleRate
                && $0.processingFormat.channelCount == format.channelCount
        }) else { throw AudioConcatenationError.formatMismatch }

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAudioFile(
            forWriting: destination, settings: readers[0].fileFormat.settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved
        )
        // A block at a time rather than a whole take, because a reading that
        // took four tries is minutes of audio and this runs while somebody
        // waits.
        let blockFrames: AVAudioFrameCount = 16_384
        for reader in readers {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: reader.processingFormat, frameCapacity: blockFrames
            ) else { continue }
            while reader.framePosition < reader.length {
                try reader.read(into: buffer, frameCount: blockFrames)
                guard buffer.frameLength > 0 else { break }
                try writer.write(from: buffer)
            }
        }
    }
}
