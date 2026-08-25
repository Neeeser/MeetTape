import Foundation

/// A half-open interval of one track's audio, in seconds on the meeting
/// timeline.
///
/// Half-open so two turns that touch do not read as overlapping: a line ending
/// at 12.0 and the next starting at 12.0 are different audio, and treating the
/// boundary as shared made every correction contradict its neighbour.
public struct AudioSpan: Codable, Sendable, Equatable, Hashable, Comparable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public var duration: Double { end - start }

    public static func < (lhs: AudioSpan, rhs: AudioSpan) -> Bool {
        lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
    }

    public func overlaps(_ other: AudioSpan) -> Bool {
        overlap(with: other) > 0
    }

    public func overlap(with other: AudioSpan) -> Double {
        max(0, min(end, other.end) - max(start, other.start))
    }

    /// Sorted, with touching and overlapping spans joined.
    ///
    /// Diarization emits one interval per turn, so a five-minute cluster
    /// arrives as hundreds of them. Storing the union keeps the row count
    /// proportional to speech rather than to turn-taking, and makes two
    /// evidence sets comparable without depending on how they were segmented.
    public static func union(_ spans: [AudioSpan]) -> [AudioSpan] {
        let sorted = spans.filter { $0.duration > 0 }.sorted()
        var merged: [AudioSpan] = []
        for span in sorted {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1] = AudioSpan(start: last.start, end: max(last.end, span.end))
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    public static func totalDuration(_ spans: [AudioSpan]) -> Double {
        union(spans).reduce(0) { $0 + $1.duration }
    }

    /// `spans` with everything `removed` covers taken out of it.
    ///
    /// What is left of a vector's evidence once part of its audio has been
    /// given to somebody else.
    public static func subtracting(_ removed: [AudioSpan], from spans: [AudioSpan]) -> [AudioSpan] {
        var out = union(spans)
        for cut in union(removed) {
            var next: [AudioSpan] = []
            for span in out {
                guard span.overlaps(cut) else { next.append(span); continue }
                if span.start < cut.start { next.append(AudioSpan(start: span.start, end: cut.start)) }
                if cut.end < span.end { next.append(AudioSpan(start: cut.end, end: span.end)) }
            }
            out = next
        }
        return out.filter { $0.duration > 0 }
    }

    public static func intersect(_ lhs: [AudioSpan], _ rhs: [AudioSpan]) -> Double {
        var total = 0.0
        for a in union(lhs) {
            for b in union(rhs) where a.overlaps(b) { total += a.overlap(with: b) }
        }
        return total
    }
}

/// The audio a stored voice vector was derived from.
///
/// This is the provenance that matters, and it is deliberately expressed in
/// coordinates the application never rewrites: a recording, a track and time
/// spans inside it. Cluster and analysis identifiers are carried alongside as
/// context for a human reading the row, and nothing about retraction depends on
/// them.
///
/// The reason is that every other candidate for provenance moves. Re-analysing
/// a meeting renumbers its clusters, merging identities moves ownership,
/// splitting one changes it back, and a line-level correction produces material
/// belonging to no cluster at all. Source audio does not move, so a question
/// like "which stored vectors contain the audio the user just reassigned" is a
/// lookup over spans rather than an inference from whatever the clustering
/// happens to look like now.
public struct VoiceEvidence: Codable, Sendable, Equatable {
    /// Which recording. A meeting folded into another keeps its own identifier,
    /// because it is still the only copy of that audio.
    public var meetingID: String
    public var track: CaptureTrack
    /// Where inside the track, on the meeting timeline.
    public var spans: [AudioSpan]
    public var confirmation: VoiceEnrollmentSource
    public var isHumanVerified: Bool
    /// The diarization run this came from, when it came from one. Context, not
    /// identity: a re-analysis makes it stale and nothing reads it to decide
    /// what a vector covers.
    public var analysisID: String?
    /// Likewise the cluster label as it stood at derivation time.
    public var clusterID: String?
    /// The part of `spans` still attributed to this vector's identity.
    ///
    /// Equal to `spans` until a person gives some of the audio to somebody
    /// else. What is left is what still supports the vector, and it is what the
    /// enrolment bar is measured against, so a series of small corrections adds
    /// up rather than each being weighed against the original.
    public var standingSpans: [AudioSpan]

