import Foundation
import MeetTapeCore
import MeetTapeIntegrations
import MeetTapeServices
import TestKit

/// A scripted AI backend. Records what it was asked and returns what the test
/// says, so the pipeline can be exercised end to end without the network.
final class FakeAIBackend: AIBackend, @unchecked Sendable {
    struct Call: Sendable, Equatable {
        let kind: String
        let model: String
        let file: String
    }

    private let lock = NSLock()
    private(set) var calls: [Call] = []
    var transcriptionSegments: [RawTranscriptSegment] = []
    var diarizationSegments: [RawTranscriptSegment] = []
    var suggestions: [SpeakerSuggestion] = []
    var enrichment = MeetingEnrichment(title: "Retrieval logic", summary: "Discussed retrieval.")
    var failNextTranscription: ProcessingError?
    /// Fails every enrichment request, for the lost-connection path.
    var failEnrichment: ProcessingError?
    var failNextDiarization: ProcessingError?
    /// Fails every request, for the bounded-retry path.
    var alwaysFailTranscription: ProcessingError?
    /// Returns a different segment set per chunk index, for overlap tests.
    var diarizationByChunk: [[RawTranscriptSegment]] = []
    /// False models a user who never entered a key.
    var configured = true

    func isConfigured() async -> Bool { configured }

    func record(_ call: Call) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    func verifyCredentials(model: String) async throws {}

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResponse {
        if let failure = alwaysFailTranscription {
            record(Call(kind: "transcribe", model: request.model, file: request.audio.lastPathComponent))
            throw failure
        }
        if let failure = failNextTranscription {
            failNextTranscription = nil
            throw failure
        }
        record(Call(kind: "transcribe", model: request.model, file: request.audio.lastPathComponent))
        return TranscriptionResponse(
            segments: transcriptionSegments,
            text: transcriptionSegments.map(\.text).joined(separator: " "),
            durationSeconds: nil,
            rawBody: Data("{}".utf8)
        )
    }

    func diarize(_ request: DiarizationRequest) async throws -> TranscriptionResponse {
        if let failure = failNextDiarization {
            failNextDiarization = nil
            throw failure
        }
        let index = lock.withLock { () -> Int in
            calls.filter { $0.kind == "diarize" }.count
        }
        record(Call(kind: "diarize", model: request.model, file: request.audio.lastPathComponent))
        let segments = index < diarizationByChunk.count ? diarizationByChunk[index] : diarizationSegments
        return TranscriptionResponse(
            segments: segments,
            text: segments.map(\.text).joined(separator: " "),
            durationSeconds: nil,
            rawBody: Data("{}".utf8)
        )
    }

    func resolveSpeakers(
        _ request: SpeakerResolutionRequest, model: String
    ) async throws -> [SpeakerSuggestion] {
        record(Call(kind: "resolve", model: model, file: ""))
        // What the real client does with no key, and the reason these stages
        // have to ask before calling: the error is not retryable.
        if !configured { throw ProcessingError.missingAPIKey }
        return suggestions
    }

    func enrich(_ request: EnrichmentRequest, model: String) async throws -> MeetingEnrichment {
        record(Call(kind: "enrich", model: model, file: ""))
        if !configured { throw ProcessingError.missingAPIKey }
        if let failEnrichment { throw failEnrichment }
        return enrichment
    }
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

enum ProcessingTests {
    static func chunk(
        id: String, track: CaptureTrack, offset: Double, segments: [RawTranscriptSegment]
    ) -> RawTranscriptChunk {
        RawTranscriptChunk(
            id: id, track: track, timelineOffset: offset, durationSeconds: 600,
            model: "test", responseFormat: "diarized_json", segments: segments
        )
    }

