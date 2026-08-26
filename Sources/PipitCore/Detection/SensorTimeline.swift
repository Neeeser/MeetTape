import Foundation

/// One person the meeting client says is in the call.
///
/// The identifier is the platform's own, not a display name: Slack's
/// `U0BSR50GN82`, or Meet's `spaces/{space}/devices/{device}`. Two people share
/// a display name and one person changes theirs, so a name is a cache and the
/// identifier is the identity. Slack's survives across meetings; Meet's lasts
/// one conference.
public struct SensorParticipant: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// Absent until the client renders it, which can be a beat after the person
    /// appears.
    public var displayName: String?
    /// The local user. Their audio is already deterministic from the microphone
    /// track, so this exists to keep the sensor from claiming credit for it.
    public var isSelf: Bool

    public init(id: String, displayName: String? = nil, isSelf: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.isSelf = isSelf
    }
}

/// One stretch where one person held the floor, on the meeting timeline.
///
/// A turn is not an utterance. Slack marks one speaker at a time and releases
/// about 1.5 s after the voice stops, so a turn's edges are the client's opinion
/// about who was talking, drifting later than the audio. Boundaries stay with
/// the diarizer; this says whose they are.
public struct SensorTurn: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var participantID: String

    public init(start: Double, end: Double, participantID: String) {
        self.start = start
        self.end = end
        self.participantID = participantID
    }

    public var duration: Double { max(0, end - start) }
}

/// `sensors.raw.json`. What the meeting client said about the call.
///
/// Immutable once written, like the diarization and the words beside it. It is
/// evidence about a recording, so re-analysing speakers reads it again and never
/// rewrites it.
public struct RawSensors: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// Which reader produced this, for example `slack-huddle-ax` or
    /// `google_meet-dom`.
    public var source: String
    public var participants: [SensorParticipant]
    public var turns: [SensorTurn]
    /// Everyone seen unmuted at least once. Recorded as evidence of what the
    /// client said, and deliberately not consulted when deciding who spoke:
    /// holding the floor for forty seconds settles that, and a tile whose
    /// overlay never resolved would otherwise outrank it.
    public var unmutedIDs: [String]
    /// Whether the local user was named by the platform rather than inferred.
    ///
    /// Only Slack is authoritative: its tile identifier literally reads
    /// `huddle-grid-gridcell-self_U…`, which is measured and structural. Meet
    /// has no such marker. What the extension does there is test whether a
    /// tile's name is the English word "You", which is a reasonable guess and
    /// still a guess: it fails in every other language, and it fires on a person
    /// whose name happens to be You.
    ///
    /// Recorded as evidence of how the local user was identified. Where the
    /// platform said so, a namesake in the roster is a different person and the
    /// display-name fallback stands down; where it only guessed, the fallback
    /// may mark a second participant, which costs at most one unnamed cluster.
    public var selfIsAuthoritative: Bool

    public init(
        version: Int = RawSensors.currentVersion,
        source: String,
        participants: [SensorParticipant] = [],
        turns: [SensorTurn] = [],
        unmutedIDs: [String] = [],
        selfIsAuthoritative: Bool = false
    ) {
        self.version = version
        self.source = source
        self.participants = participants
        self.turns = turns
        self.unmutedIDs = unmutedIDs
        self.selfIsAuthoritative = selfIsAuthoritative
    }

    /// Decoded field by field so that a record written before a field existed
    /// still reads. The synthesised decoder throws on a missing key, and this
    /// artifact is read through `try?`, so one added field would have silently
    /// turned naming off for every meeting recorded before it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? RawSensors.currentVersion
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "unknown"
        participants = try container.decodeIfPresent(
            [SensorParticipant].self, forKey: .participants
        ) ?? []
        turns = try container.decodeIfPresent([SensorTurn].self, forKey: .turns) ?? []
        unmutedIDs = try container.decodeIfPresent([String].self, forKey: .unmutedIDs) ?? []
        // Absent means unknown, which reads as a guess rather than a fact.
        selfIsAuthoritative = try container.decodeIfPresent(
            Bool.self, forKey: .selfIsAuthoritative
        ) ?? false
    }

    public func participant(_ id: String) -> SensorParticipant? {
        participants.first { $0.id == id }
    }

    /// The same record with the local user marked by name as well as by flag.
    ///
    /// The page's own answer is not enough. Meet marks the local tile with an
    /// English word, so a client in any other language reports nobody as self,
    /// and Zoom marks nobody at all. The app does know who its user is.
    public func markingSelf(named localUserName: String) -> RawSensors {
        // A fallback, not a supplement. Where the reader authoritatively named
        // the local user, somebody else carrying the same display name is a
        // different person, and marking them too was the whole bug: they left
        // the speaker count, the recording re-clustered one voice short, and two
        // people were merged into one.
        //
        // Where the reader only guessed, a second guess costs nothing: the count
        // is already off the table, and the only effect is to leave another
        // cluster unnamed.
        guard !(selfIsAuthoritative && participants.contains(where: \.isSelf)) else { return self }
        let wanted = localUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return self }
        var marked = self
        marked.participants = participants.map { person in
            guard !person.isSelf, let name = person.displayName,
                  name.caseInsensitiveCompare(wanted) == .orderedSame
            else { return person }
            var updated = person
            updated.isSelf = true
            return updated
        }
        return marked
    }

    /// The same record moved onto a different origin.
    ///
    /// Capture is armed before a meeting is committed and keeps the pre-roll, so
    /// the recording starts earlier than the moment detection began counting.
    /// The gap is one constant for the whole call, so correcting it is a shift
    /// rather than a per-turn adjustment.
    public func shifted(by seconds: Double) -> RawSensors {
        guard seconds != 0 else { return self }
        var moved = self
        moved.turns = turns.map {
            SensorTurn(
                start: $0.start + seconds, end: $0.end + seconds, participantID: $0.participantID
            )
        }
        return moved
    }
}

