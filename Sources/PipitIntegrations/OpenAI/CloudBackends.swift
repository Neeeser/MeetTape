import Foundation
import PipitCore

extension BackendAudioLimits {
    /// Both cloud endpoints reject audio past 1400 seconds and bodies past
    /// 25 MiB, measured against the live API rather than read from docs.
    public static let openAI = BackendAudioLimits(
        maximumSeconds: AILimits.maximumDiarizationSeconds,
        maximumBytes: AILimits.maximumRequestBytes
    )
}

/// OpenAI transcription behind the same protocol local Whisper implements.
public struct OpenAITranscriptionBackend: TranscriptionBackend {
    private let backend: any AIBackend
    private let model: String
    private let keywords: [String]

    public init(backend: any AIBackend, model: String, keywords: [String] = []) {
        self.backend = backend
        self.model = model
        self.keywords = keywords
    }

    public var identifier: String { model }
    public var isLocal: Bool { false }
    public var limits: BackendAudioLimits { .openAI }
    public var timing: TranscriptTiming { AIModelSettings.transcriptionTiming(for: model) }

    public func transcribe(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionOutput {
        let response = try await backend.transcribe(
            TranscriptionRequest(audio: audio, model: model, keywords: keywords)
        )
        progress(1)
        return TranscriptionOutput(
            segments: response.segments,
            text: response.text,
            durationSeconds: response.durationSeconds,
            rawBody: response.rawBody
        )
    }
}

/// OpenAI diarization behind the same protocol the offline diarizer implements.
///
/// It returns labels and no vectors, so speaker memory extracts the embeddings
/// locally over the intervals it reports. Choosing the cloud diarizer costs the
/// vectors, not the voice memory.
public struct OpenAIDiarizationBackend: DiarizationBackend {
    private let backend: any AIBackend
    private let model: String

    public init(backend: any AIBackend, model: String) {
        self.backend = backend
        self.model = model
    }

    public var identifier: String { model }
    public var isLocal: Bool { false }
    public var limits: BackendAudioLimits { .openAI }
    public var producesEmbeddings: Bool { false }
    public var producesTranscript: Bool { true }

    public func diarize(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DiarizationOutput {
        let response = try await backend.diarize(DiarizationRequest(audio: audio, model: model))
        progress(1)

        var intervals: [DiarizationInterval] = []
        var speechByCluster: [String: Double] = [:]
        for segment in response.segments {
            guard let speaker = segment.speaker else { continue }
            intervals.append(DiarizationInterval(
                start: segment.start, end: segment.end, clusterID: speaker
            ))
            speechByCluster[speaker, default: 0] += max(0, segment.end - segment.start)
        }
        let clusters = speechByCluster.keys.sorted().map {
            DiarizationCluster(id: $0, speechSeconds: speechByCluster[$0] ?? 0)
        }
        return DiarizationOutput(
            intervals: intervals,
            clusters: clusters,
            segments: response.segments,
            configuration: ["backend": model],
            rawBody: response.rawBody
        )
    }
}
