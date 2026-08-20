import Foundation
import MeetTapeCore
import MeetTapeIntegrations
import MeetTapeLocalAI
import MeetTapeServices
import MeetTapeSpeakers
import TestKit

/// A transcription backend with no model behind it, so the local path can be
/// exercised end to end without 650 MB of CoreML.
struct StubLocalTranscriber: TranscriptionBackend, @unchecked Sendable {
    var segments: [RawTranscriptSegment]
    var identifier = "stub-whisper"
    var isLocal = true
    var limits = BackendAudioLimits.none
    var producesWordTimestamps = true

    func transcribe(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionOutput {
        progress(1)
        return TranscriptionOutput(
            segments: segments, text: segments.map(\.text).joined(separator: " "),
            language: "en", durationSeconds: 6
        )
    }
}

struct StubLocalDiarizer: DiarizationBackend, @unchecked Sendable {
    var intervals: [DiarizationInterval]
    var chunkEmbeddings: [DiarizationChunkEmbedding]
    var identifier = "stub-fluidaudio"
    var isLocal = true
    var limits = BackendAudioLimits.none
    var producesEmbeddings = true
    var producesTranscript = false

    func diarize(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DiarizationOutput {
        progress(1)
        var speech: [String: Double] = [:]
        for interval in intervals { speech[interval.clusterID, default: 0] += interval.duration }
        return DiarizationOutput(
            intervals: intervals,
            clusters: speech.keys.sorted().map {
                DiarizationCluster(id: $0, speechSeconds: speech[$0] ?? 0)
            },
            chunkEmbeddings: chunkEmbeddings,
            configuration: ["warmStartFa": "0.2"]
        )
    }
}

/// Stands in for the embedding extractor on a machine with no models installed.
struct RefusingEmbeddingExtractor: SpeakerEmbeddingExtractor {
    var model: EmbeddingModelIdentifier { .fluidAudioOffline }

    func embed(audio: URL, intervals: [DiarizationInterval]) async throws -> [DiarizationChunkEmbedding] {
        throw LocalModelError.notInstalled
    }
}

/// The whole local path, with the models replaced and everything else real.
enum LocalPipelineTests {

    static func embeddings(cluster: String, seed: Int, spans: [(Double, Double)]) -> [DiarizationChunkEmbedding] {
        spans.map {
            DiarizationChunkEmbedding(
                clusterID: cluster, start: $0.0, end: $0.1,
                vector: SpeakerIdentityTests.vector(seed: seed)
            )
        }
    }

    static func makePipeline(
        repository: MeetingRepository,
        backend: FakeAIBackend,
        transcriber: StubLocalTranscriber,
        diarizer: StubLocalDiarizer,
        speakers: SpeakerRecognitionService?,
        settings: AppSettings,
        scratchRoot: URL
    ) -> ProcessingPipeline {
        ProcessingPipeline(
            repository: repository,
            backend: backend,
            backends: ProcessingBackends(
                transcription: { _, _ in transcriber },
                diarization: { _, _ in diarizer },
                speakers: speakers
            ),
            scratch: ProcessingScratch(root: scratchRoot),
            clock: ManualClock(),
            settingsProvider: { settings },
            wait: { _ in }
        )
    }

