import Foundation
import PipitCore
import TestKit

/// What the meeting client's own account of the call is allowed to decide.
///
/// The rule behind every test here: the sensor names speakers, it never moves
/// boundaries. Slack releases its speaking flag about 1.5 s after the voice
/// stops and marks one person at a time, so a turn is a claim about who held the
/// floor, not about where an utterance began. Anything that treated a turn as an
/// utterance boundary would smear one person's words onto the next.
enum SensorAttributionTests {
    private static func participant(
        _ id: String, _ name: String? = nil, isSelf: Bool = false
    ) -> SensorParticipant {
        SensorParticipant(id: id, displayName: name, isSelf: isSelf)
    }

    private static func interval(
        _ cluster: String, _ start: Double, _ end: Double
    ) -> DiarizationInterval {
        DiarizationInterval(start: start, end: end, clusterID: cluster)
    }

    /// Evidence in which the local user is audibly speaking over `talking` and
    /// nowhere else.
    ///
    /// Outside those spans the microphone is quiet and below the far end, which
    /// is what the far end playing while the user listens looks like. Over
    /// `echoDuring` the far end plays and the cleaned microphone holds what the
    /// canceller left of it, which the detector does not call speech.
    private static func speech(
        seconds: Double, talking: [(Double, Double)],
        echoDuring: [(Double, Double)] = [], window: Double = 0.25
    ) -> SpeechEvidence {
        let count = Int(seconds / window)
        var mic = [Int8](repeating: -80, count: count)
        var remote = [Int8](repeating: -30, count: count)
        var probability = [Int8](repeating: 0, count: count)
        func windows(_ spans: [(Double, Double)]) -> [Int] {
            spans.flatMap { Array(Int($0.0 / window)..<min(count, Int($0.1 / window))) }
        }
        for index in windows(talking) {
            mic[index] = -20
            remote[index] = -40
            probability[index] = 90
        }
        for index in windows(echoDuring) {
            mic[index] = -58
            remote[index] = -22
            probability[index] = 8
        }
        return SpeechEvidence(
            levelWindowSeconds: window, speechWindowSeconds: window,
            micLevels: mic, remoteLevels: remote, micSpeech: probability
        )
    }

    private static func sensors(
        participants: [SensorParticipant], turns: [(String, Double, Double)],
        unmuted: [String]? = nil
    ) -> RawSensors {
        RawSensors(
            source: "test",
            participants: participants,
            turns: turns.map { SensorTurn(start: $0.1, end: $0.2, participantID: $0.0) },
            unmutedIDs: unmuted ?? participants.map(\.id)
        )
    }

    static var builderSuite: Suite {
        Suite("SensorTimeline", [
            test("consecutive reads of one speaker are one turn") { expect in
                var builder = SensorTimelineBuilder(source: "slack")
                let roster = [participant("U1", "Ada"), participant("U2", "Grace")]
                for tick in stride(from: 0.0, through: 2.0, by: 0.25) {
                    builder.record(SensorObservation(
                        at: tick, participants: roster, speakingID: "U1",
                        unmutedIDs: ["U1", "U2"]
                    ))
                }
                let raw = builder.finish()
                expect.equal(raw.turns.count, 1)
                let turn = try expect.unwrap(raw.turns.first)
                expect.equal(turn.participantID, "U1")
                expect.close(turn.start, 0, tolerance: 0.001)
                // The last reading that saw the floor, not the end of the call.
                expect.close(turn.end, 2, tolerance: 0.001)
            },

            test("the floor moving to someone else closes the turn") { expect in
                var builder = SensorTimelineBuilder(source: "slack")
                let roster = [participant("U1"), participant("U2")]
                for tick in stride(from: 0.0, to: 2.0, by: 0.5) {
                    builder.record(SensorObservation(at: tick, participants: roster, speakingID: "U1"))
                }
                for tick in stride(from: 2.0, through: 3.0, by: 0.5) {
                    builder.record(SensorObservation(at: tick, participants: roster, speakingID: "U2"))
                }
                let raw = builder.finish()
                expect.equal(raw.turns.count, 2)
                expect.equal(raw.turns.first?.participantID, "U1")
                expect.equal(raw.turns.last?.participantID, "U2")
                // The handover is a single instant, so no second of the call
                // belongs to two people.
                expect.close(try expect.unwrap(raw.turns.first).end,
                             try expect.unwrap(raw.turns.last).start, tolerance: 0.001)
            },

            test("nobody speaking closes the turn and leaves a gap") { expect in
                var builder = SensorTimelineBuilder(source: "slack")
                let roster = [participant("U1")]
                for tick in stride(from: 0.0, to: 1.0, by: 0.5) {
                    builder.record(SensorObservation(at: tick, participants: roster, speakingID: "U1"))
                }
                for tick in stride(from: 1.0, to: 3.0, by: 0.5) {
                    builder.record(SensorObservation(at: tick, participants: roster, speakingID: nil))
                }
                for tick in stride(from: 3.0, through: 4.0, by: 0.5) {
                    builder.record(SensorObservation(at: tick, participants: roster, speakingID: "U1"))
                }
                let raw = builder.finish()
                expect.equal(raw.turns.count, 2)
                expect.close(try expect.unwrap(raw.turns.first).end, 1, tolerance: 0.001)
                expect.close(try expect.unwrap(raw.turns.last).start, 3, tolerance: 0.001)
            },

            test("the roster is the union across the call, not the last read") { expect in
                var builder = SensorTimelineBuilder(source: "slack")
                builder.record(SensorObservation(
                    at: 0, participants: [participant("U1", "Ada")], speakingID: nil
                ))
                builder.record(SensorObservation(
                    at: 1, participants: [participant("U1", "Ada"), participant("U2", "Grace")],
                    speakingID: nil
                ))
                // Grace leaves before the end. She was still in the meeting.
                builder.record(SensorObservation(
                    at: 2, participants: [participant("U1", "Ada")], speakingID: nil
                ))
                let raw = builder.finish()
                expect.equal(raw.participants.count, 2)
                expect.isTrue(raw.participants.contains { $0.id == "U2" })
            },

            test("a name that arrives late replaces a placeholder") { expect in
                var builder = SensorTimelineBuilder(source: "meet")
                builder.record(SensorObservation(
                    at: 0, participants: [participant("d406", nil)], speakingID: nil
                ))
                builder.record(SensorObservation(
                    at: 1, participants: [participant("d406", "Priya")], speakingID: nil
                ))
                let raw = builder.finish()
                expect.equal(raw.participants.first?.displayName, "Priya")
            },

            test("a speaker nobody listed cannot hold the floor") { expect in
                // A page reporting an identifier it did not put in its own
                // roster would create a participant nothing can name, which
                // still counts towards the speaker count and still re-clusters
                // the audio.
                var builder = SensorTimelineBuilder(source: "meet")
                let roster = [participant("d406", "Ada")]
                builder.record(SensorObservation(
                    at: 0, participants: roster, speakingID: "d999"
                ))
                builder.record(SensorObservation(
                    at: 5, participants: roster, speakingID: "d999"
                ))
                let raw = builder.finish()
                expect.equal(raw.turns.count, 0)
                expect.equal(raw.participants.count, 1)
            },

            test("a reading that arrives late does not swallow the open turn") { expect in
                // Detection delivers snapshots as independent tasks, so ordering
                // is not guaranteed. Closing a turn at a moment before it began
                // dropped it outright.
                var builder = SensorTimelineBuilder(source: "slack")
                let roster = [participant("U1", "Ada")]
                for tick in stride(from: 0.0, through: 3.0, by: 0.5) {
                    builder.record(SensorObservation(at: tick, participants: roster, speakingID: "U1"))
                }
                // Out of order: an older reading arriving after a newer one.
                builder.record(SensorObservation(at: 1.5, participants: roster, speakingID: nil))
                let raw = builder.finish()
                expect.equal(raw.turns.count, 1)
                expect.close(try expect.unwrap(raw.turns.first).end, 3, tolerance: 0.001)
            },

            test("a floor nobody confirmed does not run to the end of the call") { expect in
                // The failure this prevents: the sensor goes quiet mid-call with
                // somebody holding the floor, the turn never closes, and that
                // one name lands on every cluster after it at full coverage with
                // no runner-up to trip the margin rule.
                var builder = SensorTimelineBuilder(source: "slack")
                let roster = [participant("U1", "Ada")]
                for tick in stride(from: 0.0, through: 10.0, by: 0.5) {
                    builder.record(SensorObservation(at: tick, participants: roster, speakingID: "U1"))
                }
                // Slack goes blind. Nothing arrives for the rest of the hour.
                let raw = builder.finish()
                let turn = try expect.unwrap(raw.turns.first)
                expect.close(turn.end, 10, tolerance: 0.001)
            },

            test("a gap in the readings ends the turn at the last one that saw it") { expect in
                var builder = SensorTimelineBuilder(source: "slack")
                let roster = [participant("U1", "Ada"), participant("U2", "Grace")]
                for tick in stride(from: 0.0, through: 5.0, by: 0.5) {
                    builder.record(SensorObservation(at: tick, participants: roster, speakingID: "U1"))
                }
                // Sixty seconds unwatched, then Grace has the floor.
                for tick in stride(from: 65.0, through: 70.0, by: 0.5) {
                    builder.record(SensorObservation(at: tick, participants: roster, speakingID: "U2"))
                }
                let raw = builder.finish()
                expect.equal(raw.turns.count, 2)
                expect.close(try expect.unwrap(raw.turns.first).end, 5, tolerance: 0.001)
                expect.close(try expect.unwrap(raw.turns.last).start, 65, tolerance: 0.001)
            },

            test("a slow reader still produces turns") { expect in
                // The rule that broke this was a fixed three second gap. The
                // accessibility walk crosses a process boundary and slows when
                // Slack is busy, and at a four second cadence every reading
                // tripped it: each turn closed at its own start and the
                // recording ended with a full roster, no turns, and nothing to
                // distinguish that from nobody having spoken.
                var builder = SensorTimelineBuilder(source: "slack")
                let roster = [participant("U1", "Ada")]
                for tick in stride(from: 0.0, through: 40.0, by: 4.0) {
                    builder.record(SensorObservation(at: tick, participants: roster, speakingID: "U1"))
                }
                let raw = builder.finish()
                expect.equal(raw.turns.count, 1)
                expect.close(try expect.unwrap(raw.turns.first).end, 40, tolerance: 0.001)
            },

            test("a blackout on the second reading is still a blackout") { expect in
                // The threshold used to be derived from the very interval being
                // judged, which made the first one unjudgeable: a five minute
                // silence set a thirty minute threshold and passed, so one turn
                // covered the whole silence and named every cluster in it.
                var builder = SensorTimelineBuilder(source: "slack")
                let roster = [participant("U1", "Ada")]
                builder.record(SensorObservation(at: 0, participants: roster, speakingID: "U1"))
                for tick in stride(from: 300.0, through: 305.0, by: 0.5) {
                    builder.record(SensorObservation(at: tick, participants: roster, speakingID: "U1"))
                }
                let raw = builder.finish()
                // The first reading alone never established a span, so what
                // survives is the second stretch, not one turn across the gap.
                expect.equal(raw.turns.count, 1)
                expect.close(try expect.unwrap(raw.turns.first).start, 300, tolerance: 0.001)
            },

            test("a reader that slows mid-call keeps producing turns") { expect in
                // The estimate used to learn only from intervals that fit, so a
                // reader which abruptly slowed never caught up: it froze at the
                // old rate, every later reading tripped the rule, and every turn
                // was closed at its own start and discarded for the rest of the
                // call. A huddle growing from two people to ten steps the walk
                // cost up in exactly one jump.
                var builder = SensorTimelineBuilder(source: "slack")
                let roster = [participant("U1", "Ada")]
                for tick in stride(from: 0.0, through: 10.0, by: 0.5) {
                    builder.record(SensorObservation(at: tick, participants: roster, speakingID: "U1"))
                }
                for tick in stride(from: 15.0, through: 60.0, by: 5.0) {
                    builder.record(SensorObservation(at: tick, participants: roster, speakingID: "U1"))
                }
                let raw = builder.finish()
                let covered = raw.turns.reduce(0) { $0 + $1.duration }
                // The transition itself is a real gap and costs one boundary.
                // Everything after it has to be turns again.
                expect.isTrue(
                    covered >= 50, "only \(covered)s of 60 survived the slowdown"
                )
                expect.close(try expect.unwrap(raw.turns.last).end, 60, tolerance: 0.001)
            },

            test("a degraded reader still recognises a real blackout") { expect in
                // The ceiling. Without it a reader that slowed far enough would
                // set a threshold long enough to swallow any silence.
                var builder = SensorTimelineBuilder(source: "slack")
                let roster = [participant("U1", "Ada")]
                for tick in stride(from: 0.0, through: 200.0, by: 10.0) {
                    builder.record(SensorObservation(at: tick, participants: roster, speakingID: "U1"))
                }
                builder.record(SensorObservation(at: 900, participants: roster, speakingID: "U1"))
                builder.record(SensorObservation(at: 910, participants: roster, speakingID: "U1"))
                let raw = builder.finish()
                expect.isTrue(raw.turns.count >= 2, "the blackout did not end a turn")
                expect.close(try expect.unwrap(raw.turns.first).end, 200, tolerance: 0.001)
            },

            test("a blackout ends the turn however fast the reader was") { expect in
                // The same rule the other way round. At a fast cadence a long
                // silence is unmistakable, and the turn has to end at the last
                // reading that saw the floor.
                var builder = SensorTimelineBuilder(source: "slack")
                let roster = [participant("U1", "Ada")]
                for tick in stride(from: 0.0, through: 5.0, by: 0.5) {
                    builder.record(SensorObservation(at: tick, participants: roster, speakingID: "U1"))
                }
                // Five minutes later the reader comes back and Ada is talking
                // again. That is a second turn, not a continuation of the first.
                for tick in stride(from: 300.0, through: 305.0, by: 0.5) {
                    builder.record(SensorObservation(at: tick, participants: roster, speakingID: "U1"))
                }
                let raw = builder.finish()
                expect.equal(raw.turns.count, 2)
                expect.close(try expect.unwrap(raw.turns.first).end, 5, tolerance: 0.001)
                expect.close(try expect.unwrap(raw.turns.last).start, 300, tolerance: 0.001)
            },

            test("a record written before a field existed still reads") { expect in
                // The artifact is read through `try?`, so a decoder that threw on
                // a missing key would silently turn naming off for every meeting
                // recorded before the field was added.
                let json = """
                {"version":1,"source":"slack-huddle-ax",
                 "participants":[{"id":"U1","displayName":"Ada","isSelf":false}],
                 "turns":[{"start":0,"end":10,"participantID":"U1"}],
                 "unmutedIDs":["U1"]}
                """
                let decoded = try JSONDecoder().decode(
                    RawSensors.self, from: Data(json.utf8)
                )
                expect.equal(decoded.participants.count, 1)
                expect.equal(decoded.turns.count, 1)
                // Absent means unknown, which reads as a guess rather than a fact.
                expect.isFalse(decoded.selfIsAuthoritative)
            },

            test("a read with no roster does not erase the one we have") { expect in
                // Slack's accessibility subtree comes back empty intermittently
                // during a confirmed live huddle, so an empty read means no
                // information rather than an empty room.
                var builder = SensorTimelineBuilder(source: "slack")
                builder.record(SensorObservation(
                    at: 0, participants: [participant("U1", "Ada")], speakingID: "U1"
                ))
                builder.record(SensorObservation(at: 1, participants: [], speakingID: nil))
                builder.record(SensorObservation(
                    at: 2, participants: [participant("U1", "Ada")], speakingID: "U1"
                ))
                let raw = builder.finish()
                expect.equal(raw.participants.count, 1)
            },
        ])
    }

