import Foundation

/// Attributes speech from what the meeting client reported.
///
/// The sensor timeline is an observation, not a prediction: the client marked
/// who held the floor while the audio was recorded. So it labels words first,
/// directly, and the diarizer covers what the sensor did not see: gaps in the
/// readings, overlap, and every recording made without a readable client.
///
/// Three products, all pure so they can be tested without audio or a meeting.
///
/// - `wordIntervals` turns the timeline into intervals the transcript assembler
///   aligns words against, keyed on the platform's participant identifier.
/// - `enrollmentIntervals` picks the stretches safe to embed as one person's
///   voice, for the profile that recognises them next time.
/// - `attribute` matches diarization clusters to participants, which names the
///   fallback stretches: a cluster mostly covered by one person's turns names
///   that person's uncovered words too.
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
        /// Share of all diarized speech that any turn covered. The guard against
        /// two clocks that disagree.
        public var coverage: Double

        public init(matches: [Match] = [], coverage: Double = 0) {
            self.matches = matches
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
    /// Seconds of solo, sensor-owned speech a participant needs before their
    /// voice is embedded. Below ten seconds a genuine-score comparison is
    /// unreliable, and a profile seeded from a cough misidentifies its owner.
    public static let minimumEnrollmentSeconds: Double = 6
    /// How much of a turn's end is conceded to the diarizer when attributing
    /// words.
    ///
    /// A turn's end is where the client's indicator moved, sampled at 0.5 s and
    /// released after the voice stopped, so the words at the tail can be the
    /// next speaker's first words. Inside this margin the diarizer decides,
    /// because it hears the voice change.
    ///
    /// Measured against a reference diarization: on the Aug 31 2:14 PM huddle
    /// the client's turn boundaries trail the voice by a median of 1.2 s with a
    /// 90th percentile of 2.6 s, and 27 of 32 matched transitions run late. One
    /// second was inside that, so the tail routinely kept words the next person
    /// said.
    ///
    /// A turn shorter than this now yields nothing rather than half of itself.
    /// The half-turn cap was meant to protect the head of a quick exchange,
    /// where the sensor is the thing that is right, but a turn shorter than the
    /// release is late by more than its own length, so the half that survived
    /// was the previous speaker still talking. A one-second turn at 27.29 s kept
    /// 0.5 s and put "I'm glad we" on the wrong person in the middle of
    /// somebody else's sentence.
    ///
    /// On the words the sensor still claims, so the diarizer's own accuracy is
    /// not in the denominator, this takes attribution from 93.5% to 97.6%
    /// against the reference. The diarizer alone scores 96.6% under the same
    /// harness: the sensor used to be worse than the thing it overrides and is
    /// now better. Whole-transcript accuracy goes 93.4% to 96.3%, with the words
    /// handed to the diarizer rising from 436 to 864.
    ///
    /// Two seconds is a choice rather than a floor. Wrong words run 288, 207,
    /// 174, 167, 160 across tails of 1.0 to 3.0 while right words run 4499,
    /// 4540, 4526, 4503, 4487, so past 2.0 the net is nearly flat and 2.5 is
    /// about as defensible. This keeps the most sensor contribution at the point
    /// where it becomes trustworthy.
    ///
    /// One constant for every client, and Meet was measured rather than assumed.
    /// Its turns are much shorter, a median of 1.5 s against Slack's 2.5 to
    /// 11.5, and 60% of them are inside this concession, so the same number
    /// discards far more of them. It still helps: on the Sep 01 standup, scored
    /// the same way, 83.3% becomes 86.9%, improving monotonically to 2.5 exactly
    /// as it does on Slack. A per-source constant would buy little and would
    /// have to justify two numbers instead of one.
    public static let wordAttributionTailSeconds: Double = 2

    /// How long one turn may run before it stops being an observation.
    ///
    /// A turn says the client marked somebody as holding the floor between two
    /// readings that said so. An indicator that has not moved in five minutes is
    /// more likely stuck than accurate, and a stuck one is not a small error: a
    /// Meet recording produced two turns for a twenty-two minute call, one of
    /// them 863 seconds, and every remote word went to whoever held it while the
    /// diarizer had cleanly separated three voices underneath.
    ///
    /// The longest turn anybody genuinely held, across all eight recordings on
    /// disk with a sensor timeline, is 128 seconds, and the 95th percentiles run
    /// from 19 to 62 seconds. This sits 2.3x above the longest of those and 2.9x
    /// below the stuck one. Applying it changes nothing on any of the seven
    /// healthy recordings, in either word attribution or enrolment.
    ///
    /// A genuine monologue past this loses very little. `attribute` reads the
    /// turns whole, so the speaker's cluster is still matched and still named;
    /// what changes is that the words go to the diarizer, which on one voice
    /// returns that same cluster carrying that same name. Enrolment does lose
    /// the audio, and a person who talks for five unbroken minutes has other
    /// turns to be enrolled from.
    ///
    /// The sample is 15 to 48 minute meetings. Nothing here is validated against
    /// a two-hour all-hands with a single presenter.
    public static let maximumFloorSeconds: Double = 300

    /// Whether a turn is short enough to be a claim about who was speaking.
    static func isFloorObservation(_ turn: SensorTurn) -> Bool {
        turn.duration <= maximumFloorSeconds
    }

    static func attributableEnd(of turn: SensorTurn) -> Double {
        max(turn.start, turn.end - wordAttributionTailSeconds)
    }

    /// The sensor timeline as intervals the assembler can align words against.
    ///
    /// Keyed with `SpeakerLabel.sensor`, so speech lands on the platform's own
    /// identifier for the person rather than on a cluster that a re-analysis
    /// renumbers.
    ///
    /// The local user's turns are dropped, not because they are wrong but
    /// because the far-end track cannot contain them: it is a mixdown of
    /// everyone else. A span inside a self turn falls through to the diarizer,
    /// which hears the audio and is the right authority on speech the sensor
    /// cannot explain.
    public static func wordIntervals(sensors: RawSensors) -> [DiarizationInterval] {
        let selfIDs = Set(sensors.participants.filter(\.isSelf).map(\.id))
        return sensors.turns
            .filter { !selfIDs.contains($0.participantID) && isFloorObservation($0) }
            .compactMap { turn -> DiarizationInterval? in
                // The tail belongs to the diarizer. A turn the concession eats
                // whole vanishes with it, which is the point: it is shorter than
                // the indicator's own release, so all of it is late.
                let end = attributableEnd(of: turn)
                guard end > turn.start else { return nil }
                return DiarizationInterval(
                    start: turn.start, end: end,
                    clusterID: SpeakerLabel.sensor(participantID: turn.participantID)
                )
            }
            .sorted { $0.start < $1.start }
    }

    /// The stretches safe to embed as one participant's voice.
    ///
    /// Three facts have to agree before a second of audio reaches a profile.
    /// The turn says the client heard this person holding the floor. The
    /// matched clusters, found under `attribute`'s coverage and margin guards,
    /// say which diarized voices those turns dominate, and there can be more
    /// than one: the clusterer is tuned to split a speaker rather than merge
    /// two people. And `soloSpeech` says nobody talked over it. The
    /// intersection of all three is embedded.
    ///
    /// The cluster restriction is not decoration. A turn's end trails the
    /// voice by up to the indicator's release, so its tail can cover the next
    /// speaker's first words: solo speech of a *different* cluster inside the
    /// turn is exactly that tail, and folding it into this person's centroid
    /// puts somebody else's voice in their profile. A participant whose turns
    /// dominate no cluster enrolls nothing.
    ///
    /// Returned keyed with `SpeakerLabel.sensor`, on the meeting timeline.
    /// Participants below `minimumEnrollmentSeconds` of usable audio are left
    /// out entirely rather than enrolled from a fragment.
    public static func enrollmentIntervals(
        sensors: RawSensors, diarized: [DiarizationInterval]
    ) -> [DiarizationInterval] {
        let selfIDs = Set(sensors.participants.filter(\.isSelf).map(\.id))
        // Every cluster a participant's turns dominate, not one. The clusterer
        // is tuned to split a speaker rather than merge two people, so one
        // voice landing in two clusters is the expected case, and keeping only
        // one of them threw away most of that person's enrollable audio.
        var clustersOf: [String: Set<String>] = [:]
        for match in attribute(intervals: diarized, sensors: sensors).matches {
            clustersOf[match.participantID, default: []].insert(match.clusterID)
        }
        let solo = DiarizationInterval.soloSpeech(diarized)
        var byParticipant: [String: [DiarizationInterval]] = [:]
        for turn in sensors.turns
        where !selfIDs.contains(turn.participantID) && isFloorObservation(turn) {
            guard let clusters = clustersOf[turn.participantID] else { continue }
            for interval in solo where clusters.contains(interval.clusterID) {
                let start = max(turn.start, interval.start)
                let end = min(turn.end, interval.end)
                guard end > start else { continue }
                byParticipant[turn.participantID, default: []].append(
                    DiarizationInterval(
                        start: start, end: end,
                        clusterID: SpeakerLabel.sensor(participantID: turn.participantID)
                    )
                )
            }
        }
        var out: [DiarizationInterval] = []
        for (_, intervals) in byParticipant {
            let total = intervals.reduce(0) { $0 + $1.duration }
            guard total >= minimumEnrollmentSeconds else { continue }
            out.append(contentsOf: intervals)
        }
        return out.sorted { $0.start < $1.start }
    }

    /// The speaker-map entries behind the sensor keys word attribution writes.
    ///
    /// One entry per non-self participant whose speech survived attribution and
    /// whose name the client rendered. A participant the client never named gets
    /// no entry: the key still appears in the transcript, renders through the
    /// fallback, and waits for a person to fill it in.
    ///
    /// Keyed on the intervals rather than on the turns. Holding a turn is not
    /// the same as keeping one now that the concession can eat a short turn
    /// whole and the ceiling can refuse a long one, and an entry for a key no
    /// utterance uses is not harmless: it reaches the folder's people list and
    /// the enrichment prompt, and the control that confirms a voice offers a
    /// name with no audio behind it.
    public static func speakerEntries(
        sensors: RawSensors
    ) -> [(key: String, assignment: SpeakerAssignment)] {
        let kept = Set(wordIntervals(sensors: sensors).compactMap {
            SpeakerLabel.sensorParticipantID(from: $0.clusterID)
        })
        return kept.sorted().compactMap { id in
            let name = (sensors.participant(id)?.displayName ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return (
                key: SpeakerLabel.sensor(participantID: id),
                assignment: SpeakerAssignment(
                    displayName: name,
                    origin: .sensor,
                    participantID: id,
                    provenance: SpeakerProvenance(source: .sensor)
                )
            )
        }
    }

    /// The namespace a platform identifier is durable under, or nil where it
    /// does not outlive one meeting.
    ///
    /// Only Slack today. Its user id is workspace-unique and survives every
    /// meeting, so a handle bound once keeps naming that person. Meet's
    /// `spaces/{space}/devices/{n}` is per-conference: a stored handle never
    /// matches a later meeting, and a row that cannot match again only
    /// misleads. Zoom exposes no identifier at all, so its name-keyed ids are
    /// already the display name and a handle would add nothing to it.
    public static func handleProvider(source: String) -> String? {
        source.hasPrefix("slack") ? "slack" : nil
    }

    public static func attribute(
        intervals: [DiarizationInterval], sensors: RawSensors
    ) -> Result {
        // The local user is not in the far-end mixdown, so they are not one of
        // the voices to be found there. Their turns stay in the overlap below,
        // where they can still stop somebody else's name landing on the local
        // user's speech, but they never become a name.
        let selfIDs = Set(sensors.participants.filter(\.isSelf).map(\.id))
        // The same ceiling word attribution applies. Refusing a stuck turn
        // there and honouring it here was worse than doing neither: the words
        // moved onto cluster keys and those clusters were still named from the
        // turn that had just been refused, so a recording that read one wrong
        // name went on reading it under a different key.
        //
        // What a genuine monologue loses is its name, where that monologue is
        // the only turn its speaker held. That is the honest answer: a client
        // whose indicator did not move for five minutes did not observe who was
        // talking, and an unnamed speaker asks to be filled in.
        let turns = sensors.turns.filter(isFloorObservation)

        guard !intervals.isEmpty, !turns.isEmpty else {
            return Result(coverage: 0)
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
            for turn in turns {
                let overlap = min(interval.end, turn.end) - max(interval.start, turn.start)
                guard overlap > 0 else { continue }
                perCluster[interval.clusterID, default: [:]][turn.participantID, default: 0] += overlap
                totalCovered += overlap
            }
        }

        let coverage = totalSpeech > 0 ? min(1, totalCovered / totalSpeech) : 0
        guard coverage >= minimumTimelineCoverage else {
            return Result(coverage: coverage)
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
        return Result(matches: matches, coverage: coverage)
    }
}

extension SensorAttribution {
    /// The speaker-map entries a sensor record justifies for diarization
    /// clusters, keyed the way the map keys them.
    ///
    /// This is the fallback half of naming. Word attribution already put sensor
    /// keys on every span a turn covered; what remains keyed to a cluster is
    /// speech the sensor did not see. A cluster one person's turns dominate is
    /// still that person's voice where the readings went dark, so the name
    /// carries over to those stretches too.
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
    /// The record arrives already marked: the pipeline reads it through
    /// `sensorRecord`, which is where the microphone evidence lives. Marking it
    /// again here would need evidence this has no reason to take.
    public static func assignments(
        diarization: RawDiarization, sensors: RawSensors
    ) -> [(key: String, assignment: SpeakerAssignment)] {
        let scoped = sensors
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
