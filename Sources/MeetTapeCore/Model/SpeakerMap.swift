import Foundation

/// What decided a speaker's name, and therefore what may overwrite it.
///
/// The order is the correction precedence. A stage only writes an assignment
/// whose origin ranks at or above the one already stored, so re-running
/// recognition refreshes its own result and never touches a human's.
public enum SpeakerAssignmentOrigin: String, Codable, Sendable, Comparable, CaseIterable {
    /// Suggested by a language model from the words alone.
    case ai
    /// A recurring unnamed voice matched at the strict linking bar.
    case anonymousVoice = "anonymous_voice"
    /// A named voice profile matched at High confidence.
    case voiceProfile = "voice_profile"
    /// True by construction: the microphone track is the local user.
    case deterministic
    /// Set by the user. Never overwritten by anything else.
    case human

    private var rank: Int {
        switch self {
        case .ai: 0
        case .anonymousVoice: 1
        case .voiceProfile: 2
        case .deterministic: 3
        case .human: 4
        }
    }

    public static func < (lhs: SpeakerAssignmentOrigin, rhs: SpeakerAssignmentOrigin) -> Bool {
        lhs.rank < rhs.rank
    }

    public var isHuman: Bool { self == .human }

    public var displayName: String {
        switch self {
        case .human: "You set this"
        case .deterministic: "From the microphone track"
        case .voiceProfile: "Recognized voice"
        case .anonymousVoice: "Voice heard before"
        case .ai: "Suggested"
        }
    }
}

public struct SpeakerAssignment: Codable, Sendable, Equatable {
    public var displayName: String
    public var origin: SpeakerAssignmentOrigin
    public var confidence: Double?
    public var evidence: String?
    public var participantID: String?
    /// The persistent identity this name belongs to, when there is one. The
    /// name beside it is a cache: it keeps the folder readable on its own, and
    /// the store is what renaming updates.
    public var identityID: IdentityID?
    /// Why an automatic decision was made, kept so it can be explained.
    public var provenance: SpeakerProvenance?

    public init(
        displayName: String, origin: SpeakerAssignmentOrigin,
        confidence: Double? = nil, evidence: String? = nil, participantID: String? = nil,
        identityID: IdentityID? = nil, provenance: SpeakerProvenance? = nil
    ) {
        self.displayName = displayName
        self.origin = origin
        self.confidence = confidence
        self.evidence = evidence
        self.participantID = participantID
        self.identityID = identityID
        self.provenance = provenance
    }
}

/// A correction applied to one transcript line rather than to a whole cluster.
///
/// Anchored to a moment on the timeline instead of to an utterance identifier,
/// because re-assembling the transcript or re-analysing speakers moves where
/// turns begin and end. The moment the user corrected stays inside whichever
/// line covers it.
public struct UtteranceOverride: Codable, Sendable, Equatable {
    public var track: CaptureTrack
    public var anchorSeconds: Double
    public var assignment: SpeakerAssignment
    public var createdAt: Date
    /// The identifier of the line as it stood when the correction was made.
    /// Diagnostic only; matching goes through `anchorSeconds`.
    public var utteranceID: String?

    public init(
        track: CaptureTrack, anchorSeconds: Double, assignment: SpeakerAssignment,
        createdAt: Date, utteranceID: String? = nil
    ) {
        self.track = track
        self.anchorSeconds = anchorSeconds
        self.assignment = assignment
        self.createdAt = createdAt
        self.utteranceID = utteranceID
    }
}

/// `speakers.map.json`: the mutable layers above immutable diarization.
///
/// Two of them. `entries` maps a raw cluster to a name, which is what renaming a
/// whole speaker writes. `utteranceOverrides` corrects single lines, which is
/// what fixing one misattributed sentence writes. Neither touches the raw
/// diarization or the words, so every correction is a small write and nothing is
/// ever re-transcribed.
public struct SpeakerMap: Codable, Sendable, Equatable {
    public static let currentVersion = 2

    public var version: Int
    public var entries: [String: SpeakerAssignment]
    public var utteranceOverrides: [UtteranceOverride]

    public init(
        version: Int = SpeakerMap.currentVersion,
        entries: [String: SpeakerAssignment] = [:],
        utteranceOverrides: [UtteranceOverride] = []
    ) {
        self.version = version
        self.entries = entries
        self.utteranceOverrides = utteranceOverrides
    }

