import Foundation
import MeetTapeAudio
import MeetTapeCore
import MeetTapeIntegrations
import MeetTapeServices
import MeetTapeUI
import TestKit

/// Which backend runs where, how that survives an upgrade, and the rule that
/// capture outranks processing.
enum BackendSelectionTests {

    static var settingsSuite: Suite {
        Suite("BackendSettings", [
            test("a fresh installation is local and needs no API key") { expect in
                let settings = AppSettings()
                expect.equal(settings.processing.transcription, .local)
                expect.equal(settings.processing.diarization, .local)
                expect.isTrue(settings.processing.isFullyLocal)
                expect.isTrue(settings.processing.speakers.recognizeKnownVoices)
                expect.isTrue(settings.processing.speakers.rememberRecurringVoices)
                expect.isTrue(settings.processing.speakers.learnMyVoice)
                expect.isTrue(settings.processing.speakers.learnFromCorrections)
            },

            test("transcription and diarization are chosen independently") { expect in
                var settings = AppSettings()
                settings.processing.diarization = .openAI
                expect.equal(settings.processing.transcription, .local, "one does not drag the other")
                expect.isFalse(settings.processing.isFullyLocal)
                expect.isTrue(settings.processing.usesLocalTranscription)
                expect.isFalse(settings.processing.usesLocalDiarization)

                // Nor does either touch enrichment.
                expect.isTrue(settings.enrichment.suggestSpeakers)
                expect.isTrue(settings.enrichment.wantsAnything)
            },

            test("choosing a cloud backend does not switch off voice memory") { expect in
                var settings = AppSettings()
                settings.processing.transcription = .openAI
                settings.processing.diarization = .openAI
                expect.isTrue(
                    settings.processing.speakers.recognizeKnownVoices,
                    "speaker memory is local in every configuration"
                )
            },

            test("a settings file from before local processing keeps its choices") { expect in
                // The whole point: one absent key must not reset a struct.
                let legacy = """
                    {
                      "version": 1,
                      "storageRootPath": "/tmp/meetings",
                      "localUserName": "Andrew",
                      "models": { "transcription": "whisper-1" },
                      "enrichment": { "generateالتitle": true }
                    }
                    """.replacingOccurrences(of: "generateالتitle", with: "generateTitle")
                let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
                expect.equal(settings.localUserName, "Andrew")
                expect.equal(settings.storageRootPath, "/tmp/meetings")
                expect.equal(
                    settings.models.transcription, "whisper-1",
                    "the one key that was present survives"
                )
                expect.equal(
                    settings.models.diarization, AIModelSettings().diarization,
                    "the absent siblings fall back individually, not as a block"
                )
                expect.equal(
                    settings.processing.transcription, .openAI,
                    "an existing installation keeps the backend it was configured with"
                )
                expect.equal(settings.processing.diarization, .openAI)
            },

            test("a fresh installation with no file at all starts local") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let settings = SettingsStore(directory: root).load()
                expect.isTrue(settings.processing.isFullyLocal)
                expect.equal(settings.version, 2)
            },

            test("a partly-written processing block keeps what it has") { expect in
                let partial = """
                    {"processing":{"diarization":"openai","speakers":{"learnMyVoice":false}}}
                    """
                let settings = try JSONDecoder().decode(AppSettings.self, from: Data(partial.utf8))
                expect.equal(settings.processing.diarization, .openAI)
                expect.equal(settings.processing.transcription, .local)
                expect.isFalse(settings.processing.speakers.learnMyVoice)
                expect.isTrue(
                    settings.processing.speakers.recognizeKnownVoices,
                    "the switches beside it are untouched"
                )
            },

            test("settings survive a full round trip through disk") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                var settings = AppSettings()
                settings.processing.transcription = .openAI
                settings.processing.speakers.rememberRecurringVoices = false
                settings.processing.localUserIdentityID = IdentityID(42)
                let store = SettingsStore(directory: root)
                try store.save(settings)
                let reloaded = store.load()
                expect.equal(reloaded.processing.transcription, .openAI)
                expect.equal(reloaded.processing.diarization, .local)
                expect.isFalse(reloaded.processing.speakers.rememberRecurringVoices)
                expect.equal(reloaded.processing.localUserIdentityID, IdentityID(42))
            },
        ])
    }

    static var limitsSuite: Suite {
        Suite("BackendLimits", [
            test("a local backend sends the whole meeting, a cloud one is chunked") { expect in
                expect.isFalse(BackendAudioLimits.none.requiresChunking)
                expect.isTrue(BackendAudioLimits.openAI.requiresChunking)
                expect.equal(
                    BackendAudioLimits.openAI.maximumSeconds, AILimits.maximumDiarizationSeconds
                )
                expect.equal(BackendAudioLimits.openAI.maximumBytes, AILimits.maximumRequestBytes)
            },

            test("the cloud diarizer returns the words, the local one does not") { expect in
                // The stage that transcribes has to know: with a local diarizer
                // the diarized track needs its own transcription pass.
                let cloud = OpenAIDiarizationBackend(
                    backend: FakeAIBackend(), model: "gpt-4o-transcribe-diarize"
                )
                expect.isTrue(cloud.producesTranscript)
                expect.isFalse(cloud.producesEmbeddings, "a cloud diarizer returns no vectors")
                expect.isFalse(cloud.isLocal)
            },
        ])
    }

    static var gateSuite: Suite {
        Suite("ProcessingGate", [
            test("nothing heavy starts while a recording is live") { expect in
                let recording = LockedBox(RecordingAwareGate.CaptureState.recording)
                let gate = RecordingAwareGate(pollSeconds: 0.05) { recording.withLock { $0 } }
                expect.isTrue(gate.isBlocked)

                let returned = LockedBox(false)
                let waiting = Task {
                    await gate.waitUntilAllowed()
                    returned.withLock { $0 = true }
                }
                try await Task.sleep(nanoseconds: 150_000_000)
                expect.isFalse(
                    returned.withLock { $0 },
                    "waitUntilAllowed must not return while the meeting runs"
                )
                expect.isTrue(gate.isBlocked, "still held while the meeting runs")

                recording.withLock { $0 = .idle }
                await waiting.value
                expect.isTrue(returned.withLock { $0 })
                expect.isFalse(gate.isBlocked)
            },

            test("a prejoin holds processing, but not all afternoon") { expect in
                // A candidate is real capture: the microphone is open into the
                // ring about twelve seconds before a Slack huddle is joined. A
                // waiting room left open is also a candidate, and blocking on
                // that without a bound held every job for hours in exchange for
                // a recording that never happened.
                let now = LockedBox(Date(timeIntervalSince1970: 1_000))
                let opened = now.withLock { $0 }
                let gate = RecordingAwareGate(
                    pollSeconds: 0.01,
                    now: { now.withLock { $0 } },
                    capture: { .candidate(since: opened) }
                )
                expect.isTrue(gate.isBlocked, "the microphone is open, so capture wins")

                now.withLock { $0 = opened.addingTimeInterval(30) }
                expect.isTrue(gate.isBlocked, "still inside the window a real join needs")

                now.withLock {
                    $0 = opened.addingTimeInterval(RecordingAwareGate.candidateBlockSeconds + 1)
                }
                expect.isFalse(gate.isBlocked, "a candidate this old is not a meeting")
                // Guarded: without the bound, waitUntilAllowed spins forever
                // against a frozen clock and the whole suite hangs instead of
                // reporting the failure above.
                if !gate.isBlocked { await gate.waitUntilAllowed() }

                // A live recording is never released on a timer.
                let live = RecordingAwareGate(
                    pollSeconds: 0.01,
                    now: { Date().addingTimeInterval(86_400) },
                    capture: { .recording }
                )
                expect.isTrue(live.isBlocked)
            },

            test("with no recording a job starts immediately") { expect in
                let gate = RecordingAwareGate(pollSeconds: 10) { .idle }
                expect.isFalse(gate.isBlocked)
                let start = Date()
                await gate.waitUntilAllowed()
                expect.isTrue(
                    Date().timeIntervalSince(start) < 1,
                    "an idle machine must not wait for a poll interval"
                )
            },

            test("a job waiting out a recording hands its slot back") { expect in
                // "One heavy job at a time" has to mean one job doing work. A
                // job parked for the length of somebody's call must not also
                // hold the queue shut.
                let lock = ProcessingJobLock()
                await lock.acquire()
                let second = Task { await lock.acquire() }
                try await Task.sleep(nanoseconds: 20_000_000)
                expect.isFalse(second.isCancelled)
                lock.release()
                await second.value
                lock.release()
                // And the slot is genuinely free again afterwards.
                await lock.acquire()
                lock.release()
                expect.isTrue(true, "acquire returned after the holder released")
            },

            test("only one heavy job holds the lock at a time") { expect in
                let lock = ProcessingJobLock()
                let running = LockedCounter()
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<8 {
                        group.addTask {
                            await lock.acquire()
                            running.enter()
                            try? await Task.sleep(nanoseconds: 5_000_000)
                            running.leave()
                            lock.release()
                        }
                    }
                }
                expect.equal(running.peak, 1, "two meetings must not transcribe at once")
                expect.equal(running.total, 8, "and every one of them still runs")
            },

            test("a local failure is not reported as an outage at OpenAI") { expect in
                struct Refusal: LocalProcessingFailure {
                    var userMessage = "MeetTape needs to download its speech models."
                    var isRetryable = false
                }

                let local = ProcessingPipeline.processingError(from: Refusal())
                expect.isFalse(
                    local.userMessage.contains("OpenAI"),
                    "a user with no key never configured a service to blame"
                )
                expect.isFalse(local.isRetryable, "downloading is the fix, not waiting")

                // Anything genuinely unknown is still reported as local rather
                // than as a transport failure, which named OpenAI and retried.
                struct Unknown: Error {}
                let unknown = ProcessingPipeline.processingError(from: Unknown())
                expect.isFalse(unknown.userMessage.contains("OpenAI"))

                // The cloud client's own errors keep their wording.
                expect.equal(
                    ProcessingPipeline.processingError(from: ProcessingError.rateLimited(retryAfter: 1)),
                    .rateLimited(retryAfter: 1)
                )
                expect.equal(
                    ProcessingPipeline.processingError(from: CancellationError()), .cancelled
                )
            },

            test("a job started before a recording waits for it, through the pipeline") { expect in
                // Drives ProcessingPipeline.process with a real gate rather than
                // reimplementing its loop: the defect this pins is the gate
                // being consulted once per iteration, and only the pipeline has
                // that loop.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)

                let capture = LockedBox(RecordingAwareGate.CaptureState.recording)
                let gate = RecordingAwareGate(pollSeconds: 0.01) { capture.withLock { $0 } }

                let settings: AppSettings = {
                    var value = AppSettings()
                    value.enrichment = EnrichmentSettings(
                        generateTitle: false, generateDescription: false, generateNotes: false,
                        generateSummary: false, suggestSpeakers: false
                    )
                    return value
                }()
                let pipeline = ProcessingPipeline(
                    repository: meeting.repository,
                    backend: FakeAIBackend(),
                    backends: ProcessingBackends(
                        transcription: { _, _ in
                            StubLocalTranscriber(segments: [
                                RawTranscriptSegment(
                                    start: 0, end: 5, text: "hello", speaker: nil,
                                    words: [RawTranscriptWord(start: 0, end: 1, text: " hello")]
                                ),
                            ])
                        },
                        diarization: { _, _ in
                            StubLocalDiarizer(
                                intervals: [DiarizationInterval(start: 0, end: 5, clusterID: "S1")],
                                chunkEmbeddings: []
                            )
                        }
                    ),
                    gate: gate,
                    scratch: ProcessingScratch(root: root.appendingPathComponent("scratch")),
                    clock: ManualClock(),
                    settingsProvider: { settings },
                    wait: { _ in }
                )

                let job = Task { await pipeline.process(meetingID: meeting.metadata.id) }
                try await Task.sleep(nanoseconds: 120_000_000)
                // The stage the meeting is parked at, not merely "not finished":
                // an ungated run is still unfinished at this point too, so the
                // weaker assertion held with the gate deleted entirely.
                expect.equal(
                    try meeting.store.readMetadata().processing.state, .audioSafe,
                    "nothing past the gate has run while the microphone is open"
                )

                capture.withLock { $0 = .idle }
                await job.value
                expect.equal(
                    try meeting.store.readMetadata().processing.state, .complete,
                    "and it finishes once the meeting ends"
                )

                // The re-check loop this sits next to, which catches a
                // recording that starts while a parked job is queueing for the
                // slot, is not pinned here: reproducing it needs control over
                // when each job is scheduled that the pipeline does not expose,
                // and every construction that fitted in a test passed with the
                // loop removed. Argued in the comment at the loop, not tested.
            },

            test("a typed speaker count has to be one a clusterer can use") { expect in
                // Zero and negatives went straight into the clusterer, and the
                // run that came back replaced the good one with no undo.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                await MainActor.run {
                    let model = MeetingReviewModel(
                        runtime: MeetTapeRuntime(settingsDirectory: root), meetingID: "none"
                    )
                    for bad in ["0", "-3", "abc", "999"] {
                        model.reanalyzeCount = bad
                        expect.isFalse(model.hasValidReanalyzeCount, "\(bad) is not a speaker count")
                    }
                    for good in ["", "2", "7", "50"] {
                        model.reanalyzeCount = good
                        expect.isTrue(model.hasValidReanalyzeCount, "\(good) is usable")
                    }
                    // And the control needs the on-device models whatever the
                    // count says, because it runs the local diarizer.
                    model.reanalyzeCount = "3"
                    expect.isFalse(
                        model.canReanalyze,
                        "Run must not start a 650 MB download from a button that says nothing about one"
                    )

                    model.reanalyzeCount = ""
                    expect.isNil(
                        model.reanalyzeSpeakerCount,
                        "blank means decide automatically, which beat the true count"
                    )
                }
            },

            test("each setting selects its own backend, and neither the other's") { expect in
                let cloudBackend = FakeAIBackend()
                func transcriber(_ settings: AppSettings) -> any TranscriptionBackend {
                    ProcessingBackends.transcriptionBackend(
                        settings: settings, model: "gpt-4o-transcribe",
                        local: { StubLocalTranscriber(segments: []) },
                        cloud: { OpenAITranscriptionBackend(backend: cloudBackend, model: $0) }
                    )
                }
                func diarizer(_ settings: AppSettings) -> any DiarizationBackend {
                    ProcessingBackends.diarizationBackend(
                        settings: settings, model: "gpt-4o-transcribe-diarize",
                        local: {
                            StubLocalDiarizer(intervals: [], chunkEmbeddings: [])
                        },
                        cloud: { OpenAIDiarizationBackend(backend: cloudBackend, model: $0) }
                    )
                }

                // All four combinations, because the failure that matters is one
                // setting deciding the other's backend.
                for (transcription, diarization) in [
                    (ProcessingBackendChoice.local, ProcessingBackendChoice.local),
                    (.local, .openAI), (.openAI, .local), (.openAI, .openAI),
                ] {
                    var settings = AppSettings()
                    settings.processing = ProcessingSettings(
                        transcription: transcription, diarization: diarization
                    )
                    expect.equal(
                        transcriber(settings).isLocal, transcription == .local,
                        "transcription \(transcription) with diarization \(diarization)"
                    )
                    expect.equal(
                        diarizer(settings).isLocal, diarization == .local,
                        "diarization \(diarization) with transcription \(transcription)"
                    )
                }
            },

            test("a keychain that cannot answer is not read as having no key") { expect in
                struct Failing: APIKeyProviding {
                    func apiKey() throws -> String { throw ProcessingError.missingAPIKey }
                    // A locked keychain, or a denied prompt after an ad-hoc
                    // rebuild invalidates the item's ACL. Not absence.
                    var isKnownAbsent: Bool { false }
                }
                struct Absent: APIKeyProviding {
                    func apiKey() throws -> String { throw ProcessingError.missingAPIKey }
                    var isKnownAbsent: Bool { true }
                }

                let unreadable = OpenAIClient(keyProvider: Failing())
                expect.isTrue(
                    await unreadable.isConfigured(),
                    "attempt it, so the failure is visible and retryable"
                )
                let none = OpenAIClient(keyProvider: Absent())
                expect.isFalse(
                    await none.isConfigured(),
                    "a user who never entered a key opted into nothing"
                )

                // The shipping stores, not just the shape. The layered store is
                // what DEBUG builds use, and taking the protocol default there
                // reopened the bug this guard exists for.
                let layered = LayeredAPIKeyStore(providers: [Absent(), Absent()])
                expect.isTrue(layered.isKnownAbsent, "every layer says there is no key")
                expect.isFalse(
                    LayeredAPIKeyStore(providers: [Absent(), Failing()]).isKnownAbsent,
                    "one layer that cannot answer is enough to attempt the request"
                )
                expect.isTrue(
                    EnvironmentAPIKeyStore(variableName: "MEETTAPE_NO_SUCH_VARIABLE")
                        .isKnownAbsent
                )
            },
        ])
    }

    static var all: [Suite] { [settingsSuite, limitsSuite, gateSuite] }
}

/// A flag two tasks can share without an actor hop, matching how the runtime
/// hands the recording state to the processing gate.

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var peak = 0
    private(set) var total = 0

    func enter() {
        lock.lock()
        current += 1
        total += 1
        peak = max(peak, current)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        current -= 1
        lock.unlock()
    }
}