    static var suite: Suite {
        Suite("LocalPipeline", [
            test("a local run transcribes, diarizes and attributes every word") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                let transcriber = StubLocalTranscriber(segments: [
                    RawTranscriptSegment(
                        start: 0, end: 5, text: "we ship friday no we do not", speaker: nil,
                        words: [
                            RawTranscriptWord(start: 0.0, end: 0.3, text: " we"),
                            RawTranscriptWord(start: 0.4, end: 0.8, text: " ship"),
                            RawTranscriptWord(start: 0.9, end: 1.4, text: " friday"),
                            RawTranscriptWord(start: 3.0, end: 3.2, text: " no"),
                            RawTranscriptWord(start: 3.3, end: 3.5, text: " we"),
                            RawTranscriptWord(start: 3.6, end: 3.8, text: " do"),
                            RawTranscriptWord(start: 3.9, end: 4.2, text: " not"),
                        ]
                    ),
                ])
                let diarizer = StubLocalDiarizer(
                    intervals: [
                        DiarizationInterval(start: 0, end: 2, clusterID: "S1"),
                        DiarizationInterval(start: 2.9, end: 4.5, clusterID: "S2"),
                    ],
                    chunkEmbeddings: embeddings(cluster: "S1", seed: 31, spans: [(0, 2)])
                        + embeddings(cluster: "S2", seed: 32, spans: [(2.9, 4.5)])
                )

                var settings = AppSettings()
                settings.enrichment = EnrichmentSettings(
                    generateTitle: false, generateDescription: false, generateNotes: false,
                    generateSummary: false, suggestSpeakers: false
                )
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: transcriber, diarizer: diarizer, speakers: nil,
                    settings: settings, scratchRoot: root.appendingPathComponent("scratch")
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                let metadata = try meeting.store.readMetadata()
                expect.equal(metadata.processing.state, .complete)

                let raw = try meeting.store.readRawTranscript()
                expect.isTrue(
                    raw.chunks.contains { $0.id == "mic_full" },
                    "the local track is transcribed in one request, not chunked"
                )
                expect.isTrue(raw.chunks.contains { $0.id == "remote_full" })

                let diarization = try meeting.store.readRawDiarization()
                let run = try expect.unwrap(diarization.activeRun(track: .remote))
                expect.equal(run.backend, "stub-fluidaudio")
                expect.equal(run.configuration["warmStartFa"], "0.2")
                expect.equal(run.speakerCount, 2)

                let transcript = try expect.unwrap(try meeting.store.readCanonicalTranscript())
                let remote = transcript.utterances.filter { $0.track == .remote }
                expect.equal(remote.count, 2, "the segment was split where the speaker changed")
                expect.equal(remote[0].text, "we ship friday")
                expect.equal(remote[1].text, "no we do not")
                expect.notEqual(remote[0].speakerKey, remote[1].speakerKey)
            },

            test("rebuilding the transcript keeps every speaker") { expect in
                // Rebuild re-assembles from the files on disk. For a local run
                // the speakers live in a separate file from the words, and
                // leaving it out collapsed every speaker into one cluster and
                // orphaned every name the user had typed.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                var settings = AppSettings()
                settings.enrichment = EnrichmentSettings(
                    generateTitle: false, generateDescription: false, generateNotes: false,
                    generateSummary: false, suggestSpeakers: false
                )
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: StubLocalTranscriber(segments: [
                        RawTranscriptSegment(
                            start: 0, end: 5, text: "we ship friday no we do not", speaker: nil,
                            words: [
                                RawTranscriptWord(start: 0.0, end: 0.3, text: " we"),
                                RawTranscriptWord(start: 0.4, end: 0.8, text: " ship"),
                                RawTranscriptWord(start: 0.9, end: 1.4, text: " friday"),
                                RawTranscriptWord(start: 3.0, end: 3.2, text: " no"),
                                RawTranscriptWord(start: 3.3, end: 3.5, text: " we"),
                                RawTranscriptWord(start: 3.6, end: 3.8, text: " do"),
                                RawTranscriptWord(start: 3.9, end: 4.2, text: " not"),
                            ]
                        ),
                    ]),
                    diarizer: StubLocalDiarizer(
                        intervals: [
                            DiarizationInterval(start: 0, end: 2, clusterID: "S1"),
                            DiarizationInterval(start: 2.9, end: 4.5, clusterID: "S2"),
                        ],
                        chunkEmbeddings: embeddings(cluster: "S1", seed: 41, spans: [(0, 2)])
                            + embeddings(cluster: "S2", seed: 42, spans: [(2.9, 4.5)])
                    ),
                    speakers: nil,
                    settings: settings, scratchRoot: root.appendingPathComponent("scratch")
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                let before = try expect.unwrap(try meeting.store.readCanonicalTranscript())
                let keysBefore = Set(before.utterances.filter { $0.track == .remote }.map(\.speakerKey))
                expect.equal(keysBefore.count, 2)

                // Name one of them, the way a user would.
                let named = try expect.unwrap(keysBefore.sorted().first)
                var map = try meeting.store.readSpeakerMap()
                map.assign("Chris", to: named)
                try meeting.store.writeSpeakerMap(map)

                try await pipeline.rebuildTranscript(meetingID: meeting.metadata.id)

                let after = try expect.unwrap(try meeting.store.readCanonicalTranscript())
                let keysAfter = Set(after.utterances.filter { $0.track == .remote }.map(\.speakerKey))
                expect.equal(keysAfter, keysBefore, "rebuilding must not change who spoke when")
                let markdown = try String(
                    contentsOf: meeting.store.layout.transcriptMarkdown, encoding: .utf8
                )
                expect.isTrue(markdown.contains("Chris"), "the name the user typed still renders")
            },

            test("a local run leaves no voice vectors in the meeting folder") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                let store = try SpeakerStore(url: root.appendingPathComponent("voices.sqlite"))
                var settings = AppSettings()
                settings.enrichment = EnrichmentSettings(
                    generateTitle: false, generateDescription: false, generateNotes: false,
                    generateSummary: false, suggestSpeakers: false
                )
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: StubLocalTranscriber(segments: [
                        RawTranscriptSegment(
                            start: 0, end: 5, text: "hello", speaker: nil,
                            words: [RawTranscriptWord(start: 0, end: 1, text: " hello")]
                        ),
                    ]),
                    diarizer: StubLocalDiarizer(
                        intervals: [DiarizationInterval(start: 0, end: 5, clusterID: "S1")],
                        chunkEmbeddings: embeddings(cluster: "S1", seed: 33, spans: [(0, 5)])
                    ),
                    speakers: SpeakerRecognitionService(store: store),
                    settings: settings, scratchRoot: root.appendingPathComponent("scratch")
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                // The vector reached the local store.
                let occurrences = try await store.occurrences(meetingID: meeting.metadata.id)
                expect.equal(occurrences.count, 1)
                expect.isTrue(
                    try await store.occurrenceEmbedding(
                        meetingID: meeting.metadata.id, clusterID: occurrences[0].clusterID
                    ) != nil
                )

                // And nothing in the folder the user copies, syncs and shares
                // holds a float array long enough to be one.
                let files = try FileManager.default.subpathsOfDirectory(
                    atPath: meeting.store.layout.root.path
                )
                // Every text file in the folder, not only *.json: manifest.jsonl
                // is not caught by that suffix. And "vector" is the key
                // DiarizationChunkEmbedding actually encodes, which is what the
                // rule is about; searching only for "embedding" and "centroid"
                // meant this test would not have caught a vector being written.
                for file in files {
                    let url = meeting.store.layout.root.appendingPathComponent(file)
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(
                        atPath: url.path, isDirectory: &isDirectory
                    ), !isDirectory.boolValue else { continue }
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    for key in ["\"vector\"", "\"embedding\"", "\"centroid\"", "\"embedding256\""] {
                        expect.isFalse(
                            text.contains(key),
                            "\(file) carries \(key) into the folder a user copies and shares"
                        )
                    }
                }
            },

            test("a cloud diarization still records the speakers for voice memory") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                let backend = FakeAIBackend()
                backend.transcriptionSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Mine.", speaker: nil),
                ]
                backend.diarizationSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Theirs.", speaker: "A"),
                    RawTranscriptSegment(start: 3, end: 5, text: "And mine.", speaker: "B"),
                ]
                var settings = AppSettings()
                settings.processing.transcription = .openAI
                settings.processing.diarization = .openAI
                settings.enrichment = EnrichmentSettings(
                    generateTitle: false, generateDescription: false, generateNotes: false,
                    generateSummary: false, suggestSpeakers: false
                )
                let resolved = settings
                let pipeline = ProcessingPipeline(
                    repository: meeting.repository,
                    backend: backend,
                    backends: .openAIOnly(backend),
                    scratch: ProcessingScratch(root: root.appendingPathComponent("scratch")),
                    clock: ManualClock(),
                    settingsProvider: { resolved },
                    wait: { _ in }
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                let diarization = try meeting.store.readRawDiarization()
                let run = try expect.unwrap(diarization.activeRun(track: .remote))
                expect.equal(run.speakerCount, 2)
                expect.isTrue(
                    run.clusters.allSatisfy { $0.id.contains("_speaker_") },
                    "the run's cluster keys join the transcript's own keys"
                )

                let transcript = try expect.unwrap(try meeting.store.readCanonicalTranscript())
                expect.equal(
                    transcript.utterances.filter { $0.track == .remote }.count, 2,
                    "the cloud path's own labels are kept exactly as they were"
                )
            },