    static var shiftSuite: Suite {
        Suite("SensorShift", [
            test("the pre-roll offset moves every turn by the same amount") { expect in
                // Capture is armed before the meeting is committed and keeps
                // what it already had, so the recording is older than the
                // sensor's own count of the call.
                let raw = RawSensors(
                    source: "slack",
                    participants: [participant("U1", "Ada")],
                    turns: [SensorTurn(start: 10, end: 20, participantID: "U1")]
                )
                let moved = raw.shifted(by: 4.5)
                expect.close(try expect.unwrap(moved.turns.first).start, 14.5, tolerance: 0.001)
                expect.close(try expect.unwrap(moved.turns.first).end, 24.5, tolerance: 0.001)
                expect.equal(moved.participants, raw.participants)
            },

            test("readings land on the audio timeline, not on the commit") { expect in
                // Capture is armed before a meeting is committed and keeps the
                // pre-roll it already buffered, so the recording starts earlier
                // than the sensor began counting. Anchoring on the commit put
                // every turn that far early, and a uniform shift keeps overlap
                // high, so no coverage guard would have caught it.
                let preRoll = 15.0
                let origin = 1_000.0            // host time of the first frame
                let commit = origin + preRoll   // host time when the meeting committed

                var recorder = SensorRecorder(anchorMonotonic: commit)
                let roster = [participant("U1", "Ada")]
                // Ada talks from 20 s to 30 s after the commit, read twice a
                // second the way detection actually reads.
                for tick in stride(from: 20.0, through: 30.0, by: 0.5) {
                    recorder.record(SensorReading(
                        source: "slack-huddle-ax", provider: .slack, at: commit + tick,
                        participants: roster, speakingID: "U1"
                    ))
                }
                let raw = try expect.unwrap(
                    recorder.finish(timelineOriginHostTime: origin)
                )
                let turn = try expect.unwrap(raw.turns.first)
                // On the audio timeline that is 35 s to 45 s, because the audio
                // began 15 s before the commit did.
                expect.close(turn.start, 35, tolerance: 0.001)
                expect.close(turn.end, 45, tolerance: 0.001)
            },

            test("no origin means no record rather than one at an unknown offset") { expect in
                // A timeline nobody can place still overlaps clusters, so it
                // would name people confidently and wrongly.
                var recorder = SensorRecorder(anchorMonotonic: 100)
                recorder.record(SensorReading(
                    source: "slack-huddle-ax", provider: .slack, at: 101,
                    participants: [participant("U1", "Ada")], speakingID: "U1"
                ))
                expect.isNil(recorder.finish(timelineOriginHostTime: nil))
            },

            test("no offset leaves the record untouched") { expect in
                let raw = RawSensors(
                    source: "slack", participants: [participant("U1")],
                    turns: [SensorTurn(start: 1, end: 2, participantID: "U1")]
                )
                expect.equal(raw.shifted(by: 0), raw)
            },
        ])
    }

