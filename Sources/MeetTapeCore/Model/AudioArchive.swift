import Foundation

/// What the audio of a compacted meeting is stored as.
///
/// Written only after every track's archive file has been verified against the
/// manifest, and consulted instead of the disk: which representation a reader
/// gets is a recorded fact, never an inference from what files happen to exist.
public struct AudioArchive: Codable, Sendable, Equatable {
    /// One track's archive file, in coordinates a reader needs to stand in for
    /// the segment chain it replaced.
    public struct Track: Codable, Sendable, Equatable {
        /// Filename inside the archive audio directory, e.g. `mic.m4a`.
        public var file: String
        public var sampleRate: Double
        public var channelCount: Int
        /// Frames written at `sampleRate`, counted from the source stream.
        public var frameCount: Int64
        public var seconds: Double
        /// Host time of the track's first recorded frame, carried over from the
        /// segment chain. The mixdown aligns tracks by this, and the segments it
        /// originally came from are deleted.
        public var firstFrameHostTime: Double?

        public init(
            file: String, sampleRate: Double, channelCount: Int, frameCount: Int64,
            seconds: Double, firstFrameHostTime: Double?
        ) {
            self.file = file
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.frameCount = frameCount
            self.seconds = seconds
            self.firstFrameHostTime = firstFrameHostTime
        }
    }

    public var compactedAt: Date
    public var mic: Track?
    public var remote: Track?

    public init(compactedAt: Date, mic: Track? = nil, remote: Track? = nil) {
        self.compactedAt = compactedAt
        self.mic = mic
        self.remote = remote
    }

    public func track(_ track: CaptureTrack) -> Track? {
        switch track {
        case .mic: mic
        case .remote: remote
        }
    }

    public mutating func setTrack(_ track: CaptureTrack, to record: Track?) {
        switch track {
        case .mic: mic = record
        case .remote: remote = record
        }
    }
}