            test("a cloud-only meeting never starts a model download for voice memory") { expect in
                // Recognizing voices is on by default. On a machine that chose
                // OpenAI for both stages and never pressed Download, wanting
                // vectors must not fetch 650 MB from inside a processing stage.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                let store = try SpeakerStore(url: root.appendingPathComponent("voices.sqlite"))

                let backend = FakeAIBackend()
                backend.transcriptionSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Mine.", speaker: nil),
                ]
                backend.diarizationSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Theirs.", speaker: "A"),
                ]
                var settings = AppSettings()
                settings.processing.transcription = .openAI
                settings.processing.diarization = .openAI
                settings.enrichment = EnrichmentSettings(
                    generateTitle: false, generateDescription: false, generateNotes: false,
                    generateSummary: false, suggestSpeakers: false
                )
                let resolved = settings

                let installs = LockedCounter()
                let pipeline = ProcessingPipeline(
                    repository: meeting.repository,
                    backend: backend,
                    backends: ProcessingBackends(
                        transcription: { _, model in
                            OpenAITranscriptionBackend(backend: backend, model: model)
                        },
                        diarization: { _, model in
                            OpenAIDiarizationBackend(backend: backend, model: model)
                        },
                        embeddings: RefusingEmbeddingExtractor(),
                        speakers: SpeakerRecognitionService(store: store),
                        prepareLocalModels: { installs.enter(); installs.leave() },
                        requireLocalModels: { throw LocalModelError.notInstalled }
                    ),
                    scratch: ProcessingScratch(root: root.appendingPathComponent("scratch")),
                    clock: ManualClock(),
                    settingsProvider: { resolved },
                    wait: { _ in }
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                expect.equal(installs.total, 0, "no local model install was started")
                expect.equal(
                    try meeting.store.readMetadata().processing.state, .complete,
                    "and the meeting still finished"
                )
                expect.isTrue(
                    try await store.searchableProfiles(model: .fluidAudioOffline).isEmpty
                )
            },

