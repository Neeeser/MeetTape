import Foundation
import PipitCore
import PipitIntegrations
import PipitLocalAI
import PipitServices
import PipitSpeakers

/// Re-clusters one meeting folder on this Mac and reports what changed.
///
/// The developer tool for the other half of what `gate` measures. `gate` reads a
/// recording and prints what the speech gate makes of it; this runs the stage
/// that decides who spoke and writes the result back, so a change to track
/// selection or to sensor attribution can be checked against a real meeting
/// rather than against a fixture.
///
/// Words are never re-transcribed. The previous diarization stays on disk marked
/// inactive, so a run can be looked at and undone.
enum ReanalyzeCommand {
    /// Nothing here reaches the cloud. Re-analysis re-clusters and re-assembles,
    /// and the stages that would call out are not on that path, so the tool
    /// refuses to be configured rather than carrying a key it should not use.
    private struct OfflineBackend: AIBackend {
        func isConfigured() async -> Bool { false }
        func verifyCredentials(model: String) async throws {
            throw ProcessingError.cancelled
        }
        func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResponse {
            throw ProcessingError.cancelled
        }
        func diarize(_ request: DiarizationRequest) async throws -> TranscriptionResponse {
            throw ProcessingError.cancelled
        }
        func resolveSpeakers(
            _ request: SpeakerResolutionRequest, model: String
        ) async throws -> [SpeakerSuggestion] {
            throw ProcessingError.cancelled
        }
        func enrich(
            _ request: EnrichmentRequest, model: String
        ) async throws -> MeetingEnrichment {
            throw ProcessingError.cancelled
        }
    }

    static func run(
        meeting: URL, applicationSupport: URL, speakerCount: Int?
    ) async -> Int32 {
        let store = MeetingStore(layout: MeetingLayout(root: meeting))
        let metadata: MeetingMetadata
        do {
            metadata = try store.readMetadata()
        } catch {
            FileHandle.standardError.write(Data("cannot read \(meeting.path): \(error)\n".utf8))
            return 1
        }

        // The archive root, not the folder: a meeting inside a user folder is
        // two levels down, and the repository is what resolves either.
        let root = repositoryRoot(for: meeting)
        let repository = MeetingRepository(root: root)
        guard repository.findMeeting(id: metadata.id, includingMerged: true) != nil else {
            FileHandle.standardError.write(
                Data("\(metadata.id) is not in the archive at \(root.path)\n".utf8)
            )
            return 1
        }

        let manager = LocalModelManager(applicationSupport: applicationSupport)
        do {
            _ = try await manager.install(units: [.diarizer, .voiceActivity])
        } catch {
            FileHandle.standardError.write(Data("models unavailable: \(error)\n".utf8))
            return 1
        }

        let settings: AppSettings = {
            var value = AppSettings()
            value.enrichment = EnrichmentSettings(
                generateTitle: false, generateDescription: false, generateNotes: false,
                generateSummary: false, suggestSpeakers: false
            )
            return value
        }()
        let pipeline = ProcessingPipeline(
            repository: repository,
            backend: OfflineBackend(),
            backends: ProcessingBackends(
                // Re-analysis never transcribes, so this is here to satisfy the
                // shape and is not reachable from `reanalyzeSpeakers`.
                transcription: { _, _ in ParakeetTranscriptionBackend(models: manager) },
                diarization: { _, _ in FluidAudioDiarizationBackend(models: manager) },
                embeddings: FluidAudioEmbeddingExtractor(models: manager),
                voiceActivity: FluidAudioVoiceActivityBackend(models: manager),
                prepareVoiceActivity: {
                    _ = try await manager.install(units: [.voiceActivity])
                },
                prepareDiarizer: { _ = try await manager.install(units: [.diarizer]) },
                reanalyzeDiarization: { meetingID, url, count in
                    try await manager.reanalyze(
                        meetingID: meetingID, audio: url, speakerCount: count
                    )
                }
            ),
            settingsProvider: { settings }
        )

        let before = summary(store: store)
        let started = Date()
        do {
            try await pipeline.reanalyzeSpeakers(
                meetingID: metadata.id, speakerCount: speakerCount
            )
        } catch {
            FileHandle.standardError.write(Data("re-analysis failed: \(error)\n".utf8))
            return 1
        }
        let elapsed = Date().timeIntervalSince(started)
        let after = summary(store: store)

        print("meeting         \(metadata.id)")
        print("source          \(metadata.source.rawValue)")
        print("processing      \(String(format: "%.1f", elapsed))s")
        print("")
        print("                          before      after")
        print("diarized track  \(pad(before.track, 16))\(before.track == after.track ? "" : after.track)")
        print("clusters        \(pad("\(before.clusters)", 16))\(after.clusters)")
        print("utterances      \(pad("\(before.utterances)", 16))\(after.utterances)")
        print("under \"local\"   \(pad("\(before.local)", 16))\(after.local)")
        print("distinct keys   \(pad("\(before.keys)", 16))\(after.keys)")
        print("named speakers  \(pad("\(before.named)", 16))\(after.named)")
        print("")
        for name in after.names { print("  \(name)") }
        return 0
    }

    private struct Summary {
        var track = "none"
        var clusters = 0
        var utterances = 0
        var local = 0
        var keys = 0
        var named = 0
        var names: [String] = []
    }

    private static func summary(store: MeetingStore) -> Summary {
        var result = Summary()
        // The track that actually holds a clustering. Both tracks can carry an
        // active run at once, and the empty one is exactly what this tool
        // exists to make visible, so an empty run is not the answer.
        if let diarization = try? store.readRawDiarization() {
            for track in [CaptureTrack.mic, .remote] {
                guard let run = diarization.activeRun(track: track), !run.intervals.isEmpty else {
                    continue
                }
                result.track = track.rawValue
                result.clusters = run.clusters.count
            }
        }
        if let transcript = try? store.readCanonicalTranscript() {
            result.utterances = transcript.utterances.count
            result.local = transcript.utterances.filter { $0.speakerKey == SpeakerLabel.localUser }.count
            result.keys = Set(transcript.utterances.map(\.speakerKey)).count
        }
        if let speakers = try? store.readSpeakerMap() {
            let named = speakers.entries.values
                .map(\.displayName)
                .filter { !$0.isEmpty }
            result.named = named.count
            result.names = named.sorted()
        }
        return result
    }

    private static func pad(_ value: String, _ width: Int) -> String {
        value.count >= width ? value + " " : value + String(repeating: " ", count: width - value.count)
    }

    /// Walks up out of any user folders to the archive the repository owns.
    ///
    /// A meeting lives at `<root>/<id>` or at `<root>/Folders/<name>/<id>`, and
    /// the tool is pointed at the meeting.
    private static func repositoryRoot(for meeting: URL) -> URL {
        let parent = meeting.deletingLastPathComponent()
        if parent.deletingLastPathComponent().lastPathComponent == "Folders" {
            return parent.deletingLastPathComponent().deletingLastPathComponent()
        }
        return parent
    }
}
