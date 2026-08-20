import Foundation
import MeetTapeCore
import MeetTapeLocalAI
import MeetTapeSpeakers
import TestKit

/// Pins the settings the local stack was measured with.
///
/// Each of these is a value a refactor could silently revert, and each one has a
/// measurement behind it. The tests exist so the revert is a failure rather than
/// a slow degradation nobody attributes to anything.
enum LocalConfigurationTests {
    static var configurationSuite: Suite {
        Suite("LocalConfiguration", [
            test("the diarizer runs with the tuned acoustic scaling, not the library default") { expect in
                // 0.07 finds 8 speakers where there are 17 and leaves 35.4% of
                // reference speakers without a cluster. 0.20 improves DER, JER,
                // speaker count, word attribution and speaker recovery at once.
                expect.close(LocalDiarizationTuning.warmStartFa, 0.20, tolerance: 0.0001)
                expect.notEqual(
                    LocalDiarizationTuning.warmStartFa,
                    LocalDiarizationTuning.libraryDefaultWarmStartFa
                )
                let config = LocalModelManager.diarizerConfiguration(speakerCount: nil)
                expect.close(config.clustering.warmStartFa, 0.20, tolerance: 0.0001)
            },

            test("no speaker count is ever supplied automatically") { expect in
                // The tuned automatic configuration beat the exact true count on
                // word attribution, on merges the user has to perform, and on
                // speakers recovered. A participant list is worse than not asking.
                expect.isNil(LocalDiarizationTuning.automaticSpeakerCount)
                let automatic = LocalModelManager.diarizerConfiguration(speakerCount: nil)
                expect.isNil(automatic.clustering.numSpeakers)
                expect.isNil(automatic.clustering.minSpeakers)
                expect.isNil(automatic.clustering.maxSpeakers)

                // Only an explicit human request reaches the field.
                let requested = LocalModelManager.diarizerConfiguration(speakerCount: 7)
                expect.equal(requested.clustering.numSpeakers, 7)
            },

            test("chunk embeddings are exposed, because speaker memory needs them") { expect in
                expect.isTrue(LocalModelManager.diarizerConfiguration(speakerCount: nil).exposeChunkEmbeddings)
            },

            test("the run records the configuration that produced it") { expect in
                let provenance = LocalModelManager.diarizerProvenance(speakerCount: nil)
                expect.equal(provenance["warmStartFa"], "0.2")
                expect.equal(provenance["pipeline"], "offline-vbx")
                expect.isNil(provenance["numSpeakers"])
                expect.equal(
                    LocalModelManager.diarizerProvenance(speakerCount: 5)["numSpeakers"], "5"
                )
            },

            test("the decoder keeps its timings and skips the special tokens") { expect in
                // The library default leaks <|startoftranscript|> into the text.
                expect.isTrue(LocalTranscriptionTuning.skipSpecialTokens)
                // Word timings are what speaker attribution consumes.
                expect.isTrue(LocalTranscriptionTuning.wordTimestamps)
                // Prompting improves punctuation and collapses word timings:
                // 198 distinct word starts became 153, 43 with zero duration.
                expect.isFalse(LocalTranscriptionTuning.usesPromptConditioning)
                // VAD chunking was faster and dropped 231 of 9278 words.
                expect.isFalse(LocalTranscriptionTuning.usesVADChunking)
            },

            test("the pinned model identifiers are the ones that were measured") { expect in
                expect.equal(
                    LocalSpeechStack.whisperModel, "openai_whisper-large-v3-v20240930_turbo_632MB"
                )
                expect.equal(LocalSpeechStack.whisperPackage, "argmax-oss-swift 1.1.0")
                expect.equal(LocalSpeechStack.diarizerPackage, "FluidAudio 0.15.6")
            },
        ])
    }

    static var storageSuite: Suite {
        Suite("LocalModelStorage", [
            test("models never land in Documents") { expect in
                // WhisperKit's own default is ~/Documents/huggingface, which puts
                // 624 MB where Finder shows it and iCloud Drive syncs it.
                let support = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/MeetTape")
                let locations = LocalModelLocations(applicationSupport: support)
                for url in [locations.root, locations.whisperBase, locations.whisperModelFolder,
                            locations.diarizerDirectory, locations.receipt] {
                    expect.isFalse(
                        url.path.contains("/Documents/"),
                        "\(url.path) is inside Documents"
                    )
                    expect.isTrue(
                        url.path.contains("Application Support/MeetTape"),
                        "\(url.path) is outside MeetTape's own directory"
                    )
                }
            },

            test("the whisper model folder matches the layout the library builds") { expect in
                let locations = LocalModelLocations(
                    applicationSupport: URL(fileURLWithPath: "/tmp/meettape-test")
                )
                expect.equal(
                    locations.whisperModelFolder.path,
                    "/tmp/meettape-test/Models/Whisper/models/argmaxinc/whisperkit-coreml/"
                        + LocalSpeechStack.whisperModel
                )
            },

            test("a fresh directory reports the models as missing rather than usable") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let manager = LocalModelManager(applicationSupport: root)
                let state = await manager.currentState
                expect.isFalse(state.isUsable)
                expect.isFalse(state.isBusy)
            },

            test("a receipt from a different pinned revision is not treated as current") { expect in
                let stale = LocalModelReceipt(
                    whisperVariant: "openai_whisper-small",
                    whisperFolderPath: "/tmp/nowhere",
                    whisperBytes: 1, diarizerBytes: 1, installedAt: Date(),
                    whisperPackage: "argmax-oss-swift 0.9.0",
                    diarizerPackage: "FluidAudio 0.15.6"
                )
                expect.isFalse(stale.matchesCurrentBuild)

                let current = LocalModelReceipt(
                    whisperVariant: LocalSpeechStack.whisperModel,
                    whisperFolderPath: "/tmp/nowhere",
                    whisperBytes: 1, diarizerBytes: 1, installedAt: Date(),
                    whisperPackage: LocalSpeechStack.whisperPackage,
                    diarizerPackage: LocalSpeechStack.diarizerPackage
                )
                expect.isTrue(current.matchesCurrentBuild)
            },

            test("the voice database is outside the meeting archive") { expect in
                let support = URL(fileURLWithPath: "/tmp/meettape-support")
                let database = SpeakerStoreLocation.url(applicationSupport: support)
                expect.isTrue(database.path.hasPrefix("/tmp/meettape-support"))
                expect.isFalse(
                    database.path.contains(MeetingArchiveLayout.defaultRoot.path),
                    "voice vectors must never live in a folder the user exports"
                )
            },

            test("the decoder is built with the settings the numbers came from") { expect in
                // The options the transcriber actually passes, not the constants
                // beside them: these were literals at the call site, so turning
                // VAD chunking back on left every assertion here green while the
                // measured regression shipped.
                let options = LocalModelManager.decodingOptions()
                expect.isTrue(options.skipSpecialTokens, "or <|startoftranscript|> leaks into text")
                expect.isTrue(options.wordTimestamps, "speaker attribution consumes them")
                expect.isNil(
                    options.chunkingStrategy,
                    "VAD chunking dropped 231 of 9278 words over 65 minutes"
                )
                expect.isNil(options.promptTokens)
                expect.isFalse(
                    options.usePrefillPrompt,
                    "prompting took 198 distinct word starts to 153, 43 of them zero-length"
                )
            },
        ])
    }

    static var all: [Suite] { [configurationSuite, storageSuite] }
}