            test("the default configuration finishes a meeting with no API key") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                // Stock settings: both speech backends local, and every
                // enrichment switch on, which is what a fresh install has.
                let settings = AppSettings()
                expect.isTrue(settings.processing.usesLocalTranscription)
                expect.isTrue(settings.enrichment.suggestSpeakers)

                let backend = FakeAIBackend()
                backend.configured = false

                let pipeline = makePipeline(
                    repository: meeting.repository, backend: backend,
                    transcriber: StubLocalTranscriber(segments: [
                        RawTranscriptSegment(
                            start: 0, end: 5, text: "we ship friday", speaker: nil,
                            words: [RawTranscriptWord(start: 0, end: 2, text: " we ship friday")]
                        ),
                    ]),
                    diarizer: StubLocalDiarizer(
                        intervals: [DiarizationInterval(start: 0, end: 5, clusterID: "S1")],
                        chunkEmbeddings: embeddings(cluster: "S1", seed: 51, spans: [(0, 5)])
                    ),
                    speakers: nil,
                    settings: settings, scratchRoot: root.appendingPathComponent("scratch")
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                expect.equal(
                    try meeting.store.readMetadata().processing.state, .complete,
                    "a meeting that needs nothing from the cloud must not stop at a cloud stage"
                )
                // The stages after speaker resolution are where these are
                // written, so reaching them is the thing being checked.
                expect.isTrue(
                    FileManager.default.fileExists(
                        atPath: meeting.store.layout.transcriptMarkdown.path
                    ),
                    "the readable transcript is written"
                )
                expect.isFalse(
                    backend.calls.contains { $0.kind == "resolve" || $0.kind == "enrich" },
                    "and no cloud request was attempted"
                )
            },

