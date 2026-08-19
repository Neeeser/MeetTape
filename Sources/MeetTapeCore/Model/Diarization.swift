import Foundation

/// One interval of speech attributed to one raw cluster, on the meeting
/// timeline.
public struct DiarizationInterval: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    /// The diarizer's own label, before any naming happens.
    public var clusterID: String
    public var quality: Double

    public init(start: Double, end: Double, clusterID: String, quality: Double = 1) {
        self.start = start
        self.end = end
        self.clusterID = clusterID
        self.quality = quality
    }

    public var duration: Double { max(0, end - start) }
}

/// One cluster the diarizer found, with the vector that represents it.
public struct DiarizationCluster: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var speechSeconds: Double
    public var quality: Double
    /// Centroid over the cluster's chunk embeddings, already L2-normalized.
    /// Absent when the backend returned intervals without vectors.
    public var embedding: [Float]?
    public var embeddingModel: String?
    public var chunkCount: Int

    public init(
        id: String, speechSeconds: Double, quality: Double = 1,
        embedding: [Float]? = nil, embeddingModel: String? = nil, chunkCount: Int = 0
    ) {
        self.id = id
        self.speechSeconds = speechSeconds
        self.quality = quality
        self.embedding = embedding
        self.embeddingModel = embeddingModel
        self.chunkCount = chunkCount
    }
}

/// One diarization pass over one track.
///
/// Immutable once written. Re-analysing a meeting appends another run and marks
/// it active; the previous run stays on disk so the change can be undone
/// without touching audio.
public struct DiarizationRun: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var track: CaptureTrack
    /// Which backend produced it, for example
    /// `fluidaudio-offline-0.15.6` or `gpt-4o-transcribe-diarize`.
    public var backend: String
    public var producedAt: Date
    /// Seconds added to every interval to put it on the meeting timeline.
    public var timelineOffset: Double
    /// Only one run per track renders. The others are history.
    public var isActive: Bool
    /// The settings that produced it, so a result can be explained and
    /// reproduced. Kept as strings because it is provenance, not configuration.
    public var configuration: [String: String]
    public var clusters: [DiarizationCluster]
    public var intervals: [DiarizationInterval]

    public init(
        id: String,
        track: CaptureTrack,
        backend: String,
        producedAt: Date,
        timelineOffset: Double,
        isActive: Bool = true,
        configuration: [String: String] = [:],
        clusters: [DiarizationCluster] = [],
        intervals: [DiarizationInterval] = []
    ) {
        self.id = id
        self.track = track
        self.backend = backend
        self.producedAt = producedAt
        self.timelineOffset = timelineOffset
        self.isActive = isActive
        self.configuration = configuration
        self.clusters = clusters
        self.intervals = intervals
    }

    public var speakerCount: Int { Set(intervals.map(\.clusterID)).count }

    public var speechSeconds: Double { intervals.reduce(0) { $0 + $1.duration } }
}

/// `diarization.raw.json`. The immutable record of who spoke when.
///
/// Separate from `transcript.raw.json` because transcription and diarization are
/// independently chosen backends: one may be local while the other is not, and
/// re-analysing speakers must never invalidate the words.
public struct RawDiarization: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var runs: [DiarizationRun]

    public init(version: Int = RawDiarization.currentVersion, runs: [DiarizationRun] = []) {
        self.version = version
        self.runs = runs
    }

    public func activeRun(track: CaptureTrack) -> DiarizationRun? {
        runs.last { $0.track == track && $0.isActive }
    }

    public var activeRuns: [DiarizationRun] {
        CaptureTrack.allCases.compactMap { activeRun(track: $0) }
    }

    /// Replaces the active run for a track, keeping the superseded one.
    public mutating func setActive(_ run: DiarizationRun) {
        for index in runs.indices where runs[index].track == run.track {
            runs[index].isActive = false
        }
        if let existing = runs.firstIndex(where: { $0.id == run.id }) {
            runs[existing] = run
        } else {
            runs.append(run)
        }
    }

    /// The next run identifier for a track: `remote-002`.
    public func nextRunID(track: CaptureTrack) -> String {
        let count = runs.filter { $0.track == track }.count
        return String(format: "%@-%03d", track.rawValue, count + 1)
    }
}
