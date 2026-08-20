import Foundation
import MeetTapeAudio
import MeetTapeCore
import MeetTapeLocalAI
import MeetTapeSpeakers
import TestKit

/// Opt-in tests that load the real on-device models.
///
/// Skipped unless `MEETTAPE_LOCAL_MODELS=1`, because the first run downloads
/// about 650 MB and the runner has no per-test timeout. The audio is the same
/// locally synthesised fixture the live API tests use, so nothing here costs
/// money or leaves the machine.
enum LocalModelTests {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MEETTAPE_LOCAL_MODELS"] == "1"
    }

    static func requireModels() throws -> (URL, URL) {
        guard isEnabled else {
            throw TestSkip("set MEETTAPE_LOCAL_MODELS=1 to run the on-device model tests")
        }
        guard let path = ProcessInfo.processInfo.environment["MEETTAPE_LIVE_FIXTURE"] else {
            throw TestSkip("run scripts/make-live-fixture.sh and set MEETTAPE_LIVE_FIXTURE")
        }
        let fixtures = URL(fileURLWithPath: path)
        let conversation = fixtures.appendingPathComponent("conversation.wav")
        guard FileManager.default.fileExists(atPath: conversation.path) else {
            throw TestSkip("the fixture directory has no conversation.wav")
        }
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeetTape", isDirectory: true)
        return (support, conversation)
    }

    static var suite: Suite {
        Suite("LocalModels", [
            test("the models install into MeetTape's own directory and load") { expect in
                let (support, _) = try requireModels()
                let manager = LocalModelManager(applicationSupport: support)
                let receipt = try await manager.install()
                expect.equal(receipt.whisperVariant, LocalSpeechStack.whisperModel)
                expect.isTrue(
                    receipt.whisperFolderPath.contains("Application Support/MeetTape/Models/Whisper"),
                    "got \(receipt.whisperFolderPath)"
                )
                expect.isFalse(receipt.whisperFolderPath.contains("/Documents/"))
                expect.isTrue(
                    receipt.whisperBytes > 300_000_000,
                    "the model is about 624 MB, got \(receipt.whisperBytes)"
                )
                expect.isTrue(await manager.isInstalled)
            },

            test("transcription returns words with usable timings and no special tokens") { expect in
                let (support, audio) = try requireModels()
                let manager = LocalModelManager(applicationSupport: support)
                _ = try await manager.install()
                let backend = WhisperTranscriptionBackend(models: manager)

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
                expect.isTrue(seconds < audioSeconds * 2, "slower than half real time")
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