            test("local transcription keeps the words local when the cloud diarizes") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                let settings: AppSettings = {
                    var value = AppSettings()
                    value.processing = ProcessingSettings(
                        transcription: .local, diarization: .openAI
                    )
                    value.enrichment = EnrichmentSettings(
                        generateTitle: false, generateDescription: false, generateNotes: false,
                        generateSummary: false, suggestSpeakers: false
                    )
                    return value
                }()

                // The cloud diarizer returns words as well as labels.
                let cloud = FakeAIBackend()
                cloud.diarizationSegments = [
                    RawTranscriptSegment(
                        start: 0, end: 5, text: "CLOUD WORDS", speaker: "A", words: nil
                    ),
                ]
                let local = StubLocalTranscriber(segments: [
                    RawTranscriptSegment(
                        start: 0, end: 5, text: "local words", speaker: nil,
                        words: [RawTranscriptWord(start: 0, end: 2, text: " local words")]
                    ),
                ])

                let pipeline = ProcessingPipeline(
                    repository: meeting.repository,
                    backend: cloud,
                    backends: ProcessingBackends(
                        transcription: { _, _ in local },
                        diarization: { _, model in
                            OpenAIDiarizationBackend(backend: cloud, model: model)
                        }
                    ),
                    scratch: ProcessingScratch(root: root.appendingPathComponent("scratch")),
                    clock: ManualClock(),
                    settingsProvider: { settings },
                    wait: { _ in }
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                let transcript = try meeting.store.readCanonicalTranscript()
                let text = (transcript?.utterances ?? []).map(\.text).joined(separator: " ")
                expect.isTrue(
                    text.contains("local words"),
                    "the words come from the transcription backend the user chose"
                )
                expect.isFalse(
                    text.contains("CLOUD WORDS"),
                    "and the diarizer's copy of them is not assembled a second time"
                )
                // The labels it was asked for are still used.
                let runs = try meeting.store.readRawDiarization()
                expect.isFalse(runs.runs.isEmpty, "the cloud labels still produce a run")
            },

            test("renaming reaches a meeting that saw the merged identity") { expect in
                // Through refreshCachedNames itself. The store's family walk and
                // SpeakerMap.refreshName are covered elsewhere; what is only in
                // this function is that it applies the second to the whole of
                // the first, which is what a rename after a merge needs.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                let (store, storeRoot) = try SpeakerIdentityTests.makeStore()
                defer { try? FileManager.default.removeItem(at: storeRoot) }

                let ann = try await store.createPerson(name: "Ann")
                let bob = try await store.createPerson(name: "Bob")
                try await store.recordOccurrence(
                    meetingID: meeting.metadata.id, clusterID: "remote-001_speaker_00",
                    track: .remote, speechSeconds: 120, embedding: nil, model: nil,
                    resolution: nil, identityID: ann.id, source: .human,
                    humanVerified: true, wasExpectedParticipant: false
                )
                // The meeting keeps the link it was written with.
                var map = SpeakerMap()
                map.assign("Ann", to: "remote-001_speaker_00", identityID: ann.id)
                try meeting.store.writeSpeakerMap(map)

                try await store.merge(ann.id, into: bob.id)
                _ = try await store.rename(bob.id, to: "Bob Tran")

                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: StubLocalTranscriber(segments: []),
                    diarizer: StubLocalDiarizer(intervals: [], chunkEmbeddings: []),
                    speakers: SpeakerRecognitionService(store: store),
                    settings: AppSettings(),
                    scratchRoot: root.appendingPathComponent("scratch")
                )
                try await pipeline.refreshCachedNames(for: bob.id)

