import Foundation
import FluidAudio
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
            test("an LS-EEND timeline keeps two speakers talking at once") { expect in
                // The offline clusterer assigns one speaker per moment, so a
                // simultaneous second voice cannot exist in its output. The
                // whole point of the EEND backend is that it can, and the
                // conversion must not flatten it back out.
                let output = LSEendDiarizationBackend.output(
                    segments: [
                        (speaker: 0, start: 0, end: 10, activity: 0.9),
                        (speaker: 1, start: 4, end: 8, activity: 0.7),
                        (speaker: 0, start: 12, end: 15, activity: 0.5),
                    ],
                    configuration: ["backend": "test"]
                )
                expect.equal(output.intervals.count, 3)
                let sorted = output.intervals.sorted { $0.start < $1.start }
                expect.equal(sorted[0].clusterID, sorted[2].clusterID, "one voice keeps one key")
                expect.isTrue(
                    sorted[1].clusterID != sorted[0].clusterID
                        && sorted[1].start < sorted[0].end,
                    "the second voice overlaps the first and survives as its own interval"
                )
                let byID = Dictionary(uniqueKeysWithValues: output.clusters.map { ($0.id, $0) })
                expect.close(
                    byID[sorted[0].clusterID]?.speechSeconds ?? 0, 13, tolerance: 0.001,
                    "a cluster's speech is the sum of its own intervals"
                )
                expect.close(byID[sorted[1].clusterID]?.speechSeconds ?? 0, 4, tolerance: 0.001)
                expect.equal(output.configuration["backend"], "test")
            },

            test("Canary is a bench candidate, not an offered model") { expect in
                // A text-only engine: its units are its own weights plus the
                // aligner that supplies the timings it does not, the same
                // shape as Cohere. It stays out of `offered` until the
                // comparative run earns it a place in the settings UI.
                var settings = AppSettings()
                settings.processing.transcription = .local
                settings.processing.localTranscriptionModel = .canary
                // The diarizer and the voice detector ride along: every
                // configuration requires both.
                expect.equal(
                    LocalModelUnit.required(for: settings),
                    [.canary, .ctcAligner, .diarizer, .voiceActivity]
                )
                expect.isTrue(
                    !LocalTranscriptionModel.offered.contains(.canary),
                    "the settings UI does not offer what the bench has not proven"
                )
                expect.equal(
                    LocalTranscriptionModel.canary.backendIdentifier,
                    LocalSpeechStack.canaryBackendIdentifier
                )
                expect.close(
                    LocalCanaryTuning.chunkSeconds, 15, tolerance: 0.0001,
                    "one fixed model window per chunk, so the library's own stitching never runs"
                )
            },

            test("Apple speech needs no downloaded units and is not offered") { expect in
                // The models are system assets the OS installs and owns, so
                // the only unit the configuration needs is the diarizer every
                // configuration needs. It stays out of `offered` with the
                // other bench candidates.
                var settings = AppSettings()
                settings.processing.transcription = .local
                settings.processing.localTranscriptionModel = .apple
                expect.equal(LocalModelUnit.required(for: settings), [.diarizer, .voiceActivity])
                expect.isTrue(!LocalTranscriptionModel.offered.contains(.apple))
                expect.equal(
                    LocalTranscriptionModel.apple.backendIdentifier,
                    LocalSpeechStack.appleBackendIdentifier
                )
            },

            test("attributed runs become words that keep the aligner's conventions") { expect in
                // The assembler concatenates word texts verbatim, so every
                // word carries a leading space; a run's words split its span
                // evenly, and a run the recognizer left untimed rides the
                // previous edge rather than inventing a time.
                let words = AppleSpeechTranscriptionBackend.words(from: [
                    (text: "Hello there ", start: 0, end: 2),
                    (text: "world", start: 2, end: 3),
                ])
                expect.equal(words.map(\.text), [" Hello", " there", " world"])
                expect.close(words[0].start, 0, tolerance: 0.0001)
                expect.close(words[0].end, 1, tolerance: 0.0001)
                expect.close(words[1].start, 1, tolerance: 0.0001)
                expect.close(words[2].end, 3, tolerance: 0.0001)

                let tail = AppleSpeechTranscriptionBackend.words(from: [
                    (text: "one", start: 0, end: 1),
                    (text: "two", start: nil, end: nil),
                ])
                expect.close(tail[1].start, 1, tolerance: 0.0001)
                expect.close(tail[1].end, 1, tolerance: 0.0001)
            },

            test("a meeting where nobody spoke is empty, not failed") { expect in
                // FluidAudio raises noSpeechDetected rather than returning zero
                // turns. Passed on as an error it failed the meeting, so a
                // recording that captured exactly what happened was filed as
                // needing attention with no transcript, markdown or mixdown.
                let empty = LocalModelManager.silentMeeting(
                    OfflineDiarizationError.noSpeechDetected, speakerCount: nil
                )
                let output = try expect.unwrap(empty)
                expect.isTrue(output.intervals.isEmpty)
                expect.isTrue(output.clusters.isEmpty)
                expect.isTrue(
                    output.configuration["warmStartFa"] != nil,
                    "and still records how it was diarized"
                )

                // Everything else is still a failure.
                expect.isTrue(
                    LocalModelManager.silentMeeting(
                        OfflineDiarizationError.modelNotLoaded("segmentation"), speakerCount: nil
                    ) == nil
                )
            },

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
                            locations.diarizerDirectory, locations.parakeetDirectory,
                            locations.cohereDirectory, locations.alignerDirectory,
                            locations.inventory] {
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

            test("a cloud-only configuration still refuses when no models are installed") { expect in
                // The wiring, not the closure a test hands in: `required(for:)`
                // decides what `ensureInstalled` checks, and when it answered
                // with an empty set for a cloud/cloud machine, ensureInstalled
                // reported success with nothing on disk. Voice memory then
                // reached the embedding extractor and threw from inside the
                // speaker stage, which is not retryable, so the meeting never
                // reached the stage that writes the markdown and the mixdown.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                var settings = AppSettings()
                settings.processing.transcription = .openAI
                settings.processing.diarization = .openAI
                let manager = LocalModelManager(
                    applicationSupport: root, required: LocalModelUnit.required(for: settings)
                )
                await expect.throwsError(
                    { try await manager.ensureInstalled() },
                    "a machine with no models must say so, whatever the backends are"
                )
                expect.isFalse(await manager.isInstalled)
            },

            test("a unit nobody asked about does not read as a machine with no models") { expect in
                // `ensureInstalled` used to judge the whole required set, so
                // every unit added to that set turned voice memory off on
                // machines already installed: the new unit has no receipt, the
                // check throws, and `localModelsAvailable` reads that as "no
                // models" for work the new unit has nothing to do with. Voice
                // memory embeds with the diarizer and asks for it by name.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let locations = LocalModelLocations(applicationSupport: root)
                try FileManager.default.createDirectory(
                    at: locations.diarizerDirectory, withIntermediateDirectories: true
                )
                try LocalModelReceiptStore(locations: locations).write([
                    .diarizer: LocalUnitReceipt(
                        revision: LocalSpeechStack.revision(for: .diarizer),
                        bytes: 1, installedAt: Date()
                    ),
                ])
                let manager = LocalModelManager(
                    applicationSupport: root, required: [.diarizer, .voiceActivity]
                )

                try await manager.ensureInstalled(units: [.diarizer])

                await expect.throwsError(
                    { try await manager.ensureInstalled(units: [.voiceActivity]) },
                    "the unit that really is missing still says so"
                )
                await expect.throwsError(
                    { try await manager.ensureInstalled() },
                    "and so does the set as a whole, which is what the download button reads"
                )
            },

            test("a receipt from a different pinned revision is not treated as current") { expect in
                let stale = LocalUnitReceipt(
                    revision: "openai_whisper-small @ argmax-oss-swift 0.9.0",
                    bytes: 1, installedAt: Date()
                )
                expect.isFalse(stale.matchesCurrentBuild(for: .whisper))

                for unit in LocalModelUnit.allCases {
                    let current = LocalUnitReceipt(
                        revision: LocalSpeechStack.revision(for: unit),
                        bytes: 1, installedAt: Date()
                    )
                    expect.isTrue(current.matchesCurrentBuild(for: unit))
                }
            },

            test("a legacy single receipt reads as a whisper and diarizer install") { expect in
                // The old installed.json described whisper plus the diarizer;
                // an upgrade must keep reporting them as installed rather than
                // offering the same 650 MB again.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let locations = LocalModelLocations(applicationSupport: root)
                try FileManager.default.createDirectory(
                    at: locations.root, withIntermediateDirectories: true
                )
                let legacy = """
                    {"whisperVariant": "\(LocalSpeechStack.whisperModel)",
                     "whisperFolderPath": "/tmp/nowhere",
                     "whisperBytes": 5, "diarizerBytes": 7,
                     "installedAt": "2026-01-01T00:00:00Z",
                     "whisperPackage": "\(LocalSpeechStack.whisperPackage)",
                     "diarizerPackage": "\(LocalSpeechStack.diarizerPackage)"}
                    """
                try Data(legacy.utf8).write(to: locations.legacyReceipt)
                let receipts = LocalModelReceiptStore(locations: locations).read()
                expect.equal(receipts[.whisper]?.bytes, 5)
                expect.equal(receipts[.diarizer]?.bytes, 7)
                expect.equal(receipts[.whisper]?.matchesCurrentBuild(for: .whisper), true)
                expect.equal(receipts[.whisper]?.detail, "/tmp/nowhere")
            },

            test("the new engines and the aligner are pinned like the rest of the stack") { expect in
                expect.equal(
                    LocalSpeechStack.parakeetBackendIdentifier, "fluidaudio-parakeet-tdt-v3"
                )
                expect.equal(
                    LocalSpeechStack.cohereBackendIdentifier,
                    "fluidaudio-cohere-transcribe-03-2026-q8"
                )
                expect.equal(LocalSpeechStack.alignerIdentifier, "fluidaudio-parakeet-ctc-0.6b")
                expect.equal(LocalSpeechStack.revision(for: .cohere), "cohere-transcribe-03-2026-q8 @ FluidAudio 0.15.6")
                expect.equal(LocalSpeechStack.revision(for: .parakeet), "parakeet-tdt-0.6b-v3-int8 @ FluidAudio 0.15.6")
                expect.equal(LocalSpeechStack.revision(for: .ctcAligner), "parakeet-ctc-0.6b @ FluidAudio 0.15.6")

                // Alignment tuning: the aligner's segments feed duplicate
                // detection and attribution, and the chunk length bounds the
                // Viterbi trellis.
                expect.equal(LocalAlignmentTuning.segmentPauseSeconds, 1.0)
                expect.equal(LocalAlignmentTuning.segmentMaximumSeconds, 30)
                expect.equal(LocalAlignmentTuning.chunkSeconds, 300)
                // One model window per Cohere chunk: the library's own window
                // stitching dropped a five-second span on the fixture.
                expect.equal(LocalCohereTuning.chunkSeconds, 35)
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
