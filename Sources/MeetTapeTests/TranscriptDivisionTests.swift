import Foundation
import MeetTapeCore
import TestKit

/// Boundaries a person put in the transcript, and the seam repeats the reader
/// would otherwise see once the lines are joined into a paragraph.
enum TranscriptDivisionTests {
    static func word(_ text: String, _ start: Double, _ end: Double) -> RawTranscriptWord {
        RawTranscriptWord(start: start, end: end, text: text)
    }

    /// "we ship on friday" as four timed words, one per second from `start`.
    static func line(
        id: String = "c1", start: Double = 0, track: CaptureTrack = .remote,
        speaker: String = "c1_speaker_00", texts: [String] = ["we", "ship", "on", "friday"],
        timed: Bool = true
    ) -> Utterance {
        let words = texts.enumerated().map {
            word(" \($0.element)", start + Double($0.offset), start + Double($0.offset) + 0.8)
        }
        return Utterance(
            id: Utterance.identifier(
                chunkID: id, track: track, start: start, end: start + Double(texts.count)
            ),
            start: start, end: start + Double(texts.count), track: track,
            rawSpeakerLabel: speaker, speakerKey: speaker,
            text: texts.joined(separator: " "), chunkID: id, model: "test",
            words: timed ? words : nil
        )
    }

    static func cut(at seconds: Double, track: CaptureTrack = .remote, chunk: String? = "c1")
        -> LineCut {
        LineCut(track: track, atSeconds: seconds, chunkID: chunk, createdAt: Date())
    }

