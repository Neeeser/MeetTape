import Foundation

/// One diarization cluster inside one meeting: the unit a person edits.
///
/// A cluster is whatever the diarizer decided, so it may be one speaker, part of
/// one speaker, or two speakers it could not separate. The occurrence is the row
/// that carries the decision about who that cluster is, together with everything
/// needed to explain the decision later.
public struct SpeakerOccurrence: Sendable, Equatable, Identifiable, Codable {
    public var id: Int64
    public var meetingID: String
    /// The raw cluster label, namespaced the same way the transcript's
    /// `speakerKey` is, so the two join without a translation table.
    public var clusterID: String
    public var track: CaptureTrack
    public var speechSeconds: Double
    public var resolvedIdentityID: IdentityID?
    public var source: SpeakerAssignmentOrigin
    public var score: Double?
    public var runnerUpScore: Double?
    public var margin: Double?
    public var band: SpeakerConfidenceBand
    public var humanVerified: Bool
    public var wasExpectedParticipant: Bool
    public var embeddingModel: EmbeddingModelIdentifier?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64,
        meetingID: String,
        clusterID: String,
        track: CaptureTrack,
        speechSeconds: Double,
        resolvedIdentityID: IdentityID? = nil,
        source: SpeakerAssignmentOrigin = .ai,
        score: Double? = nil,
        runnerUpScore: Double? = nil,
        margin: Double? = nil,
        band: SpeakerConfidenceBand = .unknown,
        humanVerified: Bool = false,
        wasExpectedParticipant: Bool = false,
        embeddingModel: EmbeddingModelIdentifier? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.meetingID = meetingID
        self.clusterID = clusterID
        self.track = track
        self.speechSeconds = speechSeconds
        self.resolvedIdentityID = resolvedIdentityID
        self.source = source
        self.score = score
        self.runnerUpScore = runnerUpScore
        self.margin = margin
        self.band = band
        self.humanVerified = humanVerified
        self.wasExpectedParticipant = wasExpectedParticipant
        self.embeddingModel = embeddingModel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Why one speaker carries the name it does, kept so an automatic decision can
/// be explained and audited rather than only obeyed.
public struct SpeakerProvenance: Codable, Sendable, Equatable {
    public var source: SpeakerAssignmentOrigin
    public var identityID: IdentityID?
    public var score: Double?
    public var runnerUpScore: Double?
    public var margin: Double?
    public var speechSeconds: Double?
    public var band: SpeakerConfidenceBand?
    public var embeddingModel: String?
    public var wasExpectedParticipant: Bool?
    public var humanVerified: Bool

    public init(
        source: SpeakerAssignmentOrigin,
        identityID: IdentityID? = nil,
        score: Double? = nil,
        runnerUpScore: Double? = nil,
        margin: Double? = nil,
        speechSeconds: Double? = nil,
        band: SpeakerConfidenceBand? = nil,
        embeddingModel: String? = nil,
        wasExpectedParticipant: Bool? = nil,
        humanVerified: Bool = false
    ) {
        self.source = source
        self.identityID = identityID
        self.score = score
        self.runnerUpScore = runnerUpScore
        self.margin = margin
        self.speechSeconds = speechSeconds
        self.band = band
        self.embeddingModel = embeddingModel
        self.wasExpectedParticipant = wasExpectedParticipant
        self.humanVerified = humanVerified
    }

    public static func human() -> SpeakerProvenance {
        SpeakerProvenance(source: .human, humanVerified: true)
    }
}

/// A vector offered for storage in a profile, with everything needed to decide
/// whether it is allowed in.
public struct VoiceEnrollmentCandidate: Sendable, Equatable {
    public var identityID: IdentityID
    public var vector: [Float]
    public var model: EmbeddingModelIdentifier
    public var speechSeconds: Double
    public var qualityScore: Double
    public var source: VoiceEnrollmentSource
    public var meetingID: String?
    public var clusterID: String?

    public init(
        identityID: IdentityID,
        vector: [Float],
        model: EmbeddingModelIdentifier,
        speechSeconds: Double,
        qualityScore: Double,
        source: VoiceEnrollmentSource,
        meetingID: String? = nil,
        clusterID: String? = nil
    ) {
        self.identityID = identityID
        self.vector = vector
        self.model = model
        self.speechSeconds = speechSeconds
        self.qualityScore = qualityScore
        self.source = source
        self.meetingID = meetingID
        self.clusterID = clusterID
    }
}

/// Why a candidate embedding was refused. Reported rather than swallowed, so a
/// profile that is not growing has a visible reason.
public enum VoiceEnrollmentRejection: Error, Sendable, Equatable, CustomStringConvertible {
    case tooLittleSpeech(seconds: Double, required: Double)
    case wrongDimension(got: Int, expected: Int)
    case emptyVector
    case identityMissing

    public var description: String {
        switch self {
        case .tooLittleSpeech(let seconds, let required):
            "only \(Int(seconds))s of confirmed speech, \(Int(required))s needed"
        case .wrongDimension(let got, let expected):
            "embedding has \(got) dimensions, expected \(expected)"
        case .emptyVector: "empty embedding"
        case .identityMissing: "no such identity"
        }
    }
}
