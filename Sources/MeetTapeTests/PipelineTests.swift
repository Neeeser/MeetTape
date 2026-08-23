import AVFoundation
import Foundation
import MeetTapeAudio
import MeetTapeCore
import MeetTapeIntegrations
import MeetTapeServices
import TestKit

enum PipelineTests {
    /// Builds a finished two-track recording on disk, ready for processing.
    static func makeRecordedMeeting(
        root: URL, source: MeetingSource = .googleMeet, seconds: Double = 6,
        remoteStartOffset: Double = 0, amplitude: Float = 0.5
    ) throws -> (metadata: MeetingMetadata, store: MeetingStore, repository: MeetingRepository) {
        let repository = MeetingRepository(root: root)
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: source, provider: source.provider, startedAt: started,
            titles: TitleCandidates(provider: "Weekly sync", timestampFallback: "fallback"),
            now: started
        )

        let manifest = try ManifestWriter(url: created.store.layout.manifest)
        manifest.append(.sessionStart(.init(
            meetingID: created.metadata.id, source: source, segmentSeconds: 30,
            appVersion: "test", processID: 1
        )))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let micWriter = SegmentWriter(
            track: .mic, layout: created.store.layout, manifest: manifest,
            format: format, segmentSeconds: 30
        )
        micWriter.enqueueSynchronously(AudioBufferPacket(
            buffer: AudioTests.makeTone(seconds: seconds, sampleRate: 48_000, amplitude: amplitude),
            hostTime: 100
        ))
        micWriter.finish(reason: "test")

        if source.capturesRemoteAudio {
            let remoteWriter = SegmentWriter(
                track: .remote, layout: created.store.layout, manifest: manifest,
                format: format, segmentSeconds: 30
            )
            remoteWriter.enqueueSynchronously(AudioBufferPacket(
                buffer: AudioTests.makeTone(
                    seconds: seconds, sampleRate: 48_000, frequency: 220, amplitude: amplitude
                ),
                hostTime: 100 + remoteStartOffset
            ))
            remoteWriter.finish(reason: "test")
        }
        manifest.append(.sessionEnd(.init(reason: "test", micSeconds: seconds, remoteSeconds: seconds)))
        manifest.close()

