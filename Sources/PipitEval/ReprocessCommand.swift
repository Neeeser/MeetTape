import Foundation
import PipitCore
import PipitIntegrations
import PipitLocalAI
import PipitServices
import PipitSpeakers

/// Runs the processing pipeline again over one meeting folder, from the audio
/// up, with the local engines and no cloud calls.
///
/// The developer tool for the third half of what `echo` measures: `echo` says
/// what the canceller would do to a recording, this runs the whole pipeline
/// over it, cleaning included, and writes the result back. Every derived file
/// is backed up and then removed first. The recording and the manifest are
/// never touched.
///
/// Voice memory is read, never written. Known voices are recognised so the
/// transcript comes back with names, and nothing is enrolled, remembered or
/// learned from a run of this tool.
enum ReprocessCommand {
    static func run(
        meeting: URL, applicationSupport: URL, backups: URL, recognize: Bool
    ) async -> Int32 {
        let store = MeetingStore(layout: MeetingLayout(root: meeting))
        let original: MeetingMetadata
        do {
            original = try store.readMetadata()
        } catch {
            note("cannot read \(meeting.path): \(error)")
            return 1
        }
        let root = repositoryRoot(for: meeting)
        let repository = MeetingRepository(root: root)
        guard repository.findMeeting(id: original.id, includingMerged: true) != nil else {
            note("\(original.id) is not in the archive at \(root.path)")
            return 1
        }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = backups.appendingPathComponent("\(original.id)/\(stamp)", isDirectory: true)
        do {
            try Reprocessing.backUp(store: store, to: backup)
            try Reprocessing.reset(store: store)
        } catch {
            note("cannot reset \(meeting.path): \(error)")
            return 1
        }

        let before = summary(store: store, backup: backup)
        let manager = LocalModelManager(applicationSupport: applicationSupport)
        var configuration = SettingsStore(directory: applicationSupport).load()
        configuration.enrichment = EnrichmentSettings(
            generateTitle: false, generateDescription: false, generateNotes: false,
            generateSummary: false, suggestSpeakers: false
        )
        configuration.processing.transcription = .local
        configuration.processing.diarization = .local
        configuration.processing.speakers = SpeakerRecognitionSettings(
            recognizeKnownVoices: recognize, rememberRecurringVoices: false,
            learnMyVoice: false, learnFromCorrections: false
        )

        var recognition: SpeakerRecognitionService?
        if recognize {
            do {
                let speakers = try SpeakerStore(
                    url: SpeakerStore.defaultURL(applicationSupport: applicationSupport)
                )
                recognition = SpeakerRecognitionService(store: speakers)
            } catch {
                note("voice memory unavailable: \(error)")
                return 1
            }
        }
        let cloud = OpenAIClient(keyProvider: EnvironmentAPIKeyStore())
        let settings = configuration
        let backends = ProcessingBackends(
            transcription: { settings, model in
                ProcessingBackends.transcriptionBackend(
                    settings: settings, model: model,
                    local: { choice in
                        switch choice {
                        case .cohere: CohereTranscriptionBackend(models: manager)
                        case .canary: CanaryTranscriptionBackend(models: manager)
                        case .apple: AppleSpeechTranscriptionBackend()
                        case .parakeet: ParakeetTranscriptionBackend(models: manager)
                        case .whisper: WhisperTranscriptionBackend(models: manager)
                        }
                    },
                    cloud: { OpenAITranscriptionBackend(backend: cloud, model: $0) }
                )
            },
            diarization: { settings, model in
                ProcessingBackends.diarizationBackend(
                    settings: settings, model: model,
                    local: { FluidAudioDiarizationBackend(models: manager) },
                    cloud: { OpenAIDiarizationBackend(backend: cloud, model: $0) }
                )
            },
            embeddings: FluidAudioEmbeddingExtractor(models: manager),
            speakers: recognition,
            prepareLocalModels: {
                _ = try await manager.install(units: LocalModelUnit.required(for: settings))
            },
            requireLocalModels: { try await manager.ensureInstalled(units: [.diarizer]) },
            voiceActivity: FluidAudioVoiceActivityBackend(models: manager),
            prepareVoiceActivity: { _ = try await manager.install(units: [.voiceActivity]) },
            aligner: CtcTranscriptAligner(models: manager),
            prepareAligner: { _ = try await manager.install(units: [.ctcAligner]) },
            prepareDiarizer: { _ = try await manager.install(units: [.diarizer]) }
        )
        let pipeline = ProcessingPipeline(
            repository: repository, backend: cloud, backends: backends,
            settingsProvider: { settings }
        )

        let started = Date()
        await pipeline.process(meetingID: original.id)
        let elapsed = Date().timeIntervalSince(started)
        let after = summary(store: store, backup: nil)

        print("meeting         \(original.id)")
        print("source          \(original.source.rawValue)")
        print("backup          \(backup.path)")
        print("processing      \(String(format: "%.1f", elapsed))s, ended \(after.state)")
        if let failure = after.failure { print("failure         \(failure)") }
        print("cleaning        \(after.cleaning)")
        print("")
        print("                      before      after")
        print("mic words       \(pad("\(before.micWords)", 12))\(after.micWords)")
        print("far-end words   \(pad("\(before.remoteWords)", 12))\(after.remoteWords)")
        print("utterances      \(pad("\(before.utterances)", 12))\(after.utterances)")
        print("named speakers  \(pad("\(before.named)", 12))\(after.named)")
        print("")
        for name in after.names { print("  \(name)") }
        return after.state == "complete" ? 0 : 1
    }

    private struct Summary {
        var state = "unknown"
        var failure: String?
        var cleaning = "none"
        var micWords = 0
        var remoteWords = 0
        var utterances = 0
        var named = 0
        var names: [String] = []
    }

    /// Counts from the meeting folder, or from the backup taken before the
    /// reset for the "before" column.
    private static func summary(store: MeetingStore, backup: URL?) -> Summary {
        var result = Summary()
        let layout = backup.map { MeetingLayout(root: $0) } ?? store.layout
        let source = MeetingStore(layout: layout)
        if let metadata = try? source.readMetadata() {
            result.state = metadata.processing.state.rawValue
            result.failure = metadata.processing.lastFailure?.message
            result.cleaning = metadata.cleaningOutcome?.rawValue ?? "none"
            if let cleaned = metadata.cleanedMic {
                result.cleaning += String(
                    format: " (%.1f dB over %d windows)",
                    cleaned.echoRemovedMedianDB, cleaned.farEndActiveWindows
                )
            }
        }
        if let transcript = try? source.readCanonicalTranscript() {
            result.utterances = transcript.utterances.count
            for utterance in transcript.utterances {
                let words = utterance.text.split(separator: " ").count
                if utterance.track == .mic { result.micWords += words } else { result.remoteWords += words }
            }
        }
        if let speakers = try? source.readSpeakerMap() {
            let named = Set(speakers.entries.values.map(\.displayName).filter { !$0.isEmpty })
            result.named = named.count
            result.names = named.sorted()
        }
        return result
    }

    private static func pad(_ value: String, _ width: Int) -> String {
        value.count >= width ? value + " " : value + String(repeating: " ", count: width - value.count)
    }

    /// `<root>/<year>/<month>/<meeting>` or `<root>/Folders/<name>/<meeting>`.
    private static func repositoryRoot(for meeting: URL) -> URL {
        let parent = meeting.deletingLastPathComponent()
        if parent.deletingLastPathComponent().lastPathComponent == "Folders" {
            return parent.deletingLastPathComponent().deletingLastPathComponent()
        }
        return parent.deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
