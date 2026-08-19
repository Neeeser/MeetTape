import Foundation

public enum SpeakerAssignmentOrigin: String, Codable, Sendable {
    /// Set by the user. Never overwritten by anything else.
    case human
    /// Suggested by the model from transcript and context evidence.
    case ai
    /// True by construction: the microphone track is the local user.
    case deterministic
}

public struct SpeakerAssignment: Codable, Sendable, Equatable {
    public var displayName: String
    public var origin: SpeakerAssignmentOrigin
    public var confidence: Double?
    public var evidence: String?
    public var participantID: String?

    public init(
        displayName: String, origin: SpeakerAssignmentOrigin,
        confidence: Double? = nil, evidence: String? = nil, participantID: String? = nil
    ) {
        self.displayName = displayName
        self.origin = origin
        self.confidence = confidence
        self.evidence = evidence
        self.participantID = participantID
    }
}

/// `speakers.map.json`: raw diarization label to display name.
///
/// Kept separate from the transcript so a correction is instant and lossless.
/// Human assignments win over model suggestions in both directions of update.
public struct SpeakerMap: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var entries: [String: SpeakerAssignment]

    public init(version: Int = SpeakerMap.currentVersion, entries: [String: SpeakerAssignment] = [:]) {
        self.version = version
        self.entries = entries
    }

    public static func withLocalUser(named name: String) -> SpeakerMap {
        SpeakerMap(entries: [
            SpeakerLabel.localUser: SpeakerAssignment(displayName: name, origin: .deterministic),
        ])
    }

    public func displayName(for key: String) -> String? {
        entries[key]?.displayName
    }

    /// Applies a model suggestion. A label the user has already named is left alone.
    public mutating func applySuggestion(_ assignment: SpeakerAssignment, for key: String) {
        if let existing = entries[key], existing.origin == .human { return }
        entries[key] = SpeakerAssignment(
            displayName: assignment.displayName,
            origin: .ai,
            confidence: assignment.confidence,
            evidence: assignment.evidence,
            participantID: assignment.participantID
        )
    }

    /// Applies a human correction, which always wins.
    public mutating func assign(_ name: String, to key: String, participantID: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            entries.removeValue(forKey: key)
            return
        }
        entries[key] = SpeakerAssignment(
            displayName: trimmed, origin: .human, participantID: participantID
        )
    }

    /// A readable fallback for a label nobody has named yet.
    ///
    /// The chunk is part of the name because the model's labels are stable only
    /// within one request. Two chunks both reporting `speaker_00` are two
    /// different clusters until speaker resolution or a person says otherwise, so
    /// they must not read as one person.
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
