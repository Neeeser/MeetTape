import Foundation

/// Stable identifier for one voice.
///
/// Named people and recurring unnamed voices share this one identifier space, so
/// learning someone's name later is a single row update: every occurrence,
/// cluster mapping and utterance override already points at the right id and
/// none of them has to be rewritten.
public struct IdentityID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: Int64

    public init(_ rawValue: Int64) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { String(rawValue) }
}

public enum IdentityKind: String, Codable, Sendable, CaseIterable {
    /// Someone with a name a person typed in.
    case person
    /// A voice heard more than once that nobody has named.
    case anonymous
}

/// How far an identity has travelled from "heard once" to "worth remembering".
///
/// Only anonymous identities move through this. A person a user named is
/// persistent from the moment they are created.
public enum IdentityState: String, Codable, Sendable, CaseIterable {
    /// Enough clean speech to be worth a profile, heard in one meeting only.
    /// Not offered as a match candidate yet, and expires if nothing matches it.
    case ephemeral
    /// Matched in a later meeting, or confirmed by a person.
    case persistent
}

/// Identity metadata. Deliberately not a contacts system: this exists to attach
/// a name to a voice, and organization is context for the reader rather than
/// anything the matcher uses.
public struct Identity: Codable, Sendable, Equatable, Identifiable {
    public var id: IdentityID
    public var kind: IdentityKind
    /// nil while the identity is anonymous.
    public var displayName: String?
    /// The number in "Anonymous #17". Assigned once and kept after promotion so
    /// an old transcript that still shows the number can be traced.
    public var anonymousNumber: Int?
    public var aliases: [String]
    public var organization: String?
    /// True for the one identity that represents the person using this Mac.
    public var isLocalUser: Bool
    public var state: IdentityState
    /// Set when this identity was merged into another. Reads resolve through it
    /// rather than deleting the row, so the merge stays reversible and old
    /// references keep working.
    public var mergedInto: IdentityID?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastSeenAt: Date?

    public init(
        id: IdentityID,
        kind: IdentityKind,
        displayName: String? = nil,
        anonymousNumber: Int? = nil,
        aliases: [String] = [],
        organization: String? = nil,
        isLocalUser: Bool = false,
        state: IdentityState = .persistent,
        mergedInto: IdentityID? = nil,
        createdAt: Date,
        updatedAt: Date,
        lastSeenAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.anonymousNumber = anonymousNumber
        self.aliases = aliases
        self.organization = organization
        self.isLocalUser = isLocalUser
        self.state = state
        self.mergedInto = mergedInto
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSeenAt = lastSeenAt
    }

    /// What the user reads. An anonymous identity gets its number, never a
    /// fabricated name.
    public var resolvedName: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let anonymousNumber { return "Anonymous #\(anonymousNumber)" }
        return "Unknown speaker"
    }

    public var isNamed: Bool { kind == .person && !(displayName ?? "").isEmpty }
}

/// How much verified material a profile holds.
///
/// The threshold comes from the learning curve measured in the local-processing
/// probe: separation improves up to about the third confirmed recording and is
/// flat after the fifth, so anything below three is still learning.
public enum VoiceProfileStatus: Sendable, Equatable, Codable {
    case none
    case learning(samples: Int, recordings: Int, speechSeconds: Double)
    case ready(samples: Int, recordings: Int, speechSeconds: Double)

    public static let readyRecordingCount = 3

    public static func from(samples: Int, recordings: Int, speechSeconds: Double) -> VoiceProfileStatus {
        if samples == 0 { return .none }
        if recordings >= readyRecordingCount {
            return .ready(samples: samples, recordings: recordings, speechSeconds: speechSeconds)
        }
        return .learning(samples: samples, recordings: recordings, speechSeconds: speechSeconds)
    }

    public var sampleCount: Int {
        switch self {
        case .none: 0
        case .learning(let samples, _, _), .ready(let samples, _, _): samples
        }
    }

    public var recordingCount: Int {
        switch self {
        case .none: 0
        case .learning(_, let recordings, _), .ready(_, let recordings, _): recordings
        }
    }

    public var speechSeconds: Double {
        switch self {
        case .none: 0
        case .learning(_, _, let seconds), .ready(_, _, let seconds): seconds
        }
    }

    public var summary: String {
        switch self {
        case .none: "No voice profile"
        case .learning(_, let recordings, _):
            "Learning, \(recordings) confirmed recording\(recordings == 1 ? "" : "s")"
        case .ready(_, let recordings, _):
            "Ready, \(recordings) confirmed recordings"
        }
    }
}

/// What produced a voice embedding, and therefore whether it may be stored.
///
/// Only the first three are ever written. A recognition result, at any
/// confidence, is a read: letting an automatic match widen the profile it
/// matched against is the feedback loop that makes one wrong answer permanent.
public enum VoiceEnrollmentSource: String, Codable, Sendable, CaseIterable {
    /// The microphone track of a remote call, where the speaker is the local
    /// user by construction.
    case micTrackDeterministic = "mic_track_deterministic"
    /// A person assigned a whole diarization cluster to this identity.
    case humanConfirmedCluster = "human_confirmed_cluster"
    /// A person assigned individual transcript lines, accumulated until there
    /// was enough speech to be worth enrolling.
    case humanConfirmedUtterances = "human_confirmed_utterances"

    public var isHumanVerified: Bool { true }
}