/// One reading of the meeting client, already placed on the meeting timeline.
public struct SensorObservation: Sendable, Equatable {
    public var at: Double
    public var participants: [SensorParticipant]
    /// Whoever holds the floor. Slack and Zoom name at most one person, and
    /// nobody while the room is quiet.
    public var speakingID: String?
    public var unmutedIDs: Set<String>

    public init(
        at: Double, participants: [SensorParticipant],
        speakingID: String? = nil, unmutedIDs: Set<String> = []
    ) {
        self.at = at
        self.participants = participants
        self.speakingID = speakingID
        self.unmutedIDs = unmutedIDs
    }
}

/// Folds a poll of the meeting client into a turn timeline.
///
/// Pure and incremental so the recording path can hand it one reading at a time
/// and the result can be tested without a meeting.
public struct SensorTimelineBuilder: Sendable {
    /// The floor under the silence that ends a turn.
    ///
    /// A turn says somebody held the floor between two readings that said so. It
    /// is not a claim about a stretch nobody looked at. Without an upper bound an
    /// unclosed turn ran to the end of the recording, and one person's name
    /// landed on every cluster after the sensor went quiet, at full coverage and
    /// with no runner-up to trip the margin rule.
    public static let minimumGapSeconds: Double = 3
    /// The ceiling, so a long silence always ends a turn no matter how slow the
    /// reader had become. Without it a reader that degraded far enough would
    /// stop recognising a blackout as one.
    public static let maximumGapSeconds: Double = 30
    /// How many times the established cadence a silence has to exceed.
    public static let gapCadenceMultiple: Double = 6
    /// What the reader is expected to manage before it has managed anything.
    ///
    /// Detection asks twice a second. The estimate starts here rather than at
    /// the first observed interval, because deriving the first threshold from
    /// the very gap being judged makes that gap unjudgeable: a five minute
    /// silence would set a thirty minute threshold and pass.
    public static let defaultIntervalSeconds: Double = 0.5