    public init(
        meetingID: String,
        track: CaptureTrack,
        spans: [AudioSpan],
        confirmation: VoiceEnrollmentSource,
        isHumanVerified: Bool? = nil,
        analysisID: String? = nil,
        clusterID: String? = nil
    ) {
        self.meetingID = meetingID
        self.track = track
        self.spans = AudioSpan.union(spans)
        self.confirmation = confirmation
        self.isHumanVerified = isHumanVerified ?? confirmation.isHumanVerified
        self.analysisID = analysisID
        self.clusterID = clusterID
        self.standingSpans = self.spans
    }

    /// How much audio the vector was computed from.
    public var speechSeconds: Double { AudioSpan.totalDuration(spans) }

    /// How much of it is still this identity's.
    public var standingSeconds: Double { AudioSpan.totalDuration(standingSpans) }

    /// Whether this evidence covers audio that `other` also covers.
    ///
    /// Same recording, same track, overlapping time. That is the whole test:
    /// two vectors derived from overlapping audio cannot both belong to
    /// different people, whatever the clustering said at the time.
    public func contradicts(_ other: VoiceEvidence) -> Bool {
        guard meetingID == other.meetingID, track == other.track else { return false }
        return AudioSpan.intersect(spans, other.spans) > 0
    }
}

/// A retraction: the audio a person has just said belongs to somebody, which is
/// therefore no longer available to anybody else.
public struct VoiceEvidenceRetraction: Sendable, Equatable {
    public var meetingID: String
    public var track: CaptureTrack
    public var spans: [AudioSpan]
    /// Kept whole for the identity that now owns the audio, when there is one.
    /// A confirmation both retracts the audio from everybody else and enrols it
    /// for one person, and those are the same call.
    public var claimedBy: IdentityID?
    public var claimedCluster: String?

    public init(
        meetingID: String,
        track: CaptureTrack,
        spans: [AudioSpan],
        claimedBy: IdentityID? = nil
    ) {
        self.meetingID = meetingID
        self.track = track
        self.spans = AudioSpan.union(spans)
        self.claimedBy = claimedBy
    }

    /// The retraction implied by confirming one piece of evidence: everything
    /// it covers now belongs to `identity`.
    public static func claiming(
        _ evidence: VoiceEvidence, for identity: IdentityID?
    ) -> VoiceEvidenceRetraction {
        VoiceEvidenceRetraction(
            meetingID: evidence.meetingID,
            track: evidence.track,
            spans: evidence.spans,
            claimedBy: identity
        )
        .withCluster(evidence.clusterID)
    }
}

/// One stored vector and the audio behind it, as the store reports it.
extension VoiceEvidenceRetraction {
    func withCluster(_ id: String?) -> VoiceEvidenceRetraction {
        var copy = self
        copy.claimedCluster = id
        return copy
    }
}

public struct StoredVoiceEmbedding: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var identityID: IdentityID
    public var model: EmbeddingModelIdentifier
    public var speechSeconds: Double
    public var qualityScore: Double
    public var isHumanVerified: Bool
    public var createdAt: Date
    public var evidence: [VoiceEvidence]

    public init(
        id: Int64,
        identityID: IdentityID,
        model: EmbeddingModelIdentifier,
        speechSeconds: Double,
        qualityScore: Double,
        isHumanVerified: Bool,
        createdAt: Date,
        evidence: [VoiceEvidence]
    ) {
        self.id = id
        self.identityID = identityID
        self.model = model
        self.speechSeconds = speechSeconds
        self.qualityScore = qualityScore
        self.isHumanVerified = isHumanVerified
        self.createdAt = createdAt
        self.evidence = evidence
    }
}