    /// A map written before line-level corrections existed decodes with none of
    /// them, rather than failing and losing every cluster name it does hold.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        entries = try container.decodeIfPresent([String: SpeakerAssignment].self, forKey: .entries) ?? [:]
        utteranceOverrides =
            try container.decodeIfPresent([UtteranceOverride].self, forKey: .utteranceOverrides) ?? []
    }

    public static func withLocalUser(named name: String) -> SpeakerMap {
        SpeakerMap(entries: [
            SpeakerLabel.localUser: SpeakerAssignment(displayName: name, origin: .deterministic),
        ])
    }

    public func displayName(for key: String) -> String? {
        entries[key]?.displayName
    }

    /// Applies an automatic result. Anything a person set, and anything a
    /// higher-ranked stage set, is left alone.
    public mutating func applySuggestion(_ assignment: SpeakerAssignment, for key: String) {
        guard assignment.origin != .human else {
            assign(assignment, to: key)
            return
        }
        if let existing = entries[key], existing.origin > assignment.origin { return }
        entries[key] = assignment
    }

    /// Applies a human correction to a whole cluster, which always wins.
    public mutating func assign(
        _ name: String, to key: String, participantID: String? = nil, identityID: IdentityID? = nil
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            entries.removeValue(forKey: key)
            return
        }
        entries[key] = SpeakerAssignment(
            displayName: trimmed, origin: .human, participantID: participantID,
            identityID: identityID, provenance: .human()
        )
    }

    public mutating func assign(_ assignment: SpeakerAssignment, to key: String) {
        entries[key] = assignment
    }

    /// Records a correction for one line.
    ///
    /// Replaces any earlier correction covering the same moment, so correcting
    /// the same line twice leaves one override rather than a growing pile.
    public mutating func overrideUtterance(
        _ utterance: Utterance, with assignment: SpeakerAssignment, at date: Date
    ) {
        let anchor = (utterance.start + utterance.end) / 2
        utteranceOverrides.removeAll {
            $0.track == utterance.track && $0.anchorSeconds >= utterance.start
                && $0.anchorSeconds < max(utterance.end, utterance.start + 0.001)
        }
        utteranceOverrides.append(UtteranceOverride(
            track: utterance.track, anchorSeconds: anchor, assignment: assignment,
            createdAt: date, utteranceID: utterance.id
        ))
    }

    public mutating func clearOverride(for utterance: Utterance) {
        utteranceOverrides.removeAll {
            $0.track == utterance.track && $0.anchorSeconds >= utterance.start
                && $0.anchorSeconds < max(utterance.end, utterance.start + 0.001)
        }
    }

    /// The correction covering one line, if any. The most recent wins when a
    /// re-assembly has merged two corrected lines into one.
    public func override(for utterance: Utterance) -> UtteranceOverride? {
        utteranceOverrides
            .filter {
                $0.track == utterance.track && $0.anchorSeconds >= utterance.start
                    && $0.anchorSeconds < max(utterance.end, utterance.start + 0.001)
            }
            .max { $0.createdAt < $1.createdAt }
    }

    /// The assignment that decides how one line reads.
    ///
    /// A line-level correction beats the cluster's name, and the cluster's name
    /// beats the fallback. Everything below that was already settled when the
    /// cluster entry was written.
    public func assignment(for utterance: Utterance) -> SpeakerAssignment? {
        override(for: utterance)?.assignment ?? entries[utterance.speakerKey]
    }

    public func resolvedName(for utterance: Utterance) -> String {
        assignment(for: utterance)?.displayName
            ?? Self.fallbackName(for: utterance.speakerKey)
    }

    /// Every identity referenced by this map, cluster level and line level.
    public var referencedIdentities: Set<IdentityID> {
        var out = Set<IdentityID>()
        for entry in entries.values { if let id = entry.identityID { out.insert(id) } }
        for override in utteranceOverrides {
            if let id = override.assignment.identityID { out.insert(id) }
        }
        return out
    }

    /// Rewrites the cached name for one identity after it was renamed, promoted
    /// or merged. Returns whether anything changed.
    @discardableResult
    public mutating func refreshName(
        of identity: IdentityID, to name: String, replacingWith replacement: IdentityID? = nil
    ) -> Bool {
        var changed = false
        for (key, entry) in entries where entry.identityID == identity {
            var updated = entry
            updated.displayName = name
            if let replacement { updated.identityID = replacement }
            entries[key] = updated
            changed = true
        }
        for index in utteranceOverrides.indices
        where utteranceOverrides[index].assignment.identityID == identity {
            utteranceOverrides[index].assignment.displayName = name
            if let replacement { utteranceOverrides[index].assignment.identityID = replacement }
            changed = true
        }
        return changed
    }

    /// A readable fallback for a label nobody has named yet.
    ///
    /// The chunk is part of the name because a cloud model's labels are stable
    /// only within one request. Two chunks both reporting `speaker_00` are two
    /// different clusters until speaker resolution or a person says otherwise,
    /// so they must not read as one person.
    public static func fallbackName(for key: String) -> String {
        if key == SpeakerLabel.localUser { return "Me" }
        guard let range = key.range(of: "_speaker_") else { return key }
        let suffix = String(key[range.upperBound...])
        let number = Int(suffix).map { "\($0 + 1)" } ?? suffix.uppercased()
        // The first chunk carries no suffix, which keeps the common case of a
        // meeting short enough for one request reading as "Speaker 1".
        guard let chunk = chunkIndex(in: key), chunk > 1 else { return "Speaker \(number)" }
        return "Speaker \(number) (part \(chunk))"
    }

    /// The chunk number embedded in a namespaced label, if it has one.
    private static func chunkIndex(in key: String) -> Int? {
        guard let range = key.range(of: "_chunk_") else { return nil }
        let rest = key[range.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        return Int(digits)
    }

    public func resolvedName(for key: String) -> String {
        displayName(for: key) ?? Self.fallbackName(for: key)
    }
}
