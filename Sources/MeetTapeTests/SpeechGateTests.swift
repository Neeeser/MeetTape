import Foundation
import MeetTapeCore
import MeetTapeServices
import TestKit

/// Pins the guard against words the local user never said.
///
/// Every case here carries measurements from meetings on disk. A 29-minute
/// Google Meet where the user spoke once, at 0:24 to 4:11, came back from
/// gpt-4o-transcribe-diarize with 36 further segments on the microphone track,
/// among them "We'll be right back.", "Thanks for watching!" and "Good
/// evening.". A second meeting's whole microphone track was 125 consecutive
/// segments of " ♪". A third produced "Thank you." six times for a user who
/// never spoke at all. All three were rendered as the user's own words.
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
            test("the far end coming back through the speakers is not the user talking") { expect in
                // 445.97 to 446.42 of the audited meeting: "We'll be right
                // back." over a microphone reading -46.7 dBFS while the far
                // end's own track reads -16.5. Thirty decibels of separation is
                // one voice leaking into the other's microphone, not two people
                // speaking.
                expect.equal(
                    LocalSpeechPolicy.decide(
                        text: "We'll be right back.",
                        reading: SpeechReading(
                            speechProbability: 0.211, loudestLocalDB: -46.7,
                            loudestFarDB: -16.5, medianDifferenceDB: -31.4
                        )
                    ),
                    .notSpoken
                )
            },

            test("a voice the detector is sure of is still dropped when the far end is louder") { expect in
                // 971.19 of the same meeting: "This is my brother," invented
                // over the far end's leakage. The detector scores it 0.994,
                // correctly: leakage is speech. Only the comparison between the
                // two tracks says whose it is, which is why the detector cannot
                // carry this alone.
                expect.equal(
                    LocalSpeechPolicy.decide(
                        text: "This is my brother,",
                        reading: SpeechReading(
                            speechProbability: 0.994, loudestLocalDB: -35.3,
                            loudestFarDB: -20.6, medianDifferenceDB: -21.3
                        )
                    ),
                    .notSpoken
                )
            },

            test("words over audio holding no voice are dropped whatever the levels say") { expect in
                // 839.25: "to see if we can get this done." over audio the
                // detector scores 0.002. No level comparison catches this one,
                // which is why the detector is in the set.
                expect.equal(
                    LocalSpeechPolicy.decide(
                        text: "to see if we can get this done.",
                        reading: SpeechReading(
                            speechProbability: 0.002, loudestLocalDB: -38.3,
                            loudestFarDB: -22.8, medianDifferenceDB: -33.1
                        )
                    ),
                    .notSpoken
                )
            },

            test("the user's own sentence survives the far end talking under it") { expect in
                // 213.01 to 217.61: "I'll send a video in the slack later
                // today", with the microphone 12 dB above the far end at its
                // peak and 53 dB above it over most of the span.
                expect.equal(
                    LocalSpeechPolicy.decide(
                        text: "I'll send a video in the slack later today",
                        reading: SpeechReading(
                            speechProbability: 1.0, loudestLocalDB: -11.2,
                            loudestFarDB: -23.2, medianDifferenceDB: 53.4
                        )
                    ),
                    .spoken
                )
            },

            test("a word quieter than the far end at its peak survives on the rest of the span") { expect in
                // 26.70: the user's "Good" while the far end is mid-sentence.
                // The peak comparison alone reads -9.4 and would drop it; over
                // the span the microphone is 27 dB above the far end, which is
                // what a person speaking into their own microphone looks like.
                expect.equal(
                    LocalSpeechPolicy.decide(
                        text: "Good",
                        reading: SpeechReading(
                            speechProbability: 0.766, loudestLocalDB: -30.2,
                            loudestFarDB: -20.8, medianDifferenceDB: 27.3
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
                        reading: SpeechReading(
                            speechProbability: 0.9, loudestLocalDB: -50, loudestFarDB: -80,
                            medianDifferenceDB: 30
                        )
                    ),
                    .notSpoken
                )
            },

            test("one track keeps what the detector heard") { expect in
                // Imported audio has no far end to be quieter than, so the
                // comparison cannot run and the detector decides alone.
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

            test("a machine with no detector still judges on the two tracks") { expect in
                // The detector clause cannot speak either way where nothing
                // ran, and skipping the segment instead would empty the local
                // track of a meeting processed while the model was still
                // downloading.
                expect.equal(
                    LocalSpeechPolicy.decide(
                        text: "Yeah, we can definitely do today.",
                        reading: SpeechReading(
                            speechProbability: nil, loudestLocalDB: -12.3,
                            loudestFarDB: -51.2, medianDifferenceDB: 55.4
                        )
                    ),
                    .spoken
                )
                expect.equal(
                    LocalSpeechPolicy.decide(
                        text: "Good evening.",
                        reading: SpeechReading(
                            speechProbability: nil, loudestLocalDB: -28.2,
                            loudestFarDB: -14.6, medianDifferenceDB: -27.8
                        )
                    ),
                    .notSpoken
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

            test("a meeting with one track reports no far end") { expect in
                let evidence = SpeechEvidence(
                    levelWindowSeconds: 0.25, speechWindowSeconds: 0.256,
                    micLevels: [Int8](repeating: -20, count: 40), remoteLevels: [],
                    micSpeech: [Int8](repeating: 90, count: 40), detector: "silero"
                )
                let reading = try expect.unwrap(evidence.reading(from: 1, to: 2))
                expect.isTrue(reading.loudestFarDB == nil)
                expect.isTrue(reading.medianDifferenceDB == nil)
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
                // the 36 fabrications that followed it. Before this guard all
                // five were rendered under the user's name.
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
                        Span(start: 703.86, end: 704.20, mic: -49, far: -26, probability: 0.94),
                        Span(start: 839.25, end: 840.75, mic: -38, far: -23, probability: 0.00),
                        Span(start: 971.19, end: 972.89, mic: -35, far: -21, probability: 0.99),
                    ]),
                    micTrackIsLocalUser: true, generatedAt: Date(timeIntervalSince1970: 0)
                )
                expect.equal(
                    transcript.utterances.map(\.text),
                    ["Hey, Brian, how's it going?", "I'll send a video in the slack later today"],
                    "only the two turns the user spoke"
                )
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
                // leakage of anybody else, and it has no second track to be
                // compared against.
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
                expect.isTrue(
                    evidence.remoteLevels.count > leadInWindows,
                    "and its own audio follows the padding"
                )
                expect.isTrue(
                    evidence.remoteLevels[leadInWindows] > floor,
                    "the far end's tone begins at second twelve"
                )
                expect.isTrue(evidence.micSpeech.isEmpty, "no detector, no readings")
                expect.isTrue(evidence.detector == nil)
            },

            test("a far end that stopped recording first leaves the rest to the detector") { expect in
                // The process tap delivers nothing while the application is
                // idle, so the far end's track can end while the microphone is
                // still recording. There is no evidence about the far end after
                // that, and inventing some would be the guard deciding on a
                // measurement nobody made.
                let evidence = SpeechEvidence(
                    levelWindowSeconds: 0.25, speechWindowSeconds: 0.256,
                    micLevels: [Int8](repeating: -20, count: 400),
                    remoteLevels: [Int8](repeating: -18, count: 40),
                    micSpeech: [Int8](repeating: 95, count: 400), detector: "silero"
                )
                let during = try expect.unwrap(evidence.reading(from: 2, to: 3))
                expect.isTrue(during.loudestFarDB != nil, "compared while both tracks ran")
                expect.equal(
                    LocalSpeechPolicy.decide(text: "so that is the plan", reading: during),
                    .notSpoken,
                    "quieter than the far end, so not the user"
                )

                let after = try expect.unwrap(evidence.reading(from: 40, to: 41))
                expect.isTrue(after.loudestFarDB == nil, "nothing to compare against")
                expect.equal(
                    LocalSpeechPolicy.decide(text: "so that is the plan", reading: after),
                    .spoken,
                    "the detector decides alone rather than the clause deciding silently"
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
