import AVFoundation
import Foundation
import PipitCore
import PipitIntegrations
import PipitLocalAI
import PipitServices
import PipitSpeakers
import Synchronization
import TestKit

/// A transcription backend with no model behind it, so the local path can be
/// exercised end to end without 650 MB of CoreML.
final class StubLocalTranscriber: TranscriptionBackend, @unchecked Sendable {
    var segments: [RawTranscriptSegment]
    /// What the microphone track says, where a test needs the two tracks to say
    /// different things. Identical words on both tracks are read as the far end
    /// reaching the microphone, and the local lines are dropped.
    var micSegments: [RawTranscriptSegment]?
    var identifier = "stub-whisper"
    var isLocal = true
    var limits = BackendAudioLimits.none
    var timing = TranscriptTiming.words
    /// The audio handed to this backend, so a test can say which one read it.
    private let state = Mutex<[String]>([])
    var received: [String] { state.withLock { $0 } }
    /// Where to keep a copy of every file handed over, for a test that has to
    /// measure the samples rather than read the name. The pipeline deletes its
    /// working copies when the meeting finishes, so they have to be taken as
    /// they are read.
    var copyAudioTo: URL?
    private let copies = Mutex<[URL]>([])
    var copiedAudio: [URL] { copies.withLock { $0 } }

    init(segments: [RawTranscriptSegment]) { self.segments = segments }