    static var attributionSuite: Suite {
        Suite("SensorAttribution", [
            test("a cluster takes the name of whoever held the floor through it") { expect in
                let raw = sensors(
                    participants: [participant("U1", "Ada"), participant("U2", "Grace")],
                    turns: [("U1", 0, 10), ("U2", 10, 20)]
                )
                let result = SensorAttribution.attribute(
                    intervals: [interval("a", 1, 9), interval("b", 11, 19)], sensors: raw
                )
                expect.equal(result.matches.count, 2)
                let byCluster = Dictionary(
                    uniqueKeysWithValues: result.matches.map { ($0.clusterID, $0) }
                )
                expect.equal(byCluster["a"]?.displayName, "Ada")
                expect.equal(byCluster["b"]?.displayName, "Grace")
            },

            test("two clusters for one voice both take that name") { expect in
                // Over-splitting is the diarizer's common failure. The sensor
                // says both halves are the same person, which is the point.
                let raw = sensors(
                    participants: [participant("U1", "Ada")], turns: [("U1", 0, 20)]
                )
                let result = SensorAttribution.attribute(
                    intervals: [interval("a", 1, 9), interval("b", 11, 19)], sensors: raw
                )
                expect.equal(result.matches.count, 2)
                expect.isTrue(result.matches.allSatisfy { $0.participantID == "U1" })
            },

            test("a cluster no turn covers stays unnamed") { expect in
                let raw = sensors(
                    participants: [participant("U1", "Ada")], turns: [("U1", 0, 5)]
                )
                let result = SensorAttribution.attribute(
                    intervals: [interval("a", 1, 4), interval("b", 40, 50)], sensors: raw
                )
                expect.equal(result.matches.count, 1)
                expect.equal(result.matches.first?.clusterID, "a")
            },

            test("a tie between two people names neither") { expect in
                // Naming on a coin flip is worse than leaving it blank, because
                // a wrong name looks decided and a blank one asks to be filled.
                let raw = sensors(
                    participants: [participant("U1", "Ada"), participant("U2", "Grace")],
                    turns: [("U1", 0, 5), ("U2", 5, 10)]
                )
                let result = SensorAttribution.attribute(
                    intervals: [interval("a", 0, 10)], sensors: raw
                )
                expect.equal(result.matches.count, 0)
            },

            test("a timeline that lines up with nothing names nothing") { expect in
                // The clocks disagreeing is the failure that would mislabel a
                // whole call, so it has to read as no information.
                let raw = sensors(
                    participants: [participant("U1", "Ada")], turns: [("U1", 600, 900)]
                )
                let result = SensorAttribution.attribute(
                    intervals: [interval("a", 0, 30), interval("b", 30, 60)], sensors: raw
                )
                expect.equal(result.matches.count, 0)
                expect.isTrue(result.coverage < 0.1)
            },

            test("word intervals carry the person, not a cluster") { expect in
                let raw = sensors(
                    participants: [participant("U1", "Ada"), participant("U2", "Grace")],
                    turns: [("U1", 0, 10), ("U2", 10, 20)]
                )
                let intervals = SensorAttribution.wordIntervals(sensors: raw)
                expect.equal(intervals.count, 2)
                expect.equal(intervals.first?.clusterID, SpeakerLabel.sensor(participantID: "U1"))
                expect.equal(intervals.last?.clusterID, SpeakerLabel.sensor(participantID: "U2"))
            },

            test("the local user's turns produce no word intervals") { expect in
                // The far-end track is a mixdown of everyone else, so a self
                // turn cannot explain a word heard there. The span falls to the
                // diarizer, which hears the audio.
                let raw = sensors(
                    participants: [
                        participant("me", "Andrew", isSelf: true), participant("U2", "Ada"),
                    ],
                    turns: [("me", 0, 10), ("U2", 10, 20)]
                )
                let intervals = SensorAttribution.wordIntervals(sensors: raw)
                expect.equal(intervals.count, 1)
                expect.equal(intervals.first?.clusterID, SpeakerLabel.sensor(participantID: "U2"))
            },

            test("enrollment takes only solo speech inside a turn") { expect in
                // The intersection is audio the client attributed to one person
                // and the diarizer heard as a single voice: no release tail, no
                // silence, no overlap bleeding somebody else into the profile.
                let raw = sensors(
                    participants: [participant("U1", "Ada"), participant("U2", "Grace")],
                    turns: [("U1", 0, 30), ("U2", 30, 60)]
                )
                let enrolled = SensorAttribution.enrollmentIntervals(
                    sensors: raw,
                    diarized: [
                        // Ada's speech, with Grace overlapping the last stretch.
                        interval("a", 2, 28), interval("b", 20, 28),
                        interval("b", 32, 58),
                    ]
                )
                let ada = enrolled.filter {
                    $0.clusterID == SpeakerLabel.sensor(participantID: "U1")
                }
                // The overlapped 20-28 stretch is cut: only 2-20 remains.
                expect.equal(ada.count, 1)
                expect.close(ada.first?.start ?? -1, 2, tolerance: 0.001)
                expect.close(ada.first?.end ?? -1, 20, tolerance: 0.001)
            },

            test("the release tail cannot put the next voice in a profile") { expect in
                // Ada's turn trails 1.5 s past her voice, and Grace's first
                // words sit inside that tail as their own solo cluster. Only
                // the cluster Ada's turns dominate is embeddable as Ada, so
                // the tail slice of Grace's cluster contributes nothing.
                let raw = sensors(
                    participants: [participant("U1", "Ada"), participant("U2", "Grace")],
                    turns: [("U1", 0, 31.5), ("U2", 31.5, 60)]
                )
                let enrolled = SensorAttribution.enrollmentIntervals(
                    sensors: raw,
                    diarized: [
                        interval("a", 2, 30),
                        interval("b", 30.5, 59),
                    ]
                )
                let ada = enrolled.filter {
                    $0.clusterID == SpeakerLabel.sensor(participantID: "U1")
                }
                expect.isTrue(
                    ada.allSatisfy { $0.end <= 30 },
                    "a slice of Grace's cluster reached Ada's profile: \(ada)"
                )
            },

            test("a voice split across two clusters enrolls from both") { expect in
                // The clusterer is tuned to split a speaker rather than merge
                // two people, so one voice in two clusters is expected. Keeping
                // one of them threw away most of that person's audio.
                let raw = sensors(
                    participants: [participant("U1", "Ada")],
                    turns: [("U1", 0, 30), ("U1", 40, 70)]
                )
                let enrolled = SensorAttribution.enrollmentIntervals(
                    sensors: raw,
                    diarized: [interval("a", 1, 29), interval("b", 41, 69)]
                )
                let total = enrolled.reduce(0) { $0 + $1.duration }
                expect.isTrue(total > 50, "only one cluster was kept: \(total)s")
            },

            test("a turn shorter than the concession claims nothing") { expect in
                // The inverse of what shipped. Keeping half of a short turn was
                // meant to protect the head of a quick exchange, but the
                // indicator releases later than the concession allowed for, so
                // the half that survived was the previous speaker still talking.
                // A one-second turn at 27.29 s kept 0.5 s and put "I'm glad we"
                // on the wrong person mid-sentence.
                let raw = sensors(
                    participants: [participant("U1", "Ada")], turns: [("U1", 0, 1.2)]
                )
                expect.equal(SensorAttribution.wordIntervals(sensors: raw), [])
            },

            test("a turn keeps what the indicator's release does not reach") { expect in
                let raw = sensors(
                    participants: [participant("U1", "Ada")], turns: [("U1", 0, 10)]
                )
                let intervals = SensorAttribution.wordIntervals(sensors: raw)
                expect.equal(intervals.count, 1)
                expect.close(intervals.first?.end ?? 0, 8, tolerance: 0.001)
            },

            test("an indicator that never moved claims no words") { expect in
                // A Meet recording produced two turns for twenty-two minutes,
                // one of them 863 seconds, and every remote word went to it.
                // The client had stopped moving its indicator; the diarizer had
                // separated three voices cleanly underneath. The longest turn
                // anybody genuinely held across every recording on disk is 128
                // seconds.
                let raw = sensors(
                    participants: [participant("U1", "Ada"), participant("U2", "Grace")],
                    turns: [("U1", 0, 400), ("U2", 400, 600)]
                )
                let intervals = SensorAttribution.wordIntervals(sensors: raw)
                expect.equal(intervals.count, 1)
                expect.equal(intervals.first?.clusterID, SpeakerLabel.sensor(participantID: "U2"))
            },

            test("an indicator that never moved names no cluster") { expect in
                // Dropping the turn from word attribution alone made the
                // recording worse, not better. The words moved onto cluster
                // keys, and those clusters were still named from the very turn
                // that had just been refused, so a transcript that read one
                // wrong name went on reading it. On the recording this is
                // named after, the name in question is the local user's own,
                // on a track that by construction cannot hold them.
                let raw = sensors(
                    participants: [participant("U1", "Ada")], turns: [("U1", 0, 400)]
                )
                let result = SensorAttribution.attribute(
                    intervals: [interval("a", 0, 130), interval("b", 140, 260),
                                interval("c", 270, 390)],
                    sensors: raw
                )
                expect.equal(result.matches.count, 0)
            },

            test("a turn under the ceiling still names its cluster") { expect in
                // The other half of the rule, so the ceiling cannot pass by
                // breaking naming outright.
                let raw = sensors(
                    participants: [participant("U1", "Ada")], turns: [("U1", 0, 120)]
                )
                let result = SensorAttribution.attribute(
                    intervals: [interval("a", 0, 120)], sensors: raw
                )
                expect.equal(result.matches.first?.displayName, "Ada")
            },

            test("a participant whose every turn is refused gets no entry") { expect in
                // speakerEntries keyed on holding any turn at all, so a
                // participant the ceiling or the concession leaves with no
                // interval still got a named key that no utterance uses. It
                // reaches the folder's people list and the enrichment prompt,
                // and the confirm-a-voice control offers a name with no audio
                // behind it.
                let raw = sensors(
                    participants: [participant("U1", "Ada"), participant("U2", "Grace")],
                    turns: [("U1", 0, 400), ("U2", 400, 401), ("U2", 500, 560)]
                )
                let keys = Set(SensorAttribution.speakerEntries(sensors: raw).map(\.key))
                expect.isFalse(keys.contains(SpeakerLabel.sensor(participantID: "U1")))
                expect.isTrue(keys.contains(SpeakerLabel.sensor(participantID: "U2")))
            },

            test("an indicator that never moved enrols no voice") { expect in
                // The half that lasts. A wrong word label lives in one
                // transcript; a centroid built from three people's speech is
                // permanent and reaches every later meeting through the profile
                // that recognises them. On the recording above this embedded
                // 573 seconds of the far end under one person's name, and that
                // key already carried somebody's hand-typed confirmation.
                let overLong = sensors(
                    participants: [participant("U1", "Ada")], turns: [("U1", 0, 400)]
                )
                expect.equal(
                    SensorAttribution.enrollmentIntervals(
                        sensors: overLong, diarized: [interval("a", 0, 400)]
                    ),
                    []
                )
                // A turn under the ceiling still enrols, so this cannot be
                // passing because enrolment is broken.
                let ordinary = sensors(
                    participants: [participant("U1", "Ada")], turns: [("U1", 0, 200)]
                )
                expect.isFalse(
                    SensorAttribution.enrollmentIntervals(
                        sensors: ordinary, diarized: [interval("a", 0, 200)]
                    ).isEmpty
                )
            },

            test("a participant whose turns dominate no cluster enrolls nothing") { expect in
                // Two people splitting one cluster evenly means the diarizer
                // merged them, and embedding either half would put a two-voice
                // centroid in somebody's profile.
                let raw = sensors(
                    participants: [participant("U1", "Ada"), participant("U2", "Grace")],
                    turns: [("U1", 0, 30), ("U2", 30, 60)]
                )
                let enrolled = SensorAttribution.enrollmentIntervals(
                    sensors: raw, diarized: [interval("a", 0, 60)]
                )
                expect.equal(enrolled, [])
            },

            test("a fragment is not enough to enrol a voice") { expect in
                // A profile seeded from a cough misidentifies its owner in the
                // next meeting, and nothing retracts an automatic vector.
                let raw = sensors(
                    participants: [participant("U1", "Ada"), participant("U2", "Nods")],
                    turns: [("U1", 0, 30), ("U2", 30, 32)]
                )
                let enrolled = SensorAttribution.enrollmentIntervals(
                    sensors: raw,
                    diarized: [interval("a", 1, 29), interval("b", 30.2, 31.8)]
                )
                expect.isTrue(enrolled.contains {
                    $0.clusterID == SpeakerLabel.sensor(participantID: "U1")
                })
                expect.isFalse(enrolled.contains {
                    $0.clusterID == SpeakerLabel.sensor(participantID: "U2")
                })
            },

            test("the local user's voice is never enrolled from the far end") { expect in
                let raw = sensors(
                    participants: [
                        participant("me", "Andrew", isSelf: true), participant("U2", "Ada"),
                    ],
                    turns: [("me", 0, 30), ("U2", 30, 60)]
                )
                let enrolled = SensorAttribution.enrollmentIntervals(
                    sensors: raw,
                    diarized: [interval("a", 1, 29), interval("b", 31, 59)]
                )
                expect.isFalse(enrolled.contains {
                    $0.clusterID == SpeakerLabel.sensor(participantID: "me")
                })
            },

            test("speaker entries cover who held the floor and got a name") { expect in
                let raw = sensors(
                    participants: [
                        participant("me", "Andrew", isSelf: true),
                        participant("U2", "Ada"),
                        participant("U3", nil),
                        participant("U4", "Silent"),
                    ],
                    turns: [("me", 0, 10), ("U2", 10, 20), ("U3", 20, 30)]
                )
                let entries = SensorAttribution.speakerEntries(sensors: raw)
                // Ada held the floor and has a name. The local user is excluded,
                // U3 has no name to write, and U4 never held the floor.
                expect.equal(entries.count, 1)
                expect.equal(entries.first?.key, SpeakerLabel.sensor(participantID: "U2"))
                expect.equal(entries.first?.assignment.displayName, "Ada")
                expect.equal(entries.first?.assignment.origin, .sensor)
            },

            test("a participant the client never named claims no words") { expect in
                // `speakerEntries` already refuses to make a speaker out of a
                // participant with no name, so words keyed to one render as
                // `Participant` while the diarizer's own cluster for the same
                // audio, which a voice profile can name, is thrown away. One
                // rule for both: a turn claims words only where it can say
                // whose they are.
                //
                // Measured after the icon-ligature refusal landed. Four Meet
                // participants lost their scraped names, the diarizer had all
                // four voices under profiles, and the transcript came out as
                // named lines cut apart by nameless `Participant` fragments.
                let raw = sensors(
                    participants: [
                        participant("U1", "Ada"),
                        participant("U2", nil),
                        participant("U3", "keep_outline"),
                    ],
                    turns: [("U1", 0, 30), ("U2", 30, 60), ("U3", 60, 90)]
                )
                let claimed = Set(
                    SensorAttribution.wordIntervals(sensors: raw).map(\.clusterID)
                )
                expect.equal(claimed, [SpeakerLabel.sensor(participantID: "U1")])
            },

            test("an icon ligature from the page is not a person's name") { expect in
                // Measured on a real Meet recording on 3 September 2026. The
                // extension read the pin control's icon ligature off the tile
                // and sent it as the display name, so four different people
                // arrived as `keep_outline` and a fifth as `frame_person`.
                // A speaker chip is keyed by name, so those four voices
                // collapsed into one chip carrying an icon's name.
                //
                // The extension no longer sends these. This is the second
                // layer: the recordings that already carry them are immutable
                // and get re-read on every rebuild, and the next icon rename
                // lands here before anyone has shipped a new extension.
                let raw = sensors(
                    participants: [
                        participant("d406", "keep_outline"),
                        participant("d411", "frame_person"),
                        participant("d407", "Fireflies.ai Notetaker Chris"),
                    ],
                    turns: [("d406", 0, 30), ("d411", 30, 60), ("d407", 60, 90)]
                )
                let entries = SensorAttribution.speakerEntries(sensors: raw)
                expect.equal(entries.count, 1)
                expect.equal(
                    entries.first?.assignment.displayName, "Fireflies.ai Notetaker Chris"
                )
            },

            test("a one-word icon name is refused too") { expect in
                // Not every ligature has an underscore. `devices` is in the
                // extension's own list, so it is known to render inside these
                // tiles, and the snake_case test alone lets it through: a
                // recording made before the reader was fixed would keep a
                // speaker called `devices` on every rebuild.
                let raw = sensors(
                    participants: [
                        participant("U1", "devices"),
                        participant("U2", "keep"),
                        participant("U3", "Ada"),
                    ],
                    turns: [("U1", 0, 30), ("U2", 30, 60), ("U3", 60, 90)]
                )
                let entries = SensorAttribution.speakerEntries(sensors: raw)
                expect.equal(entries.count, 1)
                expect.equal(entries.first?.assignment.displayName, "Ada")
            },

            test("a name that merely contains an underscore still names its voice") { expect in
                // The test is the whole name, not a run inside it. Cutting on a
                // pattern anywhere in the string is what once took
                // `Chris Latimermore_vert` back to `Chris L`.
                let raw = sensors(
                    participants: [
                        participant("U1", "Ada Lovelace_"),
                        participant("U2", "DJ Snake_Eyes"),
                    ],
                    turns: [("U1", 0, 30), ("U2", 30, 60)]
                )
                let names = Set(
                    SensorAttribution.speakerEntries(sensors: raw)
                        .map { $0.assignment.displayName }
                )
                expect.equal(names, ["Ada Lovelace_", "DJ Snake_Eyes"])
            },

            test("only Slack's identifier is durable enough for a handle") { expect in
                // Slack's user id survives every meeting. Meet's device id is
                // per-conference, so a stored handle never matches again, and
                // Zoom's ids are already display names.
                expect.equal(SensorAttribution.handleProvider(source: "slack-huddle-ax"), "slack")
                expect.isNil(SensorAttribution.handleProvider(source: "google_meet-dom"))
                expect.isNil(SensorAttribution.handleProvider(source: "zoom-dom"))
            },

            test("the release trailing past the voice does not steal the next cluster") { expect in
                // Slack holds the flag about 1.5 s after speech stops. Ada's
                // turn therefore runs into Grace's first word, and the overlap
                // has to be small enough that Grace still wins her own cluster.
                let raw = sensors(
                    participants: [participant("U1", "Ada"), participant("U2", "Grace")],
                    turns: [("U1", 0, 11.5), ("U2", 11.5, 25)]
                )
                let result = SensorAttribution.attribute(
                    intervals: [interval("a", 0, 10), interval("b", 12, 24)], sensors: raw
                )
                let byCluster = Dictionary(
                    uniqueKeysWithValues: result.matches.map { ($0.clusterID, $0) }
                )
                expect.equal(byCluster["a"]?.displayName, "Ada")
                expect.equal(byCluster["b"]?.displayName, "Grace")
            },
        ])
    }