    static var chunkingSuite: Suite {
        Suite("ChunkPlanner", [
            test("a short recording is a single request") { expect in
                let plans = ChunkPlanner().plan(durationSeconds: 600)
                expect.equal(plans.count, 1)
                expect.equal(plans[0].start, 0)
                expect.close(plans[0].end, 600, tolerance: 0.001)
            },

            test("a plan fitted to a tighter limit never exceeds it, overlap included") { expect in
                // The local Cohere engine's window is 35 s, and one second over
                // it re-enters the library's own stitching, which is the thing
                // the limit exists to avoid.
                let limits = BackendAudioLimits(maximumSeconds: LocalCohereTuning.chunkSeconds)
                let configuration = try expect.unwrap(ChunkPlanner.Configuration.fitting(limits))
                let plans = ChunkPlanner(configuration: configuration)
                    .plan(durationSeconds: 600)
                expect.isTrue(plans.count > 15, "got \(plans.count) chunks of ten minutes")
                for plan in plans {
                    expect.isTrue(
                        plan.duration <= LocalCohereTuning.chunkSeconds + 0.001,
                        "chunk \(plan.index) is \(plan.duration)s, past the model window"
                    )
                }
                expect.isNil(
                    ChunkPlanner.Configuration.fitting(BackendAudioLimits.openAI),
                    "the cloud limit keeps the measured default plan"
                )
            },

            test("a text-only backend is chunked for the aligner, not for its own limit") { expect in
                // gpt-transcribe may send 1400 seconds, but the words come back
                // without timings and the alignment trellis is frames times
                // tokens. At the API's own limit the trellis exceeded its cap,
                // alignment refused, and a nineteen-minute chunk became one
                // utterance on one speaker.
                let configuration = try expect.unwrap(
                    ChunkPlanner.Configuration.fitting(BackendAudioLimits.openAI, timing: .text)
                )
                let plans = ChunkPlanner(configuration: configuration)
                    .plan(durationSeconds: 3_600)
                expect.isTrue(plans.count >= 12, "got \(plans.count) chunks for an hour")
                for plan in plans {
                    expect.isTrue(
                        plan.duration <= LocalAlignmentTuning.chunkSeconds + 0.001,
                        "chunk \(plan.index) is \(plan.duration)s, past the alignment window"
                    )
                }
            },

            test("a long recording is chunked under the model limit with overlap") { expect in
                // Two hours, which is four to seven requests.
                let plans = ChunkPlanner().plan(durationSeconds: 7_200)
                expect.isTrue(plans.count >= 5, "got \(plans.count) chunks")
                for plan in plans {
                    expect.isTrue(
                        plan.duration <= AILimits.maximumDiarizationSeconds,
                        "chunk \(plan.index) is \(plan.duration)s, over the 1400 s limit"
                    )
                    expect.isTrue(plan.duration > 0)
                }
                for (previous, next) in zip(plans, plans.dropFirst()) {
                    expect.isTrue(next.start < previous.end, "chunks must overlap, not just abut")
                    expect.close(previous.end - next.start, 8, tolerance: 0.5)
                }
                expect.close(plans.last?.end ?? 0, 7_200, tolerance: 0.001)
                expect.equal(plans.first?.start, 0)
            },

            test("boundaries move to the quietest nearby point") { expect in
                // Speech everywhere except a clear pause 40 s before the ideal cut.
                let windowSeconds = 0.5
                let windowCount = Int(3_000 / windowSeconds)
                var values = [Float](repeating: 0.4, count: windowCount)
                let pauseCentre = 1_140.0 - 40
                let pauseStart = Int((pauseCentre - 1) / windowSeconds)
                let pauseEnd = Int((pauseCentre + 1) / windowSeconds)
                for index in pauseStart...pauseEnd { values[index] = 0.001 }

                let profile = EnergyProfile(windowSeconds: windowSeconds, values: values)
                let plans = ChunkPlanner().plan(durationSeconds: 3_000, energy: profile)
                expect.isTrue(plans.count >= 2)
                let boundary = plans[1].overlapEnd
                expect.close(boundary, pauseCentre, tolerance: 2.0, "boundary should land in the pause")
            },

            test("chunk identifiers are namespaced so labels never collide") { expect in
                let plans = ChunkPlanner().plan(durationSeconds: 7_200)
                let ids = Set(plans.map(\.chunkID))
                expect.equal(ids.count, plans.count)
                expect.equal(plans[0].chunkID, "chunk_001")
                expect.equal(
                    SpeakerLabel.namespaced(chunkID: "chunk_001", rawLabel: "A"), "chunk_001_speaker_00"
                )
                expect.equal(
                    SpeakerLabel.namespaced(chunkID: "chunk_002", rawLabel: "A"), "chunk_002_speaker_00"
                )
                expect.notEqual(
                    SpeakerLabel.namespaced(chunkID: "chunk_001", rawLabel: "A"),
                    SpeakerLabel.namespaced(chunkID: "chunk_002", rawLabel: "A")
                )
            },
        ])
    }