    private let source: String
    private var order: [String] = []
    private var known: [String: SensorParticipant] = [:]
    private var unmuted: Set<String> = []
    private var turns: [SensorTurn] = []
    private var openID: String?
    private var openStart: Double = 0
    private var lastAt: Double = 0
    private var sawFirstReading = false
    /// The cadence this reader has actually been managing, not the one it was
    /// asked for. The walk crosses a process boundary and slows when Slack is
    /// busy, so the rate readings arrive at is not the rate they were requested
    /// at.
    private var typicalInterval: Double

    public init(source: String, expectedInterval: Double = defaultIntervalSeconds) {
        self.source = source
        self.typicalInterval = max(0.05, expectedInterval)
    }

    public mutating func record(_ observation: SensorObservation) {
        // An empty roster is no information, not an empty room. Slack's
        // accessibility subtree reads empty intermittently during a confirmed
        // live huddle, and treating that as everyone leaving would chop every
        // turn into fragments.
        guard !observation.participants.isEmpty else { return }
        // Detection delivers snapshots as independent tasks, which gives no
        // ordering guarantee. An earlier reading arriving late would close the
        // open turn at a moment before it began, dropping it entirely.
        guard observation.at >= lastAt else { return }

        // Nothing was watching across a long gap, so the floor is only known to
        // have been held up to the last reading that saw it.
        let interval = observation.at - lastAt
        if sawFirstReading {
            let allowed = min(
                Self.maximumGapSeconds,
                max(Self.minimumGapSeconds, typicalInterval * Self.gapCadenceMultiple)
            )
            if interval > allowed { closeTurn(at: lastAt) }
            // Every interval moves the estimate, including one that just ended a
            // turn. Learning only from intervals that fit meant a reader which
            // abruptly slowed never caught up: the estimate froze at the old
            // rate, every later reading tripped, and every turn was closed at
            // its own start and discarded for the rest of the call.
            //
            // A gap contributes only what the threshold allowed, so a blackout
            // drags the estimate a little rather than redefining the cadence
            // around itself, and the ceiling above bounds where that can end up.
            typicalInterval = (typicalInterval * 3 + min(interval, allowed)) / 4
        }
        sawFirstReading = true
        lastAt = observation.at
        for person in observation.participants {
            if var existing = known[person.id] {
                // A name can arrive after the person does, and an existing name
                // is never replaced with nothing.
                if let name = person.displayName, !name.isEmpty { existing.displayName = name }
                existing.isSelf = existing.isSelf || person.isSelf
                known[person.id] = existing
            } else {
                known[person.id] = person
                order.append(person.id)
            }
        }
        unmuted.formUnion(observation.unmutedIDs)

        // The floor can only be held by someone this call has listed at some
        // point. A page reporting an identifier it never put in a roster would
        // otherwise create a participant nothing can name, which still counts
        // towards the speaker count and still re-clusters the audio. Someone who
        // left earlier still passes, which is correct: they were here, and a
        // recording of them is still a recording of them.
        let speaking = observation.speakingID.flatMap { known[$0] != nil ? $0 : nil }
        if speaking != openID {
            closeTurn(at: observation.at)
            if let speaking {
                openID = speaking
                openStart = observation.at
            }
        }
    }

    private mutating func closeTurn(at moment: Double) {
        guard let openID else { return }
        if moment > openStart {
            turns.append(SensorTurn(start: openStart, end: moment, participantID: openID))
        }
        self.openID = nil
    }

    /// Closes whatever is open and returns the record to write.
    ///
    /// The last reading, not the end of the recording. A call can run for an
    /// hour after the sensor stops answering, and claiming the floor was held
    /// throughout would be inventing evidence rather than reporting it.
    public mutating func finish() -> RawSensors {
        closeTurn(at: lastAt)
        return RawSensors(
            source: source,
            participants: order.compactMap { known[$0] },
            turns: turns,
            unmutedIDs: order.filter { unmuted.contains($0) }
        )
    }
}

