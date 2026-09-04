import Foundation
import PipitCore
import PipitServices
import TestKit

/// Pins the guard against words the local user never said.
///
/// Every case here carries measurements from meetings on disk. A 29-minute
/// Google Meet where the user spoke once, at 0:24 to 4:11, came back from
/// gpt-4o-transcribe-diarize with 37 further segments on the microphone track,
/// among them "We'll be right back.", "Thanks for watching!" and "Good
/// evening.". A second meeting's whole microphone track was 125 consecutive
/// segments of " ♪". A third produced "Thank you." six times for a user who
/// never spoke at all. All three were rendered as the user's own words.
///
/// The far end leaking through the speakers is not judged here. It is
/// subtracted out of the microphone by the cleaner before transcription, so the
/// levels a segment is read against are the user's own.
enum SpeechGateTests {
    /// One span of the recording, described the way it was measured.
    struct Span {
        var start: Double
        var end: Double
        /// Loudest window on the microphone, in dBFS.
        var mic: Double
        /// Loudest window on the far end's own track over the same span.
        var far: Double
        /// The detector's highest reading over the span.
        var probability: Double
    }

    static let windowSeconds = SpeechEvidenceBuilder.levelWindowSeconds
    static let speechWindowSeconds = 0.256

    /// Builds evidence for a recording of `seconds`, with the given spans
    /// written over a background of near-silence on both tracks.
    static func evidence(seconds: Double, spans: [Span], detector: String? = "silero") -> SpeechEvidence {
        let levelCount = Int(seconds / windowSeconds)
        let speechCount = Int(seconds / speechWindowSeconds)
        var mic = [Int8](repeating: -70, count: levelCount)
        var far = [Int8](repeating: -70, count: levelCount)
        var speech = [Int8](repeating: 1, count: speechCount)
        for span in spans {
            for index in Int(span.start / windowSeconds)...Int(span.end / windowSeconds)
            where index < levelCount {
                mic[index] = Int8(span.mic.rounded())
                far[index] = Int8(span.far.rounded())
            }
            for index in Int(span.start / speechWindowSeconds)...Int(span.end / speechWindowSeconds)
            where index < speechCount {
                speech[index] = Int8((span.probability * 100).rounded())
            }
        }
        return SpeechEvidence(
            levelWindowSeconds: windowSeconds, speechWindowSeconds: speechWindowSeconds,
            micLevels: mic, remoteLevels: far, micSpeech: detector == nil ? [] : speech,
            detector: detector
        )
    }

    static func word(_ text: String, _ start: Double, _ end: Double) -> RawTranscriptWord {
        RawTranscriptWord(start: start, end: end, text: text)
    }

    static func chunk(_ segments: [(Double, Double, String)]) -> RawTranscriptChunk {
        RawTranscriptChunk(
            id: "mic_chunk_001", track: .mic, timelineOffset: 0, durationSeconds: 1149,
            model: "gpt-4o-transcribe-diarize", responseFormat: "diarized_json",
            segments: segments.map {
                RawTranscriptSegment(start: $0.0, end: $0.1, text: $0.2, speaker: "A")
            }
        )
    }