    static var linkSuite: Suite {
        Suite("SensorIdentityLink", [
            test("a voice identity that agrees with the name is linked") { expect in
                var map = SpeakerMap()
                map.applySuggestion(
                    SpeakerAssignment(displayName: "Ada", origin: .sensor),
                    for: "remote-001_speaker_01"
                )
                let identity = IdentityID(101)
                map.linkIdentity(identity, to: "remote-001_speaker_01", named: "Ada")
                expect.equal(map.entries["remote-001_speaker_01"]?.identityID, identity)
                expect.equal(map.entries["remote-001_speaker_01"]?.displayName, "Ada")
            },

            test("a voice identity that disagrees is not linked") { expect in
                // A link is not inert: refreshName rewrites the name of every
                // entry carrying an identity, whatever set it. Linking Grace's
                // voice to a cluster the roster called Ada would relabel Ada's
                // words the next time anyone touched Grace.
                var map = SpeakerMap()
                map.applySuggestion(
                    SpeakerAssignment(displayName: "Ada", origin: .sensor),
                    for: "remote-001_speaker_01"
                )
                map.linkIdentity(IdentityID(202), to: "remote-001_speaker_01", named: "Grace")
                expect.isNil(map.entries["remote-001_speaker_01"]?.identityID)
                expect.equal(map.entries["remote-001_speaker_01"]?.displayName, "Ada")
            },

            test("re-running a stage keeps the identity a later one attached") { expect in
                // applySuggestion replaces on equal origin, and a sensor
                // assignment carries no identity. Re-applying over a cluster
                // that had already been linked dropped the link and left a name
                // with no person behind it.
                var map = SpeakerMap()
                let assignment = SpeakerAssignment(displayName: "Ada", origin: .sensor)
                map.applySuggestion(assignment, for: "remote-001_speaker_01")
                map.linkIdentity(IdentityID(101), to: "remote-001_speaker_01", named: "Ada")
                map.applySuggestion(assignment, for: "remote-001_speaker_01")
                expect.equal(
                    map.entries["remote-001_speaker_01"]?.identityID, IdentityID(101)
                )
            },

            test("an unnamed voice is always safe to link") { expect in
                // It carries no name to impose, and the link is what lets a
                // recurring voice accumulate until somebody names it once.
                var map = SpeakerMap()
                map.applySuggestion(
                    SpeakerAssignment(displayName: "Ada", origin: .sensor),
                    for: "remote-001_speaker_01"
                )
                let identity = IdentityID(303)
                map.linkIdentity(identity, to: "remote-001_speaker_01", named: nil)
                expect.equal(map.entries["remote-001_speaker_01"]?.identityID, identity)
            },

            test("the local user is the one the microphone heard") { expect in
                // Meet marks its own tile with the English word "You", so a
                // client in any other language reports nobody as self. Matching
                // the configured name instead is what shipped, and it never
                // fired: Meet renders "Andrew Neeser" where the setting reads
                // "Andrew". Every Meet recording on disk has nobody marked.
                let raw = sensors(
                    participants: [
                        participant("d406", "Andrew Neeser"),
                        participant("d409", "Grace"),
                    ],
                    turns: [("d406", 0, 60), ("d409", 60, 120)]
                )
                let scoped = raw.markingSelf(using: speech(seconds: 120, talking: [(0, 60)]))
                expect.equal(scoped.participants.filter(\.isSelf).count, 1)
                expect.isTrue(scoped.participants.first { $0.id == "d406" }?.isSelf == true)
                // Marked, not removed: the turns stay and simply stop being
                // nameable, which is what keeps the margin rule working.
                expect.equal(scoped.turns.count, 2)
                let result = SensorAttribution.attribute(
                    intervals: [interval("a", 0, 60), interval("b", 60, 120)], sensors: scoped
                )
                expect.equal(result.matches.count, 1)
                expect.equal(result.matches.first?.displayName, "Grace")
            },

            test("two tiles under one name are told apart") { expect in
                // A real recording: the local user appears on two Meet devices
                // rendering the identical display name, and only one of them is
                // them. Name matching marked both and threw away 264 seconds of
                // a real participant's speech. What the microphone heard
                // separates them.
                let raw = sensors(
                    participants: [
                        participant("d381", "Andrew Neeser"),
                        participant("d382", "Andrew Neeser"),
                    ],
                    turns: [("d381", 0, 60), ("d382", 60, 120)]
                )
                let scoped = raw.markingSelf(using: speech(seconds: 120, talking: [(0, 60)]))
                expect.equal(scoped.participants.filter(\.isSelf).count, 1)
                expect.isTrue(scoped.participants.first { $0.id == "d381" }?.isSelf == true)
                expect.isFalse(scoped.participants.first { $0.id == "d382" }?.isSelf == true)
            },

            test("the far end playing over a cleaned microphone is not the user") { expect in
                // Without headphones the call comes back through the speakers.
                // The cleaner subtracts it before anything here reads the
                // microphone, so what is left under a far-end turn is not
                // speech, and the detector says so. Marking a remote
                // participant self deletes their turns outright, so this has
                // to fail closed.
                let raw = sensors(
                    participants: [participant("d406", "Grace"), participant("d409", "Ada")],
                    turns: [("d406", 0, 10), ("d409", 10, 20)]
                )
                let scoped = raw.markingSelf(
                    using: speech(seconds: 20, talking: [], echoDuring: [(0, 10)])
                )
                expect.equal(scoped.participants.filter(\.isSelf).count, 0)
            },

            test("a sliver of turn is not enough to call somebody the local user") { expect in
                // The dangerous direction. Being marked self removes a
                // participant from the roster entries, from word attribution
                // and from enrolment, so their name never lands anywhere. A
                // participant whose whole presence is one short turn that
                // happens to fall under the local user's speech would otherwise
                // score a clean 1.0: across the recordings on disk, 86 of 771
                // turns clear the threshold on their own, and 79 of those are
                // five seconds or shorter.
                let raw = sensors(
                    participants: [participant("U1", "Ada"), participant("U2", "Grace")],
                    turns: [("U1", 0, 2), ("U2", 10, 120)]
                )
                let scoped = raw.markingSelf(
                    using: speech(seconds: 200, talking: [(0, 2), (10, 120)])
                )
                // Grace has the evidence to be judged and is the local user.
                // Ada has two seconds and is left alone.
                expect.isFalse(scoped.participants.first { $0.id == "U1" }?.isSelf == true)
                expect.isTrue(scoped.participants.first { $0.id == "U2" }?.isSelf == true)
            },

            test("a recording with no far end judges nobody") { expect in
                // A process tap that produced nothing leaves no far-end series,
                // so the level and echo clauses cannot answer and the detector
                // alone would decide. On speakers that marks everybody self and
                // the meeting loses every sensor name.
                let raw = sensors(
                    participants: [participant("U1", "Ada"), participant("U2", "Grace")],
                    turns: [("U1", 0, 60), ("U2", 60, 120)]
                )
                var oneTrack = speech(seconds: 120, talking: [(0, 120)])
                oneTrack.remoteLevels = []
                expect.equal(raw.markingSelf(using: oneTrack).participants.filter(\.isSelf).count, 0)
            },

            test("a far end recorded as digital silence judges nobody") { expect in
                // The sibling of the case above, and the one that shipped. A
                // process tap bound to an application that emits nothing still
                // writes a full-length track, because the aggregate device is
                // clocked by its output sub-device rather than by the tap, so
                // the series is there and every window of it reads the floor.
                // Guarding on the series being non-empty let this through.
                //
                // With the far end at -120 the level difference is +62 dB for
                // every window and a filtered copy of silence accounts for none
                // of the microphone's energy, so both clauses answer yes to
                // whatever they are asked and the share collapses to whether
                // the detector fired. In the room it fires for whoever is
                // talking: on the recording this is taken from, all six
                // participants scored above 0.87 and every one was marked self,
                // which emptied the roster and left thirty-one minutes under
                // one name.
                let raw = sensors(
                    participants: [
                        participant("U1", "Ada"), participant("U2", "Grace"),
                        participant("U3", "Chris"),
                    ],
                    turns: [("U1", 0, 60), ("U2", 60, 120), ("U3", 120, 180)]
                )
                var silent = speech(seconds: 180, talking: [(0, 180)])
                silent.remoteLevels = silent.remoteLevels.map { _ in Int8(-120) }
                expect.equal(silent.remoteLevels.isEmpty, false)
                expect.equal(silent.farEndCarriesSignal, false)
                expect.equal(raw.markingSelf(using: silent).participants.filter(\.isSelf).count, 0)
                // And the names survive to be used, which is the point of not
                // marking them.
                expect.equal(
                    SensorAttribution.speakerEntries(sensors: raw.markingSelf(using: silent)).count,
                    3
                )
            },

            test("a far end that stopped is judged only where it was recorded") { expect in
                // A tap that captured the opening and then died leaves a track
                // that carries signal overall and nothing after the moment it
                // stopped. Both halves of that have to be respected.
                //
                // The recording still has a far end, so the track selection and
                // the enrolment guard leave it alone. But a window whose far end
                // reads the floor was measured against nothing: the level clause
                // reads +100 dB and the echo clause reads zero, so counting
                // those windows marks whoever was talking as the local user, one
                // participant at a time, for the rest of the meeting.
                let raw = sensors(
                    participants: [participant("U1", "Ada"), participant("U2", "Grace")],
                    turns: [("U1", 0, 60), ("U2", 120, 180)]
                )
                var stopped = speech(seconds: 200, talking: [(0, 60), (120, 180)])
                let died = Int(120 / 0.25)
                for index in stopped.remoteLevels.indices where index >= died {
                    stopped.remoteLevels[index] = -120
                }
                expect.equal(stopped.farEndCarriesSignal, true, "a far end was recorded")

                let scoped = raw.markingSelf(using: stopped)
                expect.isTrue(
                    scoped.participants.first { $0.id == "U1" }?.isSelf == true,
                    "judged on the windows the tap did capture"
                )
                expect.isFalse(
                    scoped.participants.first { $0.id == "U2" }?.isSelf == true,
                    "not judged on windows measured against silence"
                )
            },

            test("a turn timed past the end of the world is not walked") { expect in
                // The loop steps a quarter second at a time to the turn's end.
                // A reader that wrote milliseconds where seconds go would spend
                // billions of iterations inside an actor; SpeechEvidence already
                // refuses spans it cannot place, and this has to refuse the walk
                // before it starts.
                let raw = sensors(
                    participants: [participant("U1", "Ada")],
                    turns: [("U1", 0, 1_000_000_000)]
                )
                expect.equal(
                    raw.markingSelf(using: speech(seconds: 60, talking: [(0, 60)]))
                        .participants.filter(\.isSelf).count,
                    0
                )
            },

            test("evidence nobody measured marks nobody") { expect in
                // A meeting recorded before the measurement existed, and any
                // path that reaches this before the audio has been read. Absent
                // evidence is not evidence that nobody is the local user, so the
                // record comes back untouched rather than guessed at.
                let raw = sensors(
                    participants: [participant("d406", "Andrew"), participant("d409", "Grace")],
                    turns: [("d406", 0, 10), ("d409", 10, 20)]
                )
                expect.equal(raw.markingSelf(using: nil).participants.filter(\.isSelf).count, 0)
                expect.equal(raw.markingSelf(using: nil).turns.count, 2)
            },

            test("a reader cannot change mid-recording") { expect in
                // A Slack huddle opening beside a Meet call would otherwise fold
                // Slack user ids into a record labelled meet-dom, and nothing
                // downstream could tell the two apart.
                var recorder = SensorRecorder(anchorMonotonic: 0)
                recorder.record(SensorReading(
                    source: "meet-dom", provider: .googleMeet, at: 1,
                    participants: [participant("d406", "Ada")], speakingID: "d406"
                ))
                recorder.record(SensorReading(
                    source: "slack-huddle-ax", provider: .slack, at: 2,
                    participants: [participant("U1", "Someone else")], speakingID: "U1"
                ))
                let raw = try expect.unwrap(recorder.finish(timelineOriginHostTime: 0))
                expect.equal(raw.source, "meet-dom")
                expect.equal(raw.participants.count, 1)
                expect.equal(raw.participants.first?.id, "d406")
            },
        ])
    }

