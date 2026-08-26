import Foundation

/// Names diarization clusters from what the meeting client reported.
///
/// The division of labour is the whole design. The diarizer decides where one
/// voice stops and the next begins, because it hears the audio. The sensor
/// decides whose voice it was, because it can read the roster. Nothing here
/// moves a boundary or invents a speaker.
///
/// Every rule below exists to make a wrong answer read as no answer. A blank
/// name asks to be filled in; a confident wrong one does not.
public enum SensorAttribution {
    public struct Match: Sendable, Equatable {
        public var clusterID: String
        public var participantID: String
        public var displayName: String?
        /// Share of the cluster's speech the winning participant held.
        public var coverage: Double

        public init(
            clusterID: String, participantID: String,
            displayName: String?, coverage: Double
        ) {
            self.clusterID = clusterID
            self.participantID = participantID
            self.displayName = displayName
            self.coverage = coverage
        }
    }

    public struct Result: Sendable, Equatable {
        public var matches: [Match]
        /// How many people actually took the floor, for the diarizer to cluster
        /// towards. Absent rather than zero when the sensor saw no turns: zero
        /// would claim nobody spoke, absent says the sensor does not know.
        public var speakerCountHint: Int?
        /// Share of all diarized speech that any turn covered. The guard against
        /// two clocks that disagree.
        public var coverage: Double

        public init(matches: [Match] = [], speakerCountHint: Int? = nil, coverage: Double = 0) {
            self.matches = matches
            self.speakerCountHint = speakerCountHint
            self.coverage = coverage
        }
    }

    /// A cluster is named only when one person held most of it.
    public static let minimumClusterCoverage: Double = 0.5
    /// And held it by this much more than the runner-up. Two people splitting a
    /// cluster evenly means the diarizer merged them, and picking the longer
    /// half would be a coin flip dressed as a decision.
    public static let minimumMargin: Double = 1.5
    /// Below this share of speech covered, the two clocks do not describe the
    /// same call and nothing is named.
    public static let minimumTimelineCoverage: Double = 0.15
    /// How long a single turn has to run before its owner counts as a speaker.
    ///
    /// Slack's flag releases about 1.5 s after the voice stops, so a cough, a
    /// "mhm" or a one-word "yeah" all produce a turn. Counting those would tell
    /// the diarizer to find a cluster for everyone who ever made a noise, and
    /// re-clustering a two-voice track into five splits the two real speakers
    /// apart.
    ///
    /// The longest turn, not the sum. Four "mhm"s across an hour add up past any
    /// threshold while still describing somebody who never held the floor.
    public static let minimumSpeakerSeconds: Double = 6