        var metadata = created.metadata
        metadata.endedAt = started.addingTimeInterval(seconds)
        metadata.durationSeconds = seconds
        metadata.runs = [RecordingRun(
            id: "run-001", startedAt: started, endedAt: metadata.endedAt, durationSeconds: seconds
        )]
        metadata.processing = ProcessingStatus(state: .audioSafe, updatedAt: started)
        try created.store.writeMetadata(metadata)
        return (metadata, created.store, repository)
    }

    static func makePipeline(
        repository: MeetingRepository, backend: FakeAIBackend, settings: AppSettings = AppSettings()
    ) -> ProcessingPipeline {
        ProcessingPipeline(
            repository: repository,
            backend: backend,
            clock: ManualClock(),
            settingsProvider: { settings },
            wait: { _ in }
        )
    }

    static var suite: Suite {
        Suite("ProcessingPipeline", [
            test("a chunk that came back with words is accepted without reading its audio") { expect in
                // The level only separates silence from a lost transcript, so
                // decoding on the success path costs a full converter pass per
                // chunk and turns audio that has become unreadable into a
                // permanent failure for a transcript already in hand.
                final class Counter: @unchecked Sendable { var reads = 0 }
                let counter = Counter()
                let measure: (URL) throws -> AudioLevel = { _ in
                    counter.reads += 1
                    return AudioLevel(peakDBFS: 0, rmsDBFS: 0)
                }
                let withSegments = TranscriptionOutput(
                    segments: [RawTranscriptSegment(start: 0, end: 1, text: "Hello.", speaker: nil)],
                    text: ""
                )
                try ProcessingPipeline.requireTranscribedOrSilent(
                    response: withSegments, audio: URL(fileURLWithPath: "/nonexistent.caf"),
                    chunkID: "mic_0", purpose: .words, level: measure
                )
                let textOnly = TranscriptionOutput(segments: [], text: "Hello.")
                try ProcessingPipeline.requireTranscribedOrSilent(
                    response: textOnly, audio: URL(fileURLWithPath: "/nonexistent.caf"),
                    chunkID: "mic_1", purpose: .words, level: measure
                )
                expect.equal(counter.reads, 0, "a non-empty response never reads the audio")

                var failed = false
                do {
                    try ProcessingPipeline.requireTranscribedOrSilent(
                        response: TranscriptionOutput(segments: [], text: ""),
                        audio: URL(fileURLWithPath: "/nonexistent.caf"),
                        chunkID: "mic_2", purpose: .words, level: measure
                    )
                } catch {
                    failed = true
                }
                expect.equal(counter.reads, 1, "an empty response reads the audio")
                expect.isTrue(failed, "an empty response for audible audio fails")
            },

            test("an empty response whose audio cannot be read fails retryably") { expect in
                // Nothing proves the audio was silent, so the chunk cannot be
                // accepted, and a non-retryable failure would strand the
                // meeting on a scratch file that a retry may well read.
                struct Unreadable: Error {}
                var caught: ProcessingError?
                do {
                    try ProcessingPipeline.requireTranscribedOrSilent(
                        response: TranscriptionOutput(segments: [], text: ""),
                        audio: URL(fileURLWithPath: "/nonexistent.caf"),
                        chunkID: "mic_0", purpose: .words, level: { _ in throw Unreadable() }
                    )
                } catch let error as ProcessingError {
                    caught = error
                }
                expect.equal(caught, .emptyTranscript(chunk: "mic_0"), "fails as an empty transcript")
                expect.isTrue(caught?.isRetryable == true, "the stage retries")
            },

            test("each track is placed at its own start on the meeting timeline") { expect in
                // The remote writer opens on the first packet from the meeting
                // application, which here is 12 s after the microphone started. A
                // chunk offset is a position inside one track, so without the
                // track's lead-in every remote utterance lands 12 s early.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeRecordedMeeting(root: root, seconds: 6, remoteStartOffset: 12)

                let backend = FakeAIBackend()
                backend.transcriptionSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Mine.", speaker: nil),
                ]
                backend.diarizationSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Theirs.", speaker: "A"),
                ]
                let pipeline = makePipeline(repository: meeting.repository, backend: backend)
                await pipeline.process(meetingID: meeting.metadata.id)

                let transcript = try meeting.store.readCanonicalTranscript()
                let mine = transcript?.utterances.first { $0.text == "Mine." }
                let theirs = transcript?.utterances.first { $0.text == "Theirs." }
                expect.equal(mine?.start, 0, "the earlier track starts the timeline")
                expect.equal(
                    theirs?.start, 12,
                    "the later track is offset by when it actually started"
                )
            },

            test("a recorded meeting runs through to complete") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeRecordedMeeting(root: root)

                let backend = FakeAIBackend()
                backend.transcriptionSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "I think we change retrieval.", speaker: nil),
                ]
                backend.diarizationSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Chris here, agreed.", speaker: "A"),
                ]
                backend.suggestions = [
                    SpeakerSuggestion(
                        label: "remote_chunk_001_speaker_00", name: "Chris",
                        confidence: 0.98, evidence: "self-introduction"
                    ),
                ]

                let pipeline = makePipeline(repository: meeting.repository, backend: backend)
                await pipeline.process(meetingID: meeting.metadata.id)

                let final = try meeting.store.readMetadata()
                expect.equal(final.processing.state, .complete)
                expect.isNil(final.processing.lastFailure)

                let transcript = try expect.unwrap(try meeting.store.readCanonicalTranscript())
                expect.equal(transcript.utterances.count, 2)
                let speakers = try meeting.store.readSpeakerMap()
                expect.equal(speakers.resolvedName(for: SpeakerLabel.localUser), "Me")
                expect.equal(speakers.resolvedName(for: "remote_chunk_001_speaker_00"), "Chris")

                let markdown = try String(
                    contentsOf: meeting.store.layout.transcriptMarkdown, encoding: .utf8
                )
                expect.isTrue(markdown.contains("Chris"))
                expect.isTrue(
                    FileManager.default.fileExists(atPath: meeting.store.layout.summary.path),
                    "summary.md should exist"
                )
                // The AI title is a candidate, and the provider title still wins.
                expect.equal(final.titles.ai, "Retrieval logic")
                expect.equal(final.displayTitle, "Weekly sync")

                // The microphone track was transcribed, the remote track diarized.
                expect.equal(backend.calls.filter { $0.kind == "transcribe" }.count, 1)
                expect.equal(backend.calls.filter { $0.kind == "diarize" }.count, 1)
            },

            test("a rename during processing is not overwritten by a stage") { expect in
                // The pipeline reads metadata.json, changes its own fields and
                // writes the whole document back, while the user renames the
                // meeting from the review panel. Without serialisation the slower
                // writer restores the copy it read and the rename disappears.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeRecordedMeeting(root: root)
                let store = meeting.store

                let renames = Task.detached {
                    for index in 0..<200 {
                        _ = try? store.updateMetadata { $0.titles.human = "Renamed \(index)" }
                    }
                }
                let stages = Task.detached {
                    for _ in 0..<200 {
                        _ = try? store.updateMetadata { metadata in
                            metadata.processing.advance(to: .transcribing, at: Date())
                            metadata.durationSeconds += 1
                        }
                    }
                }
                await renames.value
                await stages.value

                let final = try store.readMetadata()
                expect.equal(
                    final.titles.human, "Renamed 199",
                    "the last rename survived every stage write"
                )
                expect.equal(final.processing.state, .transcribing)
                expect.isTrue(final.durationSeconds > 0)
            },

            test("a rate limit is retried on its own and the meeting completes") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeRecordedMeeting(root: root)

                let backend = FakeAIBackend()
                backend.failNextTranscription = .rateLimited(retryAfter: 30)
                backend.transcriptionSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Back again.", speaker: nil),
                ]
                backend.diarizationSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Welcome back.", speaker: "A"),
                ]
                let pipeline = makePipeline(repository: meeting.repository, backend: backend)
                await pipeline.process(meetingID: meeting.metadata.id)

                let recovered = try meeting.store.readMetadata()
                expect.equal(recovered.processing.state, .complete, "the second attempt succeeded")
                expect.equal(recovered.processing.attemptCount(for: .transcribing), 2)
            },

            test("a failure that keeps happening stops asking and keeps the audio") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeRecordedMeeting(root: root)
                let segmentsBefore = try FileManager.default.contentsOfDirectory(
                    atPath: meeting.store.layout.segments.path
                ).sorted()

                let backend = FakeAIBackend()
                backend.alwaysFailTranscription = .serverError(status: 503)
                let pipeline = makePipeline(repository: meeting.repository, backend: backend)
                await pipeline.process(meetingID: meeting.metadata.id)

                let failed = try meeting.store.readMetadata()
                expect.equal(failed.processing.state, .failed)
                expect.equal(failed.processing.resumeStage, .transcribing)
                expect.equal(failed.processing.lastFailure?.isRetryable, true)
                expect.equal(
                    failed.processing.attemptCount(for: .transcribing), 3,
                    "three attempts, then the meeting waits for the user"
                )
                let segmentsAfter = try FileManager.default.contentsOfDirectory(
                    atPath: meeting.store.layout.segments.path
                ).sorted()
                expect.equal(segmentsAfter, segmentsBefore, "source audio must be untouched")

                // The Retry action still works once the outage is over.
                backend.alwaysFailTranscription = nil
                backend.transcriptionSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Back again.", speaker: nil),
                ]
                backend.diarizationSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Welcome back.", speaker: "A"),
                ]
                await pipeline.retry(meetingID: meeting.metadata.id)
                expect.equal(try meeting.store.readMetadata().processing.state, .complete)
            },

            test("an authentication failure is not retried in a loop") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeRecordedMeeting(root: root)

                let backend = FakeAIBackend()
                backend.failNextTranscription = .authenticationFailed
                let pipeline = makePipeline(repository: meeting.repository, backend: backend)
                await pipeline.process(meetingID: meeting.metadata.id)

                let failed = try meeting.store.readMetadata()
                expect.equal(failed.processing.state, .failed)
                expect.equal(failed.processing.lastFailure?.isRetryable, false)
                expect.isTrue(
                    failed.processing.lastFailure?.message.contains("recording is safe") == true,
                    "the user is told the audio survived"
                )
            },

            test("work already done is not repeated on resume") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeRecordedMeeting(root: root)

                let backend = FakeAIBackend()
                backend.transcriptionSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "First half.", speaker: nil),
                ]
                backend.failNextDiarization = .serverError(status: 503)
                backend.diarizationSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Second half.", speaker: "A"),
                ]
                let pipeline = makePipeline(repository: meeting.repository, backend: backend)
                await pipeline.process(meetingID: meeting.metadata.id)
                expect.equal(try meeting.store.readMetadata().processing.state, .complete)
                let transcribeCalls = backend.calls.filter { $0.kind == "transcribe" }.count
                expect.equal(
                    transcribeCalls, 1,
                    "diarization failed and was retried; transcription was already done"
                )
                await pipeline.retry(meetingID: meeting.metadata.id)
                expect.equal(
                    backend.calls.filter { $0.kind == "transcribe" }.count, transcribeCalls,
                    "a completed chunk must not be sent again"
                )
            },

            test("an in-person recording diarizes its only track") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeRecordedMeeting(root: root, source: .inPerson)

                let backend = FakeAIBackend()
                backend.diarizationSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Morning.", speaker: "A"),
                    RawTranscriptSegment(start: 3, end: 5, text: "Morning to you.", speaker: "B"),
                ]
                let pipeline = makePipeline(repository: meeting.repository, backend: backend)
                await pipeline.process(meetingID: meeting.metadata.id)

                expect.equal(try meeting.store.readMetadata().processing.state, .complete)
                expect.equal(backend.calls.filter { $0.kind == "transcribe" }.count, 0)
                expect.equal(backend.calls.filter { $0.kind == "diarize" }.count, 1)

                let transcript = try expect.unwrap(try meeting.store.readCanonicalTranscript())
                expect.equal(transcript.utterances[0].speakerKey, "mic_chunk_001_speaker_00")
                expect.notEqual(transcript.utterances[0].speakerKey, SpeakerLabel.localUser)
            },

            test("enrichment can be switched off entirely") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeRecordedMeeting(root: root)

                var settings = AppSettings()
                settings.enrichment = EnrichmentSettings(
                    generateTitle: false, generateDescription: false, generateNotes: false,
                    generateSummary: false, suggestSpeakers: false
                )
                let backend = FakeAIBackend()
                backend.transcriptionSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Plain transcript only.", speaker: nil),
                ]
                backend.diarizationSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Understood.", speaker: "A"),
                ]
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: backend, settings: settings
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                expect.equal(try meeting.store.readMetadata().processing.state, .complete)
                expect.equal(backend.calls.filter { $0.kind == "enrich" }.count, 0)
                expect.equal(backend.calls.filter { $0.kind == "resolve" }.count, 0)
                let transcript = try expect.unwrap(try meeting.store.readCanonicalTranscript())
                expect.equal(transcript.utterances.count, 2, "the transcript is still produced")
            },

            test("a speaker rename re-renders without touching the API") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeRecordedMeeting(root: root)

                let backend = FakeAIBackend()
                backend.transcriptionSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Mine.", speaker: nil),
                ]
                backend.diarizationSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Theirs.", speaker: "A"),
                ]
                let pipeline = makePipeline(repository: meeting.repository, backend: backend)
                await pipeline.process(meetingID: meeting.metadata.id)
                let callsAfterProcessing = backend.calls.count

                try await pipeline.applySpeakerName(
                    "Tim", to: "remote_chunk_001_speaker_00", meetingID: meeting.metadata.id
                )
                let markdown = try String(
                    contentsOf: meeting.store.layout.transcriptMarkdown, encoding: .utf8
                )
                expect.isTrue(markdown.contains("Tim"))
                expect.equal(backend.calls.count, callsAfterProcessing, "renaming must cost no API calls")

                let raw = try meeting.store.readRawTranscript()
                expect.equal(
                    raw.chunks.first { $0.track == .remote }?.segments.first?.speaker, "A",
                    "raw diarization stays as the API returned it"
                )
            },

            test("chunks of one track upload concurrently") { expect in
                // A 25-minute import took over ten minutes because its chunks
                // were sent one at a time. Each request here blocks until it has
                // seen a second request in flight, so a sequential pipeline
                // never reaches 2 and the assertion fails.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeRecordedMeeting(root: root, source: .inPerson, seconds: 12)

                let backend = ConcurrencyProbeBackend()
                let pipeline = ProcessingPipeline(
                    repository: meeting.repository,
                    backend: backend,
                    clock: ManualClock(),
                    settingsProvider: { AppSettings() },
                    wait: { _ in },
                    chunking: ChunkPlanner.Configuration(
                        targetChunkSeconds: 3, maxChunkSeconds: 4, minChunkSeconds: 1,
                        searchWindowSeconds: 0.5, overlapSeconds: 0.5
                    )
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                expect.isTrue(backend.requestCount >= 3, "the recording split into several chunks")
                expect.isTrue(
                    backend.peakInFlight >= 2,
                    "chunk requests overlap instead of running one at a time"
                )
                expect.equal(try meeting.store.readMetadata().processing.state, .complete)
            },

            test("an empty transcript for audible audio fails the meeting") { expect in
                // A 168-second chunk of ordinary speech came back as
                // {"text":""} with HTTP 200, was billed, and was recorded as a
                // finished chunk: the meeting reported complete with 47% of its
                // words missing. An empty answer for audio that carries signal
                // is a failure, not a result.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeRecordedMeeting(root: root)

                let backend = FakeAIBackend()
                backend.transcriptionSegments = []
                backend.diarizationSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Theirs.", speaker: "A"),
                ]
                let pipeline = makePipeline(repository: meeting.repository, backend: backend)
                await pipeline.process(meetingID: meeting.metadata.id)

                let status = try meeting.store.readMetadata().processing
                expect.equal(status.state, .failed, "an empty transcript must not report success")
                let failure = try expect.unwrap(status.lastFailure)
                expect.isTrue(failure.isRetryable, "the meeting can be retried")
                let raw = try meeting.store.readRawTranscript()
                expect.equal(
                    raw.chunks(track: .mic, purpose: .words).count, 0,
                    "no empty chunk is filed as done"
                )
            },

            test("an empty transcript for silent audio is accepted") { expect in
                // A muted microphone transcribes to nothing legitimately, and
                // must not leave a meeting failing forever.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeRecordedMeeting(root: root, amplitude: 0)

                let backend = FakeAIBackend()
                backend.transcriptionSegments = []
                backend.diarizationSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Theirs.", speaker: "A"),
                ]
                let pipeline = makePipeline(repository: meeting.repository, backend: backend)
                await pipeline.process(meetingID: meeting.metadata.id)

                expect.equal(try meeting.store.readMetadata().processing.state, .complete)
            },

            test("reasoning effort is requested only from models that accept it") { expect in
                expect.isTrue(AIModelSettings.acceptsReasoningEffort("gpt-5.6-luna"))
                expect.isTrue(AIModelSettings.acceptsReasoningEffort("gpt-5.1-mini"))
                expect.isTrue(AIModelSettings.acceptsReasoningEffort("o4-mini"))
                // GPT-4-generation models reject the field with a 400.
                expect.isTrue(!AIModelSettings.acceptsReasoningEffort("gpt-4.1"))
                expect.isTrue(!AIModelSettings.acceptsReasoningEffort("gpt-4o-transcribe-diarize"))
                expect.isTrue(!AIModelSettings.acceptsReasoningEffort("whisper-1"))
            },
        ])
    }
}