    static var selfSuite: Suite {
        Suite("SensorSelfHandling", [
            test("a cluster the local user best explains is left blank") { expect in
                // Their voice is not in the far-end mixdown, so nothing there is
                // theirs. Naming it after whoever came second would be worse
                // than leaving it for a person to fill in.
                let raw = sensors(
                    participants: [
                        participant("me", "Andrew", isSelf: true),
                        participant("U2", "Grace"),
                    ],
                    turns: [("me", 0, 10), ("U2", 30, 40)]
                )
                let result = SensorAttribution.attribute(
                    intervals: [interval("a", 1, 9)], sensors: raw
                )
                expect.equal(result.matches.count, 0)
            },

            test("the local user's turns still block a wrong name") { expect in
                // This is why their turns stay in the overlap. Removing them
                // left the runner-up at zero, so the margin rule stopped
                // guarding and second place won the cluster outright.
                let raw = sensors(
                    participants: [
                        participant("me", "Andrew", isSelf: true),
                        participant("U2", "Grace"),
                    ],
                    turns: [("me", 0, 8), ("U2", 8, 10)]
                )
                let result = SensorAttribution.attribute(
                    intervals: [interval("a", 0, 10)], sensors: raw
                )
                expect.equal(result.matches.count, 0)
            },

            test("the local user is not one of the voices to be found") { expect in
                let raw = sensors(
                    participants: [
                        participant("me", "Andrew", isSelf: true),
                        participant("U2", "Grace"), participant("U3", "Ada"),
                    ],
                    turns: [("me", 0, 30), ("U2", 30, 60), ("U3", 60, 90)]
                )
                let result = SensorAttribution.attribute(
                    intervals: [interval("a", 31, 59)], sensors: raw
                )
                expect.equal(result.matches.count, 1)
                expect.equal(result.matches.first?.displayName, "Grace")
            },

            test("an authoritative self flag short-circuits the measurement") { expect in
                // The case that shipped broken twice under the old design.
                // Where the platform said who the local user is, nothing else
                // gets to add a second: a colleague on a noisy line whose share
                // crossed the threshold would otherwise be marked too, and a
                // participant marked self has their turns dropped from word
                // attribution entirely. Their turns still attribute, and their
                // name still lands.
                let raw = sensors(
                    participants: [
                        participant("me", "Andrew", isSelf: true),
                        participant("U2", "Andrew"),
                        participant("U3", "Ada"),
                        participant("U4", "Grace"),
                    ],
                    turns: [("me", 0, 30), ("U2", 30, 60), ("U3", 60, 90), ("U4", 90, 120)]
                )
                var authoritative = raw
                authoritative.selfIsAuthoritative = true
                // Evidence that would otherwise mark U2 as well.
                let marked = authoritative.markingSelf(
                    using: speech(seconds: 120, talking: [(0, 30), (30, 60)])
                )
                expect.equal(
                    marked.participants.filter(\.isSelf).count, 1,
                    "the platform already said who the local user is"
                )
                let result = SensorAttribution.attribute(
                    intervals: [
                        interval("a", 31, 59), interval("b", 61, 89), interval("c", 91, 119),
                    ],
                    sensors: marked
                )
                let named = Dictionary(
                    uniqueKeysWithValues: result.matches.map { ($0.clusterID, $0.displayName) }
                )
                expect.equal(named["a"], "Andrew")
                expect.equal(named["b"], "Ada")
                expect.equal(named["c"], "Grace")
            },

            test("a missing mute reading cannot unmake a speaker") { expect in
                // A tile whose overlay never resolved reads as never-unmuted.
                // Holding the floor is the evidence; mute state is recorded and
                // not consulted, so both people still name their clusters.
                let raw = RawSensors(
                    source: "slack-huddle-ax",
                    participants: [participant("U1", "Ada"), participant("U2", "Grace")],
                    turns: [
                        SensorTurn(start: 0, end: 40, participantID: "U1"),
                        SensorTurn(start: 40, end: 80, participantID: "U2"),
                    ],
                    unmutedIDs: ["U1"]
                )
                let result = SensorAttribution.attribute(
                    intervals: [interval("a", 1, 39), interval("b", 41, 79)], sensors: raw
                )
                expect.equal(result.matches.count, 2)
            },

        ])
    }