/// One reading of the meeting client, stamped with the capture clock.
///
/// Monotonic host time, not the wall clock, because that is what every audio
/// buffer is stamped with. Sharing one clock with the recording is what makes
/// the two timelines comparable without measuring an offset or worrying about
/// drift across a long call.
///
/// Detection has no idea when a recording started, so whoever owns the recording
/// rebases these onto the meeting timeline.
public struct SensorReading: Sendable, Equatable {
    /// Which reader produced it, for example `slack-huddle-ax` or
    /// `google_meet-dom`.
    public var source: String
    /// Whether this reader names the local user structurally rather than by
    /// inference. True for Slack, whose tile identifier carries `self_`.
    public var selfIsAuthoritative: Bool
    /// Which meeting provider it describes. A recording only folds in readings
    /// about the meeting it is recording.
    public var provider: MeetingProvider
    /// The provider's own identifier for the call, where the reader knows it.
    /// Two browser tabs in two different calls report the same provider, so the
    /// provider alone cannot tell one from the other.
    public var meetingID: String?
    public var at: Double
    public var participants: [SensorParticipant]
    public var speakingID: String?
    public var unmutedIDs: Set<String>

    public init(
        source: String, provider: MeetingProvider, at: Double,
        participants: [SensorParticipant], meetingID: String? = nil,
        speakingID: String? = nil, unmutedIDs: Set<String> = [],
        selfIsAuthoritative: Bool = false
    ) {
        self.source = source
        self.selfIsAuthoritative = selfIsAuthoritative
        self.provider = provider
        self.meetingID = meetingID
        self.at = at
        self.participants = participants
        self.speakingID = speakingID
        self.unmutedIDs = unmutedIDs
    }

    public func observation(relativeTo start: Double) -> SensorObservation {
        SensorObservation(
            at: at - start, participants: participants,
            speakingID: speakingID, unmutedIDs: unmutedIDs
        )
    }
}

/// Accumulates readings across one recording and rebases them onto its timeline.
///
/// One clock, deliberately. Readings and audio buffers are both stamped with
/// monotonic host time, so placing a reading on the meeting timeline is a
/// subtraction rather than a correlation, and a long call cannot drift.
///
/// The origin is the earliest frame any track recorded, which is what every
/// diarization interval is measured from. It is not the moment the meeting was
/// committed: capture is armed first and keeps the pre-roll it had already
/// buffered, so the recording can be a good fifteen seconds older than the
/// commit. Anchoring on the commit put every turn that far early, and because a
/// uniform shift leaves overlap high, no coverage guard would have caught it.
public struct SensorRecorder: Sendable {
    private var builder: SensorTimelineBuilder?
    private var source: String?
    private var selfIsAuthoritative = false
    private let anchorMonotonic: Double

    public init(anchorMonotonic: Double) {
        self.anchorMonotonic = anchorMonotonic
    }

    public mutating func record(_ reading: SensorReading) {
        // One recording, one reader. The runtime already drops readings from
        // another provider, so this is the backstop rather than the gate: it
        // holds even if a future reader emits two source names for one provider,
        // and it keeps the file's `source` field true to its contents.
        if let source, source != reading.source { return }
        source = reading.source
        selfIsAuthoritative = reading.selfIsAuthoritative
        var current = builder ?? SensorTimelineBuilder(source: reading.source)
        current.record(reading.observation(relativeTo: anchorMonotonic))
        builder = current
    }

    /// The record to write, on the recording's own timeline.
    ///
    /// Without an origin the turns are dropped rather than written at an unknown
    /// offset. A timeline nobody can place is worse than no timeline: it still
    /// overlaps clusters, so it would name people confidently and wrongly.
    public mutating func finish(timelineOriginHostTime: Double?) -> RawSensors? {
        guard var builder else { return nil }
        var raw = builder.finish()
        raw.selfIsAuthoritative = selfIsAuthoritative
        self.builder = nil
        guard let origin = timelineOriginHostTime else { return nil }
        return raw.shifted(by: anchorMonotonic - origin)
    }
}
