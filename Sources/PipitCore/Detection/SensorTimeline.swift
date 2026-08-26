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
    /// Everyone seen unmuted at least once. Someone muted for the whole call is
    /// in the room and not in the transcript.
    public var unmutedIDs: [String]

    public init(
        version: Int = RawSensors.currentVersion,
        source: String,
        participants: [SensorParticipant] = [],
        turns: [SensorTurn] = [],
        unmutedIDs: [String] = []
    ) {
        self.version = version
        self.source = source
        self.participants = participants
        self.turns = turns
        self.unmutedIDs = unmutedIDs
    }

    public func participant(_ id: String) -> SensorParticipant? {
        participants.first { $0.id == id }
    }

    /// Whether the local user could only be found by matching a display name.
    ///
    /// Paired with `markingSelf`, which declines to mark anyone once the
    /// platform has named the local user. The two answer the same question and
    /// have to agree: this one reports the guess, that one makes it.
    ///
    /// The platform's own flag is trustworthy: Slack marks the tile `self_`, and
    /// Meet marks its own tile. A name match is a guess, and two people called
    /// Andrew in one call is not a rare event. So a name match is allowed to
    /// suppress a name, which is safe, and never to drive the speaker count,
    /// which is not: dropping a real speaker from the count re-clusters the
    /// recording one short and merges two voices into one, and a merge cannot be
    /// undone by renaming.
    public func selfIsOnlyAGuess(localUserName: String) -> Bool {
        let wanted = localUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, !participants.contains(where: \.isSelf) else { return false }
        return participants.contains { person in
            guard let name = person.displayName else { return false }
            return name.caseInsensitiveCompare(wanted) == .orderedSame
        }
    }

    /// The same record with the local user marked by name as well as by flag.
    ///
    /// The page's own answer is not enough. Meet marks the local tile with an
    /// English word, so a client in any other language reports nobody as self,
    /// and Zoom marks nobody at all. The app does know who its user is.
    public func markingSelf(named localUserName: String) -> RawSensors {
        // A fallback, not a supplement. Where the platform already named the
        // local user, somebody else carrying the same display name is a
        // different person, and marking them too was the whole bug: they left
        // the speaker count, the recording re-clustered one voice short, and two
        // people were merged into one.
        guard !participants.contains(where: \.isSelf) else { return self }
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
    private let source: String
    private var order: [String] = []
    private var known: [String: SensorParticipant] = [:]
    private var unmuted: Set<String> = []
    private var turns: [SensorTurn] = []
    private var openID: String?
    private var openStart: Double = 0
    private var lastAt: Double = 0

    public init(source: String) { self.source = source }

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

        // The floor can only be held by someone the same reading listed. A page
        // that reports an identifier it did not put in its roster would
        // otherwise create a participant nothing can name, which still counts
        // towards the speaker count and still re-clusters the audio.
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
    public mutating func finish(at moment: Double) -> RawSensors {
        closeTurn(at: max(moment, lastAt))
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
        speakingID: String? = nil, unmutedIDs: Set<String> = []
    ) {
        self.source = source
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
    private let anchorMonotonic: Double
    private var lastMonotonic: Double

    public init(anchorMonotonic: Double) {
        self.anchorMonotonic = anchorMonotonic
        self.lastMonotonic = anchorMonotonic
    }

    public mutating func record(_ reading: SensorReading) {
        // One recording, one reader. The runtime already drops readings from
        // another provider, so this is the backstop rather than the gate: it
        // holds even if a future reader emits two source names for one provider,
        // and it keeps the file's `source` field true to its contents.
        if let source, source != reading.source { return }
        source = reading.source
        lastMonotonic = max(lastMonotonic, reading.at)
        var current = builder ?? SensorTimelineBuilder(source: reading.source)
        current.record(reading.observation(relativeTo: anchorMonotonic))
        builder = current
    }

    /// The record to write, on the recording's own timeline.
    ///
    /// Without an origin the turns are dropped rather than written at an unknown
    /// offset. A timeline nobody can place is worse than no timeline: it still
    /// overlaps clusters, so it would name people confidently and wrongly.
    public mutating func finish(
        at monotonic: Double, timelineOriginHostTime: Double?
    ) -> RawSensors? {
        guard var builder else { return nil }
        let raw = builder.finish(at: max(monotonic, lastMonotonic) - anchorMonotonic)
        self.builder = nil
        guard let origin = timelineOriginHostTime else { return nil }
        return raw.shifted(by: anchorMonotonic - origin)
    }
}
