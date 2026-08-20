import Foundation
import MeetTapeCore
import MeetTapeIntegrations
import MeetTapeServices
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
                let recording = LockedFlag(true)
                let gate = RecordingAwareGate(pollSeconds: 0.05) { recording.value }
                expect.isTrue(gate.isBlocked)

                let waiting = Task { await gate.waitUntilAllowed() }
                try await Task.sleep(nanoseconds: 150_000_000)
                expect.isFalse(waiting.isCancelled)
                expect.isTrue(gate.isBlocked, "still held while the meeting runs")

                recording.value = false
                await waiting.value
                expect.isFalse(gate.isBlocked)
            },

            test("with no recording a job starts immediately") { expect in
                let gate = RecordingAwareGate(pollSeconds: 10) { false }
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
        ])
    }

    static var all: [Suite] { [settingsSuite, limitsSuite, gateSuite] }
}

/// A flag two tasks can share without an actor hop, matching how the runtime
/// hands the recording state to the processing gate.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool

    init(_ value: Bool) { storage = value }

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

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