    static var policySuite: Suite {
        Suite("SpeechGate/policy", [
            test("words over audio holding no voice are dropped whatever the levels say") { expect in
                // Two of the 37 fabrications sit on audio the detector scores at
                // 0.000 and 0.002, and one of them is louder than anything the
                // user said all meeting.
                expect.equal(
                    LocalSpeechPolicy.decide(
                        text: "to see if we can get this done.",
                        reading: SpeechReading(speechProbability: 0.002, loudestLocalDB: -12)
                    ),
                    .notSpoken
                )
            },

            test("a sentence the detector is sure of is the user's, whatever the far end read") { expect in
                // On a cleaned microphone the far end is gone, so a loud far end
                // under the user's words says nothing about whose they are.
                expect.equal(
                    LocalSpeechPolicy.decide(
                        text: "Yeah but I mean it's not like it's impossible",
                        reading: SpeechReading(
                            speechProbability: 0.99, loudestLocalDB: -31, loudestFarDB: -18
                        )
                    ),
                    .spoken
                )
            },

            test("a segment with no letters or digits in it is not words") { expect in
                // One meeting's whole microphone track came back as 125
                // consecutive five-second segments of " ♪".
                // `DegenerateTranscriptPolicy` scores it at zero repetition,
                // because it strips everything that is not alphanumeric before
                // counting and then has nothing left to count.
                expect.isFalse(LocalSpeechPolicy.holdsWords(" ♪"))
                expect.close(DegenerateTranscriptPolicy.repeatedShare(of: " ♪ ♪ ♪ ♪"), 0, tolerance: 0.001)
                expect.equal(
                    LocalSpeechPolicy.decide(
                        text: " ♪",
                        reading: SpeechReading(speechProbability: 0.9, loudestLocalDB: -50, loudestFarDB: -80)
                    ),
                    .notSpoken
                )
            },

            test("one track keeps what the detector heard") { expect in
                expect.equal(
                    LocalSpeechPolicy.decide(
                        text: "so I spent the morning on the migration",
                        reading: SpeechReading(speechProbability: 0.98, loudestLocalDB: -22)
                    ),
                    .spoken
                )
                expect.equal(
                    LocalSpeechPolicy.decide(
                        text: "Thanks for watching!",
                        reading: SpeechReading(speechProbability: 0.05, loudestLocalDB: -55)
                    ),
                    .notSpoken
                )
            },

            test("a machine with no detector keeps every segment") { expect in
                // Nothing can say the words are invented, and dropping them
                // instead would empty the local track of a meeting processed
                // while the model was still downloading.
                expect.equal(
                    LocalSpeechPolicy.decide(
                        text: "Good evening.",
                        reading: SpeechReading(
                            speechProbability: nil, loudestLocalDB: -28.2, loudestFarDB: -14.6
                        )
                    ),
                    .spoken
                )
            },
        ])
    }

    static var evidenceSuite: Suite {
        Suite("SpeechGate/evidence", [
            test("a reading covers the whole span, not the window its start lands in") { expect in
                let evidence = evidence(seconds: 60, spans: [
                    Span(start: 10, end: 11, mic: -12, far: -50, probability: 0.99),
                ])
                let reading = try expect.unwrap(evidence.reading(from: 9.5, to: 11.5))
                expect.close(reading.loudestLocalDB, -12, tolerance: 0.001, "the loud window is found")
                expect.close(reading.loudestFarDB ?? 0, -50, tolerance: 0.001)
                expect.close(reading.speechProbability ?? 0, 0.99, tolerance: 0.001)
            },

            test("a span past the end of the recording is unmeasured, not silent") { expect in
                // A backend can time a segment past the audio it was given.
                // Reading that as silence would drop words for want of evidence
                // rather than because of it.
                let evidence = evidence(seconds: 10, spans: [])
                expect.isTrue(evidence.reading(from: 30, to: 31) == nil)
            },

            test("evidence written with the echo series still reads") { expect in
                // Every meeting measured before the series was removed carries
                // it. The file has to decode, and the series is left unread.
                let json = """
                {"version":1,"levelWindowSeconds":0.25,"speechWindowSeconds":0.256,
                 "micLevels":[-20,-21],"remoteLevels":[-30,-31],"micSpeech":[90,91],
                 "micEchoReturnLoss":[4,5],"detector":"silero"}
                """
                let decoded = try JSONDecoder().decode(SpeechEvidence.self, from: Data(json.utf8))
                expect.equal(decoded.micLevels, [-20, -21])
                expect.equal(decoded.remoteLevels, [-30, -31])
                expect.equal(decoded.micSpeech, [90, 91])
            },

            test("a meeting with one track reports no far end") { expect in
                let evidence = SpeechEvidence(
                    levelWindowSeconds: 0.25, speechWindowSeconds: 0.256,
                    micLevels: [Int8](repeating: -20, count: 40), remoteLevels: [],
                    micSpeech: [Int8](repeating: 90, count: 40), detector: "silero"
                )
                let reading = try expect.unwrap(evidence.reading(from: 1, to: 2))
                expect.isTrue(reading.loudestFarDB == nil)
            },

            test("a far end recorded as silence is read as no far end at all") { expect in
                // A tap that produced nothing writes a full-length track of the
                // floor. That is not a reference, and reading it as one made
                // every comparison against it trivially true.
                let evidence = SpeechEvidence(
                    levelWindowSeconds: 0.25, speechWindowSeconds: 0.256,
                    micLevels: [Int8](repeating: -20, count: 40),
                    remoteLevels: [Int8](repeating: -120, count: 40),
                    micSpeech: [Int8](repeating: 90, count: 40), detector: "silero"
                )
                expect.isFalse(evidence.farEndCarriesSignal)
                let reading = try expect.unwrap(evidence.reading(from: 1, to: 2))
                expect.isTrue(reading.loudestFarDB == nil)
            },

            test("digital silence reads as the floor rather than as minus infinity") { expect in
                expect.equal(
                    SpeechEvidence.decibels(rms: 0), Int8(EmptyTranscriptPolicy.silenceFloorDBFS)
                )
                expect.equal(SpeechEvidence.decibels(rms: 1), 0)
                expect.equal(SpeechEvidence.decibels(rms: 0.1), -20)
            },
        ])
    }

