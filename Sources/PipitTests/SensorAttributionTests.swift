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
                let raw = builder.finish(at: 2.25)
                expect.equal(raw.turns.count, 1)
                let turn = try expect.unwrap(raw.turns.first)
                expect.equal(turn.participantID, "U1")
                expect.close(turn.start, 0, tolerance: 0.001)
                expect.close(turn.end, 2.25, tolerance: 0.001)
            },

            test("the floor moving to someone else closes the turn") { expect in
                var builder = SensorTimelineBuilder(source: "slack")
                let roster = [participant("U1"), participant("U2")]
                builder.record(SensorObservation(at: 0, participants: roster, speakingID: "U1"))
                builder.record(SensorObservation(at: 1, participants: roster, speakingID: "U1"))
                builder.record(SensorObservation(at: 2, participants: roster, speakingID: "U2"))
                builder.record(SensorObservation(at: 3, participants: roster, speakingID: "U2"))
                let raw = builder.finish(at: 4)
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
                builder.record(SensorObservation(at: 0, participants: roster, speakingID: "U1"))
                builder.record(SensorObservation(at: 1, participants: roster, speakingID: nil))
                builder.record(SensorObservation(at: 5, participants: roster, speakingID: "U1"))
                let raw = builder.finish(at: 6)
                expect.equal(raw.turns.count, 2)
                expect.close(try expect.unwrap(raw.turns.first).end, 1, tolerance: 0.001)
                expect.close(try expect.unwrap(raw.turns.last).start, 5, tolerance: 0.001)
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
                let raw = builder.finish(at: 3)
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
                let raw = builder.finish(at: 2)
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
                let raw = builder.finish(at: 10)
                expect.equal(raw.turns.count, 0)
                expect.equal(raw.participants.count, 1)
            },

            test("a reading that arrives late does not swallow the open turn") { expect in
                // Detection delivers snapshots as independent tasks, so ordering
                // is not guaranteed. Closing a turn at a moment before it began
                // dropped it outright.
                var builder = SensorTimelineBuilder(source: "slack")
                let roster = [participant("U1", "Ada")]
                builder.record(SensorObservation(at: 0, participants: roster, speakingID: "U1"))
                builder.record(SensorObservation(at: 10, participants: roster, speakingID: "U1"))
                // Out of order: an older reading arriving after a newer one.
                builder.record(SensorObservation(at: 4, participants: roster, speakingID: nil))
                let raw = builder.finish(at: 12)
                expect.equal(raw.turns.count, 1)
                expect.close(try expect.unwrap(raw.turns.first).end, 12, tolerance: 0.001)
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
                let raw = builder.finish(at: 3)
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
                // Ada talks from 20 s to 30 s after the commit.
                recorder.record(SensorReading(
                    source: "slack-huddle-ax", provider: .slack, at: commit + 20, participants: roster,
                    speakingID: "U1"
                ))
                recorder.record(SensorReading(
                    source: "slack-huddle-ax", provider: .slack, at: commit + 30, participants: roster,
                    speakingID: nil
                ))
                let raw = try expect.unwrap(
                    recorder.finish(at: commit + 31, timelineOriginHostTime: origin)
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
                expect.isNil(recorder.finish(at: 110, timelineOriginHostTime: nil))
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

            test("the speaker count counts who talked, not who attended") { expect in
                let raw = sensors(
                    participants: [
                        participant("U1", "Ada"), participant("U2", "Grace"),
                        participant("U3", "Silent"), participant("U4", "AlsoSilent"),
                    ],
                    turns: [("U1", 0, 10), ("U2", 10, 20)]
                )
                let result = SensorAttribution.attribute(
                    intervals: [interval("a", 1, 9)], sensors: raw
                )
                expect.equal(result.speakerCountHint, 2)
            },

            test("a one-word interjection does not make somebody a speaker") { expect in
                // Slack's flag releases about 1.5 s after the voice stops, so a
                // cough or a "yeah" produces a turn. Counting those told the
                // diarizer to find a cluster per person who made a noise, which
                // splits the people who were actually talking.
                let raw = sensors(
                    participants: [
                        participant("U1", "Ada"), participant("U2", "Grace"),
                        participant("U3", "Nods"), participant("U4", "AlsoNods"),
                    ],
                    turns: [
                        ("U1", 0, 200), ("U2", 200, 400),
                        ("U3", 400, 401.6), ("U4", 401.6, 403),
                    ]
                )
                let result = SensorAttribution.attribute(
                    intervals: [interval("a", 1, 199)], sensors: raw
                )
                expect.equal(result.speakerCountHint, 2)
            },

            test("nothing but interjections gives no count rather than zero") { expect in
                let raw = sensors(
                    participants: [participant("U1", "Ada")], turns: [("U1", 0, 1.2)]
                )
                let result = SensorAttribution.attribute(
                    intervals: [interval("a", 0, 1)], sensors: raw
                )
                expect.isNil(result.speakerCountHint)
            },

            test("no turns at all gives no count rather than zero") { expect in
                // Zero would be a claim that nobody spoke. Absent is the truth:
                // the sensor saw a roster and never saw the floor taken.
                let raw = sensors(
                    participants: [participant("U1", "Ada")], turns: []
                )
                let result = SensorAttribution.attribute(
                    intervals: [interval("a", 1, 9)], sensors: raw
                )
                expect.isNil(result.speakerCountHint)
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

            test("the local user is excluded by configured name, not only by flag") { expect in
                // Meet marks its own tile with the English word "You", so a
                // client in any other language reports nobody as self.
                let raw = sensors(
                    participants: [
                        participant("d406", "Andrew Neeser"),
                        participant("d409", "Grace"),
                    ],
                    turns: [("d406", 0, 10), ("d409", 10, 20)]
                )
                let scoped = raw.markingSelf(named: "andrew neeser")
                expect.equal(scoped.participants.filter(\.isSelf).count, 1)
                // Marked, not removed: the turns stay and simply stop being
                // nameable, which is what keeps the margin rule working.
                expect.equal(scoped.turns.count, 2)
                let result = SensorAttribution.attribute(
                    intervals: [interval("a", 0, 10), interval("b", 10, 20)], sensors: scoped
                )
                expect.equal(result.matches.count, 1)
                expect.equal(result.matches.first?.displayName, "Grace")
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
                let raw = try expect.unwrap(recorder.finish(at: 3, timelineOriginHostTime: 0))
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
                expect.equal(result.speakerCountHint, 2)
            },

            test("a namesake of the local user is a guess, not a fact") { expect in
                // Two people called Andrew in one call is not rare. Acting on
                // the name would drop a real speaker from the count, merge two
                // voices into one, and rename one of them, which no later stage
                // can undo.
                let raw = sensors(
                    participants: [participant("U2", "Andrew"), participant("U3", "Grace")],
                    turns: [("U2", 0, 30), ("U3", 30, 60)]
                )
                expect.isTrue(raw.selfIsOnlyAGuess(localUserName: "andrew"))
                expect.isFalse(raw.selfIsOnlyAGuess(localUserName: "Priya"))
            },

            test("a namesake beside a real self flag is still a speaker") { expect in
                // The case that shipped broken twice. Slack and Meet both name
                // the local user, so the guess guard cleared, and the name match
                // then marked the colleague as well. He left the speaker count,
                // the recording re-clustered one voice short, and two people
                // were merged into one and enrolled as one voice.
                let raw = sensors(
                    participants: [
                        participant("me", "Andrew", isSelf: true),
                        participant("U2", "Andrew"),
                        participant("U3", "Ada"),
                        participant("U4", "Grace"),
                    ],
                    turns: [("me", 0, 30), ("U2", 30, 60), ("U3", 60, 90), ("U4", 90, 120)]
                )
                let marked = raw.markingSelf(named: "Andrew")
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
                expect.equal(result.speakerCountHint, 3, "three remote voices, three speakers")
                let named = Dictionary(
                    uniqueKeysWithValues: result.matches.map { ($0.clusterID, $0.displayName) }
                )
                expect.equal(named["a"], "Andrew")
                expect.equal(named["b"], "Ada")
                expect.equal(named["c"], "Grace")
            },

            test("a missing mute reading cannot unmake a speaker") { expect in
                // A tile whose overlay never resolved reads as never-unmuted.
                // Letting that outrank forty seconds of holding the floor
                // removed a real speaker from the count and merged them into
                // somebody else.
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
                expect.equal(result.speakerCountHint, 2)
            },

            test("four interjections do not add up to a speaker") { expect in
                // The longest turn decides, not the sum. Slack releases about
                // 1.5 s after a voice stops, so repeated "mhm"s accumulate past
                // any threshold while describing somebody who never held the
                // floor.
                let raw = sensors(
                    participants: [participant("U1", "Ada"), participant("U2", "Nods")],
                    turns: [
                        ("U1", 0, 60),
                        ("U2", 100, 101.6), ("U2", 200, 201.6),
                        ("U2", 300, 301.6), ("U2", 400, 401.6),
                    ]
                )
                let result = SensorAttribution.attribute(
                    intervals: [interval("a", 1, 59)], sensors: raw
                )
                expect.equal(result.speakerCountHint, 1)
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
            builderSuite, shiftSuite, attributionSuite,
            linkSuite, selfSuite, slackTileSuite, roundTripSuite,
        ]
    }
}

extension SensorAttributionTests {
    /// The whole path a real meeting takes, minus the audio: a sensor record and
    /// a diarization run go into a meeting folder, and names come out of the
    /// speaker map under the right keys and the right origin.
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
