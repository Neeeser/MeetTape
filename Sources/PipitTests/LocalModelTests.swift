import Foundation
import PipitAudio
import PipitCore
import PipitLocalAI
import PipitSpeakers
import TestKit

/// Opt-in tests that load the real on-device models.
///
/// Skipped unless `PIPIT_LOCAL_MODELS=1`, because the first run downloads
/// about 650 MB and the runner has no per-test timeout. The audio is the same
/// locally synthesised fixture the live API tests use, so nothing here costs
/// money or leaves the machine.
enum LocalModelTests {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["PIPIT_LOCAL_MODELS"] == "1"
    }

    static func requireModels() throws -> (URL, URL) {
        guard isEnabled else {
            throw TestSkip("set PIPIT_LOCAL_MODELS=1 to run the on-device model tests")
        }
        guard let path = ProcessInfo.processInfo.environment["PIPIT_LIVE_FIXTURE"] else {
            throw TestSkip("run scripts/make-live-fixture.sh and set PIPIT_LIVE_FIXTURE")
        }
        let fixtures = URL(fileURLWithPath: path)
        let conversation = fixtures.appendingPathComponent("conversation.wav")
        guard FileManager.default.fileExists(atPath: conversation.path) else {
            throw TestSkip("the fixture directory has no conversation.wav")
        }
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pipit", isDirectory: true)
        return (support, conversation)
    }

    static var suite: Suite {
        Suite("LocalModels", [
            test("the models install into Pipit's own directory and load") { expect in
                let (support, _) = try requireModels()
                let manager = LocalModelManager(applicationSupport: support)
                let snapshot = try await manager.install()
                let whisper = try expect.unwrap(snapshot.receipts[.whisper])
                expect.equal(whisper.revision, LocalSpeechStack.revision(for: .whisper))
                let folder = try expect.unwrap(whisper.detail)
                expect.isTrue(
                    folder.contains("Application Support/Pipit/Models/Whisper"),
                    "got \(folder)"
                )
                expect.isFalse(folder.contains("/Documents/"))
                expect.isTrue(
                    whisper.bytes > 300_000_000,
                    "the model is about 624 MB, got \(whisper.bytes)"
                )
                expect.isTrue(snapshot.receipts[.diarizer] != nil, "the diarizer installs with it")
                expect.isTrue(await manager.isInstalled)
            },

            test("transcription returns words with usable timings and no special tokens") { expect in
                let (support, audio) = try requireModels()
                let manager = LocalModelManager(applicationSupport: support)
                _ = try await manager.install()
                let backend = WhisperTranscriptionBackend(models: manager)

                // Warm the pipeline first. On a 38-second clip the one-off
                // model load dominates, and timing it would pin the load rather
                // than the transcription.
                _ = try await backend.transcribe(audio: audio) { _ in }
                let started = Date()
                let output = try await backend.transcribe(audio: audio) { _ in }
                let seconds = Date().timeIntervalSince(started)

                expect.isFalse(output.text.isEmpty)
                expect.isFalse(
                    output.text.contains("<|"),
                    "skipSpecialTokens is off: \(output.text.prefix(80))"
                )
                expect.isTrue(output.hasWordTimings, "word timings are what attribution consumes")
                expect.isTrue(output.wordCount > 50, "got \(output.wordCount) words")

                var last = -1.0
                var zeroLength = 0
                for segment in output.segments {
                    expect.isTrue(segment.start >= last - 0.001, "segment starts went backwards")
                    last = segment.start
                    for word in segment.words ?? [] where word.end <= word.start {
                        zeroLength += 1
                    }
                }
                expect.isTrue(
                    zeroLength * 10 < output.wordCount,
                    "\(zeroLength) of \(output.wordCount) words have no duration"
                )

                let audioSeconds = MonoAudioDecoder.durationSeconds(audio)
                Log.processing.info(
                    "local ASR: \(audioSeconds, privacy: .public)s in \(seconds, privacy: .public)s"
                )
                expect.isTrue(
                    seconds < audioSeconds,
                    "warm transcription ran slower than real time: \(seconds)s for \(audioSeconds)s"
                )
            },

            test("diarization separates the fixture's voices and returns their vectors") { expect in
                let (support, audio) = try requireModels()
                let manager = LocalModelManager(applicationSupport: support)
                _ = try await manager.install()
                let backend = FluidAudioDiarizationBackend(models: manager)

                let output = try await backend.diarize(audio: audio) { _ in }
                expect.equal(output.configuration["warmStartFa"], "0.2")
                expect.isTrue(
                    output.speakerCount >= 2,
                    "the fixture has three voices, found \(output.speakerCount)"
                )
                expect.isFalse(output.chunkEmbeddings.isEmpty)
                expect.equal(output.chunkEmbeddings.first?.vector.count, 256)

                // Different clusters must be further apart than one cluster is
                // from itself, or nothing downstream can work.
                var byCluster: [String: [[Float]]] = [:]
                for chunk in output.chunkEmbeddings {
                    byCluster[chunk.clusterID, default: []].append(chunk.vector)
                }
                let centroids = byCluster.mapValues { VoiceVector.centroid($0) }
                let ids = centroids.keys.sorted()
                if ids.count >= 2 {
                    let across = VoiceVector.cosine(centroids[ids[0]]!, centroids[ids[1]]!)
                    let within = VoiceVector.cosine(
                        centroids[ids[0]]!, VoiceVector.l2Normalized(byCluster[ids[0]]![0])
                    )
                    expect.isTrue(
                        within > across,
                        "a cluster should sit closer to its own chunks (\(within)) than to another cluster (\(across))"
                    )
                }
            },

            test("parakeet transcribes the fixture with word timings of its own") { expect in
                let (support, audio) = try requireModels()
                let manager = LocalModelManager(applicationSupport: support)
                _ = try await manager.install(units: [.parakeet])
                let output = try await ParakeetTranscriptionBackend(models: manager)
                    .transcribe(audio: audio) { _ in }
                expect.isFalse(output.text.isEmpty)
                expect.isTrue(output.hasWordTimings, "word timings are what attribution consumes")
                expect.isTrue(output.wordCount > 50, "got \(output.wordCount) words")
            },

            test("the aligner recovers timings for a text-only transcript") { expect in
                let (support, audio) = try requireModels()
                let manager = LocalModelManager(applicationSupport: support)
                _ = try await manager.install(units: [.parakeet, .ctcAligner])
                // Parakeet's own timed words are the reference: align its text
                // as though it had none, and the timings should come back
                // close to where the decoder heard them.
                let reference = try await ParakeetTranscriptionBackend(models: manager)
                    .transcribe(audio: audio) { _ in }
                let aligned = try await CtcTranscriptAligner(models: manager)
                    .align(audio: audio, text: reference.text)

                let alignedWords = aligned.flatMap { $0.words ?? [] }
                let referenceWords = reference.segments.flatMap { $0.words ?? [] }
                expect.isTrue(
                    alignedWords.count * 10 >= referenceWords.count * 9,
                    "aligned \(alignedWords.count) of \(referenceWords.count) words"
                )
                var last = -1.0
                for word in alignedWords {
                    expect.isTrue(word.start >= last - 0.001, "word starts went backwards")
                    last = word.start
                }
                // Same words in, so start times should track the decoder's own.
                var deviations: [Double] = []
                for (aligned, reference) in zip(alignedWords, referenceWords)
                where aligned.text.trimmingCharacters(in: .whitespaces).lowercased()
                    == reference.text.trimmingCharacters(in: .whitespaces).lowercased() {
                    deviations.append(abs(aligned.start - reference.start))
                }
                let mean = deviations.isEmpty
                    ? .infinity : deviations.reduce(0, +) / Double(deviations.count)
                expect.isTrue(
                    mean < 0.5,
                    "mean start deviation \(mean)s over \(deviations.count) matched words"
                )
            },

            test("cohere transcribes the fixture, text only, and the pipeline shape holds") { expect in
                // The heavyweight: about 2.1 GB on first run and a several
                // minute ANE compile. Deliberately last in the suite.
                let (support, audio) = try requireModels()
                let manager = LocalModelManager(applicationSupport: support)
                _ = try await manager.install(units: [.cohere])
                let backend = CohereTranscriptionBackend(models: manager)
                expect.equal(backend.timing, .text)
                let output = try await backend.transcribe(audio: audio) { _ in }
                expect.isFalse(output.text.isEmpty)
                expect.equal(output.segments.count, 0, "no timings are invented")
                let terms = ["staging", "rollback", "replication"]
                let survived = terms.filter { output.text.lowercased().contains($0) }
                expect.isTrue(
                    survived.count >= 2,
                    "expected the fixture's terms to survive, got: \(output.text.prefix(120))"
                )
            },

            test("the archive bitrate preserves the voices the identity models read") { expect in
                let (support, audio) = try requireModels()
                let manager = LocalModelManager(applicationSupport: support)
                _ = try await manager.install()
                let backend = FluidAudioDiarizationBackend(models: manager)

                // The fixture re-encoded exactly as compaction stores a track:
                // AAC, mono, 16 kHz, 48 kbps. Identity margins are thin (the
                // worst impostor scored 0.957 against the true speaker's own
                // 0.951), so the archive representation must keep each voice
                // where the PCM put it.
                let tmp = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: tmp) }
                let info = try AudioFileInspector().inspect(url: audio)
                let location = TrackAudioLocation.archived(
                    track: .remote,
                    record: AudioArchive.Track(
                        file: audio.lastPathComponent, sampleRate: info.sampleRate,
                        channelCount: info.channelCount, frameCount: info.frameCount,
                        seconds: info.seconds, firstFrameHostTime: nil
                    ),
                    directory: audio.deletingLastPathComponent(),
                    compactedAt: Date()
                )
                let compressed = tmp.appendingPathComponent("archive.m4a")
                _ = try TrackArchiveExporter().export(location: location, to: compressed)

                let original = try await backend.diarize(audio: audio) { _ in }
                let archived = try await backend.diarize(audio: compressed) { _ in }
                expect.isTrue(
                    archived.speakerCount >= 2,
                    "the archive still separates the voices, found \(archived.speakerCount)"
                )

                func centroids(_ chunks: [(clusterID: String, vector: [Float])]) -> [[Float]] {
                    var byCluster: [String: [[Float]]] = [:]
                    for chunk in chunks { byCluster[chunk.clusterID, default: []].append(chunk.vector) }
                    return byCluster.values.map { VoiceVector.centroid($0) }
                }
                let pcmVoices = centroids(original.chunkEmbeddings.map { ($0.clusterID, $0.vector) })
                let aacVoices = centroids(archived.chunkEmbeddings.map { ($0.clusterID, $0.vector) })
                for voice in pcmVoices {
                    let best = aacVoices.map { VoiceVector.cosine(voice, $0) }.max() ?? -1
                    expect.isTrue(
                        best > 0.9,
                        "each PCM voice has a close match in the archive, best \(best)"
                    )
                }
            },

            test("the models load with the network refused") { expect in
                let (support, audio) = try requireModels()
                let manager = LocalModelManager(applicationSupport: support)
                _ = try await manager.install()
                // A fresh manager over the same directory: nothing is cached in
                // memory, so this is the path a relaunch takes.
                let cold = LocalModelManager(applicationSupport: support)
                expect.isTrue(await cold.isInstalled, "the receipt survives a restart")

                let output = try await FluidAudioDiarizationBackend(models: cold)
                    .diarize(audio: audio) { _ in }
                expect.isFalse(
                    output.intervals.isEmpty,
                    "the diarizer resolved its own models without downloading"
                )
                let words = try await WhisperTranscriptionBackend(models: cold)
                    .transcribe(audio: audio) { _ in }
                expect.isFalse(
                    words.segments.isEmpty,
                    "WhisperKit resolved its model folder without downloading"
                )
            },
        ])
    }
}