    static var assemblySuite: Suite {
        Suite("TranscriptAssembler", [
            test("overlapping chunks do not duplicate the sentence they share") { expect in
                // The last sentence of chunk one is repeated at the start of chunk
                // two, which is exactly what the 8 s overlap produces.
                let first = chunk(id: "remote_chunk_001", track: .remote, offset: 0, segments: [
                    RawTranscriptSegment(start: 0, end: 3, text: "Let's start with retrieval.", speaker: "A"),
                    RawTranscriptSegment(start: 4, end: 8, text: "The second pass is the slow one.", speaker: "B"),
                ])
                let second = chunk(id: "remote_chunk_002", track: .remote, offset: 4, segments: [
                    RawTranscriptSegment(start: 0, end: 4, text: "The second pass is the slow one.", speaker: "A"),
                    RawTranscriptSegment(start: 5, end: 9, text: "Agreed, let's cache it.", speaker: "B"),
                ])
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [first, second]),
                    micTrackIsLocalUser: true,
                    generatedAt: Date(timeIntervalSince1970: 0)
                )
                let texts = transcript.utterances.map(\.text)
                expect.equal(texts.count, 3, "got \(texts)")
                expect.equal(
                    texts.filter { $0.contains("second pass") }.count, 1,
                    "the overlapping sentence appears twice: \(texts)"
                )
                expect.isTrue(texts.contains("Agreed, let's cache it."))
            },

            test("a remote speaker heard through the local microphone is not the local user") { expect in
                // Recorded on a real call without headphones: the remote side
                // plays through the speakers, the microphone records it, and the
                // transcription model writes the remote speaker's sentence onto
                // the local track. The remote track already owns those words.
                let remote = chunk(id: "remote_chunk_001", track: .remote, offset: 0, segments: [
                    RawTranscriptSegment(
                        start: 279.07, end: 282.37,
                        text: "Yeah, you can go watch the Blue Jays if you're still into baseball at all.",
                        speaker: "00"
                    ),
                ])
                let mic = chunk(id: "mic_chunk_001", track: .mic, offset: 0, segments: [
                    RawTranscriptSegment(start: 269, end: 270, text: "Have you been?", speaker: nil),
                    RawTranscriptSegment(
                        start: 278, end: 282,
                        text: "Yeah, you can go watch the Blue Jays if you're still into baseball at all.",
                        speaker: nil
                    ),
                    RawTranscriptSegment(start: 284, end: 287, text: "The Red Sox, mostly out of habit.", speaker: nil),
                ])
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [mic, remote]),
                    micTrackIsLocalUser: true,
                    generatedAt: Date(timeIntervalSince1970: 0)
                )
                let local = transcript.utterances.filter { $0.speakerKey == SpeakerLabel.localUser }
                expect.isTrue(
                    !local.contains { $0.text.contains("Blue Jays") },
                    "the remote speaker's sentence stayed on the local track: \(local.map(\.text))"
                )
                expect.isTrue(local.contains { $0.text.contains("Have you been?") })
                expect.isTrue(local.contains { $0.text.contains("Red Sox") })
                expect.isTrue(
                    transcript.utterances.contains {
                        $0.track == .remote && $0.text.contains("Blue Jays")
                    },
                    "the remote track keeps the sentence"
                )
            },

