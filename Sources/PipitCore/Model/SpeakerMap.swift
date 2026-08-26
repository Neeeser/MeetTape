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
    /// The meeting client's own account of who held the floor. Stronger than a
    /// voice match, because it reads the roster rather than inferring it, and
    /// weaker than the microphone track, which is true by construction.
    case sensor
    /// True by construction: the microphone track is the local user.
    case deterministic
    /// Set by the user. Never overwritten by anything else.
    case human

    private var rank: Int {
        switch self {
        case .ai: 0
        case .anonymousVoice: 1
        case .voiceProfile: 2
        case .sensor: 3
        case .deterministic: 4
        case .human: 5
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
        case .sensor: "From the meeting"
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
    /// The middle of the corrected line, kept so a file written before spans
    /// existed still resolves.
    public var anchorSeconds: Double
    /// The span the correction covers. Matching is by intersection, so a line
    /// that is later split keeps the correction on both halves and a line that
    /// is merged with its neighbour keeps it too. Anchoring to the midpoint
    /// alone dropped the correction from whichever half missed the instant.
    public var startSeconds: Double?
    public var endSeconds: Double?
    public var assignment: SpeakerAssignment
    public var createdAt: Date
    /// The identifier of the line as it stood when the correction was made.
    /// Diagnostic only; matching goes through the span.
    public var utteranceID: String?
    /// The chunk the corrected line came from.
    ///
    /// Time alone cannot tell a split half of the corrected line from a
    /// different line that overlaps it: both sit inside the span. A split half
    /// keeps its chunk, and an overlapping near-duplicate comes from the
    /// neighbouring chunk, which is what separates them. Absent on a file
    /// written before this, where it matches anything.
    public var chunkID: String?

    public init(
        track: CaptureTrack, anchorSeconds: Double,
        startSeconds: Double? = nil, endSeconds: Double? = nil,
        assignment: SpeakerAssignment, createdAt: Date, utteranceID: String? = nil,
        chunkID: String? = nil
    ) {
        self.track = track
        self.anchorSeconds = anchorSeconds
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.assignment = assignment
        self.createdAt = createdAt
        self.utteranceID = utteranceID
        self.chunkID = chunkID
    }

    /// Whether this correction is about a line.
    ///
    /// Most of the line has to be inside the corrected span, not any part of
    /// it. Chunks overlap by eight seconds and near-duplicate text is only
    /// dropped above a similarity bar, so two utterances on one track routinely
    /// share a moment; a plain intersection made correcting one line rename the
    /// other, and correcting that one delete the first correction outright.
    ///
    /// Majority rather than containment, because re-assembly splits and merges
    /// turns: each piece of a split line is wholly inside the original span, and
    /// a merged line is mostly inside it.
    func covers(_ utterance: Utterance) -> Bool {
        guard track == utterance.track else { return false }
        if let chunkID, chunkID != utterance.chunkID { return false }
        let end = max(utterance.end, utterance.start + 0.001)
        guard let start = startSeconds, let finish = endSeconds else {
            return anchorSeconds >= utterance.start && anchorSeconds < end
        }
        let spanEnd = max(finish, start + 0.001)
        let overlap = min(end, spanEnd) - max(utterance.start, start)
        guard overlap > 0 else { return false }
        // Measured against whichever of the two is shorter, so the rule holds in
        // both directions that re-assembly moves a turn. A line split in half is
        // wholly inside the span; a line merged with a long neighbour wholly
        // contains it, and dividing by the new line's length dropped the
        // correction exactly when re-analysing at a lower speaker count merged
        // the corrected interjection into the monologue around it.
        return overlap / min(end - utterance.start, spanEnd - start) >= 0.5
    }
}

/// A line boundary a person put there.
///
/// The diarizer prefers splitting a speaker over merging two, but it does run
/// two people together, and then one line holds a question and its answer. A
/// cut says a boundary belongs at this moment on this track, and the transcript
/// is divided there when it is read.
///
/// A statement about the audio rather than about a clustering, so it outlives a
/// re-analysis the way a line correction does, and anchored to a time rather
/// than to a line identifier because re-assembly moves where turns begin and
/// end. Who the pieces belong to is a separate record: clearing a name leaves
/// the words divided, which is still true.
public struct LineCut: Codable, Sendable, Equatable {
    public var track: CaptureTrack
    /// Where the boundary goes, in seconds on this recording's timeline.
    public var atSeconds: Double
    /// The chunk the divided line came from. Chunks overlap, so time alone
    /// cannot tell one line from a near-duplicate of it in the neighbouring
    /// chunk. Absent on a cut that should apply to whichever line covers the
    /// moment.
    public var chunkID: String?
    public var createdAt: Date

    public init(
        track: CaptureTrack, atSeconds: Double, chunkID: String? = nil, createdAt: Date
    ) {
        self.track = track
        self.atSeconds = atSeconds
        self.chunkID = chunkID
        self.createdAt = createdAt
    }

    /// Whether this cut falls strictly inside a line, which is the only place
    /// it divides anything. A cut on a boundary is already satisfied.
    public func divides(_ utterance: Utterance) -> Bool {
        guard track == utterance.track else { return false }
        if let chunkID, chunkID != utterance.chunkID { return false }
        return atSeconds > utterance.start && atSeconds < utterance.end
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
    /// Where a person said one line is really two.
    public var lineCuts: [LineCut]

    public init(
        version: Int = SpeakerMap.currentVersion,
        entries: [String: SpeakerAssignment] = [:],
        utteranceOverrides: [UtteranceOverride] = [],
        lineCuts: [LineCut] = []
    ) {
        self.version = version
        self.entries = entries
        self.utteranceOverrides = utteranceOverrides
        self.lineCuts = lineCuts
    }

    /// A map written before line-level corrections existed decodes with none of
    /// them, rather than failing and losing every cluster name it does hold.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        entries = try container.decodeIfPresent([String: SpeakerAssignment].self, forKey: .entries) ?? [:]
        utteranceOverrides =
            try container.decodeIfPresent([UtteranceOverride].self, forKey: .utteranceOverrides) ?? []
        lineCuts = try container.decodeIfPresent([LineCut].self, forKey: .lineCuts) ?? []
    }

    /// Records a boundary, ignoring one that falls where a boundary already is.
    public mutating func cut(_ cut: LineCut) {
        guard !lineCuts.contains(where: {
            $0.track == cut.track && $0.chunkID == cut.chunkID
                && abs($0.atSeconds - cut.atSeconds) < 0.001
        }) else { return }
        lineCuts.append(cut)
    }

    /// The cuts that divide one line, earliest first.
    public func cuts(dividing utterance: Utterance) -> [LineCut] {
        lineCuts.filter { $0.divides(utterance) }.sorted { $0.atSeconds < $1.atSeconds }
    }

    public static func withLocalUser(named name: String) -> SpeakerMap {
        SpeakerMap(entries: [
            SpeakerLabel.localUser: SpeakerAssignment(displayName: name, origin: .deterministic),
        ])
    }

    /// An empty stored name is no name. `assign` removes an entry rather than
    /// storing a blank one, so this only guards a file written by hand or by an
    /// older build, where a blank would otherwise render as a nameless speaker.
    public func displayName(for key: String) -> String? {
        guard let name = entries[key]?.displayName, !name.isEmpty else { return nil }
        return name
    }

    /// Applies an automatic result. Anything a person set, and anything a
    /// higher-ranked stage set, is left alone.
    public mutating func applySuggestion(_ assignment: SpeakerAssignment, for key: String) {
        guard assignment.origin != .human else {
            assign(assignment, to: key)
            return
        }
        if let existing = entries[key], existing.origin > assignment.origin { return }
        var incoming = assignment
        // An identity is not part of the suggestion being replaced. Re-running a
        // stage over a cluster it already named would otherwise drop the link a
        // later stage attached, leaving a name with no person behind it: no face
        // in the list, no profile to learn from, nothing for the next meeting to
        // recognise.
        if incoming.identityID == nil, let existing = entries[key] {
            incoming.identityID = existing.identityID
        }
        entries[key] = incoming
    }

    /// Attaches a voice identity to a cluster whose name already agrees with it.
    ///
    /// Naming and identity are two different facts, and only naming has a
    /// precedence order. A cluster the meeting client named outranks a voice
    /// match, so the match's assignment is rejected, and with it went the only
    /// thing carrying `identityID`. The cluster then showed a name with no
    /// person behind it: no face in the meetings list, no profile to learn from,
    /// and nothing for a later meeting to recognise.
    ///
    /// Agreement is required because a link is not inert. `refreshName` rewrites
    /// the name of every entry carrying an identity, with no regard for what set
    /// it, so linking a voice called Grace to a cluster the roster called Ada
    /// does not merely add an avatar: the next time anyone touches Grace, Ada's
    /// words are relabelled Grace. Where the two disagree, one of them is wrong
    /// and the disagreement is the useful fact. It stays visible.
    ///
    /// An unnamed identity carries no name to impose today, and linking is what
    /// lets a recurring voice accumulate until someone names it once. It is not
    /// free forever: naming that voice later rewrites this entry too, because
    /// `refreshName` follows the identity and does not ask what set the name. A
    /// roster name can therefore be replaced by a name a person chose in another
    /// meeting, which is recoverable by renaming and is the price of the link.
    public mutating func linkIdentity(
        _ identityID: IdentityID, to key: String, named identityName: String?
    ) {
        guard var existing = entries[key], existing.identityID == nil else { return }
        if let identityName, !identityName.isEmpty,
           existing.displayName.caseInsensitiveCompare(identityName) != .orderedSame {
            return
        }
        existing.identityID = identityID
        entries[key] = existing
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
        utteranceOverrides.removeAll { $0.covers(utterance) }
        utteranceOverrides.append(UtteranceOverride(
            track: utterance.track,
            anchorSeconds: (utterance.start + utterance.end) / 2,
            startSeconds: utterance.start,
            endSeconds: max(utterance.end, utterance.start + 0.001),
            assignment: assignment,
            createdAt: date,
            utteranceID: utterance.id,
            chunkID: utterance.chunkID
        ))
    }

    public mutating func clearOverride(for utterance: Utterance) {
        utteranceOverrides.removeAll { $0.covers(utterance) }
    }

    /// The correction covering one line, if any. The most recent wins when a
    /// re-assembly has merged two corrected lines into one.
    public func override(for utterance: Utterance) -> UtteranceOverride? {
        utteranceOverrides
            .filter { $0.covers(utterance) }
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

    /// Whether any line-level correction applies to this line.
    public func hasOverride(for utterance: Utterance) -> Bool {
        utteranceOverrides.contains { $0.covers(utterance) }
    }

    /// Whether a person's correction covers enough of a line to stand as
    /// confirmation that they spoke it.
    ///
    /// Stricter than `covers`, which decides what to display. A correction made
    /// on a three-second interjection keeps its name after re-analysis merges
    /// that interjection into a thirty-second turn, which is what `covers` is
    /// for. Treating the whole merged turn as confirmed speech is a different
    /// claim: enrolment would embed twenty-seven seconds of whoever the rest of
    /// the turn belongs to into the corrected person's voice profile.
    public func confirms(_ utterance: Utterance) -> Bool {
        // The one that decides the name, which is the newest covering
        // correction, not the first in the array. Judging a different override
        // than the one being applied let a merged line be confirmed for the
        // person named on it using the span of somebody else's correction.
        guard let override = override(for: utterance), override.assignment.origin == .human
        else { return false }
        guard let start = override.startSeconds, let finish = override.endSeconds else {
            return true
        }
        let end = max(utterance.end, utterance.start + 0.001)
        let overlap = min(end, max(finish, start + 0.001)) - max(utterance.start, start)
        guard overlap > 0 else { return false }
        return overlap / (end - utterance.start) >= 0.5
    }

    /// A readable fallback for a label nobody has named yet.
    ///
    /// The chunk is part of the name because a cloud model's labels are stable
    /// only within one request. Two chunks both reporting `speaker_00` are two
    /// different clusters until speaker resolution or a person says otherwise,
    /// so they must not read as one person.
    public static func fallbackName(for key: String) -> String {
        if key == SpeakerLabel.localUser { return "Me" }
        if key.hasSuffix(SpeakerLabel.unattributed) { return "Unattributed" }
        // A sensor speaker the client never named. The key is an opaque
        // platform identifier and must not render as one.
        if SpeakerLabel.sensorParticipantID(from: key) != nil { return "Participant" }
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