    static var slackTileSuite: Suite {
        Suite("SlackHuddleTile", [
            test("the user id is what follows the last underscore") { expect in
                // Own tile and someone else's differ only in the prefix, and the
                // prefix is the session rather than the person. One person on
                // two devices is two tiles carrying one id.
                expect.equal(
                    SlackHuddleTileParser.userID(from: "huddle-grid-gridcell-self_U0BSR53NYHG"),
                    "U0BSR53NYHG"
                )
                expect.equal(
                    SlackHuddleTileParser.userID(
                        from: "huddle-grid-gridcell-0a5e5133-729a-48f9-b964-00b1690d7b37_U0BSR50GN82"
                    ),
                    "U0BSR50GN82"
                )
            },

            test("only the self_ prefix marks the local user") { expect in
                expect.isTrue(SlackHuddleTileParser.isSelf("huddle-grid-gridcell-self_U1"))
                expect.isFalse(SlackHuddleTileParser.isSelf(
                    "huddle-grid-gridcell-0a5e5133-729a-48f9-b964-00b1690d7b37_U2"
                ))
                // A display name containing the word does not make it the user.
                expect.isFalse(SlackHuddleTileParser.isSelf("huddle-grid-gridcell-myself_U3"))
            },

            test("the accessibility description that is not a tile is rejected") { expect in
                expect.isNil(SlackHuddleTileParser.userID(from: "Pbrowse-huddles"))
                expect.isNil(SlackHuddleTileParser.userID(
                    from: "huddle-grid-gridcell-self_U1-a11y_huddle_peer_tile_description"
                ))
                // The description node is rejected for being a description, not
                // for how its trailing token happens to look. Pinned with one
                // whose token would otherwise pass.
                expect.isNil(SlackHuddleTileParser.userID(
                    from: "huddle-grid-gridcell-a11y_huddle_peer_tile_description_U0BSR53NYHG"
                ))
            },

            test("a placeholder tile is not a person") { expect in
                // Slack renders a tile before its session resolves and writes
                // `pending` where the user id goes. Two recordings on disk carry
                // it beside the same person's real id, so it duplicates the
                // roster. It has never held the floor, and the damage if it did
                // is not a stray label: naming it binds `slack/pending` as a
                // durable handle, and every later placeholder tile in every
                // later meeting is then that person before a second of audio is
                // scored.
                expect.isNil(SlackHuddleTileParser.userID(
                    from: "huddle-grid-gridcell-0a5e5133-729a-48f9-b964-00b1690d7b37_pending"
                ))
                expect.isNil(SlackHuddleTileParser.userID(from: "huddle-grid-gridcell-self_pending"))
                // Shape, not a list of known ids. A workspace id this app has
                // never seen still has to read as a person.
                expect.equal(
                    SlackHuddleTileParser.userID(from: "huddle-grid-gridcell-self_W012ABCDEFG"),
                    "W012ABCDEFG"
                )
                expect.equal(
                    SlackHuddleTileParser.userID(from: "huddle-grid-gridcell-abc_B0B17GB9VPA"),
                    "B0B17GB9VPA"
                )
                // Slack's own bot, and a classic nine-character account. The
                // bound has to admit both: the shortest account in any recording
                // on disk is eleven, so a length fitted to what was measured
                // would silently drop every account shorter than the corpus.
                expect.equal(
                    SlackHuddleTileParser.userID(from: "huddle-grid-gridcell-abc_USLACKBOT"),
                    "USLACKBOT"
                )
                expect.equal(
                    SlackHuddleTileParser.userID(from: "huddle-grid-gridcell-abc_U023BECGF"),
                    "U023BECGF"
                )
                // Too short to be one, and lowercase never is.
                expect.isNil(SlackHuddleTileParser.userID(from: "huddle-grid-gridcell-abc_U01"))
                expect.isNil(SlackHuddleTileParser.userID(from: "huddle-grid-gridcell-abc_u0b17gb9vpa"))
                // Upper-case and numeric span the whole of Unicode, so the
                // check is ASCII or a Cyrillic run reads as an account.
                expect.isNil(SlackHuddleTileParser.userID(
                    from: "huddle-grid-gridcell-abc_U\u{0414}\u{0414}\u{0414}\u{0414}\u{0414}\u{0414}\u{0414}\u{0414}"
                ))
                expect.isNil(SlackHuddleTileParser.userID(
                    from: "huddle-grid-gridcell-abc_U\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}\u{0666}\u{0667}\u{0668}"
                ))
            },

            test("the display name comes out of the profile description") { expect in
                expect.equal(
                    SlackHuddleTileParser.displayName(from: "View Andrew Neeser\'s profile"),
                    "Andrew Neeser"
                )
                expect.equal(
                    SlackHuddleTileParser.displayName(from: "View andrew.neeser525\'s profile"),
                    "andrew.neeser525"
                )
                expect.isNil(SlackHuddleTileParser.displayName(from: "video is off, audio is on"))
            },

            test("mute state reads from the description either way round") { expect in
                expect.equal(SlackHuddleTileParser.isMuted(description: "video is off, audio is on"), false)
                expect.equal(SlackHuddleTileParser.isMuted(description: "video is off, audio is off"), true)
                expect.isNil(SlackHuddleTileParser.isMuted(description: "View Ada\'s profile"))
            },

            test("the speaking class is the one that only exists while set") { expect in
                expect.isTrue(SlackHuddleTileParser.isSpeaking(
                    classList: "p-huddle_peer_tile__mic_overlay,p-huddle_peer_tile__overlay--active_speaker"
                ))
                // The unmuted modifier is not the speaking one. Reading it as
                // speaking would mark everyone who simply left their microphone on.
                expect.isFalse(SlackHuddleTileParser.isSpeaking(
                    classList: "p-huddle_peer_tile__name_overlay,p-huddle_peer_tile__name_overlay--unmuted"
                ))
            },
        ])
    }