            test("continuous audio cannot merge into one multi-minute utterance") { expect in
                // Without headphones the microphone never goes silent, so the
                // pause rule alone chained a real recording into one 219-second
                // utterance and every remote reply rendered after the whole
                // block. A turn is capped so other speakers interleave.
                var segments: [RawTranscriptSegment] = []
                for index in 0..<12 {
                    let start = Double(index) * 6.5
                    segments.append(RawTranscriptSegment(
                        start: start, end: start + 6,
                        text: "Sentence number \(index) of a long stretch.", speaker: nil
                    ))
                }
                let mic = chunk(id: "mic_chunk_001", track: .mic, offset: 0, segments: segments)
                let remote = chunk(id: "remote_chunk_001", track: .remote, offset: 0, segments: [
                    RawTranscriptSegment(start: 35, end: 38, text: "A short remote reply.", speaker: "00"),
                ])
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [mic, remote]),
                    micTrackIsLocalUser: true,
                    generatedAt: Date(timeIntervalSince1970: 0)
                )
                let local = transcript.utterances.filter { $0.speakerKey == SpeakerLabel.localUser }
                expect.isTrue(local.count >= 3, "expected several turns, got \(local.count)")
                let longest = local.map { $0.end - $0.start }.max() ?? 0
                expect.isTrue(longest <= 30.01, "an utterance still spans \(longest)s")
                let order = transcript.utterances.map(\.track)
                expect.isTrue(
                    order.firstIndex(of: .remote).map { $0 > 0 && $0 < order.count - 1 } == true,
                    "the remote reply should land between local turns, not after the block"
                )
            },

            test("a phrase repeated inside one chunk is kept") { expect in
                // De-duplication exists for the overlap between chunks. A speaker
                // who repeats themselves inside a single chunk said it twice.
                let only = chunk(id: "remote_chunk_001", track: .remote, offset: 0, segments: [
                    RawTranscriptSegment(start: 0, end: 2, text: "Yes, exactly.", speaker: "A"),
                    RawTranscriptSegment(start: 4, end: 8, text: "So the index is the slow part.", speaker: "B"),
                    RawTranscriptSegment(start: 9, end: 11, text: "Yes, exactly.", speaker: "A"),
                ])
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [only]),
                    micTrackIsLocalUser: true,
                    generatedAt: Date(timeIntervalSince1970: 0)
                )
                let texts = transcript.utterances.map(\.text)
                expect.equal(
                    texts.filter { $0 == "Yes, exactly." }.count, 2,
                    "both repetitions should survive: \(texts)"
                )
            },

            test("anonymous labels from different chunks read as different speakers") { expect in
                let first = SpeakerMap.fallbackName(for: "remote_chunk_001_speaker_00")
                let second = SpeakerMap.fallbackName(for: "remote_chunk_002_speaker_00")
                expect.equal(first, "Speaker 1", "one chunk of audio should read plainly")
                expect.notEqual(
                    first, second,
                    "two chunks' labels are different clusters until someone maps them"
                )
                expect.equal(second, "Speaker 1 (part 2)")
                expect.equal(SpeakerMap.fallbackName(for: SpeakerLabel.localUser), "Me")
            },

            test("timestamps stay monotonic across chunks") { expect in
                let first = chunk(id: "remote_chunk_001", track: .remote, offset: 0, segments: [
                    RawTranscriptSegment(start: 10, end: 12, text: "One.", speaker: "A"),
                ])
                let second = chunk(id: "remote_chunk_002", track: .remote, offset: 600, segments: [
                    RawTranscriptSegment(start: 5, end: 7, text: "Two.", speaker: "A"),
                ])
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [first, second]),
                    micTrackIsLocalUser: true,
                    generatedAt: Date(timeIntervalSince1970: 0)
                )
                expect.equal(transcript.utterances.map(\.start), [10, 605])
                for (previous, next) in zip(transcript.utterances, transcript.utterances.dropFirst()) {
                    expect.isTrue(next.start >= previous.start)
                }
            },

            test("the microphone track is the local user and is never diarized") { expect in
                let mic = chunk(id: "mic_chunk_001", track: .mic, offset: 0, segments: [
                    RawTranscriptSegment(start: 1, end: 3, text: "I think we change retrieval.", speaker: nil),
                ])
                let remote = chunk(id: "remote_chunk_001", track: .remote, offset: 0, segments: [
                    RawTranscriptSegment(start: 4, end: 6, text: "Yeah, on the second pass.", speaker: "A"),
                    RawTranscriptSegment(start: 8, end: 10, text: "Would that affect latency?", speaker: "B"),
                ])
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [mic, remote]),
                    micTrackIsLocalUser: true,
                    generatedAt: Date(timeIntervalSince1970: 0)
                )
                expect.equal(transcript.utterances.count, 3)
                expect.equal(transcript.utterances[0].speakerKey, SpeakerLabel.localUser)
                expect.isNil(transcript.utterances[0].rawSpeakerLabel)
                expect.equal(transcript.utterances[1].speakerKey, "remote_chunk_001_speaker_00")
                expect.equal(transcript.utterances[2].speakerKey, "remote_chunk_001_speaker_01")
            },

            test("the diarizer the user chose beats labels embedded in the words") { expect in
                // Cloud transcription with diarization set to Local ran the
                // local diarizer, wrote an active run with the right four
                // speakers, and then assembled the transcriber's own ten
                // chunk-scoped labels anyway. The run comes from a different
                // producer than the words, so it is the answer the user asked
                // for and it wins on the first pass.
                var words = chunk(id: "mic_chunk_001", track: .mic, offset: 0, segments: [
                    RawTranscriptSegment(start: 0, end: 4, text: "One two.", speaker: "spk_0"),
                    RawTranscriptSegment(start: 6, end: 9, text: "Three four.", speaker: "spk_1"),
                ])
                words.model = "gpt-4o-transcribe-diarize"
                func run(backend: String) -> RawDiarization {
                    RawDiarization(runs: [DiarizationRun(
                        id: "run-local", track: .mic, backend: backend,
                        producedAt: Date(timeIntervalSince1970: 0), timelineOffset: 0,
                        intervals: [
                            DiarizationInterval(start: 0, end: 5, clusterID: "S1"),
                            DiarizationInterval(start: 5, end: 10, clusterID: "S2"),
                        ]
                    )])
                }

                let local = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [words]),
                    diarization: run(backend: "fluidaudio-offline-0.15.6"),
                    micTrackIsLocalUser: false,
                    generatedAt: Date(timeIntervalSince1970: 0)
                )
                expect.equal(local.utterances.count, 2)
                expect.equal(local.utterances[0].speakerKey, "run-local_speaker_00")
                expect.equal(local.utterances[1].speakerKey, "run-local_speaker_01")

                // Cloud words with a cloud diarizer: the run carries the same
                // producer as the words, so the embedded labels stand.
                let cloud = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [words]),
                    diarization: run(backend: "gpt-4o-transcribe-diarize"),
                    micTrackIsLocalUser: false,
                    generatedAt: Date(timeIntervalSince1970: 0)
                )
                expect.equal(cloud.utterances[0].speakerKey, "mic_chunk_001_speaker_spk_0")
                expect.equal(cloud.utterances[1].speakerKey, "mic_chunk_001_speaker_spk_1")
            },

            test("an in-person recording keeps the raw labels on its only track") { expect in
                let mic = chunk(id: "mic_chunk_001", track: .mic, offset: 0, segments: [
                    RawTranscriptSegment(start: 1, end: 3, text: "Morning.", speaker: "A"),
                    RawTranscriptSegment(start: 4, end: 6, text: "Morning to you.", speaker: "B"),
                ])
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [mic]),
                    micTrackIsLocalUser: false,
                    generatedAt: Date(timeIntervalSince1970: 0)
                )
                expect.equal(transcript.utterances[0].speakerKey, "mic_chunk_001_speaker_00")
                expect.equal(transcript.utterances[1].speakerKey, "mic_chunk_001_speaker_01")
                expect.notEqual(transcript.utterances[0].speakerKey, SpeakerLabel.localUser)
            },

            test("consecutive segments from one speaker read as one turn") { expect in
                let remote = chunk(id: "remote_chunk_001", track: .remote, offset: 0, segments: [
                    RawTranscriptSegment(start: 0, end: 0.4, text: "Hey,", speaker: "A"),
                    RawTranscriptSegment(start: 0.5, end: 0.9, text: "Andrew,", speaker: "A"),
                    RawTranscriptSegment(start: 1.0, end: 1.6, text: "Chris here.", speaker: "A"),
                    RawTranscriptSegment(start: 4.0, end: 5.0, text: "This is Tim.", speaker: "B"),
                ])
                let transcript = TranscriptAssembler().assemble(
                    raw: RawTranscript(chunks: [remote]),
                    micTrackIsLocalUser: true,
                    generatedAt: Date(timeIntervalSince1970: 0)
                )
                expect.equal(transcript.utterances.count, 2)
                expect.equal(transcript.utterances[0].text, "Hey, Andrew, Chris here.")
                expect.close(transcript.utterances[0].end, 1.6, tolerance: 0.001)
            },

            test("renaming a speaker changes the rendering, not the raw data") { expect in
                let raw = RawTranscript(chunks: [
                    chunk(id: "remote_chunk_001", track: .remote, offset: 0, segments: [
                        RawTranscriptSegment(start: 0, end: 2, text: "Chris here.", speaker: "A"),
                    ]),
                ])
                let transcript = TranscriptAssembler().assemble(
                    raw: raw, micTrackIsLocalUser: true, generatedAt: Date(timeIntervalSince1970: 0)
                )
                var speakers = SpeakerMap.withLocalUser(named: "Andrew")
                let renderer = TranscriptRenderer()

                let before = renderer.markdown(
                    transcript: transcript, speakers: speakers, title: "Sync",
                    startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 2,
                    participants: []
                )
                expect.isTrue(before.contains("Speaker 1"), "unnamed speakers get a readable fallback")

                speakers.assign("Chris", to: "remote_chunk_001_speaker_00")
                let after = renderer.markdown(
                    transcript: transcript, speakers: speakers, title: "Sync",
                    startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 2,
                    participants: []
                )
                expect.isTrue(after.contains("Chris"))
                expect.isFalse(after.contains("Speaker 1"))
                // The raw response is untouched by the rename.
                expect.equal(raw.chunks[0].segments[0].speaker, "A")
            },

            test("a human name is never overwritten by a suggestion") { expect in
                var speakers = SpeakerMap()
                speakers.assign("Chris", to: "remote_chunk_001_speaker_00")
                speakers.applySuggestion(
                    SpeakerAssignment(displayName: "Tim", origin: .ai, confidence: 0.98),
                    for: "remote_chunk_001_speaker_00"
                )
                expect.equal(speakers.resolvedName(for: "remote_chunk_001_speaker_00"), "Chris")

                // A label the user has not named does take the suggestion.
                speakers.applySuggestion(
                    SpeakerAssignment(displayName: "Tim", origin: .ai, confidence: 0.9),
                    for: "remote_chunk_001_speaker_01"
                )
                expect.equal(speakers.resolvedName(for: "remote_chunk_001_speaker_01"), "Tim")
                // And a human correction wins over the suggestion afterwards.
                speakers.assign("John", to: "remote_chunk_001_speaker_01")
                expect.equal(speakers.entries["remote_chunk_001_speaker_01"]?.origin, .human)
            },

            test("similar text is recognised, unrelated text is not") { expect in
                expect.isTrue(
                    TextSimilarity.score(
                        "The second pass is the slow one.", "the second pass is the slow one"
                    ) > 0.9
                )
                expect.isTrue(
                    TextSimilarity.score("Would that affect latency?", "Agreed, let's cache it.") < 0.2
                )
            },
        ])
    }

    static var all: [Suite] { [chunkingSuite, assemblySuite] }
}
