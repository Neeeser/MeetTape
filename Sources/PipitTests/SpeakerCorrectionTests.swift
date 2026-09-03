import Foundation
import PipitCore
import TestKit

/// Attribution, the layers above it, and the rule that a person's correction is
/// the last word.
enum SpeakerCorrectionTests {

    static func interval(_ start: Double, _ end: Double, _ cluster: String) -> DiarizationInterval {
        DiarizationInterval(start: start, end: end, clusterID: cluster)
    }

    static func word(_ text: String, _ start: Double, _ end: Double) -> RawTranscriptWord {
        RawTranscriptWord(start: start, end: end, text: text)
    }

    static var alignmentSuite: Suite {
        Suite("SpeakerAlignment", [
            test("a word goes to the cluster it overlaps most") { expect in
                let intervals = [interval(0, 5, "S1"), interval(4.5, 10, "S2")]
                let (clusters, statistics) = SpeakerAlignment.assign(
                    spans: [TimedSpan(start: 4.6, end: 6.0)], to: intervals
                )
                expect.equal(clusters.first ?? nil, "S2", "1.5 s of overlap beats 0.4 s")
                expect.equal(statistics.byOverlap, 1)
                expect.equal(statistics.straddled, 1, "a boundary word is counted, not special-cased")
            },

            test("a word in a gap adopts the nearest cluster within half a second") { expect in
                let intervals = [interval(0, 5, "S1"), interval(8, 12, "S2")]
                let near = SpeakerAlignment.assign(
                    spans: [TimedSpan(start: 5.2, end: 5.4)], to: intervals
                )
                expect.equal(near.clusters.first ?? nil, "S1")
                expect.equal(near.statistics.byNearest, 1)

                let far = SpeakerAlignment.assign(
                    spans: [TimedSpan(start: 6.0, end: 6.4)], to: intervals
                )
                expect.isNil(far.clusters.first ?? nil, "1 s from any speech is nobody's word")
                expect.equal(far.statistics.unassigned, 1)
            },

            test("with no diarization at all every word is unattributed") { expect in
                let (clusters, statistics) = SpeakerAlignment.assign(
                    spans: [TimedSpan(start: 1, end: 2), TimedSpan(start: 3, end: 4)], to: []
                )
                expect.equal(clusters.count, 2)
                expect.isTrue(clusters.allSatisfy { $0 == nil })
                expect.equal(statistics.unassigned, 2)
                expect.close(statistics.attributedShare, 0, tolerance: 0.0001)
            },

            test("a long meeting's words are attributed in the order they were given") { expect in
                var intervals: [DiarizationInterval] = []
                for index in 0..<400 {
                    let start = Double(index) * 5
                    intervals.append(interval(start, start + 4, index.isMultiple(of: 2) ? "S1" : "S2"))
                }
                let spans = (0..<400).map { TimedSpan(start: Double($0) * 5 + 1, end: Double($0) * 5 + 2) }
                let (clusters, statistics) = SpeakerAlignment.assign(spans: spans, to: intervals)
                expect.equal(statistics.byOverlap, 400)
                expect.equal(clusters[0], "S1")
                expect.equal(clusters[1], "S2")
                expect.equal(clusters[399], "S2")
            },
        ])
    }