    static var assemblySuite: Suite {
        Suite("SpeechGate/assembly", [
            test("the standup turn survives and the invented filler after it does not") { expect in
                // The audited meeting, cut down: one real turn, then four of
                // the 37 fabrications that followed it. Before this guard all
                // five were rendered under the user's name. The microphone is
                // the cleaned one, so the fabricated spans sit over audio the
                // detector does not call speech.
                let raw = RawTranscript(chunks: [chunk([
                    (24.95, 27.25, "Hey, Brian, how's it going?"),
                    (213.01, 217.61, "I'll send a video in the slack later today"),
                    (445.97, 446.42, "We'll be right back."),
                    (703.86, 704.20, "Thanks for watching!"),
                    (839.25, 840.75, "to see if we can get this done."),
                    (971.19, 972.89, "This is my brother,"),
                ])])
                let transcript = TranscriptAssembler().assemble(
                    raw: raw, diarization: RawDiarization(),
                    speech: evidence(seconds: 1000, spans: [
                        Span(start: 24.95, end: 27.25, mic: -15, far: -58, probability: 1.0),
                        Span(start: 213.01, end: 217.61, mic: -11, far: -23, probability: 1.0),
                        Span(start: 445.97, end: 446.42, mic: -47, far: -17, probability: 0.21),
                        Span(start: 703.86, end: 704.20, mic: -49, far: -26, probability: 0.12),
                        Span(start: 839.25, end: 840.75, mic: -38, far: -23, probability: 0.00),
                        Span(start: 971.19, end: 972.89, mic: -35, far: -21, probability: 0.30),
                    ]),
                    micTrackIsLocalUser: true, generatedAt: Date(timeIntervalSince1970: 0)
                )
                expect.equal(
                    transcript.utterances.map(\.text),
                    ["Hey, Brian, how's it going?", "I'll send a video in the slack later today"],
                    "only the two turns the user spoke"
                )
            },

            test("a turn the far end also holds is kept whole") { expect in
                // The far end's own words used to be cut out of the local track
                // by matching text. The cleaner removes the far end from the
                // audio instead, so a local segment is judged on its own
                // detector reading and never against what the far end said.
                let remote = RawTranscriptChunk(
                    id: "remote_chunk_001", track: .remote, timelineOffset: 0,
                    durationSeconds: 1000, model: "gpt-4o-transcribe-diarize",
                    responseFormat: "diarized_json",
                    segments: [RawTranscriptSegment(
                        start: 100, end: 104, text: "so what I would do is run three nodes", speaker: "A"
                    )]
                )
                let local = chunk([(101, 103, "so what I would do is run three nodes")])
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [remote, local]), diarization: RawDiarization(),
                    speech: evidence(seconds: 1000, spans: [
                        Span(start: 101, end: 103, mic: -20, far: -18, probability: 0.97),
                    ]),
                    micTrackIsLocalUser: true, generatedAt: Date(timeIntervalSince1970: 0)
                )
                expect.equal(transcript.utterances.filter { $0.track == .mic }.count, 1)
            },

            test("a meeting with no evidence assembles exactly as it did before") { expect in
                // Every meeting already on disk. Measuring nothing must not
                // read as measuring silence.
                let raw = RawTranscript(chunks: [chunk([
                    (445.97, 446.42, "We'll be right back."),
                ])])
                let transcript = TranscriptAssembler().assemble(
                    raw: raw, diarization: RawDiarization(), speech: nil,
                    micTrackIsLocalUser: true, generatedAt: Date(timeIntervalSince1970: 0)
                )
                expect.equal(transcript.utterances.count, 1, "kept, for want of anything to judge it by")
            },

            test("the far end's own track is never gated") { expect in
                // The guard exists because a fabrication on the microphone is
                // shown as something the user said. The far end arrives on its
                // own tap, which is silent when nobody speaks and carries no
                // leakage of anybody else.
                let remote = RawTranscriptChunk(
                    id: "remote_chunk_001", track: .remote, timelineOffset: 0,
                    durationSeconds: 1000, model: "gpt-4o-transcribe-diarize",
                    responseFormat: "diarized_json",
                    segments: [RawTranscriptSegment(
                        start: 445.97, end: 446.42, text: "So that is the plan for Pure.", speaker: "A"
                    )]
                )
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [remote]), diarization: RawDiarization(),
                    speech: evidence(seconds: 1000, spans: [
                        Span(start: 445.97, end: 446.42, mic: -47, far: -17, probability: 0.21),
                    ]),
                    micTrackIsLocalUser: true, generatedAt: Date(timeIntervalSince1970: 0)
                )
                expect.equal(transcript.utterances.count, 1, "the far end keeps its words")
            },
        ])
    }

    static var measurementSuite: Suite {
        Suite("SpeechGate/measurement", [
            test("each track's measurements are moved onto the meeting timeline") { expect in
                // The two tracks do not start at the same instant, and the
                // transcript segments this is compared against already carry
                // their track's lead-in. A profile measured from each track's
                // own zero would put the microphone and the far end twelve
                // seconds out of step, and every level comparison would then be
                // between two different moments.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(
                    root: root, seconds: 6, remoteStartOffset: 12
                )
                let evidence = try await SpeechEvidenceBuilder.build(
                    store: meeting.store, metadata: meeting.metadata,
                    timeline: try meeting.store.readTimeline(), detector: nil
                )

                let floor = Int8(EmptyTranscriptPolicy.silenceFloorDBFS)
                let leadInWindows = Int(12 / SpeechEvidenceBuilder.levelWindowSeconds)
                expect.isTrue(
                    evidence.micLevels.first.map { $0 > floor } ?? false,
                    "the earlier track's tone starts at the timeline's zero"
                )
                expect.equal(
                    Array(evidence.remoteLevels.prefix(leadInWindows)),
                    Array(repeating: floor, count: leadInWindows),
                    "the later track reads as nothing until it started"
                )
                let afterPadding = Array(evidence.remoteLevels.dropFirst(leadInWindows))
                expect.isTrue(!afterPadding.isEmpty, "and its own audio follows the padding")
                // The first window after the padding, not any window after it:
                // padding the track twice over leaves the prefix silent too,
                // and only the boundary says how much was added.
                expect.isTrue(
                    afterPadding.first.map { $0 > floor } ?? false,
                    "the far end's tone begins at second twelve"
                )
                expect.isTrue(evidence.micSpeech.isEmpty, "no detector, no readings")
                expect.isTrue(evidence.detector == nil)
            },

            test("a recording with no far end carries no far-end series") { expect in
                // An import and an in-person session have one track.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, source: .inPerson)
                let evidence = try await SpeechEvidenceBuilder.build(
                    store: meeting.store, metadata: meeting.metadata,
                    timeline: try meeting.store.readTimeline(), detector: nil
                )
                expect.isTrue(evidence.remoteLevels.isEmpty, "no far end was recorded")
            },

            test("a far end that stopped recording first reads as absent after it stopped") { expect in
                // The process tap delivers nothing while the application is
                // idle, so the far end's track can end while the microphone is
                // still recording. There is no evidence about the far end after
                // that, and inventing some would be a measurement nobody made.
                let evidence = SpeechEvidence(
                    levelWindowSeconds: 0.25, speechWindowSeconds: 0.256,
                    micLevels: [Int8](repeating: -20, count: 400),
                    remoteLevels: [Int8](repeating: -18, count: 40),
                    micSpeech: [Int8](repeating: 95, count: 400), detector: "silero"
                )
                let during = try expect.unwrap(evidence.reading(from: 2, to: 3))
                expect.isTrue(during.loudestFarDB != nil, "measured while both tracks ran")
                let after = try expect.unwrap(evidence.reading(from: 40, to: 41))
                expect.isTrue(after.loudestFarDB == nil, "nothing recorded to read")
                expect.equal(
                    LocalSpeechPolicy.decide(text: "so that is the plan", reading: after),
                    .spoken,
                    "the detector decides"
                )
            },

            test("evidence already on disk is never measured over") { expect in
                // The stage that measures is retryable, so a failure writing the
                // transcript or the speaker map after the measurement brings it
                // round again. Without this the second attempt decodes both
                // tracks from the top for a file it already has.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root)
                let sentinel = SpeechEvidence(
                    levelWindowSeconds: 0.25, speechWindowSeconds: 0.256,
                    micLevels: [-11, -12, -13], detector: "measured-earlier"
                )
                try meeting.store.writeSpeechEvidence(sentinel)

                let backend = FakeAIBackend()
                backend.transcriptionSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "I think we change retrieval.", speaker: nil),
                ]
                backend.diarizationSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Chris here, agreed.", speaker: "A"),
                ]
                let pipeline = PipelineTests.makePipeline(
                    repository: meeting.repository, backend: backend
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                expect.equal(
                    meeting.store.readSpeechEvidence(), sentinel,
                    "what was measured before is what the meeting is judged against"
                )
            },

            test("a meeting is measured once, and only where the gate can use it") { expect in
                // Re-measuring decodes both tracks again on every re-analysis,
                // and on a machine whose detector has since been deleted it
                // would put the fabricated lines back. An imported recording's
                // microphone holds everybody, so it never reaches the gate.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root)
                let backend = FakeAIBackend()
                backend.transcriptionSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "I think we change retrieval.", speaker: nil),
                ]
                backend.diarizationSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Chris here, agreed.", speaker: "A"),
                ]
                let pipeline = PipelineTests.makePipeline(
                    repository: meeting.repository, backend: backend
                )
                await pipeline.process(meetingID: meeting.metadata.id)
                let written = try expect.unwrap(meeting.store.readSpeechEvidence())
                expect.isTrue(!written.micLevels.isEmpty, "a call is measured")

                // A rebuild reads the file rather than measuring again: the
                // levels it assembles against are the ones already on disk.
                let stamp = try FileManager.default.attributesOfItem(
                    atPath: meeting.store.layout.speechEvidence.path
                )[.modificationDate] as? Date
                try await pipeline.rebuildTranscript(meetingID: meeting.metadata.id)
                let after = try FileManager.default.attributesOfItem(
                    atPath: meeting.store.layout.speechEvidence.path
                )[.modificationDate] as? Date
                expect.equal(after, stamp, "the rebuild rewrote nothing")

                let importedRoot = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: importedRoot) }
                let imported = try PipelineTests.makeRecordedMeeting(
                    root: importedRoot, source: .imported
                )
                let importedPipeline = PipelineTests.makePipeline(
                    repository: imported.repository, backend: backend
                )
                await importedPipeline.process(meetingID: imported.metadata.id)
                expect.isTrue(
                    imported.store.readSpeechEvidence() == nil,
                    "an imported recording is never measured"
                )
            },
        ])
    }

    static var all: [Suite] { [policySuite, evidenceSuite, assemblySuite, measurementSuite] }
}
