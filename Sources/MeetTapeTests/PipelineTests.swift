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
        root: URL, source: MeetingSource = .googleMeet, seconds: Double = 6
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
            buffer: AudioTests.makeTone(seconds: seconds, sampleRate: 48_000), hostTime: 100
        ))
        micWriter.finish(reason: "test")

        if source.capturesRemoteAudio {
            let remoteWriter = SegmentWriter(
                track: .remote, layout: created.store.layout, manifest: manifest,
                format: format, segmentSeconds: 30
            )
            remoteWriter.enqueueSynchronously(AudioBufferPacket(
                buffer: AudioTests.makeTone(seconds: seconds, sampleRate: 48_000, frequency: 220),
                hostTime: 100
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
            settingsProvider: { settings }
        )
    }

    static var suite: Suite {
        Suite("ProcessingPipeline", [
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

            test("an API failure keeps the audio and stays retryable") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeRecordedMeeting(root: root)
                let segmentsBefore = try FileManager.default.contentsOfDirectory(
                    atPath: meeting.store.layout.segments.path
                ).sorted()

                let backend = FakeAIBackend()
                backend.failNextTranscription = .rateLimited(retryAfter: 30)
                let pipeline = makePipeline(repository: meeting.repository, backend: backend)
                await pipeline.process(meetingID: meeting.metadata.id)

                let failed = try meeting.store.readMetadata()
                expect.equal(failed.processing.state, .failed)
                expect.equal(failed.processing.resumeStage, .transcribing)
                expect.equal(failed.processing.lastFailure?.isRetryable, true)

                let segmentsAfter = try FileManager.default.contentsOfDirectory(
                    atPath: meeting.store.layout.segments.path
                ).sorted()
                expect.equal(segmentsAfter, segmentsBefore, "source audio must be untouched")

                // Retrying picks up from the stage that failed and completes.
                backend.transcriptionSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Back again.", speaker: nil),
                ]
                backend.diarizationSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Welcome back.", speaker: "A"),
                ]
                await pipeline.retry(meetingID: meeting.metadata.id)

                let recovered = try meeting.store.readMetadata()
                expect.equal(recovered.processing.state, .complete)
                expect.equal(recovered.processing.attemptCount(for: .transcribing), 2)
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
                let pipeline = makePipeline(repository: meeting.repository, backend: backend)
                await pipeline.process(meetingID: meeting.metadata.id)
                expect.equal(try meeting.store.readMetadata().processing.state, .failed)
                let transcribeCalls = backend.calls.filter { $0.kind == "transcribe" }.count
                expect.equal(transcribeCalls, 1)

                backend.diarizationSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Second half.", speaker: "A"),
                ]
                await pipeline.retry(meetingID: meeting.metadata.id)
                expect.equal(try meeting.store.readMetadata().processing.state, .complete)
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

                try pipeline.applySpeakerName(
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
        ])
    }
}