    func transcribe(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionOutput {
        state.withLock { $0.append(audio.lastPathComponent) }
        if let copyAudioTo {
            copies.withLock { made in
                let destination = copyAudioTo.appendingPathComponent(
                    "\(made.count).\(audio.lastPathComponent)"
                )
                try? FileManager.default.createDirectory(
                    at: copyAudioTo, withIntermediateDirectories: true
                )
                try? FileManager.default.copyItem(at: audio, to: destination)
                made.append(destination)
            }
        }
        progress(1)
        let spoken = audio.lastPathComponent.hasPrefix(CaptureTrack.mic.rawValue)
            ? (micSegments ?? segments) : segments
        return TranscriptionOutput(
            segments: spoken, text: spoken.map(\.text).joined(separator: " "),
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

/// A transcription backend that returns the best words and no timings, the
/// shape gpt-transcribe and local Cohere produce.
final class StubTextTranscriber: TranscriptionBackend, @unchecked Sendable {
    var text: String
    var identifier = "stub-cohere"
    var isLocal = true
    var limits: BackendAudioLimits
    var timing = TranscriptTiming.text
    private let state = Mutex<[String]>([])
    /// The audio handed to this backend, so a test can count its chunks.
    var received: [String] { state.withLock { $0 } }

    init(text: String, limits: BackendAudioLimits = .none) {
        self.text = text
        self.limits = limits
    }

    func transcribe(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionOutput {
        state.withLock { $0.append(audio.lastPathComponent) }
        progress(1)
        return TranscriptionOutput(segments: [], text: text, durationSeconds: 6)
    }
}

/// An aligner with a fixed answer, or a refusal.
struct StubAligner: TranscriptAligner, @unchecked Sendable {
    var identifier = "stub-aligner"
    var segments: [RawTranscriptSegment]
    var refuses = false

    func align(audio: URL, text: String) async throws -> [RawTranscriptSegment] {
        if refuses { throw TranscriptAlignmentRefused(reason: "stub refusal") }
        return segments
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

    /// Every sample of one file, so a test can measure what a backend was
    /// handed rather than trust the name it came under.
    static func samples(ofFile url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)
        ) else { return [] }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    /// What the far end and the user's own voice did between the recording and
    /// the file the transcription backend opened.
    ///
    /// Measured on `makeCallOnSpeakers`, where the far end plays for all 30
    /// seconds and the user talks over it for the middle third. Both figures
    /// are decibels lost against the recording. A cleaned microphone loses tens
    /// of decibels of far end and none of the user. A far-end figure near zero
    /// says the backend was handed the recording.
    static func farEndAndUser(
        handed: URL, recording: TrackAudioLocation
    ) throws -> (farEndLostDB: Double, userLostDB: Double) {
        let heard = try samples(ofFile: handed)
        let recorded = try MicrophoneCleanerTests.samples(recording)
        func energy(_ samples: [Float], _ from: Double, _ to: Double, _ frequency: Double) -> Double {
            MicrophoneCleanerTests.toneEnergy(
                MicrophoneCleanerTests.seconds(from, to, of: samples), frequency: frequency
            )
        }
        let far = MicrophoneCleanerTests.farToneA
        let near = MicrophoneCleanerTests.nearTone
        return (
            MicrophoneCleanerTests.dropDB(
                from: energy(recorded, 20, 30, far), to: energy(heard, 20, 30, far)
            ),
            MicrophoneCleanerTests.dropDB(
                from: energy(recorded, 12, 18, near), to: energy(heard, 12, 18, near)
            )
        )
    }

    static func makePipeline(
        repository: MeetingRepository,
        backend: FakeAIBackend,
        transcriber: any TranscriptionBackend,
        diarizer: StubLocalDiarizer,
        speakers: SpeakerRecognitionService?,
        aligner: (any TranscriptAligner)? = nil,
        prepareAligner: (@Sendable () async throws -> Void)? = nil,
        singleSpeakerEmbedding: (@Sendable (URL) async throws -> SingleSpeakerSample?)? = nil,
        settings: AppSettings,
        scratchRoot: URL,
        onProgress: @escaping @Sendable (ProcessingPipeline.Progress) -> Void = { _ in }
    ) -> ProcessingPipeline {
        ProcessingPipeline(
            repository: repository,
            backend: backend,
            backends: ProcessingBackends(
                transcription: { _, _ in transcriber },
                diarization: { _, _ in diarizer },
                speakers: speakers,
                aligner: aligner,
                prepareAligner: prepareAligner,
                singleSpeakerEmbedding: singleSpeakerEmbedding
            ),
            scratch: ProcessingScratch(root: scratchRoot),
            clock: ManualClock(),
            settingsProvider: { settings },
            onProgress: onProgress,
            wait: { _ in }
        )
    }

    /// Lets a test wait for one progress line and then act while the pipeline
    /// is still inside the stage that reported it.
    final class ProgressGate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiting: CheckedContinuation<Void, Never>?

        func open() {
            lock.lock()
            let resumed = waiting
            waiting = nil
            opened = true
            lock.unlock()
            resumed?.resume()
        }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if opened {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiting = continuation
                lock.unlock()
            }
        }
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

            test("a call whose far end never arrived diarizes the microphone") { expect in
                // The recording this is taken from: thirty-one minutes of a
                // six-person standup where the process tap wrote digital zero
                // from arm to teardown. The far end never reached its own
                // track, the room reached the microphone, and which track held
                // the people to find was read off the kind of call it was. It
                // chose the silent one, which returned no clusters, so every
                // word stayed on the microphone under the key that means the
                // local user and six people read as one.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                // A tap bound to an application that emits nothing still writes
                // a full-length track, because the aggregate device is clocked
                // by its output sub-device rather than by the tap. The series is
                // there and every window of it reads the floor.
                try meeting.store.writeSpeechEvidence(SpeechEvidence(
                    levelWindowSeconds: 0.25, speechWindowSeconds: 0.25,
                    micLevels: [Int8](repeating: -20, count: 24),
                    remoteLevels: [Int8](repeating: -120, count: 24),
                    micSpeech: [Int8](repeating: 95, count: 24),
                    micEchoReturnLoss: [Int16](repeating: 0, count: 24),
                    detector: "silero"
                ))

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
                    chunkEmbeddings: embeddings(cluster: "S1", seed: 41, spans: [(0, 2)])
                        + embeddings(cluster: "S2", seed: 42, spans: [(2.9, 4.5)])
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

                let diarization = try meeting.store.readRawDiarization()
                expect.isTrue(
                    diarization.activeRun(track: .mic) != nil,
                    "the track carrying the voices is the one that gets diarized"
                )
                expect.isTrue(
                    diarization.activeRun(track: .remote) == nil,
                    "and nothing is asked of the track that holds no audio"
                )
                let transcript = try expect.unwrap(try meeting.store.readCanonicalTranscript())
                let mic = transcript.utterances.filter { $0.track == .mic }
                expect.equal(mic.count, 2, "the segment was split where the speaker changed")
                expect.equal(
                    Set(mic.map(\.speakerKey)).count, mic.count,
                    "two voices, two keys"
                )
                expect.isTrue(
                    !mic.contains { $0.speakerKey == SpeakerLabel.localUser },
                    "a room full of people is not the local user"
                )
            },

            test("a call whose far end arrived keeps diarizing the far end") { expect in
                // The other side of the same decision, and the one that must
                // not move. Taking the local user out of the diarization
                // problem measured 97% attribution against 84% for diarizing a
                // mixdown, so a recording whose tap worked keeps that, and its
                // microphone track stays one known person.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                try meeting.store.writeSpeechEvidence(SpeechEvidence(
                    levelWindowSeconds: 0.25, speechWindowSeconds: 0.25,
                    micLevels: [Int8](repeating: -20, count: 24),
                    remoteLevels: [Int8](repeating: -18, count: 24),
                    micSpeech: [Int8](repeating: 95, count: 24),
                    micEchoReturnLoss: [Int16](repeating: 0, count: 24),
                    detector: "silero"
                ))
                let transcriber = StubLocalTranscriber(segments: [
                    RawTranscriptSegment(
                        start: 0, end: 5, text: "we ship friday", speaker: nil,
                        words: [RawTranscriptWord(start: 0.0, end: 0.3, text: " we")]
                    ),
                ])
                let diarizer = StubLocalDiarizer(
                    intervals: [DiarizationInterval(start: 0, end: 2, clusterID: "S1")],
                    chunkEmbeddings: embeddings(cluster: "S1", seed: 43, spans: [(0, 2)])
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

                let diarization = try meeting.store.readRawDiarization()
                expect.isTrue(
                    diarization.activeRun(track: .remote) != nil,
                    "a far end that arrived is still where the unknown people are"
                )
                expect.isTrue(
                    diarization.activeRun(track: .mic) == nil,
                    "and the microphone stays the local user's own track"
                )
            },

            test("a text-only backend's words reach the timeline through the aligner") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                let transcriber = StubTextTranscriber(text: "we ship friday no we do not")
                let aligner = StubAligner(segments: [
                    RawTranscriptSegment(
                        start: 0, end: 4.2, text: "we ship friday no we do not", speaker: nil,
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
                    aligner: aligner,
                    settings: settings, scratchRoot: root.appendingPathComponent("scratch")
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                expect.equal(try meeting.store.readMetadata().processing.state, .complete)

                // The raw chunk stays what the model returned: text, no timings.
                let raw = try meeting.store.readRawTranscript()
                let chunk = try expect.unwrap(raw.chunks.first { $0.track == .remote })
                expect.equal(chunk.text, "we ship friday no we do not")
                expect.equal(chunk.segments.count, 0, "no timings are invented into the raw record")
                expect.equal(chunk.responseFormat, "local_text")

                // The alignment is its own derived file, with provenance.
                let alignment = try expect.unwrap(meeting.store.readAlignment(chunkID: chunk.id))
                expect.equal(alignment.aligner, "stub-aligner")

                // And assembly consumes the aligned words: split where the
                // speaker changed, exactly as a word-timed backend would be.
                let transcript = try expect.unwrap(try meeting.store.readCanonicalTranscript())
                let remote = transcript.utterances.filter { $0.track == .remote }
                expect.equal(remote.count, 2, "attribution worked on aligned words")
                expect.equal(remote.first?.text, "we ship friday")
                expect.equal(remote.last?.text, "no we do not")
            },

            test("a chunked local engine and a cloud diarizer do not collide") { expect in
                // Both chunk the same track, and both went through the same
                // naming. The diarizer's plans matched the transcriber's
                // chunks, so every one was skipped as already done: nothing
                // was diarized, no run was written, and the far end came back
                // as one unattributed speaker with the meeting reporting
                // success.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                let backend = FakeAIBackend()
                backend.diarizationSegments = [
                    RawTranscriptSegment(start: 0, end: 1.5, text: "Theirs.", speaker: "A"),
                ]
                // Chunked, the way Cohere is: a request limit under the
                // meeting's own length.
                let transcriber = StubTextTranscriber(
                    text: "we ship friday",
                    limits: BackendAudioLimits(maximumSeconds: 3)
                )
                let aligner = StubAligner(segments: [
                    RawTranscriptSegment(
                        start: 0, end: 1.2, text: "we ship friday", speaker: nil,
                        words: [
                            RawTranscriptWord(start: 0.0, end: 0.4, text: " we"),
                            RawTranscriptWord(start: 0.5, end: 0.8, text: " ship"),
                            RawTranscriptWord(start: 0.9, end: 1.2, text: " friday"),
                        ]
                    ),
                ])

                var settings = AppSettings()
                settings.processing.transcription = .local
                settings.processing.diarization = .openAI
                settings.enrichment = EnrichmentSettings(
                    generateTitle: false, generateDescription: false, generateNotes: false,
                    generateSummary: false, suggestSpeakers: false
                )
                let resolved = settings
                let pipeline = ProcessingPipeline(
                    repository: meeting.repository,
                    backend: backend,
                    backends: ProcessingBackends(
                        transcription: { _, _ in transcriber },
                        diarization: { _, model in
                            OpenAIDiarizationBackend(backend: backend, model: model)
                        },
                        aligner: aligner
                    ),
                    scratch: ProcessingScratch(root: root.appendingPathComponent("scratch")),
                    clock: ManualClock(),
                    settingsProvider: { resolved },
                    wait: { _ in }
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                expect.equal(try meeting.store.readMetadata().processing.state, .complete)
                let words = try meeting.store.readRawTranscript()
                    .chunks(track: .remote, purpose: .words)
                expect.isTrue(
                    words.count > 1 && words.contains { $0.id == "remote_chunk_001" },
                    "the local engine chunked the far end under the diarizer's own naming"
                )
                expect.isTrue(
                    backend.calls.contains { $0.kind == "diarize" },
                    "the diarizer was actually asked, not skipped as already done"
                )
                let diarization = try meeting.store.readRawDiarization()
                let run = try expect.unwrap(diarization.activeRun(track: .remote))
                expect.isFalse(run.intervals.isEmpty, "a run was written")

                let transcript = try expect.unwrap(try meeting.store.readCanonicalTranscript())
                let remote = transcript.utterances.filter { $0.track == .remote }
                expect.isFalse(remote.isEmpty)
                expect.isFalse(
                    remote.allSatisfy { $0.speakerKey == SpeakerLabel.unattributed(track: .remote) },
                    "the far end must not collapse into one unattributed speaker"
                )
            },

            test("switching to cloud transcription later still diarizes the far end") { expect in
                // The other route into the same collision. A local engine has
                // already chunked the far end; the user switches transcription
                // to Cloud and the meeting resumes at diarization. The cloud
                // diarizer's words are no longer wanted — the local ones are
                // already on disk and own the track — so it must ask for
                // labels alone rather than claiming the same purpose and the
                // same chunk names.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                // What the interrupted local pass left behind.
                var raw = try meeting.store.readRawTranscript()
                raw.chunks.append(RawTranscriptChunk(
                    id: "remote_chunk_001", track: .remote, timelineOffset: 0,
                    durationSeconds: 6, model: "stub-cohere", responseFormat: "local_text",
                    segments: [RawTranscriptSegment(
                        start: 0, end: 2, text: "we ship friday", speaker: nil,
                        words: [
                            RawTranscriptWord(start: 0.0, end: 0.4, text: " we"),
                            RawTranscriptWord(start: 0.5, end: 0.8, text: " ship"),
                            RawTranscriptWord(start: 0.9, end: 1.2, text: " friday"),
                        ]
                    )],
                    purpose: .words
                ))
                try meeting.store.writeRawTranscript(raw)

                let backend = FakeAIBackend()
                // The microphone track is transcribed in the cloud on this
                // route; an empty answer for audible audio is a failure now.
                backend.transcriptionSegments = [
                    RawTranscriptSegment(start: 0, end: 2, text: "Mine.", speaker: nil),
                ]
                backend.diarizationSegments = [
                    RawTranscriptSegment(start: 0, end: 1.5, text: "Theirs.", speaker: "A"),
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
                    backends: ProcessingBackends.openAIOnly(backend),
                    scratch: ProcessingScratch(root: root.appendingPathComponent("scratch")),
                    clock: ManualClock(),
                    settingsProvider: { resolved },
                    wait: { _ in }
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                expect.equal(try meeting.store.readMetadata().processing.state, .complete)
                expect.isTrue(
                    backend.calls.contains { $0.kind == "diarize" },
                    "the diarizer was asked, not skipped as already done"
                )
                let diarization = try meeting.store.readRawDiarization()
                expect.isFalse(
                    try expect.unwrap(diarization.activeRun(track: .remote)).intervals.isEmpty
                )

                // And the local words still own the track: the cloud pass took
                // labels only, so nothing is transcribed twice.
                let after = try meeting.store.readRawTranscript()
                    .chunks(track: .remote, purpose: .words)
                expect.equal(
                    Set(after.map(\.model)), ["stub-cohere"],
                    "one track's words come from one backend"
                )
            },

            test("a whole track that keeps looping fails the meeting, it never empties it") { expect in
                // Dropping a looping chunk on the last attempt is scoped to a
                // window: a hole in one of sixteen costs that window and the
                // other fifteen are still speech. On the whole-track path the
                // one chunk is the meeting, so the same drop wrote an empty
                // raw transcript, enrichment returned early on it, and the
                // meeting reported success with an empty transcript.md. A
                // whole track therefore fails however many attempts it has
                // used, which leaves the meeting retryable with its audio
                // untouched.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                // What five of ES2003a's sixteen chunks returned, verbatim.
                let loop = "The world is a very important part of the world. And I think "
                    + "that's what we need to do in terms of the world, and it's not just "
                    + "about the world, but also about the world, and we need to be able to "
                    + "make sure that there are people who are not going to be able to do "
                    + "that. So, I think that's what we need to do in terms of the world."
                let transcriber = StubLocalTranscriber(segments: [
                    RawTranscriptSegment(start: 0, end: 5, text: loop, speaker: nil, words: nil),
                ])
                let diarizer = StubLocalDiarizer(
                    intervals: [DiarizationInterval(start: 0, end: 5, clusterID: "S1")],
                    chunkEmbeddings: embeddings(cluster: "S1", seed: 37, spans: [(0, 5)])
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
                expect.notEqual(
                    metadata.processing.state, .complete,
                    "a meeting with nothing in its transcript must not report success"
                )
                expect.equal(metadata.processing.state, .failed)
                expect.isTrue(
                    metadata.processing.lastFailure?.isRetryable == true,
                    "and the meeting can be transcribed again"
                )
                let raw = try meeting.store.readRawTranscript()
                expect.isTrue(
                    raw.chunks.allSatisfy { !($0.segments.isEmpty && ($0.text ?? "").isEmpty) },
                    "no track was recorded as nothing"
                )
                expect.isFalse(
                    FileManager.default.fileExists(
                        atPath: meeting.store.layout.transcriptMarkdown.path
                    ),
                    "and no empty transcript was written"
                )
            },

            test("an aligner that will not install fails the stage, it does not ship coarse timings") { expect in
                // Distinct from a refusal. A refusal is deterministic and the
                // chunk keeps whole-chunk timing for good; a model that would
                // not download is transient, and completing the meeting on
                // five-minute utterances would be permanent, because nothing
                // revisits a finished meeting's alignment.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                let transcriber = StubTextTranscriber(text: "we ship friday")
                let diarizer = StubLocalDiarizer(
                    intervals: [DiarizationInterval(start: 0, end: 5, clusterID: "S1")],
                    chunkEmbeddings: embeddings(cluster: "S1", seed: 41, spans: [(0, 5)])
                )
                var settings = AppSettings()
                settings.enrichment = EnrichmentSettings(
                    generateTitle: false, generateDescription: false, generateNotes: false,
                    generateSummary: false, suggestSpeakers: false
                )
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: transcriber, diarizer: diarizer, speakers: nil,
                    aligner: StubAligner(segments: []),
                    prepareAligner: { throw LocalModelError.installFailed("no network") },
                    settings: settings, scratchRoot: root.appendingPathComponent("scratch")
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                let metadata = try meeting.store.readMetadata()
                expect.notEqual(
                    metadata.processing.state, .complete,
                    "a meeting whose words have no timings must not report success"
                )
                expect.equal(metadata.processing.state, .failed)
                expect.isTrue(
                    metadata.processing.lastFailure?.isRetryable == true,
                    "and the download can be tried again"
                )

                // The words are safe, so a retry aligns them rather than
                // transcribing again.
                let raw = try meeting.store.readRawTranscript()
                expect.isTrue(
                    raw.chunks.contains { $0.text == "we ship friday" },
                    "the transcription is kept whatever the aligner did"
                )
            },

            test("an aligner refusal keeps the words at chunk precision") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                let transcriber = StubTextTranscriber(text: "nothing aligned here")
                let diarizer = StubLocalDiarizer(
                    intervals: [DiarizationInterval(start: 0, end: 5, clusterID: "S1")],
                    chunkEmbeddings: embeddings(cluster: "S1", seed: 33, spans: [(0, 5)])
                )
                var settings = AppSettings()
                settings.enrichment = EnrichmentSettings(
                    generateTitle: false, generateDescription: false, generateNotes: false,
                    generateSummary: false, suggestSpeakers: false
                )
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: transcriber, diarizer: diarizer, speakers: nil,
                    aligner: StubAligner(segments: [], refuses: true),
                    settings: settings, scratchRoot: root.appendingPathComponent("scratch")
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                expect.equal(try meeting.store.readMetadata().processing.state, .complete)
                let transcript = try expect.unwrap(try meeting.store.readCanonicalTranscript())
                expect.isTrue(
                    transcript.utterances.contains { $0.text.contains("nothing aligned here") },
                    "the words survive at chunk-level timing instead of vanishing"
                )
                // A refusal is recorded as one, so the next run does not pay
                // for the same hopeless alignment again, and a later build can
                // tell it from real timings.
                let raw = try meeting.store.readRawTranscript()
                let chunk = try expect.unwrap(raw.chunks.first { $0.text != nil })
                let alignment = try expect.unwrap(meeting.store.readAlignment(chunkID: chunk.id))
                expect.isTrue(alignment.refused, "recorded as a refusal, not as timings")
                expect.isTrue(alignment.segments.isEmpty)
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

            test("rebuilding a transcript sheds a stored icon name") { expect in
                // Re-analysing sheds these too, but it re-clusters the whole
                // recording for minutes to do it. Rebuild is the cheap button
                // next to it, and a name read off a web page needs neither the
                // audio nor the diarizer to be taken back.
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
                            start: 0, end: 5, text: "we ship friday", speaker: nil,
                            words: [
                                RawTranscriptWord(start: 0.0, end: 0.3, text: " we"),
                                RawTranscriptWord(start: 0.4, end: 0.8, text: " ship"),
                                RawTranscriptWord(start: 0.9, end: 1.4, text: " friday"),
                            ]
                        ),
                    ]),
                    diarizer: StubLocalDiarizer(
                        intervals: [DiarizationInterval(start: 0, end: 2, clusterID: "S1")],
                        chunkEmbeddings: embeddings(cluster: "S1", seed: 41, spans: [(0, 2)])
                    ),
                    speakers: nil,
                    settings: settings, scratchRoot: root.appendingPathComponent("scratch")
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                // What a build with the stale reader left on disk.
                let before = try expect.unwrap(try meeting.store.readCanonicalTranscript())
                let key = try expect.unwrap(
                    before.utterances.first { $0.track == .remote }?.speakerKey
                )
                var map = try meeting.store.readSpeakerMap()
                map.applySuggestion(
                    SpeakerAssignment(
                        displayName: "keep_outline", origin: .sensor,
                        provenance: SpeakerProvenance(source: .sensor)
                    ),
                    for: key
                )
                try meeting.store.writeSpeakerMap(map)
                expect.equal(
                    try meeting.store.readSpeakerMap().displayName(for: key), "keep_outline"
                )

                try await pipeline.rebuildTranscript(meetingID: meeting.metadata.id)

                expect.isNil(try meeting.store.readSpeakerMap().displayName(for: key))
                let markdown = try String(
                    contentsOf: meeting.store.layout.transcriptMarkdown, encoding: .utf8
                )
                expect.isFalse(markdown.contains("keep_outline"))
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

            test("a summary can be written after a key arrives") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                let settings = AppSettings()
                let backend = FakeAIBackend()
                // Processed before a key was stored, which is the whole reason
                // this entry point exists.
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
                        chunkEmbeddings: embeddings(cluster: "S1", seed: 61, spans: [(0, 5)])
                    ),
                    speakers: nil,
                    settings: settings, scratchRoot: root.appendingPathComponent("scratch")
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                expect.equal(try meeting.store.readMetadata().processing.state, .complete)
                expect.isFalse(
                    FileManager.default.fileExists(atPath: meeting.store.layout.summary.path),
                    "there should be no summary yet"
                )

                // The user stores a key and asks for the summary by hand.
                backend.configured = true
                try await pipeline.generateEnrichment(meetingID: meeting.metadata.id)

                let document = meeting.store.readSummaryDocument()
                expect.equal(document.summary, "Discussed retrieval.")
                let after = try meeting.store.readMetadata()
                expect.equal(after.titles.ai, "Retrieval logic")
                // The notice was the reason the user pressed the button, so it
                // has to stop being true once the button worked.
                expect.isFalse(after.processing.skippedForMissingKey)
                // The meeting was already complete and must stay that way.
                expect.equal(after.processing.state, .complete)
            },

            test("a meeting trashed while a summary is written does not come back") { expect in
                // Holding the folder tells the runtime a job will notice the
                // move, so the runtime does not clean up and this job has to.
                // Every write here goes through AtomicFile, which recreates the
                // folder, and the metadata written back is enough for the
                // folder rename at the tail to find it and move it somewhere
                // the deferred check no longer looks.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                let folder = meeting.store.layout.root
                let meetingID = meeting.metadata.id

                let backend = FakeAIBackend()
                backend.enrichment = MeetingEnrichment(
                    title: "Retrieval logic", summary: "We agreed on the pilot."
                )
                // Processed before a key existed, so no title was generated.
                // That is what lets this run fill the slot, change the resolved
                // title and set the folder rename in motion, which is the part
                // that carries a recreated folder out of reach.
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
                        chunkEmbeddings: embeddings(cluster: "S1", seed: 66, spans: [(0, 5)])
                    ),
                    speakers: nil,
                    settings: AppSettings(),
                    scratchRoot: root.appendingPathComponent("scratch")
                )
                await pipeline.process(meetingID: meetingID)
                expect.isNil(try meeting.store.readMetadata().titles.ai)
                // Nothing outranking the generated title, so filling that slot
                // changes the name the folder is derived from. Without this the
                // folder never renames and the deferred check finds the ghost
                // where it left it, which hides the bug rather than fixing it.
                _ = try meeting.store.updateMetadata { $0.titles.provider = nil }

                backend.configured = true
                let trashed = root.appendingPathComponent("Trash", isDirectory: true)
                backend.enrichInterference = { [pipeline] in
                    // What the window does: the folder moves, and the job is
                    // told once it has.
                    try? FileManager.default.moveItem(at: folder, to: trashed)
                    _ = await pipeline.forget(meetingID: meetingID, movedAt: Date())
                }
                try await pipeline.generateEnrichment(meetingID: meetingID)

                // Checked by identifier rather than by path. A ghost that the
                // folder rename has already moved is not at `folder` any more,
                // so the path alone would report success on the bug.
                expect.isNil(
                    meeting.repository.findMeeting(id: meetingID, includingMerged: true)?.metadata,
                    "the meeting the user trashed came back"
                )
                expect.isTrue(
                    FileManager.default.fileExists(atPath: trashed.path),
                    "and what was moved is untouched"
                )
            },

            test("writing a summary leaves a generated title alone") { expect in
                // The control says nothing already on the meeting is replaced,
                // and the title is the one field enrichment overwrites rather
                // than fills. A meeting with titling on and summaries off is
                // named by that title, so replacing it renames the meeting.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                var settings = AppSettings()
                settings.enrichment = EnrichmentSettings(
                    generateTitle: true, generateDescription: false, generateNotes: false,
                    generateSummary: false, suggestSpeakers: false
                )
                let backend = FakeAIBackend()
                backend.enrichment = MeetingEnrichment(title: "Retrieval sync")

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
                        chunkEmbeddings: embeddings(cluster: "S1", seed: 63, spans: [(0, 5)])
                    ),
                    speakers: nil,
                    settings: settings, scratchRoot: root.appendingPathComponent("scratch")
                )
                await pipeline.process(meetingID: meeting.metadata.id)
                expect.equal(try meeting.store.readMetadata().titles.ai, "Retrieval sync")

                // The user now wants a summary. The model answers with a
                // different title in the same response.
                backend.enrichment = MeetingEnrichment(
                    title: "Something else entirely", summary: "We agreed on the pilot."
                )
                try await pipeline.generateEnrichment(meetingID: meeting.metadata.id)

                let after = try meeting.store.readMetadata()
                expect.equal(
                    after.titles.ai, "Retrieval sync",
                    "asking for a summary renamed the meeting"
                )
                expect.equal(
                    meeting.store.readSummaryDocument().summary, "We agreed on the pilot.",
                    "and the summary it was asked for was not written"
                )
            },