    static var suite: Suite {
        Suite("TranscriptDivision", [
            test("a cut divides one line at the word it falls on") { expect in
                let pieces = LineDivision.divide(line(), at: [cut(at: 2)])
                expect.equal(pieces.count, 2, "one boundary, two pieces")
                expect.equal(pieces[0].text, "we ship")
                expect.equal(pieces[1].text, "on friday")
                expect.close(pieces[1].start, 2, tolerance: 0.001, "the third word's own start")
                expect.close(pieces[0].start, 0, tolerance: 0.001, "the line keeps its outer edges")
                expect.close(pieces[1].end, 4, tolerance: 0.001)
            },

            test("the pieces stay addressable and keep what the line was") { expect in
                let original = line()
                let pieces = LineDivision.divide(original, at: [cut(at: 2)])
                expect.notEqual(pieces[0].id, pieces[1].id, "two lines, two identities")
                expect.equal(
                    pieces[1].id,
                    Utterance.identifier(
                        chunkID: "c1", track: .remote, start: pieces[1].start, end: pieces[1].end
                    ),
                    "derived from where the piece sits, like any other line"
                )
                expect.equal(pieces.map(\.speakerKey), [original.speakerKey, original.speakerKey])
                expect.equal(pieces.map(\.chunkID), ["c1", "c1"])
                expect.equal(pieces[1].words?.count, 2, "each piece keeps its own words")
            },

            test("two cuts pull a phrase out and leave the words either side") { expect in
                let pieces = LineDivision.divide(
                    line(texts: ["so", "yes", "exactly", "anyway", "moving", "on"]),
                    at: [cut(at: 1), cut(at: 3)]
                )
                expect.equal(pieces.count, 3)
                expect.equal(pieces.map(\.text), ["so", "yes exactly", "anyway moving on"])
            },

            test("a line whose words were never timed is left whole") { expect in
                // A text-only backend whose aligner refused. Dividing it would
                // mean guessing where the boundary is, and a guessed span
                // decides which seconds of audio reach a voice profile.
                let pieces = LineDivision.divide(line(timed: false), at: [cut(at: 2)])
                expect.equal(pieces.count, 1)
                expect.isNil(LineDivision.boundary(in: line(timed: false), near: 2))
            },

            test("a cut on another track or another chunk divides nothing") { expect in
                expect.equal(LineDivision.divide(line(), at: [cut(at: 2, track: .mic)]).count, 1)
                expect.equal(LineDivision.divide(line(), at: [cut(at: 2, chunk: "c2")]).count, 1)
                expect.equal(
                    LineDivision.divide(line(), at: [cut(at: 9)]).count, 1, "past the end"
                )
            },

            test("a cut before the first word leaves the line whole") { expect in
                // The boundary is already there. Dividing would make a piece
                // with nothing in it.
                expect.equal(LineDivision.divide(line(), at: [cut(at: 0)]).count, 1)
                expect.isNil(LineDivision.boundary(in: line(), near: 0))
            },

            test("division applies across a transcript and keeps the order") { expect in
                let lines = [line(start: 0), line(id: "c2", start: 10)]
                let divided = LineDivision.apply([cut(at: 2)], to: lines)
                expect.equal(divided.count, 3)
                expect.equal(divided.map(\.text), ["we ship", "on friday", "we ship on friday"])
            },

            test("a correction made before the cut covers both pieces") { expect in
                // Re-assembly and re-analysis split and merge lines all the
                // time, so a correction is anchored to a span. A piece of a
                // corrected line is inside that span and keeps the name.
                var speakers = SpeakerMap()
                let original = line()
                speakers.overrideUtterance(
                    original,
                    with: SpeakerAssignment(displayName: "Dana", origin: .human),
                    at: Date()
                )
                let pieces = LineDivision.divide(original, at: [cut(at: 2)])
                expect.equal(speakers.resolvedName(for: pieces[0]), "Dana")
                expect.equal(speakers.resolvedName(for: pieces[1]), "Dana")
            },

            test("naming one piece does not confirm the other's audio") { expect in
                // What separates display from enrolment. The name is right on
                // the piece it was set on; the seconds either side belong to
                // whoever was speaking there, and must not reach a profile.
                var speakers = SpeakerMap()
                let pieces = LineDivision.divide(line(), at: [cut(at: 2)])
                speakers.overrideUtterance(
                    pieces[1],
                    with: SpeakerAssignment(displayName: "Dana", origin: .human),
                    at: Date()
                )
                expect.isTrue(speakers.confirms(pieces[1]), "the piece that was named")
                expect.isFalse(speakers.confirms(pieces[0]), "the words before the boundary")
            },

            test("the same boundary is only recorded once") { expect in
                var speakers = SpeakerMap()
                speakers.cut(cut(at: 2))
                speakers.cut(cut(at: 2))
                speakers.cut(cut(at: 2.0004))
                expect.equal(speakers.lineCuts.count, 1)
                speakers.cut(cut(at: 3))
                expect.equal(speakers.lineCuts.count, 2)
            },

            test("cuts decode as none in a map written before they existed") { expect in
                let json = Data(#"{"version":2,"entries":{},"utteranceOverrides":[]}"#.utf8)
                let map = try JSONDecoder().decode(SpeakerMap.self, from: json)
                expect.isTrue(map.lineCuts.isEmpty)
            },
        ])
    }

    /// The paragraph a block renders as, and where each word sits in it.
    static var paragraphSuite: Suite {
        Suite("TranscriptParagraph", [
            test("a block's words are located in the text the reader sees") { expect in
                let block = CombinedLineBlock(lines: [
                    CombinedLine(
                        recordingID: "rec", utterance: line(), speakerName: "Dana",
                        timelineStart: 0
                    ),
                    CombinedLine(
                        recordingID: "rec", utterance: line(id: "c1", start: 4),
                        speakerName: "Dana", timelineStart: 4
                    ),
                ])
                let (text, spans) = block.paragraph()
                expect.equal(text, "we ship on friday we ship on friday", "the lines joined")
                expect.equal(spans.count, 8, "one span per word")
                let nsText = text as NSString
                for span in spans {
                    expect.isTrue(
                        span.location + span.length <= nsText.length, "inside the paragraph"
                    )
                }
                expect.equal(nsText.substring(with: NSRange(
                    location: spans[5].location, length: spans[5].length
                )), "ship")
                expect.close(spans[5].startSeconds, 5, tolerance: 0.001, "the second line's own time")
            },

            test("a line without timings contributes one span covering it") { expect in
                let block = CombinedLineBlock(lines: [CombinedLine(
                    recordingID: "rec", utterance: line(timed: false), speakerName: "Dana",
                    timelineStart: 0
                )])
                let (text, spans) = block.paragraph()
                expect.equal(spans.count, 1)
                expect.equal(spans[0].length, (text as NSString).length)
                expect.close(spans[0].endSeconds, 4, tolerance: 0.001)
            },

            test("a block reports the range it covers") { expect in
                let block = CombinedLineBlock(lines: [
                    CombinedLine(
                        recordingID: "rec", utterance: line(), speakerName: "Dana",
                        timelineStart: 60
                    ),
                    CombinedLine(
                        recordingID: "rec", utterance: line(start: 4), speakerName: "Dana",
                        timelineStart: 64
                    ),
                ])
                expect.close(block.timelineStart, 60, tolerance: 0.001)
                expect.close(block.timelineEnd, 68, tolerance: 0.001)
                expect.close(block.startSeconds, 0, tolerance: 0.001, "the recording's own clock")
                expect.close(block.endSeconds, 8, tolerance: 0.001)
            },
        ])
    }

    /// A chunk carries eight seconds of the one before it so a sentence on the
    /// boundary lands whole somewhere, and the model transcribes that overlap
    /// twice.
    static var seamSuite: Suite {
        Suite("TranscriptSeam", [
            test("a line that opens by repeating the one before it is trimmed") { expect in
                // Measured on a 25-minute meeting: 21 of 148 consecutive pairs
                // repeated between 3 and 17 words at a chunk boundary.
                let first = RawTranscriptChunk(
                    id: "remote_chunk_001", track: .remote, timelineOffset: 0, durationSeconds: 20,
                    model: "test", responseFormat: "json",
                    segments: [RawTranscriptSegment(
                        start: 0, end: 6, text: "so the plan is we ship on friday", speaker: "A",
                        words: [
                            word(" so", 0, 0.4), word(" the", 0.5, 0.8), word(" plan", 0.9, 1.3),
                            word(" is", 1.4, 1.7), word(" we", 3.0, 3.3),
                            word(" ship", 3.4, 3.8), word(" on", 3.9, 4.1),
                            word(" friday", 4.2, 4.8),
                        ]
                    )]
                )
                let second = RawTranscriptChunk(
                    id: "remote_chunk_002", track: .remote, timelineOffset: 3, durationSeconds: 20,
                    model: "test", responseFormat: "json",
                    segments: [RawTranscriptSegment(
                        start: 0, end: 5, text: "we ship on friday unless qa says otherwise",
                        speaker: "A",
                        words: [
                            word(" we", 0, 0.3), word(" ship", 0.4, 0.8), word(" on", 0.9, 1.1),
                            word(" friday", 1.2, 1.8), word(" unless", 2.0, 2.4),
                            word(" qa", 2.5, 2.8), word(" says", 2.9, 3.2),
                            word(" otherwise", 3.3, 3.9),
                        ]
                    )]
                )
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [first, second]),
                    micTrackIsLocalUser: false, generatedAt: Date()
                )
                expect.equal(transcript.utterances.count, 2)
                expect.equal(transcript.utterances[0].text, "so the plan is we ship on friday")
                expect.equal(
                    transcript.utterances[1].text, "unless qa says otherwise",
                    "the four repeated words are gone and the rest of the sentence is not"
                )
                expect.close(
                    transcript.utterances[1].start, 5.0, tolerance: 0.001,
                    "the line starts where its first surviving word does"
                )
            },

            test("a phrase said twice in a row inside one chunk is kept") { expect in
                let chunk = RawTranscriptChunk(
                    id: "remote_chunk_001", track: .remote, timelineOffset: 0, durationSeconds: 20,
                    model: "test", responseFormat: "json",
                    segments: [
                        RawTranscriptSegment(
                            start: 0, end: 2, text: "that is fine", speaker: "A",
                            words: [word(" that", 0, 0.4), word(" is", 0.5, 0.8), word(" fine", 0.9, 1.4)]
                        ),
                        RawTranscriptSegment(
                            start: 8, end: 10, text: "that is fine", speaker: "B",
                            words: [word(" that", 8, 8.4), word(" is", 8.5, 8.8), word(" fine", 8.9, 9.4)]
                        ),
                    ]
                )
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [chunk]),
                    micTrackIsLocalUser: false, generatedAt: Date()
                )
                expect.equal(transcript.utterances.count, 2, "one chunk repeating itself is speech")
                expect.equal(transcript.utterances.map(\.text), ["that is fine", "that is fine"])
            },

