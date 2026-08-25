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

    /// The same intervals with every second that a different cluster also
    /// claims cut out. An interval fully covered by another voice disappears.
    ///
    /// This is what voice enrolment reads. An overlap-aware diarizer marks
    /// both speakers across shared seconds, and that audio holds two people:
    /// fed to either cluster's embedding it puts someone else's voice in a
    /// profile, which is the permanent kind of wrong. Overlapping audio cannot
    /// belong to two people, so it enrols neither. Two intervals of the same
    /// cluster never cut each other: one voice cannot talk over itself.
    public static func soloSpeech(_ intervals: [DiarizationInterval]) -> [DiarizationInterval] {
        var out: [DiarizationInterval] = []
        for interval in intervals {
            let others = intervals.filter {
                $0.clusterID != interval.clusterID
                    && $0.start < interval.end && $0.end > interval.start
            }
            var pieces: [(start: Double, end: Double)] = [(interval.start, interval.end)]
            for other in others {
                var next: [(start: Double, end: Double)] = []
                for piece in pieces {
                    if other.end <= piece.start || other.start >= piece.end {
                        next.append(piece)
                        continue
                    }
                    if other.start > piece.start { next.append((piece.start, other.start)) }
                    if other.end < piece.end { next.append((other.end, piece.end)) }
                }
                pieces = next
            }
            for piece in pieces where piece.end > piece.start {
                out.append(DiarizationInterval(
                    start: piece.start, end: piece.end,
                    clusterID: interval.clusterID, quality: interval.quality
                ))
            }
        }
        return out
    }
}

/// One cluster the diarizer found.
///
/// Carries no vector on purpose. This structure is written into the meeting
/// folder, which is the user's export, and a speaker embedding is a biometric
/// identifier that matches the same person across devices, rooms and years.
/// Vectors live in the identity store under Application Support and nowhere
/// else.
public struct DiarizationCluster: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var speechSeconds: Double
    public var quality: Double
    /// How many embedding windows the cluster covered, as a rough measure of
    /// how much the diarizer had to work with.
    public var chunkCount: Int

    public init(id: String, speechSeconds: Double, quality: Double = 1, chunkCount: Int = 0) {
        self.id = id
        self.speechSeconds = speechSeconds
        self.quality = quality
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
    /// The track lead-in already added to every interval below, kept as
    /// provenance. Intervals are stored on the meeting timeline.
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