    public static func attribute(
        intervals: [DiarizationInterval], sensors: RawSensors
    ) -> Result {
        // The local user is not in the far-end mixdown, so they are not one of
        // the voices to be found there. Their turns stay in the overlap below,
        // where they can still stop somebody else's name landing on the local
        // user's speech, but they never become a name and never a count.
        let selfIDs = Set(sensors.participants.filter(\.isSelf).map(\.id))
        var longestTurn: [String: Double] = [:]
        for turn in sensors.turns where !selfIDs.contains(turn.participantID) {
            longestTurn[turn.participantID] = max(
                longestTurn[turn.participantID] ?? 0, turn.duration
            )
        }
        // Somebody muted for the entire call is in the room and not on the
        // track, whatever their tile did. Where the reader reported mute state
        // at all, it decides this; where it reported none, every turn stands.
        let everUnmuted = Set(sensors.unmutedIDs)
        let speakers = longestTurn
            .filter { $0.value >= minimumSpeakerSeconds }
            .filter { everUnmuted.isEmpty || everUnmuted.contains($0.key) }
            .count
        // Absent rather than zero: the sensor saw turns and none of them was a
        // real turn, which is not the same as knowing nobody spoke.
        let countHint = speakers > 0 ? speakers : nil

        guard !intervals.isEmpty, !sensors.turns.isEmpty else {
            return Result(speakerCountHint: countHint, coverage: 0)
        }

        var perCluster: [String: [String: Double]] = [:]
        var clusterSeconds: [String: Double] = [:]
        var totalSpeech: Double = 0
        var totalCovered: Double = 0

        for interval in intervals {
            let length = interval.duration
            guard length > 0 else { continue }
            totalSpeech += length
            clusterSeconds[interval.clusterID, default: 0] += length
            for turn in sensors.turns {
                let overlap = min(interval.end, turn.end) - max(interval.start, turn.start)
                guard overlap > 0 else { continue }
                perCluster[interval.clusterID, default: [:]][turn.participantID, default: 0] += overlap
                totalCovered += overlap
            }
        }

        let coverage = totalSpeech > 0 ? min(1, totalCovered / totalSpeech) : 0
        guard coverage >= minimumTimelineCoverage else {
            return Result(speakerCountHint: countHint, coverage: coverage)
        }

        var matches: [Match] = []
        for (clusterID, byParticipant) in perCluster {
            let seconds = clusterSeconds[clusterID] ?? 0
            guard seconds > 0 else { continue }
            let ranked = byParticipant.sorted { lhs, rhs in
                // Ties broken by identifier so the result does not depend on
                // dictionary order.
                lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
            }
            guard let winner = ranked.first else { continue }
            let runnerUp = ranked.dropFirst().first?.value ?? 0
            guard winner.value / seconds >= minimumClusterCoverage else { continue }
            guard runnerUp == 0 || winner.value >= runnerUp * minimumMargin else { continue }
            // A cluster the local user best explains is a cluster this track
            // cannot contain, so it is left blank rather than handed to whoever
            // came second. Dropping their turns instead would have made the
            // runner-up zero and let second place win outright.
            guard !selfIDs.contains(winner.key) else { continue }
            matches.append(Match(
                clusterID: clusterID,
                participantID: winner.key,
                displayName: sensors.participant(winner.key)?.displayName,
                coverage: min(1, winner.value / seconds)
            ))
        }
        matches.sort { $0.clusterID < $1.clusterID }
        return Result(matches: matches, speakerCountHint: countHint, coverage: coverage)
    }
}

extension SensorAttribution {
    /// The speaker-map entries a sensor record justifies, keyed the way the map
    /// keys them.
    ///
    /// Pure on purpose. The decision of who gets named is the part worth testing,
    /// and keeping it out of the pipeline means it can be tested without audio,
    /// models or a meeting folder. The pipeline's remaining job is to apply
    /// these, which `SpeakerMap.applySuggestion` already governs.
    ///
    /// The local user is marked, not removed. The far-end track is a mixdown of
    /// everyone else, so a turn saying the local user held the floor cannot
    /// explain a voice heard there. Removing those turns looked equivalent and
    /// was not: it left the runner-up at zero, so the margin rule stopped
    /// guarding and second place won the cluster outright.
    public static func assignments(
        diarization: RawDiarization, sensors: RawSensors, localUserName: String = ""
    ) -> [(key: String, assignment: SpeakerAssignment)] {
        let scoped = sensors.markingSelf(named: localUserName)
        guard !scoped.turns.isEmpty else { return [] }

        var out: [(key: String, assignment: SpeakerAssignment)] = []
        for run in diarization.activeRuns {
            let result = attribute(intervals: run.intervals, sensors: scoped)
            for match in result.matches {
                let name = (match.displayName ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // No name means the client never rendered one. The cluster stays
                // blank rather than taking an opaque platform identifier as a
                // display name.
                guard !name.isEmpty else { continue }
                let seconds = run.intervals
                    .filter { $0.clusterID == match.clusterID }
                    .reduce(0) { $0 + $1.duration }
                out.append((
                    key: SpeakerLabel.namespaced(chunkID: run.id, rawLabel: match.clusterID),
                    assignment: SpeakerAssignment(
                        displayName: name,
                        origin: .sensor,
                        confidence: match.coverage,
                        participantID: match.participantID,
                        provenance: SpeakerProvenance(
                            source: .sensor, score: match.coverage, speechSeconds: seconds
                        )
                    )
                ))
            }
        }
        return out
    }
}