            test("the generated notes survive the round trip through the file") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                let backend = FakeAIBackend()
                backend.enrichment = MeetingEnrichment(
                    title: "Retrieval logic",
                    summary: "We agreed on the pilot.",
                    notes: "- Chris sends the connector list."
                )

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
                        chunkEmbeddings: embeddings(cluster: "S1", seed: 64, spans: [(0, 5)])
                    ),
                    speakers: nil,
                    settings: AppSettings(),
                    scratchRoot: root.appendingPathComponent("scratch")
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                // Written as one file, read back as two, which is what puts the
                // notes on their own tab instead of under the summary.
                let document = meeting.store.readSummaryDocument()
                expect.equal(document.summary, "We agreed on the pilot.")
                expect.equal(document.generatedNotes, "- Chris sends the connector list.")
            },

            test("asking by hand still refuses a name the user cleared") { expect in
                // The stage guard, reached through the on-demand entry point
                // rather than through the pipeline.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                let backend = FakeAIBackend()
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
                        chunkEmbeddings: embeddings(cluster: "S1", seed: 65, spans: [(0, 5)])
                    ),
                    speakers: nil,
                    settings: AppSettings(),
                    scratchRoot: root.appendingPathComponent("scratch")
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                var map = try meeting.store.readSpeakerMap()
                let unnamed = try meeting.store.readTranscriptSpeakers()
                    .map(\.key)
                    .filter {
                        $0 != SpeakerLabel.localUser && !$0.hasSuffix(SpeakerLabel.unattributed)
                            && map.entries[$0] == nil
                    }
                let target = try expect.unwrap(unnamed.first)
                // A name waiting to be proposed for exactly that speaker, so
                // the guard is the only thing keeping it off the strip.
                backend.suggestions = [
                    SpeakerSuggestion(
                        label: target, name: "Priya Raman", confidence: 0.93,
                        quote: "Priya, what did it come back at?", atSeconds: 3
                    ),
                ]
                // "Leave unnamed" on the chip, which is what clears a key.
                map.assign("", to: target)
                expect.isTrue(map.clearedKeys.contains(target))
                try meeting.store.writeSpeakerMap(map)

                // Nothing was asked, so nothing may be written either.
                try await pipeline.suggestSpeakers(meetingID: meeting.metadata.id)
                expect.isTrue(
                    meeting.store.readSpeakerSuggestions()
                        .visible(forUnnamed: [target]).isEmpty,
                    "a name the user cleared was proposed again"
                )
            },

            test("speaker names can be asked for after a key arrives") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                let settings = AppSettings()
                let backend = FakeAIBackend()
                backend.configured = false
                backend.suggestions = [
                    SpeakerSuggestion(
                        label: "remote-001_speaker_00", name: "Priya Raman",
                        confidence: 0.93, quote: "Priya, what did it come back at?", atSeconds: 3
                    ),
                ]

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
                        chunkEmbeddings: embeddings(cluster: "S1", seed: 62, spans: [(0, 5)])
                    ),
                    speakers: nil,
                    settings: settings, scratchRoot: root.appendingPathComponent("scratch")
                )
                await pipeline.process(meetingID: meeting.metadata.id)
                expect.isTrue(
                    meeting.store.readSpeakerSuggestions().suggestions.isEmpty,
                    "no key means nothing was proposed on the first pass"
                )

                backend.configured = true
                try await pipeline.suggestSpeakers(meetingID: meeting.metadata.id)

                let written = meeting.store.readSpeakerSuggestions().suggestions
                expect.equal(written.count, 1)
                expect.equal(written.first?.name, "Priya Raman")
                // A proposal, exactly as on the first pass. Asking by hand does
                // not make it an assignment.
                expect.isNil(try meeting.store.readSpeakerMap().entries["remote-001_speaker_00"])
                expect.isFalse(try meeting.store.readMetadata().processing.skippedForMissingKey)
            },

            test("the missing-key notice is recorded when only suggestions want the cloud") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                // Every title and summary switch off, speaker suggestions on.
                // The flag used to be written only inside enrichment, which
                // returns before it can say anything under exactly these
                // settings, so this user got no suggestions and no reason.
                var settings = AppSettings()
                settings.enrichment = EnrichmentSettings(
                    generateTitle: false, generateDescription: false, generateNotes: false,
                    generateSummary: false, suggestSpeakers: true
                )
                expect.isFalse(settings.enrichment.wantsAnything)

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
                        chunkEmbeddings: embeddings(cluster: "S1", seed: 53, spans: [(0, 5)])
                    ),
                    speakers: nil,
                    settings: settings, scratchRoot: root.appendingPathComponent("scratch")
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                let processing = try meeting.store.readMetadata().processing
                expect.equal(processing.state, .complete)
                expect.isTrue(
                    processing.skippedForMissingKey,
                    "suggestions were wanted, the key was missing, and nothing said so"
                )
            },

            test("turning the cloud toggles off clears the missing-key notice") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                // The state a meeting processed without a key is left in.
                _ = try meeting.store.updateMetadata {
                    $0.processing.skippedForMissingKey = true
                }

                var settings = AppSettings()
                settings.enrichment = EnrichmentSettings(
                    generateTitle: false, generateDescription: false, generateNotes: false,
                    generateSummary: false, suggestSpeakers: false
                )
                // Nothing wants the cloud any more, so whether a key is stored
                // does not come into it.
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
                        chunkEmbeddings: embeddings(cluster: "S1", seed: 54, spans: [(0, 5)])
                    ),
                    speakers: nil,
                    settings: settings, scratchRoot: root.appendingPathComponent("scratch")
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                expect.isFalse(
                    try meeting.store.readMetadata().processing.skippedForMissingKey,
                    "the notice outlived the reason for it"
                )
            },

            test("storing a key clears the missing-key notice on the next run") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                // The state a meeting processed without a key is left in.
                _ = try meeting.store.updateMetadata {
                    $0.processing.skippedForMissingKey = true
                }

                // The cloud is still wanted, so clearing the notice has to come
                // from reading the key rather than from nothing being asked for.
                var settings = AppSettings()
                settings.enrichment = EnrichmentSettings(
                    generateTitle: false, generateDescription: false, generateNotes: false,
                    generateSummary: false, suggestSpeakers: true
                )
                let backend = FakeAIBackend()
                backend.configured = true

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
                        chunkEmbeddings: embeddings(cluster: "S1", seed: 55, spans: [(0, 5)])
                    ),
                    speakers: nil,
                    settings: settings, scratchRoot: root.appendingPathComponent("scratch")
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                expect.isFalse(
                    try meeting.store.readMetadata().processing.skippedForMissingKey,
                    "the notice outlived the key that was stored to answer it"
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
                // Skipping is silent to the pipeline and must not be silent to
                // the reader: a stored key that goes missing otherwise looks
                // exactly like a key that was never set.
                expect.isTrue(
                    try meeting.store.readMetadata().processing.skippedForMissingKey,
                    "the meeting completed with no summary and did not record why"
                )
                expect.isTrue(
                    meeting.store.readSpeakerSuggestions().suggestions.isEmpty,
                    "no key means nothing was proposed"
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

                // Which backend was handed the audio, rather than only what came
                // back. Choosing Local for transcription is a statement about
                // where the audio goes, not only about which words are kept.
                expect.isFalse(
                    local.received.isEmpty,
                    "the local transcriber read this meeting's audio"
                )
                expect.isTrue(
                    cloud.calls.filter { $0.kind == "transcribe" }.isEmpty,
                    "and no audio was uploaded for transcription"
                )
                expect.isFalse(
                    cloud.calls.filter { $0.kind == "diarize" }.isEmpty,
                    "the one upload is the diarization the user asked for"
                )
            },

            test("a batch correction is applied to every line or to none") { expect in
                // Thirty lines selected together are one decision. Applying them
                // one at a time meant a failure at line eighteen left seventeen
                // renamed with no error shown, the person who lost them still
                // holding a vector built from their audio, and nothing left to
                // say a rebuild was owed.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                let (store, storeRoot) = try SpeakerIdentityTests.makeStore()
                defer { try? FileManager.default.removeItem(at: storeRoot) }

                let key = "remote-001_speaker_00"
                let lines = (0..<4).map { index in
                    Utterance(
                        id: "u\(index)", start: Double(index) * 10, end: Double(index) * 10 + 5,
                        track: .remote, rawSpeakerLabel: nil, speakerKey: key,
                        text: "line \(index)", chunkID: "c", model: "m"
                    )
                }
                try meeting.store.writeCanonicalTranscript(
                    CanonicalTranscript(generatedAt: Date(), utterances: lines)
                )

                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: StubLocalTranscriber(segments: []),
                    diarizer: StubLocalDiarizer(intervals: [], chunkEmbeddings: []),
                    speakers: SpeakerRecognitionService(store: store),
                    settings: AppSettings(),
                    scratchRoot: root.appendingPathComponent("scratch")
                )

                // The third identifier is one a re-analysis has taken away,
                // which is how this fails in practice.
                var threw = false
                do {
                    try await pipeline.applyUtteranceSpeaker(
                        "Priya", utteranceIDs: ["u0", "u1", "gone", "u3"],
                        meetingID: meeting.metadata.id
                    )
                } catch {
                    threw = true
                }
                expect.isTrue(threw, "the caller is told, rather than left with a partial result")

                let map = try meeting.store.readSpeakerMap()
                expect.isTrue(
                    map.utteranceOverrides.isEmpty,
                    "and no line moved, so there is no half-applied correction to reconcile"
                )
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
                // The run is what says which audio the cluster covers, and a
                // confirmation records that rather than the label, so without it
                // there is nothing to learn from and nothing to take back.
                try meeting.store.writeRawDiarization(RawDiarization(runs: [
                    DiarizationRun(
                        id: "remote-001", track: .remote, backend: "test",
                        producedAt: Date(), timelineOffset: 0,
                        clusters: [DiarizationCluster(id: "speaker_00", speechSeconds: 200)],
                        intervals: [DiarizationInterval(start: 0, end: 200, clusterID: "speaker_00")]
                    ),
                ]))
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

                let chris = try expect.unwrap(
                    await pipeline.applySpeakerName("Chris", to: key, meetingID: meeting.metadata.id)
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

            test("clearing a sensor speaker's name withdraws the account binding") { expect in
                // Naming a sensor speaker binds their platform account, so the
                // next meeting names them automatically. Clearing the name has
                // to withdraw that too, or the correction is undone by the very
                // mechanism the confirmation armed: re-analysis writes the
                // cleared name back here, and every later huddle writes it on
                // arrival.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                let (store, storeRoot) = try SpeakerIdentityTests.makeStore()
                defer { try? FileManager.default.removeItem(at: storeRoot) }
                try meeting.store.writeRawSensors(RawSensors(
                    source: "slack-huddle-ax",
                    participants: [SensorParticipant(id: "U123", displayName: "Chris")],
                    turns: [SensorTurn(start: 0, end: 30, participantID: "U123")]
                ))
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: StubLocalTranscriber(segments: []),
                    diarizer: StubLocalDiarizer(intervals: [], chunkEmbeddings: []),
                    speakers: SpeakerRecognitionService(store: store),
                    settings: AppSettings(),
                    scratchRoot: root.appendingPathComponent("scratch")
                )
                let key = SpeakerLabel.sensor(participantID: "U123")

                let chris = try expect.unwrap(
                    await pipeline.applySpeakerName("Chris", to: key, meetingID: meeting.metadata.id)
                )
                expect.equal(
                    await store.identity(handle: "U123", provider: "slack")?.id, chris,
                    "naming a sensor speaker binds the account"
                )

                _ = try await pipeline.applySpeakerName("", to: key, meetingID: meeting.metadata.id)
                expect.isNil(
                    await store.identity(handle: "U123", provider: "slack"),
                    "and clearing the name withdraws it"
                )
            },

            test("correcting a second person keeps the first person's voice") { expect in
                // Two people can each hold a legitimate enrolment from one
                // meeting. Removing everyone else's on each correction meant a
                // meeting could only ever keep the last-corrected person's.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let (store, storeRoot) = try SpeakerIdentityTests.makeStore()
                defer { try? FileManager.default.removeItem(at: storeRoot) }

                let alice = try await store.createPerson(name: "Alice")
                let bob = try await store.createPerson(name: "Bob")
                // Different halves of the same meeting, which is what two people
                // talking in it looks like.
                let halves = [(alice, 0.0), (bob, 600.0)]
                for (person, offset) in halves {
                    _ = try await store.enrol(VoiceEnrollmentCandidate(
                        identityID: person.id,
                        vector: SpeakerIdentityTests.vector(seed: offset == 0 ? 91 : 92),
                        model: .fluidAudioOffline, speechSeconds: 60, qualityScore: 1,
                        source: .humanConfirmedUtterances,
                        evidence: VoiceEvidenceFixture.evidence(
                            meeting: "m1", seconds: 60,
                            source: .humanConfirmedUtterances, start: offset
                        )
                    ))
                }
                for (person, _) in halves {
                    expect.equal(
                        try await store.profileStatus(
                            of: person.id, model: .fluidAudioOffline
                        ).sampleCount,
                        1
                    )
                }

                // Giving Alice's audio to somebody else touches Alice's row and
                // nothing else, because Bob's vector was derived from different
                // audio and the store knows which.
                let removed = try await store.retractEvidence(
                    VoiceEvidenceRetraction(
                        meetingID: "m1", track: .remote,
                        spans: [AudioSpan(start: 0, end: 60)]
                    ),
                    keepingClaimant: false
                )
                expect.equal(removed.map(\.rawValue), [alice.id.rawValue])
                expect.equal(
                    try await store.profileStatus(
                        of: bob.id, model: .fluidAudioOffline
                    ).sampleCount,
                    1,
                    "the other person's enrolment from the same meeting is untouched"
                )
            },

            test("clearing a line that was never corrected changes nothing") { expect in
                // The menu offers "use this speaker's name" on every line. On a
                // line with no correction it is a no-op, and reading the
                // rendered assignment reported the cluster's owner as having
                // lost the line, which deleted their voice for the meeting.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                let (store, storeRoot) = try SpeakerIdentityTests.makeStore()
                defer { try? FileManager.default.removeItem(at: storeRoot) }

                let alice = try await store.createPerson(name: "Alice")
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: alice.id, vector: SpeakerIdentityTests.vector(seed: 95),
                    model: .fluidAudioOffline, speechSeconds: 90, qualityScore: 1,
                    source: .humanConfirmedUtterances,
                    evidence: VoiceEvidenceFixture.evidence(meeting: meeting.metadata.id, seconds: 90, source: .humanConfirmedUtterances)
                ))

                let key = "remote-001_speaker_00"
                var map = SpeakerMap()
                map.assign("Alice", to: key, identityID: alice.id)
                try meeting.store.writeSpeakerMap(map)

                let line = Utterance(
                    id: "u1", start: 0, end: 4, track: .remote, rawSpeakerLabel: nil,
                    speakerKey: key, text: "hello", chunkID: "c", model: "m"
                )
                try meeting.store.writeCanonicalTranscript(
                    CanonicalTranscript(generatedAt: Date(), utterances: [line])
                )

                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: StubLocalTranscriber(segments: []),
                    diarizer: StubLocalDiarizer(intervals: [], chunkEmbeddings: []),
                    speakers: SpeakerRecognitionService(store: store),
                    settings: AppSettings(),
                    scratchRoot: root.appendingPathComponent("scratch")
                )
                try await pipeline.applyUtteranceSpeaker(
                    "", utteranceIDs: ["u1"], meetingID: meeting.metadata.id
                )

                expect.equal(
                    try await store.profileStatus(
                        of: alice.id, model: .fluidAudioOffline
                    ).sampleCount,
                    1,
                    "a click that moves no line must not cost a voice profile"
                )
            },

            test("a microphone track linked to nobody is linked to you") { expect in
                // Meetings processed before Settings held an identity name the
                // track and link it to no row at all. The track is the local
                // user by construction and the entry says the pipeline wrote
                // it, so the backfill gives it the link a fresh run would.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                let (store, storeRoot) = try SpeakerIdentityTests.makeStore()
                defer { try? FileManager.default.removeItem(at: storeRoot) }
                let me = try await store.createPerson(name: "Andrew", isLocalUser: true)

                var map = SpeakerMap()
                map.entries[SpeakerLabel.localUser] = SpeakerAssignment(
                    displayName: "Andrew", origin: .deterministic
                )
                try meeting.store.writeSpeakerMap(map)
                try meeting.store.writeCanonicalTranscript(CanonicalTranscript(
                    generatedAt: Date(timeIntervalSince1970: 1_787_070_000),
                    utterances: [Utterance(
                        id: "u0", start: 0, end: 30, track: .mic, rawSpeakerLabel: nil,
                        speakerKey: SpeakerLabel.localUser, text: "sounds right to me",
                        chunkID: "c1", model: "m"
                    )]
                ))

                var settings = AppSettings()
                settings.processing.localUserIdentityID = me.id
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: StubLocalTranscriber(segments: []),
                    diarizer: StubLocalDiarizer(intervals: [], chunkEmbeddings: []),
                    speakers: SpeakerRecognitionService(store: store),
                    settings: settings,
                    scratchRoot: root.appendingPathComponent("scratch")
                )
                expect.equal(await pipeline.backfillLocalUserOccurrences(), 1)
                expect.equal(try await store.meetingCount(for: me.id), 1)
                expect.equal(
                    try meeting.store.readSpeakerMap().entries[SpeakerLabel.localUser]?.identityID,
                    me.id,
                    "the meeting's own map carries the link too, or the next rename misses it"
                )
            },

            test("a microphone track a person gave to somebody else is left alone") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                let (store, storeRoot) = try SpeakerIdentityTests.makeStore()
                defer { try? FileManager.default.removeItem(at: storeRoot) }
                let me = try await store.createPerson(name: "Andrew", isLocalUser: true)

                // What "the microphone was Priya" leaves behind: a human origin
                // and no link, because that identity was never resolved here.
                var map = SpeakerMap()
                map.entries[SpeakerLabel.localUser] = SpeakerAssignment(
                    displayName: "Priya", origin: .human
                )
                try meeting.store.writeSpeakerMap(map)
                try meeting.store.writeCanonicalTranscript(CanonicalTranscript(
                    generatedAt: Date(timeIntervalSince1970: 1_787_070_000),
                    utterances: [Utterance(
                        id: "u0", start: 0, end: 30, track: .mic, rawSpeakerLabel: nil,
                        speakerKey: SpeakerLabel.localUser, text: "sounds right to me",
                        chunkID: "c1", model: "m"
                    )]
                ))

                var settings = AppSettings()
                settings.processing.localUserIdentityID = me.id
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: StubLocalTranscriber(segments: []),
                    diarizer: StubLocalDiarizer(intervals: [], chunkEmbeddings: []),
                    speakers: SpeakerRecognitionService(store: store),
                    settings: settings,
                    scratchRoot: root.appendingPathComponent("scratch")
                )
                _ = await pipeline.backfillLocalUserOccurrences()
                expect.equal(
                    try await store.meetingCount(for: me.id), 0,
                    "a name a person typed is not the microphone track's construction"
                )
            },

            test("meetings recorded before the microphone had a row get one") { expect in
                // The fix writes the row as a meeting is processed, which
                // leaves every meeting already in the archive counting for
                // nobody. A person who has been using Pipit for months would
                // have read their own profile as "heard in 0 meetings" forever.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                let (store, storeRoot) = try SpeakerIdentityTests.makeStore()
                defer { try? FileManager.default.removeItem(at: storeRoot) }
                let me = try await store.createPerson(name: "Andrew", isLocalUser: true)

                // What an already-processed meeting holds: a named microphone
                // track in the map, lines in the transcript, no occurrence row.
                var map = SpeakerMap()
                map.entries[SpeakerLabel.localUser] = SpeakerAssignment(
                    displayName: "Andrew", origin: .deterministic, identityID: me.id
                )
                try meeting.store.writeSpeakerMap(map)
                try meeting.store.writeCanonicalTranscript(CanonicalTranscript(
                    generatedAt: Date(timeIntervalSince1970: 1_787_070_000),
                    utterances: [Utterance(
                        id: "u0", start: 0, end: 30, track: .mic, rawSpeakerLabel: nil,
                        speakerKey: SpeakerLabel.localUser, text: "sounds right to me",
                        chunkID: "c1", model: "m"
                    )]
                ))
                expect.equal(try await store.meetingCount(for: me.id), 0)

                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: StubLocalTranscriber(segments: []),
                    diarizer: StubLocalDiarizer(intervals: [], chunkEmbeddings: []),
                    speakers: SpeakerRecognitionService(store: store),
                    settings: AppSettings(),
                    scratchRoot: root.appendingPathComponent("scratch")
                )
                expect.equal(await pipeline.backfillLocalUserOccurrences(), 1)
                expect.equal(try await store.meetingCount(for: me.id), 1)

                // Idempotent: the row is keyed on the meeting and the cluster,
                // so a second pass rewrites it rather than counting twice.
                _ = await pipeline.backfillLocalUserOccurrences()
                expect.equal(try await store.meetingCount(for: me.id), 1)
            },

            test("taking your name off the microphone track drops the meeting") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                let (store, storeRoot) = try SpeakerIdentityTests.makeStore()
                defer { try? FileManager.default.removeItem(at: storeRoot) }
                let me = try await store.createPerson(name: "Andrew", isLocalUser: true)

                var map = SpeakerMap()
                map.entries[SpeakerLabel.localUser] = SpeakerAssignment(
                    displayName: "Andrew", origin: .deterministic, identityID: me.id
                )
                try meeting.store.writeSpeakerMap(map)
                try meeting.store.writeCanonicalTranscript(CanonicalTranscript(
                    generatedAt: Date(timeIntervalSince1970: 1_787_070_000),
                    utterances: [Utterance(
                        id: "u0", start: 0, end: 30, track: .mic, rawSpeakerLabel: nil,
                        speakerKey: SpeakerLabel.localUser, text: "sounds right to me",
                        chunkID: "c1", model: "m"
                    )]
                ))

                var settings = AppSettings()
                settings.processing.localUserIdentityID = me.id
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: StubLocalTranscriber(segments: []),
                    diarizer: StubLocalDiarizer(intervals: [], chunkEmbeddings: []),
                    speakers: SpeakerRecognitionService(store: store),
                    settings: settings,
                    scratchRoot: root.appendingPathComponent("scratch")
                )
                _ = await pipeline.backfillLocalUserOccurrences()
                expect.equal(try await store.meetingCount(for: me.id), 1)

                // The chip offers "Leave unnamed" on this track like any other.
                _ = try await pipeline.applySpeakerName(
                    "", to: SpeakerLabel.localUser, meetingID: meeting.metadata.id
                )
                expect.equal(
                    try await store.meetingCount(for: me.id), 0,
                    "a meeting somebody says was not them is not one they were in"
                )
            },

            test("reading a few sentences aloud builds a voice profile") { expect in
                // The one enrolment a person starts. Without it a Mac that has
                // only ever recorded in-person meetings has nothing to
                // recognise its own user by: no microphone track of a remote
                // call, and no cluster anybody has named.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                let (store, storeRoot) = try SpeakerIdentityTests.makeStore()
                defer { try? FileManager.default.removeItem(at: storeRoot) }
                let me = try await store.createPerson(name: "Andrew", isLocalUser: true)

                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: StubLocalTranscriber(segments: []),
                    diarizer: StubLocalDiarizer(intervals: [], chunkEmbeddings: []),
                    speakers: SpeakerRecognitionService(store: store),
                    singleSpeakerEmbedding: { _ in
                        SingleSpeakerSample(
                            vector: SpeakerIdentityTests.vector(seed: 7), speechSeconds: 60,
                            quality: 0.9, spans: [AudioSpan(start: 0, end: 62)]
                        )
                    },
                    settings: AppSettings(),
                    scratchRoot: root.appendingPathComponent("scratch")
                )

                let status = try await pipeline.enrolSpokenSample(
                    audio: root.appendingPathComponent("read-aloud.wav"), identityID: me.id
                )
                expect.equal(status.sampleCount, 1)
                expect.equal(
                    try await store.profileStatus(of: me.id, model: .fluidAudioOffline).sampleCount,
                    1,
                    "the profile a later meeting is scored against holds it"
                )
            },

            test("a reading with two voices in it enrols nobody") { expect in
                // The embedder refuses audio whose dominant speaker holds less
                // than three quarters of the speech. A colleague answering a
                // question mid-take must not join the profile of the person who
                // pressed record.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                let (store, storeRoot) = try SpeakerIdentityTests.makeStore()
                defer { try? FileManager.default.removeItem(at: storeRoot) }
                let me = try await store.createPerson(name: "Andrew", isLocalUser: true)

                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: StubLocalTranscriber(segments: []),
                    diarizer: StubLocalDiarizer(intervals: [], chunkEmbeddings: []),
                    speakers: SpeakerRecognitionService(store: store),
                    singleSpeakerEmbedding: { _ in nil },
                    settings: AppSettings(),
                    scratchRoot: root.appendingPathComponent("scratch")
                )

                do {
                    _ = try await pipeline.enrolSpokenSample(
                        audio: root.appendingPathComponent("read-aloud.wav"), identityID: me.id
                    )
                    expect.fail("a recording with no single voice must not enrol")
                } catch let error as SpokenEnrollmentError {
                    expect.equal(error, .noSingleVoice)
                }
                expect.equal(
                    try await store.profileStatus(of: me.id, model: .fluidAudioOffline).sampleCount,
                    0
                )
            },

            test("a reading too short to stand behind says how short it was") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                let (store, storeRoot) = try SpeakerIdentityTests.makeStore()
                defer { try? FileManager.default.removeItem(at: storeRoot) }
                let me = try await store.createPerson(name: "Andrew", isLocalUser: true)

                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: StubLocalTranscriber(segments: []),
                    diarizer: StubLocalDiarizer(intervals: [], chunkEmbeddings: []),
                    speakers: SpeakerRecognitionService(store: store),
                    singleSpeakerEmbedding: { _ in
                        SingleSpeakerSample(
                            vector: SpeakerIdentityTests.vector(seed: 7), speechSeconds: 12,
                            quality: 0.9, spans: [AudioSpan(start: 0, end: 12)]
                        )
                    },
                    settings: AppSettings(),
                    scratchRoot: root.appendingPathComponent("scratch")
                )

                do {
                    _ = try await pipeline.enrolSpokenSample(
                        audio: root.appendingPathComponent("read-aloud.wav"), identityID: me.id
                    )
                    expect.fail("twelve seconds is below the enrolment bar")
                } catch let error as SpokenEnrollmentError {
                    // The numbers reach the screen: "keep reading" is only
                    // useful next to how much further there is to go.
                    expect.equal(
                        error, .rejected(.tooLittleSpeech(seconds: 12, required: 45))
                    )
                }
            },

            test("the microphone track counts as a meeting the local user was in") { expect in
                // The microphone track has no diarization cluster, so nothing
                // wrote an occurrence row for it. Every count over that table
                // then read the local user as having been in no meeting at all:
                // the People list said zero beside a profile built from those
                // very recordings, and the rename that walks the same query
                // visited none of their transcripts.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                let (store, storeRoot) = try SpeakerIdentityTests.makeStore()
                defer { try? FileManager.default.removeItem(at: storeRoot) }

                let me = try await store.createPerson(name: "Andrew", isLocalUser: true)
                var settings = AppSettings()
                settings.processing.localUserIdentityID = me.id
                settings.enrichment = EnrichmentSettings(
                    generateTitle: false, generateDescription: false, generateNotes: false,
                    generateSummary: false, suggestSpeakers: false
                )

                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: {
                        let stub = StubLocalTranscriber(segments: [
                            RawTranscriptSegment(
                                start: 0, end: 5, text: "we ship friday", speaker: nil
                            ),
                        ])
                        stub.micSegments = [
                            RawTranscriptSegment(
                                start: 0, end: 4, text: "sounds right to me", speaker: nil
                            ),
                        ]
                        return stub
                    }(),
                    diarizer: StubLocalDiarizer(
                        intervals: [DiarizationInterval(start: 0, end: 5, clusterID: "S1")],
                        chunkEmbeddings: embeddings(cluster: "S1", seed: 41, spans: [(0, 5)])
                    ),
                    speakers: SpeakerRecognitionService(store: store),
                    settings: settings,
                    scratchRoot: root.appendingPathComponent("scratch")
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                expect.equal(
                    try await store.meetingCount(for: me.id), 1,
                    "the microphone track is the local user, so this is a meeting they were in"
                )
                let occurrences = try await store.occurrences(meetingID: meeting.metadata.id)
                let mine = try expect.unwrap(
                    occurrences.first { $0.clusterID == SpeakerLabel.localUser }
                )
                expect.equal(mine.track, .mic)
                expect.equal(mine.resolvedIdentityID, me.id)
                expect.isTrue(mine.speechSeconds > 0, "the row carries the speech behind it")

                // The same query drives the rename refresh, so without the row
                // above, renaming yourself left every past transcript of your
                // own showing the name you had left behind.
                _ = try await store.rename(me.id, to: "Andrew Neeser")
                try await pipeline.refreshCachedNames(for: me.id)
                expect.equal(
                    try meeting.store.readSpeakerMap().displayName(for: SpeakerLabel.localUser),
                    "Andrew Neeser",
                    "renaming yourself reaches the meetings you were in"
                )
            },

            test("saying the microphone was somebody else takes back what it taught") { expect in
                // The microphone track has no diarization cluster, so nothing
                // reached the vector it produced. That vector claims to be the
                // local user's own voice, which is the one profile no person ever
                // reviews, and it was learned on a claim the user has just
                // withdrawn.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                let (store, storeRoot) = try SpeakerIdentityTests.makeStore()
                defer { try? FileManager.default.removeItem(at: storeRoot) }

                let me = try await store.createPerson(name: "Andrew", isLocalUser: true)
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: me.id, vector: SpeakerIdentityTests.vector(seed: 99),
                    model: .fluidAudioOffline, speechSeconds: 200, qualityScore: 1,
                    source: .micTrackDeterministic,
                    evidence: [VoiceEvidence(
                        meetingID: meeting.metadata.id, track: .mic,
                        spans: [AudioSpan(start: 0, end: 200)],
                        confirmation: .micTrackDeterministic
                    )]
                ))
                expect.equal(
                    try await store.profileStatus(of: me.id, model: .fluidAudioOffline).sampleCount,
                    1
                )

                var settings = AppSettings()
                settings.processing.localUserIdentityID = me.id
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: StubLocalTranscriber(segments: []),
                    diarizer: StubLocalDiarizer(intervals: [], chunkEmbeddings: []),
                    speakers: SpeakerRecognitionService(store: store),
                    settings: settings,
                    scratchRoot: root.appendingPathComponent("scratch")
                )
                _ = try await pipeline.applySpeakerName(
                    "Priya", to: SpeakerLabel.localUser, meetingID: meeting.metadata.id
                )
                expect.equal(
                    try await store.profileStatus(of: me.id, model: .fluidAudioOffline).sampleCount,
                    0,
                    "the microphone was not you, so it taught your profile nothing"
                )
            },

            test("switching backend and retrying does not transcribe the track twice") { expect in
                // A cloud run failed after writing its chunks. The user switches
                // transcription to Local and retries, which resumes at this
                // stage. The two paths namespace their chunk identifiers
                // differently, so the resume guards missed each other and both
                // sets landed on the same track: the meeting was assembled
                // twice, once in each model's phrasing.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                try meeting.store.writeRawTranscript(RawTranscript(chunks: [
                    RawTranscriptChunk(
                        id: "remote_0000", track: .remote, timelineOffset: 0,
                        durationSeconds: 6, model: "gpt-cloud-transcribe",
                        responseFormat: "json",
                        segments: [
                            RawTranscriptSegment(
                                start: 0, end: 5, text: "the cloud already said this",
                                speaker: nil
                            ),
                        ],
                        purpose: .words
                    ),
                ]))

                let settings: AppSettings = {
                    var value = AppSettings()
                    value.processing = ProcessingSettings(
                        transcription: .local, diarization: .local
                    )
                    value.enrichment = EnrichmentSettings(
                        generateTitle: false, generateDescription: false, generateNotes: false,
                        generateSummary: false, suggestSpeakers: false
                    )
                    return value
                }()
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: StubLocalTranscriber(segments: [
                        RawTranscriptSegment(
                            start: 0, end: 5, text: "and whisper says it differently",
                            speaker: nil,
                            words: [RawTranscriptWord(start: 0, end: 2, text: " and")]
                        ),
                    ]),
                    diarizer: StubLocalDiarizer(intervals: [], chunkEmbeddings: []),
                    speakers: nil, settings: settings,
                    scratchRoot: root.appendingPathComponent("scratch")
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                let remote = try meeting.store.readRawTranscript()
                    .chunks(track: .remote, purpose: .words)
                expect.equal(
                    remote.map(\.model), ["gpt-cloud-transcribe"],
                    "the words already on disk stand; a second backend does not add its own"
                )
                // The microphone track had no cloud words, so it is transcribed
                // locally as normal. The far end is what must not be doubled.
                let farEnd = (try meeting.store.readCanonicalTranscript()?.utterances ?? [])
                    .filter { $0.track == .remote }.map(\.text).joined(separator: " ")
                expect.isTrue(farEnd.contains("the cloud already said this"))
                expect.isFalse(
                    farEnd.contains("whisper says it differently"),
                    "so the far end is not assembled twice in two models' phrasing"
                )
            },

            test("re-analysing a cloud-diarized meeting changes who the lines belong to") { expect in
                // A backend that transcribes and diarizes in one request writes
                // its labels into the words, so the assembler kept them and the
                // run a re-analysis produced was never read: pressing Run under
                // Re-analyze speakers showed the same speakers however many
                // times it was pressed.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                // What a cloud pass leaves behind: words carrying their own
                // labels, and a run derived from them.
                try meeting.store.writeRawTranscript(RawTranscript(chunks: [
                    RawTranscriptChunk(
                        id: "remote_0000", track: .remote, timelineOffset: 0,
                        durationSeconds: 6, model: "cloud", responseFormat: "json",
                        segments: [
                            RawTranscriptSegment(start: 0, end: 3, text: "first", speaker: "A"),
                            RawTranscriptSegment(start: 3, end: 6, text: "second", speaker: "A"),
                        ],
                        purpose: .words
                    ),
                ]))
                try meeting.store.writeRawDiarization(RawDiarization(runs: [
                    DiarizationRun(
                        id: "remote-001", track: .remote, backend: "cloud",
                        producedAt: Date(), timelineOffset: 0,
                        clusters: [DiarizationCluster(id: "A", speechSeconds: 6)],
                        intervals: [DiarizationInterval(start: 0, end: 6, clusterID: "A")]
                    ),
                ]))

                let assembler = TranscriptAssembler()
                let before = assembler.assemble(
                    raw: try meeting.store.readRawTranscript(),
                    diarization: try meeting.store.readRawDiarization(),
                    micTrackIsLocalUser: true, generatedAt: Date()
                )
                expect.equal(
                    Set(before.utterances.filter { $0.track == .remote }.map(\.speakerKey)).count,
                    1,
                    "the cloud heard one speaker"
                )

                // A local re-analysis splits it in two.
                var diarization = try meeting.store.readRawDiarization()
                diarization.setActive(DiarizationRun(
                    id: "remote-002", track: .remote, backend: "fluidaudio",
                    producedAt: Date(), timelineOffset: 0,
                    clusters: [
                        DiarizationCluster(id: "S1", speechSeconds: 3),
                        DiarizationCluster(id: "S2", speechSeconds: 3),
                    ],
                    intervals: [
                        DiarizationInterval(start: 0, end: 3, clusterID: "S1"),
                        DiarizationInterval(start: 3, end: 6, clusterID: "S2"),
                    ]
                ))
                try meeting.store.writeRawDiarization(diarization)

                let after = assembler.assemble(
                    raw: try meeting.store.readRawTranscript(),
                    diarization: try meeting.store.readRawDiarization(),
                    micTrackIsLocalUser: true, generatedAt: Date()
                )
                expect.equal(
                    Set(after.utterances.filter { $0.track == .remote }.map(\.speakerKey)).count,
                    2,
                    "and the re-analysis is what the transcript now reads from"
                )
            },

            test("naming a cluster leaves the lines already given to somebody else") { expect in
                // A line-level correction outranks the cluster's name on screen.
                // Claiming the whole cluster's audio for the person being named
                // took the corrected line's voice away from the person still
                // shown as speaking it, so the transcript said one thing and
                // voice memory the other.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                let (store, storeRoot) = try SpeakerIdentityTests.makeStore()
                defer { try? FileManager.default.removeItem(at: storeRoot) }

                let key = "remote-001_speaker_00"
                try meeting.store.writeRawDiarization(RawDiarization(runs: [
                    DiarizationRun(
                        id: "remote-001", track: .remote, backend: "test",
                        producedAt: Date(), timelineOffset: 0,
                        clusters: [DiarizationCluster(id: "speaker_00", speechSeconds: 300)],
                        intervals: [DiarizationInterval(start: 0, end: 300, clusterID: "speaker_00")]
                    ),
                ]))
                try await store.recordOccurrence(
                    meetingID: meeting.metadata.id, clusterID: key, track: .remote,
                    speechSeconds: 300, embedding: SpeakerIdentityTests.vector(seed: 97),
                    model: .fluidAudioOffline, resolution: nil, identityID: nil,
                    source: .ai, humanVerified: false, wasExpectedParticipant: false
                )

                // Bob owns one line inside the cluster, and enough of it to hold
                // a vector of his own.
                let bob = try await store.createPerson(name: "Bob")
                let line = Utterance(
                    id: "u1", start: 100, end: 180, track: .remote, rawSpeakerLabel: nil,
                    speakerKey: key, text: "this bit is Bob", chunkID: "c", model: "m"
                )
                try meeting.store.writeCanonicalTranscript(
                    CanonicalTranscript(generatedAt: Date(), utterances: [line])
                )
                var map = SpeakerMap()
                map.overrideUtterance(
                    line,
                    with: SpeakerAssignment(
                        displayName: "Bob", origin: .human, identityID: bob.id,
                        provenance: .human()
                    ),
                    at: Date()
                )
                try meeting.store.writeSpeakerMap(map)
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: bob.id, vector: SpeakerIdentityTests.vector(seed: 98),
                    model: .fluidAudioOffline, speechSeconds: 80, qualityScore: 1,
                    source: .humanConfirmedUtterances,
                    evidence: [VoiceEvidence(
                        meetingID: meeting.metadata.id, track: .remote,
                        spans: [AudioSpan(start: 100, end: 180)],
                        confirmation: .humanConfirmedUtterances
                    )]
                ))

                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: StubLocalTranscriber(segments: []),
                    diarizer: StubLocalDiarizer(intervals: [], chunkEmbeddings: []),
                    speakers: SpeakerRecognitionService(store: store),
                    settings: AppSettings(),
                    scratchRoot: root.appendingPathComponent("scratch")
                )
                let alice = try expect.unwrap(
                    await pipeline.applySpeakerName(
                        "Alice", to: key, meetingID: meeting.metadata.id
                    )
                )
                expect.equal(
                    try await store.profileStatus(
                        of: bob.id, model: .fluidAudioOffline
                    ).sampleCount,
                    1,
                    "the line is still Bob's on screen, so it is still his in voice memory"
                )
                expect.equal(
                    try await store.profileStatus(
                        of: alice, model: .fluidAudioOffline
                    ).sampleCount,
                    1,
                    "and Alice is enrolled from the rest of the cluster"
                )
            },

            test("undoing a line correction hands the audio back, it does not orphan it") { expect in
                // Correcting one line away from the cluster's owner and then
                // clearing it returns that line to them. Retracting it for
                // nobody took those seconds off the person it had just gone back
                // to, so undoing a mistake cost them the profile the mistake had
                // not.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
                let (store, storeRoot) = try SpeakerIdentityTests.makeStore()
                defer { try? FileManager.default.removeItem(at: storeRoot) }

                let key = "remote-001_speaker_00"
                let alice = try await store.createPerson(name: "Alice")
                // Alice's confirmed cluster covers the whole meeting, including
                // the line about to be corrected away and back.
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: alice.id, vector: SpeakerIdentityTests.vector(seed: 96),
                    model: .fluidAudioOffline, speechSeconds: 60, qualityScore: 1,
                    source: .humanConfirmedCluster,
                    evidence: [VoiceEvidence(
                        meetingID: meeting.metadata.id, track: .remote,
                        spans: [AudioSpan(start: 0, end: 60)],
                        confirmation: .humanConfirmedCluster, clusterID: key
                    )]
                ))
                var map = SpeakerMap()
                map.assign("Alice", to: key, identityID: alice.id)
                try meeting.store.writeSpeakerMap(map)

                let line = Utterance(
                    id: "u1", start: 10, end: 40, track: .remote, rawSpeakerLabel: nil,
                    speakerKey: key, text: "this bit was Bob", chunkID: "c", model: "m"
                )
                try meeting.store.writeCanonicalTranscript(
                    CanonicalTranscript(generatedAt: Date(), utterances: [line])
                )

                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: StubLocalTranscriber(segments: []),
                    diarizer: StubLocalDiarizer(intervals: [], chunkEmbeddings: []),
                    speakers: SpeakerRecognitionService(store: store),
                    settings: AppSettings(),
                    scratchRoot: root.appendingPathComponent("scratch")
                )

                // Thirty of Alice's sixty seconds go to Bob, which leaves her
                // below the bar, so her vector goes.
                try await pipeline.applyUtteranceSpeaker(
                    "Bob", utteranceIDs: ["u1"], meetingID: meeting.metadata.id
                )
                expect.equal(
                    try await store.profileStatus(
                        of: alice.id, model: .fluidAudioOffline
                    ).sampleCount,
                    0,
                    "half the audio is somebody else's, so the vector cannot stand"
                )

                // Alice is enrolled again, and the correction is undone.
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: alice.id, vector: SpeakerIdentityTests.vector(seed: 96),
                    model: .fluidAudioOffline, speechSeconds: 60, qualityScore: 1,
                    source: .humanConfirmedCluster,
                    evidence: [VoiceEvidence(
                        meetingID: meeting.metadata.id, track: .remote,
                        spans: [AudioSpan(start: 0, end: 60)],
                        confirmation: .humanConfirmedCluster, clusterID: key
                    )]
                ))
                try await pipeline.applyUtteranceSpeaker(
                    "", utteranceIDs: ["u1"], meetingID: meeting.metadata.id
                )
                expect.equal(
                    try await store.profileStatus(
                        of: alice.id, model: .fluidAudioOffline
                    ).sampleCount,
                    1,
                    "the line went back to Alice, so her own vector keeps covering it"
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

            test("a re-analysis keeps line corrections and drops cluster names") { expect in
                // What a person is left with after pressing Re-analyze speakers,
                // observed on the installed app: the line they corrected still
                // reads their name, and every speaker they named at the cluster
                // level reads "Speaker 1" again.
                //
                // Both halves are deliberate. A line override is anchored to a
                // span of the timeline, which renumbering does not move. A
                // cluster name is attached to a cluster of the previous run, and
                // the new run's clusters are not the same sets of audio, so
                // carrying the name across would be a guess about who the new
                // cluster is. Pinned so that changing either half has to be a
                // decision rather than an accident.
                var map = SpeakerMap()
                map.assign("Andrew", to: "remote-001_speaker_00")
                let corrected = Utterance(
                    id: "chunk_000-remote-001000-004000", start: 1, end: 4, track: .remote,
                    rawSpeakerLabel: "remote-001_speaker_00",
                    speakerKey: "remote-001_speaker_00", text: "hello",
                    chunkID: "chunk_000", model: "stub"
                )
                map.overrideUtterance(
                    corrected,
                    with: SpeakerAssignment(
                        displayName: "Chris", origin: .human,
                        provenance: SpeakerProvenance(source: .human, humanVerified: true)
                    ),
                    at: Date(timeIntervalSince1970: 1_787_070_000)
                )

                let renumbered = Utterance(
                    id: "chunk_000-remote-001000-004000", start: 1, end: 4, track: .remote,
                    rawSpeakerLabel: "remote-002_speaker_00",
                    speakerKey: "remote-002_speaker_00", text: "hello",
                    chunkID: "chunk_000", model: "stub"
                )
                expect.equal(
                    map.resolvedName(for: renumbered), "Chris",
                    "the correction is anchored to the audio, not to the cluster"
                )
                expect.isTrue(map.hasOverride(for: renumbered))

                let otherLine = Utterance(
                    id: "chunk_000-remote-010000-014000", start: 10, end: 14, track: .remote,
                    rawSpeakerLabel: "remote-002_speaker_00",
                    speakerKey: "remote-002_speaker_00", text: "and again",
                    chunkID: "chunk_000", model: "stub"
                )
                expect.equal(
                    map.resolvedName(for: otherLine), "Speaker 1",
                    "the name given to the previous run's cluster does not follow it"
                )
                expect.equal(
                    map.displayName(for: "remote-001_speaker_00"), "Andrew",
                    "and is still on disk rather than deleted"
                )
            },

            test("the transcriber reads the microphone with the far end taken out of it") { expect in
                // The canceller reaches the user here. Every stage above takes
                // its audio through `trackAudioLocation`, so cleaning the
                // microphone at the top of transcription is what stops the far
                // end's words being written down under the local user's name.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try MicrophoneCleanerTests.makeCallOnSpeakers(root: root)

                let transcriber = StubLocalTranscriber(segments: [
                    RawTranscriptSegment(
                        start: 0, end: 5, text: "we ship friday", speaker: nil,
                        words: [RawTranscriptWord(start: 0, end: 0.3, text: " we")]
                    ),
                ])
                transcriber.copyAudioTo = root.appendingPathComponent("handed")
                let diarizer = StubLocalDiarizer(
                    intervals: [DiarizationInterval(start: 0, end: 2, clusterID: "S1")],
                    chunkEmbeddings: embeddings(cluster: "S1", seed: 51, spans: [(0, 2)])
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
                expect.equal(metadata.cleaningOutcome, CleaningOutcome.cleaned)
                let cleaned = try expect.unwrap(metadata.cleanedMic)
                expect.equal(cleaned.track.file, "mic.cleaned.m4a")

                let handed = try expect.unwrap(
                    transcriber.copiedAudio.first { $0.lastPathComponent.hasSuffix("mic.wav") },
                    "the microphone was transcribed"
                )
                let measured = try farEndAndUser(
                    handed: handed,
                    recording: meeting.store.rawTrackAudioLocation(
                        track: .mic, metadata: metadata, timeline: try meeting.store.readTimeline()
                    )
                )
                expect.isTrue(
                    measured.farEndLostDB > 20,
                    "the transcriber read a microphone whose far end is only "
                        + "\(measured.farEndLostDB) dB down on the recording"
                )
                expect.isTrue(
                    abs(measured.userLostDB) < 3,
                    "and the user's own voice moved \(measured.userLostDB) dB with it"
                )
            },

            test("a working copy an earlier run left is thrown away when the microphone is cleaned") { expect in
                // The working copies in Caches are keyed by meeting and track
                // alone and carry no record of what they were exported from, and
                // an existing one is handed back without being read. A run that
                // exported the recording and then stopped part-way leaves one.
                // The next run cleans the microphone and then transcribes that
                // export instead of the track it just wrote.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try MicrophoneCleanerTests.makeCallOnSpeakers(root: root)
                let scratchRoot = root.appendingPathComponent("scratch")

                let recording = meeting.store.rawTrackAudioLocation(
                    track: .mic, metadata: meeting.metadata,
                    timeline: try meeting.store.readTimeline()
                )
                let stale = try expect.unwrap(try ProcessingScratch(root: scratchRoot).trackAudio(
                    meetingID: meeting.metadata.id, track: .mic,
                    segments: recording.segments, segmentsDirectory: recording.directory
                ))
                expect.isTrue(
                    FileManager.default.fileExists(atPath: stale.path),
                    "the earlier run's export is there to be picked up"
                )

                let transcriber = StubLocalTranscriber(segments: [
                    RawTranscriptSegment(
                        start: 0, end: 5, text: "we ship friday", speaker: nil,
                        words: [RawTranscriptWord(start: 0, end: 0.3, text: " we")]
                    ),
                ])
                transcriber.copyAudioTo = root.appendingPathComponent("handed")
                let diarizer = StubLocalDiarizer(
                    intervals: [DiarizationInterval(start: 0, end: 2, clusterID: "S1")],
                    chunkEmbeddings: embeddings(cluster: "S1", seed: 52, spans: [(0, 2)])
                )
                var settings = AppSettings()
                settings.enrichment = EnrichmentSettings(
                    generateTitle: false, generateDescription: false, generateNotes: false,
                    generateSummary: false, suggestSpeakers: false
                )
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: transcriber, diarizer: diarizer, speakers: nil,
                    settings: settings, scratchRoot: scratchRoot
                )
                await pipeline.process(meetingID: meeting.metadata.id)

                let metadata = try meeting.store.readMetadata()
                expect.equal(metadata.cleaningOutcome, CleaningOutcome.cleaned)
                let handed = try expect.unwrap(
                    transcriber.copiedAudio.first { $0.lastPathComponent.hasSuffix("mic.wav") },
                    "the microphone was transcribed"
                )
                // Read again after the run rather than reusing the location the
                // stale copy was made from. Compaction replaces the segment
                // chain with `mic.m4a` and deletes the segments, so the
                // pre-run location names files that are no longer there.
                let measured = try farEndAndUser(
                    handed: handed,
                    recording: meeting.store.rawTrackAudioLocation(
                        track: .mic, metadata: metadata, timeline: try meeting.store.readTimeline()
                    )
                )
                expect.isTrue(
                    measured.farEndLostDB > 20,
                    "the transcriber was handed the earlier run's export of the recording, whose "
                        + "far end is \(measured.farEndLostDB) dB down"
                )
            },

            test("speech evidence measured on the recording is re-measured once the mic is cleaned") { expect in
                // `speech.json` is the other artefact cached per meeting with
                // nothing in it saying which microphone it was measured on, and
                // `measureSpeech` returns early whenever the file is there. An
                // upgrade landing on a meeting stopped part-way through
                // transcription carries evidence measured on the recording into
                // a run that cleans the microphone. The echo readings in it are
                // then applied to words transcribed from the cleaned track, and
                // a high reading on a double-talk window is what drops a line
                // the user really spoke.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try MicrophoneCleanerTests.makeCallOnSpeakers(root: root)

                // A microphone loud in every window and carrying the far end in
                // every window, which is what the recording measures and the
                // cleaned track does not.
                let windows = 120
                try meeting.store.writeSpeechEvidence(SpeechEvidence(
                    levelWindowSeconds: 0.25, speechWindowSeconds: 0.25,
                    micLevels: [Int8](repeating: -20, count: windows),
                    remoteLevels: [Int8](repeating: -18, count: windows),
                    micSpeech: [Int8](repeating: 95, count: windows),
                    micEchoReturnLoss: [Int16](repeating: 50, count: windows),
                    detector: "measured-on-the-recording"
                ))

                let transcriber = StubLocalTranscriber(segments: [
                    RawTranscriptSegment(
                        start: 0, end: 5, text: "we ship friday", speaker: nil,
                        words: [RawTranscriptWord(start: 0, end: 0.3, text: " we")]
                    ),
                ])
                let diarizer = StubLocalDiarizer(
                    intervals: [DiarizationInterval(start: 0, end: 2, clusterID: "S1")],
                    chunkEmbeddings: embeddings(cluster: "S1", seed: 54, spans: [(0, 2)])
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

                expect.equal(
                    try meeting.store.readMetadata().cleaningOutcome, CleaningOutcome.cleaned
                )
                let evidence = try expect.unwrap(meeting.store.readSpeechEvidence())
                expect.notEqual(
                    evidence.detector, "measured-on-the-recording",
                    "the evidence the interrupted run left is not the evidence the words are read with"
                )
                // The levels themselves, not just the provenance string. The
                // far end plays alone for the last third, so the recording
                // holds its echo there and the cleaned track holds only what
                // the canceller could not subtract. Compared against the
                // recording's own level rather than a fixed number, because
                // what is being asserted is which track was measured.
                let recorded = try MicrophoneCleanerTests.samples(
                    meeting.store.rawTrackAudioLocation(
                        track: .mic, metadata: try meeting.store.readMetadata(),
                        timeline: try meeting.store.readTimeline()
                    )
                )
                let tail = MicrophoneCleanerTests.seconds(20, 30, of: recorded)
                let squares = tail.reduce(0.0) { $0 + Double($1) * Double($1) }
                let recordedDBFS = 20 * log10((squares / Double(max(tail.count, 1))).squareRoot())
                let lastThird = evidence.micLevels.suffix(evidence.micLevels.count / 3)
                let loudest = Double(lastThird.max() ?? 0)
                expect.isTrue(
                    !lastThird.isEmpty && loudest < recordedDBFS - 6,
                    "the microphone reads \(loudest) dBFS where only the far end played, against "
                        + "\(recordedDBFS) dBFS in the recording, so the levels were measured on "
                        + "the recording"
                )
            },

            test("a meeting whose cleaner throws is still transcribed") { expect in
                // Cleaning is an improvement on the recording, never a
                // condition of reading it. A disk that will not take the
                // cleaned file has to leave the user with the same transcript
                // they would have had before any of this existed.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                // The cleaned track's own directory, taken away from the writer
                // after the recording is safely in the segments. Nothing else
                // this run needs is written here. The mixdown goes to the
                // meeting root, and compaction reports its own failure and
                // leaves the segments where they are.
                let audioDirectory = meeting.store.layout.trackArchiveDirectory
                try FileManager.default.createDirectory(
                    at: audioDirectory, withIntermediateDirectories: true
                )
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o555], ofItemAtPath: audioDirectory.path
                )
                defer {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o755], ofItemAtPath: audioDirectory.path
                    )
                }

                let transcriber = StubLocalTranscriber(segments: [
                    RawTranscriptSegment(
                        start: 0, end: 5, text: "we ship friday", speaker: nil,
                        words: [RawTranscriptWord(start: 0, end: 0.3, text: " we")]
                    ),
                ])
                let diarizer = StubLocalDiarizer(
                    intervals: [DiarizationInterval(start: 0, end: 2, clusterID: "S1")],
                    chunkEmbeddings: embeddings(cluster: "S1", seed: 53, spans: [(0, 2)])
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
                expect.equal(metadata.cleaningOutcome, CleaningOutcome.failed)
                expect.isNil(metadata.cleanedMic, "and nothing points a reader at a file")
                expect.equal(
                    metadata.processing.state, .complete,
                    "the meeting was transcribed on the microphone it recorded"
                )
                let raw = try meeting.store.readRawTranscript()
                expect.isTrue(raw.chunks.contains { $0.id == "mic_full" })
                expect.isTrue(raw.chunks.contains { $0.id == "remote_full" })
            },

            test("the panel is answered while the microphone is being cleaned") { expect in
                // Cleaning decodes both tracks, runs the canceller over every
                // 10 ms block and encodes the whole microphone. On a one-hour
                // meeting that is minutes, and run on this actor's executor it
                // is minutes in which Move to Trash, a speaker rename and a
                // line correction all wait. The probe is `forget`, which is
                // what Move to Trash calls, asked about a meeting the pipeline
                // holds nothing for so it cannot disturb the run.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try MicrophoneCleanerTests.makeCallOnSpeakers(root: root)
                let cleanedFile = meeting.store.layout.cleanedMicFile

                let transcriber = StubLocalTranscriber(segments: [
                    RawTranscriptSegment(
                        start: 0, end: 5, text: "we ship friday", speaker: nil,
                        words: [RawTranscriptWord(start: 0, end: 0.3, text: " we")]
                    ),
                ])
                let diarizer = StubLocalDiarizer(
                    intervals: [DiarizationInterval(start: 0, end: 2, clusterID: "S1")],
                    chunkEmbeddings: embeddings(cluster: "S1", seed: 57, spans: [(0, 2)])
                )
                var settings = AppSettings()
                settings.enrichment = EnrichmentSettings(
                    generateTitle: false, generateDescription: false, generateNotes: false,
                    generateSummary: false, suggestSpeakers: false
                )
                let started = ProgressGate()
                let pipeline = makePipeline(
                    repository: meeting.repository, backend: FakeAIBackend(),
                    transcriber: transcriber, diarizer: diarizer, speakers: nil,
                    settings: settings, scratchRoot: root.appendingPathComponent("scratch"),
                    onProgress: { progress in
                        if progress.detail == "Removing the far end from the microphone" {
                            started.open()
                        }
                    }
                )
                let run = Task { await pipeline.process(meetingID: meeting.metadata.id) }
                await started.wait()
                // Reported from the actor immediately before the pass begins,
                // so this call is enqueued while the pass is running and comes
                // back only once the actor is free to take it. The cleaned file
                // is renamed into place at the very end of the pass, which is
                // what dates the answer.
                _ = await pipeline.forget(meetingID: "held-by-nobody", movedAt: Date())
                let answeredDuringThePass = !FileManager.default.fileExists(
                    atPath: cleanedFile.path
                )
                await run.value

                expect.isTrue(
                    answeredDuringThePass,
                    "the actor answered only after the cleaned track was already written"
                )
                expect.equal(
                    try meeting.store.readMetadata().cleaningOutcome, CleaningOutcome.cleaned,
                    "and the pass this raced ran to the end"
                )
            },
        ])
    }
}