/// Blocks each diarization request until another one is running alongside it,
/// which distinguishes concurrent uploads from sequential ones.
final class ConcurrencyProbeBackend: AIBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var peakInFlight = 0
    private(set) var requestCount = 0

    func isConfigured() async -> Bool { true }

    func verifyCredentials(model: String) async throws {}

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResponse {
        try await diarize(DiarizationRequest(audio: request.audio, model: request.model))
    }

    func diarize(_ request: DiarizationRequest) async throws -> TranscriptionResponse {
        lock.withLock {
            inFlight += 1
            requestCount += 1
            peakInFlight = max(peakInFlight, inFlight)
        }
        // Wait briefly for a companion request; a sequential caller times out
        // here with peakInFlight stuck at 1.
        for _ in 0..<100 {
            let overlapped = lock.withLock { peakInFlight >= 2 }
            if overlapped { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        lock.withLock { inFlight -= 1 }
        return TranscriptionResponse(
            segments: [RawTranscriptSegment(start: 0, end: 1, text: "Chunk.", speaker: "A")],
            text: "Chunk.",
            durationSeconds: nil,
            rawBody: Data("{}".utf8)
        )
    }

    func resolveSpeakers(
        _ request: SpeakerResolutionRequest, model: String
    ) async throws -> [SpeakerSuggestion] { [] }

    func enrich(_ request: EnrichmentRequest, model: String) async throws -> MeetingEnrichment {
        MeetingEnrichment()
    }
}