                expect.equal(
                    try meeting.store.readSpeakerMap().displayName(for: "remote-001_speaker_00"),
                    "Bob Tran",
                    "the entry written under the merged identifier is refreshed too"
                )
                expect.equal(
                    try meeting.store.readSpeakerMap().entries["remote-001_speaker_00"]?.identityID,
                    ann.id,
                    "and the link is left alone, so separating the merge can find it"
                )
            },

            test("losing the network at the end still leaves a readable meeting") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                // A key is configured, so enrichment is attempted, and the
                // request fails the way a closed lid or lost wifi fails.
                let backend = FakeAIBackend()
                backend.failEnrichment = .transport(reason: "offline")

                let settings: AppSettings = {
                    var value = AppSettings()
                    value.enrichment = EnrichmentSettings(
                        generateTitle: true, generateDescription: false, generateNotes: false,
                        generateSummary: true, suggestSpeakers: false
                    )
                    return value
                }()
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: backend,
                    transcriber: StubLocalTranscriber(segments: [
                        RawTranscriptSegment(
                            start: 0, end: 5, text: "we ship friday", speaker: nil,
                            words: [RawTranscriptWord(start: 0, end: 2, text: " we ship friday")]
                        ),
                    ]),
                    diarizer: StubLocalDiarizer(
                        intervals: [DiarizationInterval(start: 0, end: 5, clusterID: "S1")],
                        chunkEmbeddings: []
                    ),
                    speakers: nil,
                    settings: settings, scratchRoot: root.appendingPathComponent("scratch")
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                // The stage still fails and still says so.
                expect.equal(try meeting.store.readMetadata().processing.state, .failed)
                // But the words were already on this machine, so the archive is
                // written: the markdown had no recovery but Rebuild Transcript,
                // and the mixdown had none at all.
                expect.isTrue(
                    FileManager.default.fileExists(
                        atPath: meeting.store.layout.transcriptMarkdown.path
                    ),
                    "the readable transcript survives a failed enrichment"
                )
            },

            test("a reconnected meeting is still transcribed after it is folded in") { expect in
                // combine links the metadata and moves no audio, so the second
                // half of a dropped call lives only in its own folder. Hiding it
                // from the archive listing must not hide it from processing.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let earlier = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                let later = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                _ = try later.store.updateMetadata { $0.mergedIntoMeetingID = earlier.metadata.id }
                expect.isNil(
                    later.repository.findMeeting(id: later.metadata.id),
                    "it is hidden from the archive, which is what the listing wants"
                )

                let settings: AppSettings = {
                    var value = AppSettings()
                    value.enrichment = EnrichmentSettings(
                        generateTitle: false, generateDescription: false, generateNotes: false,
                        generateSummary: false, suggestSpeakers: false
                    )
                    return value
                }()
                let pipeline = makePipeline(
                    repository: later.repository, backend: FakeAIBackend(),
                    transcriber: StubLocalTranscriber(segments: [
                        RawTranscriptSegment(
                            start: 0, end: 5, text: "second half", speaker: nil,
                            words: [RawTranscriptWord(start: 0, end: 2, text: " second half")]
                        ),
                    ]),
                    diarizer: StubLocalDiarizer(
                        intervals: [DiarizationInterval(start: 0, end: 5, clusterID: "S1")],
                        chunkEmbeddings: []
                    ),
                    speakers: nil,
                    settings: settings, scratchRoot: root.appendingPathComponent("scratch")
                )
                await pipeline.process(meetingID: later.metadata.id)

                expect.equal(
                    try later.store.readMetadata().processing.state, .complete,
                    "the audio that only this folder holds is transcribed"
                )
                expect.isTrue(
                    later.repository.mergedMeetingIDs().contains(later.metadata.id),
                    "and recovery can enumerate it, so an interrupted run resumes"
                )
                let transcript = try later.store.readCanonicalTranscript()
                expect.isTrue(
                    (transcript?.utterances ?? []).contains { $0.text.contains("second half") }
                )
            },

            test("leaving a cluster unknown takes the voice back, through the panel") { expect in
                // Driven by the control the user actually has: an empty name
                // through applySpeakerName. Calling the store directly missed
                // that the clear path had no retraction at all.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                let (store, storeRoot) = try SpeakerIdentityTests.makeStore()
                defer { try? FileManager.default.removeItem(at: storeRoot) }

                let key = "remote-001_speaker_00"
                try await store.recordOccurrence(
                    meetingID: meeting.metadata.id, clusterID: key, track: .remote,
                    speechSeconds: 200, embedding: SpeakerIdentityTests.vector(seed: 84),
                    model: .fluidAudioOffline, resolution: nil, identityID: nil,
                    source: .ai, humanVerified: false, wasExpectedParticipant: false
                )

                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: StubLocalTranscriber(segments: []),
                    diarizer: StubLocalDiarizer(intervals: [], chunkEmbeddings: []),
                    speakers: SpeakerRecognitionService(store: store),
                    settings: AppSettings(),
                    scratchRoot: root.appendingPathComponent("scratch")
                )

                let chris = try await expect.unwrap(
                    try await pipeline.applySpeakerName("Chris", to: key, meetingID: meeting.metadata.id)
                )
                expect.equal(
                    try await store.profileStatus(of: chris, model: .fluidAudioOffline).sampleCount,
                    1,
                    "confirming a cluster is what builds a profile"
                )

                _ = try await pipeline.applySpeakerName("", to: key, meetingID: meeting.metadata.id)
                expect.equal(
                    try await store.profileStatus(of: chris, model: .fluidAudioOffline).sampleCount,
                    0,
                    "and clearing it takes the voice back, or the next pass writes the name again"
                )
                expect.isNil(
                    try await store.occurrences(meetingID: meeting.metadata.id)
                        .first { $0.clusterID == key }?.resolvedIdentityID
                )
            },

            test("re-analysing speakers keeps the previous result and the words") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                var diarization = RawDiarization()
                let first = DiarizationRun(
                    id: "remote-001", track: .remote, backend: "stub", producedAt: Date(),
                    timelineOffset: 0,
                    clusters: [DiarizationCluster(id: "S1", speechSeconds: 5)],
                    intervals: [DiarizationInterval(start: 0, end: 5, clusterID: "S1")]
                )
                diarization.setActive(first)
                let second = DiarizationRun(
                    id: diarization.nextRunID(track: .remote), track: .remote, backend: "stub",
                    producedAt: Date(), timelineOffset: 0,
                    clusters: [
                        DiarizationCluster(id: "S1", speechSeconds: 3),
                        DiarizationCluster(id: "S2", speechSeconds: 2),
                    ],
                    intervals: [
                        DiarizationInterval(start: 0, end: 3, clusterID: "S1"),
                        DiarizationInterval(start: 3, end: 5, clusterID: "S2"),
                    ]
                )
                diarization.setActive(second)
                try meeting.store.writeRawDiarization(diarization)

                let reread = try meeting.store.readRawDiarization()
                expect.equal(reread.runs.count, 2, "the earlier analysis stays on disk")
                expect.equal(reread.activeRun(track: .remote)?.id, "remote-002")
                expect.isFalse(
                    reread.runs.first { $0.id == "remote-001" }?.isActive ?? true,
                    "superseded, not deleted"
                )
                expect.equal(reread.nextRunID(track: .remote), "remote-003")
            },
        ])
    }
}
