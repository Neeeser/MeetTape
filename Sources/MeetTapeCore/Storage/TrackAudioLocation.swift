import Foundation

/// Where one track's audio can be read from: a list of files in a directory,
/// in playback order.
///
/// Before compaction this is the live segment chain; afterwards it is a single
/// archive file wearing a synthetic segment so every reader keeps working off
/// the same shape. Which one a meeting gets is decided by
/// `MeetingStore.trackAudioLocation`, from the metadata rather than the disk.
public struct TrackAudioLocation: Sendable, Equatable {
    public let segments: [RecordedSegment]
    public let directory: URL

    public init(segments: [RecordedSegment], directory: URL) {
        self.segments = segments
        self.directory = directory
    }

    public var isEmpty: Bool { segments.isEmpty }

    /// Total seconds of audio at this location.
    public var seconds: Double { segments.reduce(0) { $0 + $1.seconds } }

    /// A compacted track: one archive file standing in for the chain it
    /// replaced, carrying the first-frame host time the mixdown aligns by.
    public static func archived(
        track: CaptureTrack, record: AudioArchive.Track, directory: URL, compactedAt: Date
    ) -> TrackAudioLocation {
        var segment = RecordedSegment(
            track: track,
            index: 1,
            file: record.file,
            format: AudioFormatDescriptor(
                sampleRate: record.sampleRate, channelCount: record.channelCount
            ),
            startFrame: 0,
            firstFrameHostTime: record.firstFrameHostTime,
            openedAt: compactedAt,
            openReason: "archive"
        )
        segment.close(
            frameCount: record.frameCount, byteCount: 0, reason: "archive", adopted: false
        )
        return TrackAudioLocation(segments: [segment], directory: directory)
    }
}