            test("two words in common are not a seam") { expect in
                let first = RawTranscriptChunk(
                    id: "remote_chunk_001", track: .remote, timelineOffset: 0, durationSeconds: 20,
                    model: "test", responseFormat: "json",
                    segments: [RawTranscriptSegment(
                        start: 0, end: 3, text: "well that is fine", speaker: "A",
                        words: [
                            word(" well", 0, 0.4), word(" that", 0.5, 0.9),
                            word(" is", 1.0, 1.2), word(" fine", 1.3, 1.8),
                        ]
                    )]
                )
                let second = RawTranscriptChunk(
                    id: "remote_chunk_002", track: .remote, timelineOffset: 4, durationSeconds: 20,
                    model: "test", responseFormat: "json",
                    segments: [RawTranscriptSegment(
                        start: 0, end: 3, text: "is fine by me honestly", speaker: "A",
                        words: [
                            word(" is", 0, 0.3), word(" fine", 0.4, 0.9), word(" by", 1.0, 1.2),
                            word(" me", 1.3, 1.5), word(" honestly", 1.6, 2.2),
                        ]
                    )]
                )
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [first, second]),
                    micTrackIsLocalUser: false, generatedAt: Date()
                )
                expect.equal(transcript.utterances[1].text, "is fine by me honestly")
            },

            test("the words behind a line reach the transcript on the meeting clock") { expect in
                // What a division is measured against. Chunk-relative timings
                // would put a boundary somewhere else entirely on any chunk
                // after the first.
                let chunk = RawTranscriptChunk(
                    id: "remote_chunk_002", track: .remote, timelineOffset: 60, durationSeconds: 20,
                    model: "test", responseFormat: "json",
                    segments: [RawTranscriptSegment(
                        start: 1, end: 3, text: "we ship friday", speaker: "A",
                        words: [word(" we", 1, 1.4), word(" ship", 1.5, 1.9), word(" friday", 2.0, 2.6)]
                    )]
                )
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [chunk]),
                    micTrackIsLocalUser: false, generatedAt: Date()
                )
                let words = try expect.unwrap(transcript.utterances.first?.words)
                expect.equal(words.count, 3)
                expect.close(words[0].start, 61, tolerance: 0.001)
                expect.close(words[2].end, 62.6, tolerance: 0.001)
            },
        ])
    }

    static var all: [Suite] { [suite, paragraphSuite, seamSuite] }
}