    static var all: [Suite] {
        [
            builderSuite, shiftSuite, attributionSuite, assemblySuite,
            linkSuite, selfSuite, slackTileSuite, roundTripSuite,
        ]
    }
}

extension SensorAttributionTests {
    /// The whole path a real meeting takes, minus the audio: a sensor record and
    /// a diarization run go into a meeting folder, and names come out of the
    /// speaker map under the right keys and the right origin.
    private static func remoteChunk(words: [RawTranscriptWord]) -> RawTranscriptChunk {
        RawTranscriptChunk(
            id: "remote_chunk_001", track: .remote, timelineOffset: 0, durationSeconds: 600,
            model: "test", responseFormat: "verbose_json",
            segments: [RawTranscriptSegment(
                start: words.first?.start ?? 0, end: words.last?.end ?? 0,
                text: words.map(\.text).joined(), speaker: nil, words: words
            )]
        )
    }

    private static func run(_ intervals: [DiarizationInterval]) -> RawDiarization {
        var diarization = RawDiarization()
        diarization.setActive(DiarizationRun(
            id: "remote-001", track: .remote, backend: "test",
            producedAt: Date(timeIntervalSince1970: 0), timelineOffset: 0,
            intervals: intervals
        ))
        return diarization
    }

    static var assemblySuite: Suite {
        Suite("SensorAssembly", [
            test("words inside a turn take the person, the rest the cluster") { expect in
                // The order is the design: a turn is the client's observation of
                // who held the floor, so where one covers a word it decides. The
                // diarizer attributes only what no turn covers.
                let words = [
                    RawTranscriptWord(start: 2, end: 3, text: "Hello "),
                    RawTranscriptWord(start: 3, end: 4, text: "there. "),
                    RawTranscriptWord(start: 15, end: 16, text: "Later "),
                    RawTranscriptWord(start: 16, end: 17, text: "words."),
                ]
                let sensors = RawSensors(
                    source: "slack-huddle-ax",
                    participants: [SensorParticipant(id: "U_ADA", displayName: "Ada")],
                    turns: [SensorTurn(start: 0, end: 10, participantID: "U_ADA")]
                )
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [remoteChunk(words: words)]),
                    diarization: run([
                        DiarizationInterval(start: 1, end: 9, clusterID: "1"),
                        DiarizationInterval(start: 14, end: 18, clusterID: "1"),
                    ]),
                    sensors: sensors,
                    micTrackIsLocalUser: true,
                    generatedAt: Date(timeIntervalSince1970: 0)
                )
                let keys = transcript.utterances.map(\.speakerKey)
                expect.equal(keys.count, 2, "got \(keys)")
                expect.equal(keys.first, SpeakerLabel.sensor(participantID: "U_ADA"))
                expect.equal(keys.last, "remote-001_speaker_01")
            },

            test("a turn outranks the cluster where both cover a word") { expect in
                // The cluster is the diarizer's guess about the same seconds the
                // client observed. Observation wins.
                let words = [
                    RawTranscriptWord(start: 2, end: 3, text: "Hello "),
                    RawTranscriptWord(start: 3, end: 4, text: "there."),
                ]
                let sensors = RawSensors(
                    source: "slack-huddle-ax",
                    participants: [SensorParticipant(id: "U_ADA", displayName: "Ada")],
                    turns: [SensorTurn(start: 0, end: 10, participantID: "U_ADA")]
                )
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [remoteChunk(words: words)]),
                    diarization: run([DiarizationInterval(start: 1, end: 9, clusterID: "1")]),
                    sensors: sensors,
                    micTrackIsLocalUser: true,
                    generatedAt: Date(timeIntervalSince1970: 0)
                )
                expect.equal(
                    transcript.utterances.map(\.speakerKey),
                    [SpeakerLabel.sensor(participantID: "U_ADA")]
                )
            },

            test("words in a turn's tail go to the diarizer, not the last holder") { expect in
                // A turn's end is where the indicator moved: sampled at 0.5 s
                // and released late, so the next speaker's first words can sit
                // inside it. The tail is conceded to the diarizer, which hears
                // the voice change.
                let words = [
                    RawTranscriptWord(start: 2, end: 3, text: "Hello "),
                    // Inside Ada's turn on paper, and inside Grace's cluster
                    // in the audio.
                    RawTranscriptWord(start: 10.1, end: 10.4, text: "actually."),
                ]
                let sensors = RawSensors(
                    source: "slack-huddle-ax",
                    participants: [SensorParticipant(id: "U_ADA", displayName: "Ada")],
                    turns: [SensorTurn(start: 0, end: 10.6, participantID: "U_ADA")]
                )
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [remoteChunk(words: words)]),
                    diarization: run([
                        DiarizationInterval(start: 1, end: 9.5, clusterID: "1"),
                        DiarizationInterval(start: 10, end: 14, clusterID: "2"),
                    ]),
                    sensors: sensors,
                    micTrackIsLocalUser: true,
                    generatedAt: Date(timeIntervalSince1970: 0)
                )
                let keys = transcript.utterances.map(\.speakerKey)
                expect.equal(keys.count, 2, "got \(keys)")
                expect.equal(keys.first, SpeakerLabel.sensor(participantID: "U_ADA"))
                expect.equal(keys.last, "remote-001_speaker_02", "the audio decides the tail")
            },

            test("a self turn does not capture far-end words") { expect in
                // The far-end track cannot contain the local user, so a span
                // their turn covers goes to the diarizer, which heard the audio.
                let words = [
                    RawTranscriptWord(start: 2, end: 3, text: "Hello "),
                    RawTranscriptWord(start: 3, end: 4, text: "there."),
                ]
                let sensors = RawSensors(
                    source: "slack-huddle-ax",
                    participants: [
                        SensorParticipant(id: "U_ME", displayName: "Andrew", isSelf: true),
                    ],
                    turns: [SensorTurn(start: 0, end: 10, participantID: "U_ME")]
                )
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [remoteChunk(words: words)]),
                    diarization: run([DiarizationInterval(start: 1, end: 9, clusterID: "1")]),
                    sensors: sensors,
                    micTrackIsLocalUser: true,
                    generatedAt: Date(timeIntervalSince1970: 0)
                )
                expect.equal(transcript.utterances.map(\.speakerKey), ["remote-001_speaker_01"])
            },

            test("no sensors attributes exactly as before") { expect in
                let words = [
                    RawTranscriptWord(start: 2, end: 3, text: "Hello "),
                    RawTranscriptWord(start: 3, end: 4, text: "there."),
                ]
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [remoteChunk(words: words)]),
                    diarization: run([DiarizationInterval(start: 1, end: 9, clusterID: "1")]),
                    sensors: nil,
                    micTrackIsLocalUser: true,
                    generatedAt: Date(timeIntervalSince1970: 0)
                )
                expect.equal(transcript.utterances.map(\.speakerKey), ["remote-001_speaker_01"])
            },

            test("turns alone attribute a track the diarizer has not run on") { expect in
                // A sensor is evidence in its own right. A meeting whose
                // diarization produced nothing still gets its words attributed
                // where the client saw the floor held.
                let words = [
                    RawTranscriptWord(start: 2, end: 3, text: "Hello "),
                    RawTranscriptWord(start: 3, end: 4, text: "there."),
                ]
                let sensors = RawSensors(
                    source: "slack-huddle-ax",
                    participants: [SensorParticipant(id: "U_ADA", displayName: "Ada")],
                    turns: [SensorTurn(start: 0, end: 10, participantID: "U_ADA")]
                )
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [remoteChunk(words: words)]),
                    diarization: RawDiarization(),
                    sensors: sensors,
                    micTrackIsLocalUser: true,
                    generatedAt: Date(timeIntervalSince1970: 0)
                )
                expect.equal(
                    transcript.utterances.map(\.speakerKey),
                    [SpeakerLabel.sensor(participantID: "U_ADA")]
                )
            },
        ])
    }

    static var roundTripSuite: Suite {
        Suite("SensorRoundTrip", [
            test("a sensor record on disk names the clusters it explains") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let repository = MeetingRepository(root: root)
                let created = try repository.createMeeting(
                    source: .slackHuddle, provider: .slack,
                    startedAt: Date(timeIntervalSince1970: 1_787_070_000),
                    now: Date(timeIntervalSince1970: 1_787_070_000)
                )
                let store = created.store

                var diarization = RawDiarization()
                diarization.setActive(DiarizationRun(
                    id: "remote-001", track: .remote, backend: "test",
                    producedAt: Date(timeIntervalSince1970: 1_787_070_000), timelineOffset: 0,
                    clusters: [
                        DiarizationCluster(id: "1", speechSeconds: 8),
                        DiarizationCluster(id: "2", speechSeconds: 8),
                    ],
                    intervals: [
                        DiarizationInterval(start: 1, end: 9, clusterID: "1"),
                        DiarizationInterval(start: 11, end: 19, clusterID: "2"),
                    ]
                ))
                try store.writeRawDiarization(diarization)

                try store.writeRawSensors(RawSensors(
                    source: "slack-huddle-ax",
                    participants: [
                        SensorParticipant(id: "U_ME", displayName: "Andrew", isSelf: true),
                        SensorParticipant(id: "U_ADA", displayName: "Ada"),
                        SensorParticipant(id: "U_GRACE", displayName: "Grace"),
                    ],
                    turns: [
                        SensorTurn(start: 0, end: 10, participantID: "U_ADA"),
                        SensorTurn(start: 10, end: 20, participantID: "U_GRACE"),
                    ],
                    unmutedIDs: ["U_ME", "U_ADA", "U_GRACE"]
                ))

                let sensors = try expect.unwrap(store.readRawSensors())
                let entries = SensorAttribution.assignments(
                    diarization: try store.readRawDiarization(), sensors: sensors
                )
                var speakers = try store.readSpeakerMap()
                for entry in entries { speakers.applySuggestion(entry.assignment, for: entry.key) }
                try store.writeSpeakerMap(speakers)

                let reread = try store.readSpeakerMap()
                expect.equal(reread.entries["remote-001_speaker_01"]?.displayName, "Ada")
                expect.equal(reread.entries["remote-001_speaker_02"]?.displayName, "Grace")
                expect.equal(reread.entries["remote-001_speaker_01"]?.origin, .sensor)
                expect.equal(
                    reread.entries["remote-001_speaker_01"]?.participantID, "U_ADA",
                    "the platform identity is kept, not just the name"
                )
            },

            test("a name a person cleared is not written back by the meeting") { expect in
                // The client hands the same name over every meeting, so without
                // a record of the clearing, a person can never take a roster
                // name off a speaker: the next pass puts it straight back.
                var speakers = SpeakerMap()
                let key = SpeakerLabel.sensor(participantID: "U_ADA")
                speakers.assign("Ada", to: key)
                speakers.assign("", to: key)
                expect.isNil(speakers.entries[key])

                let sensors = RawSensors(
                    source: "slack-huddle-ax",
                    participants: [SensorParticipant(id: "U_ADA", displayName: "Ada")],
                    turns: [SensorTurn(start: 0, end: 30, participantID: "U_ADA")]
                )
                for entry in SensorAttribution.speakerEntries(sensors: sensors) {
                    speakers.applySuggestion(entry.assignment, for: entry.key)
                }
                expect.isNil(speakers.entries[key], "the roster wrote the cleared name back")

                // And naming it again lifts the block.
                speakers.assign("Grace", to: key)
                expect.equal(speakers.entries[key]?.displayName, "Grace")
            },

            test("a name a person set is not overwritten by the meeting") { expect in
                // The correction precedence is the reason origins are ranked at
                // all, and this is the case that matters most: a user fixing a
                // wrong name must not have it undone on the next re-analysis.
                var speakers = SpeakerMap()
                speakers.assign("Priya", to: "remote-001_speaker_01")

                var diarization = RawDiarization()
                diarization.setActive(DiarizationRun(
                    id: "remote-001", track: .remote, backend: "test",
                    producedAt: Date(timeIntervalSince1970: 0), timelineOffset: 0,
                    intervals: [DiarizationInterval(start: 1, end: 9, clusterID: "1")]
                ))
                let sensors = RawSensors(
                    source: "slack-huddle-ax",
                    participants: [SensorParticipant(id: "U_ADA", displayName: "Ada")],
                    turns: [SensorTurn(start: 0, end: 10, participantID: "U_ADA")]
                )
                for entry in SensorAttribution.assignments(
                    diarization: diarization, sensors: sensors
                ) {
                    speakers.applySuggestion(entry.assignment, for: entry.key)
                }
                expect.equal(speakers.entries["remote-001_speaker_01"]?.displayName, "Priya")
                expect.equal(speakers.entries["remote-001_speaker_01"]?.origin, .human)
            },

            test("a participant the client never named leaves the cluster blank") { expect in
                // Meet reports an identifier like spaces/x/devices/406 before it
                // renders a name. Showing that to a person would be worse than
                // showing nothing.
                var diarization = RawDiarization()
                diarization.setActive(DiarizationRun(
                    id: "remote-001", track: .remote, backend: "test",
                    producedAt: Date(timeIntervalSince1970: 0), timelineOffset: 0,
                    intervals: [DiarizationInterval(start: 1, end: 9, clusterID: "1")]
                ))
                let sensors = RawSensors(
                    source: "meet-dom",
                    participants: [SensorParticipant(id: "spaces/x/devices/406")],
                    turns: [SensorTurn(start: 0, end: 10, participantID: "spaces/x/devices/406")]
                )
                expect.equal(
                    SensorAttribution.assignments(diarization: diarization, sensors: sensors).count,
                    0
                )
            },
        ])
    }
}