    static var assemblySuite: Suite {
        Suite("SpeakerAttribution", [
            test("a segment spanning two speakers is split at the change") { expect in
                let chunk = RawTranscriptChunk(
                    id: "remote_full", track: .remote, timelineOffset: 0, durationSeconds: 20,
                    model: "whisperkit", responseFormat: "local_words",
                    segments: [RawTranscriptSegment(
                        start: 0, end: 8, text: "yes exactly no i disagree", speaker: nil,
                        words: [
                            word(" yes", 0.0, 0.5), word(" exactly", 0.6, 1.2),
                            word(" no", 5.0, 5.3), word(" i", 5.4, 5.6),
                            word(" disagree", 5.7, 6.4),
                        ]
                    )]
                )
                var diarization = RawDiarization()
                diarization.setActive(DiarizationRun(
                    id: "remote-001", track: .remote, backend: "fluidaudio-offline-0.15.6",
                    producedAt: Date(), timelineOffset: 0,
                    clusters: [
                        DiarizationCluster(id: "S1", speechSeconds: 2),
                        DiarizationCluster(id: "S2", speechSeconds: 2),
                    ],
                    intervals: [interval(0, 2, "S1"), interval(4.8, 7, "S2")]
                ))

                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [chunk]), diarization: diarization,
                    micTrackIsLocalUser: false, generatedAt: Date()
                )
                expect.equal(transcript.utterances.count, 2)
                expect.equal(transcript.utterances[0].text, "yes exactly")
                expect.equal(transcript.utterances[1].text, "no i disagree")
                expect.notEqual(
                    transcript.utterances[0].speakerKey, transcript.utterances[1].speakerKey
                )
                expect.isTrue(
                    transcript.utterances[0].speakerKey.hasPrefix("remote-001_speaker_"),
                    "the run is part of the key, so a re-analysis cannot inherit its names"
                )
            },

            test("segments that already name a speaker are left exactly as they are") { expect in
                // The cloud diarizer's own output. Re-deriving it from intervals
                // would change a working result for nothing.
                let chunk = RawTranscriptChunk(
                    id: "remote_chunk_001", track: .remote, timelineOffset: 0, durationSeconds: 10,
                    model: "gpt-4o-transcribe-diarize", responseFormat: "diarized_json",
                    segments: [
                        RawTranscriptSegment(start: 0, end: 3, text: "hello", speaker: "A"),
                        RawTranscriptSegment(start: 4, end: 7, text: "hi there", speaker: "B"),
                    ]
                )
                var diarization = RawDiarization()
                diarization.setActive(DiarizationRun(
                    id: "remote-001", track: .remote, backend: "gpt-4o-transcribe-diarize",
                    producedAt: Date(), timelineOffset: 0,
                    intervals: [interval(0, 7, "everything-is-one-speaker")]
                ))
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [chunk]), diarization: diarization,
                    micTrackIsLocalUser: false, generatedAt: Date()
                )
                expect.equal(transcript.utterances.count, 2)
                expect.equal(transcript.utterances[0].speakerKey, "remote_chunk_001_speaker_00")
                expect.equal(transcript.utterances[1].speakerKey, "remote_chunk_001_speaker_01")
            },

            test("a backchannel nobody claimed stays with the words around it") { expect in
                let chunk = RawTranscriptChunk(
                    id: "remote_full", track: .remote, timelineOffset: 0, durationSeconds: 20,
                    model: "whisperkit", responseFormat: "local_words",
                    segments: [RawTranscriptSegment(
                        start: 0, end: 6, text: "so the plan yeah is to ship", speaker: nil,
                        words: [
                            word(" so", 0.0, 0.3), word(" the", 0.4, 0.6), word(" plan", 0.7, 1.0),
                            // Spoken over the speaker, so the diarizer dropped it.
                            word(" yeah", 3.0, 3.2),
                            word(" is", 5.1, 5.3), word(" to", 5.4, 5.5), word(" ship", 5.6, 5.9),
                        ]
                    )]
                )
                var diarization = RawDiarization()
                diarization.setActive(DiarizationRun(
                    id: "remote-001", track: .remote, backend: "fluidaudio-offline-0.15.6",
                    producedAt: Date(), timelineOffset: 0,
                    clusters: [DiarizationCluster(id: "S1", speechSeconds: 5)],
                    intervals: [interval(0, 1.2, "S1"), interval(5.0, 6.0, "S1")]
                ))
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [chunk]), diarization: diarization,
                    micTrackIsLocalUser: false, generatedAt: Date()
                )
                let text = transcript.utterances.map(\.text).joined(separator: " ")
                expect.isTrue(text.contains("yeah"), "an unattributed word is kept, not dropped")
                expect.equal(Set(transcript.utterances.map(\.speakerKey)).count, 1)
            },
        ])
    }

    static var layerSuite: Suite {
        Suite("SpeakerCorrections", [
            test("renaming a cluster changes every line it owns and nothing else") { expect in
                var map = SpeakerMap()
                map.assign("Samantha", to: "remote-001_speaker_00")
                let mine = Utterance(
                    id: "u1", start: 0, end: 3, track: .remote,
                    rawSpeakerLabel: "remote-001_speaker_00",
                    speakerKey: "remote-001_speaker_00", text: "hello",
                    chunkID: "remote_full", model: "whisperkit"
                )
                let theirs = Utterance(
                    id: "u2", start: 4, end: 6, track: .remote,
                    rawSpeakerLabel: "remote-001_speaker_01",
                    speakerKey: "remote-001_speaker_01", text: "hi",
                    chunkID: "remote_full", model: "whisperkit"
                )
                expect.equal(map.resolvedName(for: mine), "Samantha")
                expect.equal(map.resolvedName(for: theirs), "Speaker 2")
            },

            test("correcting one line leaves every other line in its cluster alone") { expect in
                var map = SpeakerMap()
                map.assign("Samantha", to: "remote-001_speaker_00")
                let first = Utterance(
                    id: "u1", start: 0, end: 3, track: .remote, rawSpeakerLabel: nil,
                    speakerKey: "remote-001_speaker_00", text: "one",
                    chunkID: "remote_full", model: "whisperkit"
                )
                let second = Utterance(
                    id: "u2", start: 4, end: 7, track: .remote, rawSpeakerLabel: nil,
                    speakerKey: "remote-001_speaker_00", text: "two",
                    chunkID: "remote_full", model: "whisperkit"
                )
                map.overrideUtterance(
                    second,
                    with: SpeakerAssignment(displayName: "Chris", origin: .human),
                    at: Date()
                )
                expect.equal(map.resolvedName(for: first), "Samantha")
                expect.equal(map.resolvedName(for: second), "Chris")
                expect.equal(
                    map.entries["remote-001_speaker_00"]?.displayName, "Samantha",
                    "the cluster mapping is untouched"
                )
            },

            test("a line correction beats the cluster it belongs to") { expect in
                var map = SpeakerMap()
                let line = Utterance(
                    id: "u1", start: 10, end: 14, track: .remote, rawSpeakerLabel: nil,
                    speakerKey: "remote-001_speaker_02", text: "friday",
                    chunkID: "remote_full", model: "whisperkit"
                )
                map.overrideUtterance(
                    line, with: SpeakerAssignment(displayName: "Chris", origin: .human), at: Date()
                )
                map.assign("Samantha", to: "remote-001_speaker_02")
                expect.equal(map.resolvedName(for: line), "Chris")
            },

            test("a correction survives the transcript being reassembled differently") { expect in
                // Anchored to a moment, not to a line identifier, because
                // re-analysing speakers moves where turns begin and end.
                var map = SpeakerMap()
                let before = Utterance(
                    id: "remote_full-3", start: 20, end: 26, track: .remote, rawSpeakerLabel: nil,
                    speakerKey: "remote-001_speaker_00", text: "we can have that friday",
                    chunkID: "remote_full", model: "whisperkit"
                )
                map.overrideUtterance(
                    before, with: SpeakerAssignment(displayName: "Chris", origin: .human), at: Date()
                )

                // The same moment, in a line with a different identifier, a
                // different cluster and different boundaries.
                let after = Utterance(
                    id: "remote_full-11", start: 22, end: 24, track: .remote, rawSpeakerLabel: nil,
                    speakerKey: "remote-002_speaker_04", text: "we can have that friday",
                    chunkID: "remote_full", model: "whisperkit"
                )
                expect.equal(map.resolvedName(for: after), "Chris")
            },

            test("a correction survives the corrected line being split in two") { expect in
                // Re-analysing at a higher speaker count splits turns. Anchored
                // to the midpoint alone, the correction landed on whichever half
                // happened to contain that instant and vanished from the other.
                var map = SpeakerMap()
                let before = Utterance(
                    id: "u1", start: 10, end: 14, track: .remote, rawSpeakerLabel: nil,
                    speakerKey: "remote-001_speaker_00", text: "and then we shipped it on friday",
                    chunkID: "remote_full", model: "whisperkit"
                )
                map.overrideUtterance(
                    before, with: SpeakerAssignment(displayName: "Chris", origin: .human), at: Date()
                )

                let firstHalf = Utterance(
                    id: "u9", start: 10, end: 12, track: .remote, rawSpeakerLabel: nil,
                    speakerKey: "remote-002_speaker_03", text: "and then we",
                    chunkID: "remote_full", model: "whisperkit"
                )
                let secondHalf = Utterance(
                    id: "u10", start: 12, end: 14, track: .remote, rawSpeakerLabel: nil,
                    speakerKey: "remote-002_speaker_04", text: "shipped it on friday",
                    chunkID: "remote_full", model: "whisperkit"
                )
                expect.equal(map.resolvedName(for: firstHalf), "Chris")
                expect.equal(map.resolvedName(for: secondHalf), "Chris")

                // And a line the correction never covered is untouched.
                let elsewhere = Utterance(
                    id: "u11", start: 30, end: 34, track: .remote, rawSpeakerLabel: nil,
                    speakerKey: "remote-002_speaker_05", text: "different turn",
                    chunkID: "remote_full", model: "whisperkit"
                )
                expect.equal(map.resolvedName(for: elsewhere), "Speaker 6")
            },

            test("correcting the same line twice leaves one correction") { expect in
                var map = SpeakerMap()
                let line = Utterance(
                    id: "u1", start: 0, end: 4, track: .remote, rawSpeakerLabel: nil,
                    speakerKey: "remote-001_speaker_00", text: "x", chunkID: "c", model: "m"
                )
                for name in ["Chris", "Samantha", "John"] {
                    map.overrideUtterance(
                        line, with: SpeakerAssignment(displayName: name, origin: .human), at: Date()
                    )
                }
                expect.equal(map.utteranceOverrides.count, 1)
                expect.equal(map.resolvedName(for: line), "John")

                map.clearOverride(for: line)
                expect.isTrue(map.utteranceOverrides.isEmpty)
                expect.equal(map.resolvedName(for: line), "Speaker 1")
            },

            test("a correction on one track does not reach the same moment on the other") { expect in
                var map = SpeakerMap()
                let remote = Utterance(
                    id: "r", start: 10, end: 14, track: .remote, rawSpeakerLabel: nil,
                    speakerKey: "k", text: "x", chunkID: "c", model: "m"
                )
                let mic = Utterance(
                    id: "m", start: 10, end: 14, track: .mic, rawSpeakerLabel: nil,
                    speakerKey: SpeakerLabel.localUser, text: "y", chunkID: "c", model: "m"
                )
                map.overrideUtterance(
                    remote, with: SpeakerAssignment(displayName: "Chris", origin: .human), at: Date()
                )
                expect.equal(map.resolvedName(for: remote), "Chris")
                expect.equal(map.resolvedName(for: mic), "Me")
            },

            test("the precedence of automatic sources is enforced when they are written") { expect in
                var map = SpeakerMap()
                let key = "remote-001_speaker_00"

                map.applySuggestion(
                    SpeakerAssignment(displayName: "Guessed", origin: .ai), for: key
                )
                map.applySuggestion(
                    SpeakerAssignment(displayName: "Recognized", origin: .voiceProfile), for: key
                )
                expect.equal(map.displayName(for: key), "Recognized", "a voice match beats a guess")

                map.applySuggestion(
                    SpeakerAssignment(displayName: "Guessed again", origin: .ai), for: key
                )
                expect.equal(
                    map.displayName(for: key), "Recognized",
                    "a later textual guess must not undo a voice match"
                )

                map.assign("Chris", to: key)
                map.applySuggestion(
                    SpeakerAssignment(displayName: "Someone else", origin: .voiceProfile), for: key
                )
                expect.equal(map.displayName(for: key), "Chris", "a person's answer is final")

                var mine = SpeakerMap.withLocalUser(named: "Andrew")
                mine.applySuggestion(
                    SpeakerAssignment(displayName: "Not me", origin: .voiceProfile),
                    for: SpeakerLabel.localUser
                )
                expect.equal(
                    mine.displayName(for: SpeakerLabel.localUser), "Andrew",
                    "the microphone track is not a guess"
                )
            },

            test("a stored icon ligature is dropped when the meeting is rebuilt") { expect in
                // The map on disk still holds what the extension sent before it
                // was fixed, and `sensors.raw.json` is immutable, so nothing
                // else takes these names back out: applying sensor names only
                // ever adds. Rebuilding a Meet recording from 3 September 2026
                // would otherwise keep showing four people as `keep_outline`.
                var map = SpeakerMap()
                map.applySuggestion(
                    SpeakerAssignment(
                        displayName: "keep_outline", origin: .sensor,
                        participantID: "spaces/x/devices/406",
                        provenance: SpeakerProvenance(source: .sensor)
                    ),
                    for: "remote-001_speaker_01"
                )
                map.applySuggestion(
                    SpeakerAssignment(
                        displayName: "frame_person", origin: .sensor,
                        provenance: SpeakerProvenance(source: .sensor)
                    ),
                    for: SpeakerLabel.sensor(participantID: "spaces/x/devices/411")
                )
                map.applySuggestion(
                    SpeakerAssignment(displayName: "Ada Lovelace", origin: .sensor),
                    for: "remote-001_speaker_02"
                )
                map.assign("keep_outline", to: "remote-001_speaker_03")

                expect.equal(map.dropIconNamedSensorEntries(), 2)
                expect.isNil(map.displayName(for: "remote-001_speaker_01"))
                expect.isNil(
                    map.displayName(for: SpeakerLabel.sensor(participantID: "spaces/x/devices/411"))
                )
                expect.equal(
                    map.displayName(for: "remote-001_speaker_02"), "Ada Lovelace",
                    "a real name from the same source is untouched"
                )
                expect.equal(
                    map.displayName(for: "remote-001_speaker_03"), "keep_outline",
                    "a name a person typed is theirs, however odd it looks"
                )
            },

            test("renaming an identity updates its cached name everywhere in one meeting") { expect in
                var map = SpeakerMap()
                let identity = IdentityID(17)
                map.assign(
                    SpeakerAssignment(
                        displayName: "Anonymous #17", origin: .anonymousVoice, identityID: identity
                    ),
                    to: "remote-001_speaker_00"
                )
                let line = Utterance(
                    id: "u1", start: 0, end: 4, track: .remote, rawSpeakerLabel: nil,
                    speakerKey: "remote-001_speaker_01", text: "x", chunkID: "c", model: "m"
                )
                map.overrideUtterance(
                    line,
                    with: SpeakerAssignment(
                        displayName: "Anonymous #17", origin: .human, identityID: identity
                    ),
                    at: Date()
                )
                expect.equal(map.referencedIdentities, [identity])

                expect.isTrue(map.refreshName(of: identity, to: "Samantha Lee"))
                expect.equal(map.displayName(for: "remote-001_speaker_00"), "Samantha Lee")
                expect.equal(map.resolvedName(for: line), "Samantha Lee")
                expect.isFalse(
                    map.refreshName(of: IdentityID(99), to: "Nobody"),
                    "an identity this meeting never saw changes nothing"
                )
            },

            test("renaming a person reaches the meetings that saw the merged one") { expect in
                let (store, storeRoot) = try SpeakerIdentityTests.makeStore()
                defer { try? FileManager.default.removeItem(at: storeRoot) }
                let ann = try await store.createPerson(name: "Ann")
                let bob = try await store.createPerson(name: "Bob")
                for (identity, meeting) in [(ann, "m1"), (bob, "m2")] {
                    try await store.recordOccurrence(
                        meetingID: meeting, clusterID: "remote-001_speaker_00", track: .remote,
                        speechSeconds: 120, embedding: nil, model: nil, resolution: nil,
                        identityID: identity.id, source: .human,
                        humanVerified: true, wasExpectedParticipant: false
                    )
                }
                try await store.merge(ann.id, into: bob.id)

                // The meeting keeps the link it was written with, so a rename
                // of the survivor has to reach the merged identifier too.
                let family = try await store.family(of: bob.id)
                expect.isTrue(family.contains(ann.id), "the family carries what was merged in")

                var map = SpeakerMap()
                map.assign("Bob", to: "remote-001_speaker_00", identityID: ann.id)
                _ = try await store.rename(bob.id, to: "Bob Tran")
                let current = try await store.current(bob.id)

                var changed = false
                for member in family
                where map.refreshName(of: member, to: current?.resolvedName ?? "") {
                    changed = true
                }
                expect.isTrue(changed, "the entry written under the merged id is found")
                expect.equal(map.displayName(for: "remote-001_speaker_00"), "Bob Tran")
            },

            test("a speaker map written before line corrections existed still loads") { expect in
                let legacy = """
                    {"version":1,"entries":{"local":{"displayName":"Andrew","origin":"deterministic"}}}
                    """
                let map = try JSONDecoder().decode(SpeakerMap.self, from: Data(legacy.utf8))
                expect.equal(map.entries.count, 1)
                expect.equal(map.displayName(for: SpeakerLabel.localUser), "Andrew")
                expect.isTrue(map.utteranceOverrides.isEmpty)
            },

            test("correcting one line leaves an overlapping neighbour alone") { expect in
                // Chunks overlap by eight seconds and near-duplicate text
                // survives when it is not similar enough to drop, so two
                // utterances on one track routinely share a moment.
                func line(
                    _ id: String, _ start: Double, _ end: Double, _ text: String, chunk: String
                ) -> Utterance {
                    Utterance(
                        id: id, start: start, end: end, track: .remote, rawSpeakerLabel: nil,
                        speakerKey: "remote-001_speaker_00", text: text, chunkID: chunk, model: "m"
                    )
                }
                // The tail of one chunk and the fuller version from the next.
                let tail = line("u1", 1_130, 1_134, "so I think we should", chunk: "chunk_000")
                let full = line(
                    "u2", 1_130, 1_138, "so I think we should ship it on friday",
                    chunk: "chunk_001"
                )

                var map = SpeakerMap()
                map.overrideUtterance(
                    full,
                    with: SpeakerAssignment(displayName: "Chris", origin: .human),
                    at: Date()
                )
                expect.equal(map.resolvedName(for: full), "Chris")
                expect.notEqual(
                    map.resolvedName(for: tail), "Chris",
                    "a line the user never touched keeps its own speaker"
                )

                // And correcting the shorter line does not delete the longer
                // one's correction.
                map.overrideUtterance(
                    tail,
                    with: SpeakerAssignment(displayName: "Dana", origin: .human),
                    at: Date()
                )
                expect.equal(map.resolvedName(for: tail), "Dana")
                expect.equal(map.resolvedName(for: full), "Chris")
            },

            test("a correction survives the line being split in two") { expect in
                func line(_ id: String, _ start: Double, _ end: Double) -> Utterance {
                    Utterance(
                        id: id, start: start, end: end, track: .remote, rawSpeakerLabel: nil,
                        speakerKey: "remote-001_speaker_00", text: "x", chunkID: "c", model: "m"
                    )
                }
                var map = SpeakerMap()
                map.overrideUtterance(
                    line("u1", 10, 20),
                    with: SpeakerAssignment(displayName: "Chris", origin: .human),
                    at: Date()
                )
                // Re-assembly splits the turn where the speaker changed.
                expect.equal(map.resolvedName(for: line("u1", 10, 15)), "Chris")
                expect.equal(map.resolvedName(for: line("u2", 15, 20)), "Chris")
            },

            test("words no interval claimed are not filed under a real cluster") { expect in
                let raw = RawTranscript(chunks: [RawTranscriptChunk(
                    id: "remote_full", track: .remote, timelineOffset: 0, durationSeconds: 10,
                    model: "whisper", responseFormat: "verbose_json",
                    segments: [RawTranscriptSegment(
                        start: 0, end: 6, text: "yeah we ship friday", speaker: nil,
                        words: [
                            // Dropped by the diarizer: 0.8s before the first interval.
                            RawTranscriptWord(start: 0.0, end: 0.2, text: " yeah"),
                            RawTranscriptWord(start: 1.2, end: 1.6, text: " we"),
                            RawTranscriptWord(start: 1.7, end: 2.1, text: " ship"),
                            RawTranscriptWord(start: 2.2, end: 2.8, text: " friday"),
                        ]
                    )]
                )])
                var diarization = RawDiarization()
                diarization.setActive(DiarizationRun(
                    id: "remote-001", track: .remote, backend: "fluidaudio",
                    producedAt: Date(), timelineOffset: 0, configuration: [:],
                    clusters: [DiarizationCluster(id: "remote-001_speaker_00", speechSeconds: 5)],
                    intervals: [DiarizationInterval(
                        start: 1.0, end: 6.0, clusterID: "remote-001_speaker_00"
                    )]
                ))

                let transcript = TranscriptAssembler().assemble(
                    raw: raw, diarization: diarization,
                    micTrackIsLocalUser: true, generatedAt: Date()
                )
                let keys = Set(transcript.speakerKeys)
                for key in keys where key != SpeakerLabel.localUser {
                    expect.isFalse(
                        key.hasSuffix("_speaker_00") && !key.hasPrefix("remote-001"),
                        "no key outside the run may render as one of its clusters: \(key)"
                    )
                }
                if let stray = keys.first(where: { $0.hasSuffix(SpeakerLabel.unattributed) }) {
                    expect.equal(SpeakerMap.fallbackName(for: stray), "Unattributed")
                }
            },
        ])
    }

    static var all: [Suite] { [alignmentSuite, assemblySuite, layerSuite] }
}
