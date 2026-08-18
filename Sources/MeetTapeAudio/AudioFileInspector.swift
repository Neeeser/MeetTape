import AVFoundation
import Foundation
import MeetTapeCore

/// Reads what a recorded file actually contains.
///
/// Crash recovery depends on this: a CAF written by a killed process has a data
/// chunk size of -1, so its real length comes from the file, not the header.
public struct AudioFileInspector: AudioFileInspecting {
    public init() {}

    public func inspect(url: URL) throws -> AudioFileInfo {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw StorageError.fileReadFailed(path: url.path, underlying: "unreadable audio file")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let format = file.processingFormat
        return AudioFileInfo(
            frameCount: file.length,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            byteCount: byteCount
        )
    }
}

/// Reads media files chosen for import. Uses AVFoundation only, which decoded
/// WAV, M4A, MP3, CAF, AIFF and MP4 in feasibility testing with no FFmpeg.
public struct MediaFileInspector: Sendable {
    public struct Info: Sendable, Equatable {
        public let durationSeconds: Double
        public let sampleRate: Double
        public let channelCount: Int
        public let hasAudioTrack: Bool
    }

    public init() {}

    public func inspect(url: URL) async throws -> Info {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw ProcessingError.audioUnreadable(path: url.lastPathComponent)
        }
        guard let track = tracks.first else {
            return Info(durationSeconds: 0, sampleRate: 0, channelCount: 0, hasAudioTrack: false)
        }
        let duration = (try? await asset.load(.duration)) ?? .zero
        var sampleRate: Double = 0
        var channels = 0
        if let descriptions = try? await track.load(.formatDescriptions) {
            for description in descriptions {
                guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { continue }
                sampleRate = basic.pointee.mSampleRate
                channels = Int(basic.pointee.mChannelsPerFrame)
                break
            }
        }
        return Info(
            durationSeconds: CMTimeGetSeconds(duration),
            sampleRate: sampleRate,
            channelCount: channels,
            hasAudioTrack: true
        )
    }

    public static var supportedExtensions: [String] {
        ["wav", "m4a", "mp3", "caf", "aiff", "aif", "mp4", "mov", "aac", "flac", "m4v"]
    }
}
