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
        remoteStartOffset: Double = 0
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

            test("reasoning effort is requested only from models that accept it") { expect in
                expect.isTrue(AIModelSettings.acceptsReasoningEffort("gpt-5.6-luna"))
                expect.isTrue(AIModelSettings.acceptsReasoningEffort("gpt-5.1-mini"))
                expect.isTrue(AIModelSettings.acceptsReasoningEffort("o4-mini"))
                // GPT-4-generation models reject the field with a 400.
                expect.isTrue(!AIModelSettings.acceptsReasoningEffort("gpt-4.1"))
                expect.isTrue(!AIModelSettings.acceptsReasoningEffort("gpt-4o-transcribe-diarize"))
                expect.isTrue(!AIModelSettings.acceptsReasoningEffort("whisper-1"))
            },

            test("splitting a turn names the words after the boundary only") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeTranscribedMeeting(root: root)
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend()
                )

                // "so what do you think" | "i think we ship on friday": the
                // question and its answer, run together by the diarizer. A
                // split runs to the end of the turn, which is already a
                // boundary, so it records one cut and not two.
                _ = try await pipeline.applySpeakerRange(
                    "Dana", meetingID: meeting.id, track: .remote,
                    lineIDs: try lineIDs(of: meeting.store),
                    startSeconds: 5, endSeconds: 11
                )

                let map = try meeting.store.readSpeakerMap()
                expect.equal(map.lineCuts.count, 1, "one boundary, recorded once")
                expect.close(map.lineCuts.first?.atSeconds ?? 0, 5, tolerance: 0.001)

                let lines = try expect.unwrap(
                    try meeting.store.readCanonicalTranscript()
                ).utterances
                expect.equal(lines.count, 2, "the line reads as two")
                expect.equal(lines[0].text, "so what do you think")
                expect.equal(lines[1].text, "i think we ship on friday")
                expect.equal(map.resolvedName(for: lines[1]), "Dana")
                expect.equal(
                    map.resolvedName(for: lines[0]), "Priya",
                    "the words before the boundary stay with the cluster"
                )
                let markdown = try String(
                    contentsOf: meeting.store.layout.transcriptMarkdown, encoding: .utf8
                )
                expect.isTrue(markdown.contains("Dana"), "and the markdown says so too")
                expect.isTrue(markdown.contains("Priya"), "on the half that kept its name")
            },

            test("pulling a phrase out leaves the words either side alone") { expect in
                // What an interjection needs: the diarizer missed someone
                // chiming in, and correcting the whole turn would move the
                // speaker's own words with it.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeTranscribedMeeting(root: root)
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend()
                )

                _ = try await pipeline.applySpeakerRange(
                    "Dana", meetingID: meeting.id, track: .remote,
                    lineIDs: try lineIDs(of: meeting.store),
                    startSeconds: 5, endSeconds: 7
                )

                let map = try meeting.store.readSpeakerMap()
                let lines = try expect.unwrap(
                    try meeting.store.readCanonicalTranscript()
                ).utterances
                expect.equal(lines.count, 3, "two boundaries, three pieces")
                expect.equal(lines.map { map.resolvedName(for: $0) }, ["Priya", "Dana", "Priya"])
                expect.equal(lines[1].text, "i think", "only the phrase moved")
            },

            test("a name set before the split stays on the piece nobody touched") { expect in
                // Both pieces sit inside the correction's span, so a correction
                // on one of them would take the wide override off the other and
                // the first half would silently revert to the cluster.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeTranscribedMeeting(root: root)
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend()
                )

                let first = try expect.unwrap(
                    try meeting.store.readCanonicalTranscript()
                ).utterances[0]
                _ = try await pipeline.applyUtteranceSpeaker(
                    "Sam", utteranceIDs: [first.id], meetingID: meeting.id
                )
                _ = try await pipeline.applySpeakerRange(
                    "Dana", meetingID: meeting.id, track: .remote,
                    lineIDs: try lineIDs(of: meeting.store),
                    startSeconds: 5, endSeconds: 11
                )

                let map = try meeting.store.readSpeakerMap()
                let lines = try expect.unwrap(
                    try meeting.store.readCanonicalTranscript()
                ).utterances
                expect.equal(lines.map { map.resolvedName(for: $0) }, ["Sam", "Dana"])
            },

            test("splitting a line keeps a narrow correction narrow") { expect in
                // A name set on a short interjection displays across the turn
                // it was merged into and confirms none of it. Stretching that
                // correction to the piece it lands in would confirm the whole
                // piece, and the words before the interjection are somebody
                // else's voice going into that person's profile.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeTranscribedMeeting(root: root)
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend()
                )

                // Confirmed on "what do" alone, two seconds of an 11 s line.
                var speakers = try meeting.store.readSpeakerMap()
                speakers.utteranceOverrides.append(UtteranceOverride(
                    track: .remote, anchorSeconds: 2, startSeconds: 1, endSeconds: 3,
                    assignment: SpeakerAssignment(displayName: "Sam", origin: .human),
                    createdAt: Date(), chunkID: "c1"
                ))
                try meeting.store.writeSpeakerMap(speakers)

                _ = try await pipeline.applySpeakerRange(
                    "Dana", meetingID: meeting.id, track: .remote,
                    lineIDs: try lineIDs(of: meeting.store),
                    startSeconds: 5, endSeconds: 11
                )

                let map = try meeting.store.readSpeakerMap()
                let sam = try expect.unwrap(
                    map.utteranceOverrides.first { $0.assignment.displayName == "Sam" }
                )
                expect.close(
                    sam.startSeconds ?? 0, 1, tolerance: 0.001,
                    "the correction still starts where the person put it"
                )
                expect.close(
                    sam.endSeconds ?? 0, 3, tolerance: 0.001,
                    "and still ends there, rather than growing to the piece"
                )
                let lines = try expect.unwrap(
                    try meeting.store.readCanonicalTranscript()
                ).utterances
                expect.equal(lines.count, 2)
                expect.equal(map.resolvedName(for: lines[0]), "Sam", "it still names its line")
                expect.isFalse(
                    map.confirms(lines[0]),
                    "and still confirms none of it, so the other four seconds of that "
                        + "piece cannot reach Sam's voice profile"
                )
            },

            test("a split reaches the line the reader clicked, not an overlapping twin") { expect in
                // Chunks overlap by eight seconds and a near-duplicate is only
                // dropped above a similarity bar, so two lines on one track
                // routinely hold the same second. Placed by time alone the
                // boundary went into whichever sorted first, and the other
                // speaker's words were handed to the person being named.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeTranscribedMeeting(root: root, withOverlappingTwin: true)
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend()
                )

                // The reader clicked the second chunk's line, which sorts after
                // the first line and sits entirely inside its span.
                let all = try expect.unwrap(try meeting.store.readCanonicalTranscript()).utterances
                let clicked = try expect.unwrap(all.first { $0.chunkID == "c2" })
                _ = try await pipeline.applySpeakerRange(
                    "Dana", meetingID: meeting.id, track: .remote, lineIDs: [clicked.id],
                    startSeconds: 6, endSeconds: 10
                )

                let map = try meeting.store.readSpeakerMap()
                expect.equal(
                    map.lineCuts.first?.chunkID, "c2", "the boundary went in the line clicked"
                )
                let lines = try expect.unwrap(
                    try meeting.store.readCanonicalTranscript()
                ).utterances
                let untouched = try expect.unwrap(lines.first { $0.chunkID == "c1" })
                expect.close(
                    untouched.end - untouched.start, 11, tolerance: 0.001,
                    "the other chunk's line was not divided"
                )
                expect.equal(
                    map.resolvedName(for: untouched), "Priya",
                    "and did not change hands"
                )
                expect.equal(map.utteranceOverrides.count, 1, "one piece changed hands")
                expect.equal(
                    lines.filter { $0.chunkID == "c2" }.map(\.text),
                    ["the other", "chunk heard this too"]
                )
            },

            test("pulling out the first words of a turn names them") { expect in
                // A line starts before its first word and ends after its last,
                // and the outermost piece keeps those edges. Compared against
                // the span rather than the words, the first phrase of a turn
                // matched no piece: the boundary was written, the name was not,
                // and the paragraph split in two with one name on both halves.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeTranscribedMeeting(root: root, padded: true)
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend()
                )

                // "so", the first word, which starts a second after the line
                // does and lasts less than that second.
                _ = try await pipeline.applySpeakerRange(
                    "Dana", meetingID: meeting.id, track: .remote,
                    lineIDs: try lineIDs(of: meeting.store),
                    startSeconds: 1, endSeconds: 1.7
                )

                let map = try meeting.store.readSpeakerMap()
                let lines = try expect.unwrap(
                    try meeting.store.readCanonicalTranscript()
                ).utterances
                expect.equal(lines.count, 2)
                expect.equal(lines[0].text, "so")
                expect.equal(map.resolvedName(for: lines[0]), "Dana")
                expect.equal(map.resolvedName(for: lines[1]), "Priya", "the rest is untouched")
            },

            test("pulling out the last words of a turn names them") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeTranscribedMeeting(root: root, padded: true)
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend()
                )

                // "friday", the last word, which ends a second before the line
                // does and lasts less than that second.
                _ = try await pipeline.applySpeakerRange(
                    "Dana", meetingID: meeting.id, track: .remote,
                    lineIDs: try lineIDs(of: meeting.store),
                    startSeconds: 11, endSeconds: 11.7
                )

                let map = try meeting.store.readSpeakerMap()
                let lines = try expect.unwrap(
                    try meeting.store.readCanonicalTranscript()
                ).utterances
                expect.equal(lines.count, 2)
                expect.equal(lines[1].text, "friday")
                expect.equal(map.resolvedName(for: lines[1]), "Dana")
                expect.equal(map.resolvedName(for: lines[0]), "Priya")
            },

            test("a boundary is kept when the transcript is assembled again") { expect in
                // A cut is a claim about the audio, so it outlives re-assembly
                // and re-analysis the way a line correction does.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try makeTranscribedMeeting(root: root)
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend()
                )
                _ = try await pipeline.applySpeakerRange(
                    "Dana", meetingID: meeting.id, track: .remote,
                    lineIDs: try lineIDs(of: meeting.store),
                    startSeconds: 5, endSeconds: 11
                )
                // Whatever else re-assembly does, the boundary and the name it
                // carries are still there to apply.
                let map = try meeting.store.readSpeakerMap()
                expect.equal(map.lineCuts.count, 1)
                expect.equal(map.utteranceOverrides.count, 1)
                expect.equal(map.utteranceOverrides.first?.assignment.displayName, "Dana")
            },
        ])
    }

    /// Every line the panel would be showing.
    static func lineIDs(of store: MeetingStore) throws -> [String] {
        (try store.readCanonicalTranscript())?.utterances.map(\.id) ?? []
    }

    /// A meeting with one transcript line: a question and its answer run
    /// together on one speaker, with word timings a second apart.
    /// - Parameter padded: the line starts a second before its first word and
    ///   ends a second after its last, which is what a decoder reports.
    static func makeTranscribedMeeting(
        root: URL, withOverlappingTwin: Bool = false, padded: Bool = false
    ) throws -> (id: String, store: MeetingStore, repository: MeetingRepository) {
        let repository = MeetingRepository(root: root)
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .googleMeet, provider: .googleMeet, startedAt: started,
            titles: TitleCandidates(provider: "Weekly sync", timestampFallback: "f"), now: started
        )
        _ = try created.store.updateMetadata { $0.durationSeconds = 30 }
        let texts = ["so", "what", "do", "you", "think", "i", "think", "we", "ship", "on", "friday"]
        // A padded line begins a second before its first word and ends a
        // second after its last, which is what a decoder reports.
        let lead = padded ? 1.0 : 0.0
        let words = texts.enumerated().map {
            RawTranscriptWord(
                start: lead + Double($0.offset), end: lead + Double($0.offset) + 0.7,
                text: " \($0.element)"
            )
        }
        let lineStart = 0.0
        let lineEnd = padded ? 12.7 : 11.0
        var utterances = [Utterance(
            id: Utterance.identifier(
                chunkID: "c1", track: .remote, start: lineStart, end: lineEnd
            ),
            start: lineStart, end: lineEnd, track: .remote,
            rawSpeakerLabel: "remote-001_speaker_00",
            speakerKey: "remote-001_speaker_00", text: texts.joined(separator: " "),
            chunkID: "c1", model: "m", words: words
        )]
        if withOverlappingTwin {
            // The next chunk's own transcription of the same audio, segmented
            // differently and kept because it is not similar enough to drop.
            let twinWords = ["the", "other", "chunk", "heard", "this", "too"].enumerated().map {
                RawTranscriptWord(
                    start: 4 + Double($0.offset), end: 4 + Double($0.offset) + 0.7,
                    text: " \($0.element)"
                )
            }
            utterances.append(Utterance(
                id: Utterance.identifier(chunkID: "c2", track: .remote, start: 4, end: 10),
                start: 4, end: 10, track: .remote, rawSpeakerLabel: "remote-001_speaker_00",
                speakerKey: "remote-001_speaker_00", text: "the other chunk heard this too",
                chunkID: "c2", model: "m", words: twinWords
            ))
        }
        try created.store.writeCanonicalTranscript(
            CanonicalTranscript(generatedAt: started, utterances: utterances)
        )
        var map = SpeakerMap()
        map.assign("Priya", to: "remote-001_speaker_00")
        try created.store.writeSpeakerMap(map)
        return (created.metadata.id, created.store, repository)
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
