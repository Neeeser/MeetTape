import Foundation

/// Limits a backend imposes on one request.
///
/// A local backend has none: WhisperKit and the offline diarizer both take a
/// whole meeting. The cloud endpoints reject audio past 1400 seconds and bodies
/// past 25 MiB, which is what the chunk planner exists for.
public struct BackendAudioLimits: Sendable, Equatable {
    public var maximumSeconds: Double?
    public var maximumBytes: Int?

    public init(maximumSeconds: Double? = nil, maximumBytes: Int? = nil) {
        self.maximumSeconds = maximumSeconds
        self.maximumBytes = maximumBytes
    }

    public static let none = BackendAudioLimits()

    public var requiresChunking: Bool { maximumSeconds != nil || maximumBytes != nil }
}

/// What a transcription backend returns for one request.
public struct TranscriptionOutput: Sendable, Equatable {
    public var segments: [RawTranscriptSegment]
    public var text: String
    public var language: String?
    public var durationSeconds: Double?
    /// The response body exactly as received. Cloud backends store it as the
    /// record of what the model said; a local backend has no body and leaves it
    /// nil.
    public var rawBody: Data?

    public init(
        segments: [RawTranscriptSegment], text: String, language: String? = nil,
        durationSeconds: Double? = nil, rawBody: Data? = nil
    ) {
        self.segments = segments
        self.text = text
        self.language = language
        self.durationSeconds = durationSeconds
        self.rawBody = rawBody
    }

    public var wordCount: Int { segments.reduce(0) { $0 + ($1.words?.count ?? 0) } }
    public var hasWordTimings: Bool { segments.contains { !($0.words?.isEmpty ?? true) } }
}

/// One embedding covering a short span of one cluster.
///
/// The diarizer emits these roughly every nine seconds. They are what a profile
/// is built from: a cluster's centroid over its own chunks scores far better
/// than any single chunk, and correcting individual transcript lines needs
/// vectors at a finer grain than the whole cluster.
public struct DiarizationChunkEmbedding: Sendable, Equatable, Codable {
    public var clusterID: String
    public var start: Double
    public var end: Double
    public var vector: [Float]

    public init(clusterID: String, start: Double, end: Double, vector: [Float]) {
        self.clusterID = clusterID
        self.start = start
        self.end = end
        self.vector = vector
    }

    public var duration: Double { max(0, end - start) }
}

/// What a diarization backend returns for one request. Times are relative to the
/// audio that was submitted; the pipeline puts them on the meeting timeline.
public struct DiarizationOutput: Sendable, Equatable {
    public var intervals: [DiarizationInterval]
    public var clusters: [DiarizationCluster]
    /// Empty when the backend returns labels without vectors, which is the case
    /// for every cloud diarizer. Speaker memory then extracts them locally.
    public var chunkEmbeddings: [DiarizationChunkEmbedding]
    public var configuration: [String: String]
    /// The body as received, for a cloud backend.
    public var rawBody: Data?

    public init(
        intervals: [DiarizationInterval], clusters: [DiarizationCluster],
        chunkEmbeddings: [DiarizationChunkEmbedding] = [], configuration: [String: String] = [:],
        rawBody: Data? = nil
    ) {
        self.intervals = intervals
        self.clusters = clusters
        self.chunkEmbeddings = chunkEmbeddings
        self.configuration = configuration
        self.rawBody = rawBody
    }

    public var speakerCount: Int { Set(intervals.map(\.clusterID)).count }
}

/// Turns audio into words with timings.
///
/// Local Whisper and the OpenAI endpoints implement this identically, so which
/// one runs is a setting rather than a code path.
public protocol TranscriptionBackend: Sendable {
    /// Recorded on every chunk, so a transcript says what produced it.
    var identifier: String { get }
    var isLocal: Bool { get }
    var limits: BackendAudioLimits { get }
    var producesWordTimestamps: Bool { get }

    func transcribe(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionOutput
}

/// Turns audio into who spoke when.
public protocol DiarizationBackend: Sendable {
    var identifier: String { get }
    var isLocal: Bool { get }
    var limits: BackendAudioLimits { get }
    /// Whether the backend also returns speaker vectors. When it does not, the
    /// pipeline runs local embedding extraction over the returned intervals so
    /// voice memory keeps working whatever produced the labels.
    var producesEmbeddings: Bool { get }

    func diarize(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DiarizationOutput
}

/// Extracts speaker vectors for intervals somebody else decided.
///
/// This is the seam that keeps voice memory local when diarization is not:
/// choosing the cloud diarizer costs the vectors, and this puts them back
/// without a second diarization.
public protocol SpeakerEmbeddingExtractor: Sendable {
    var model: EmbeddingModelIdentifier { get }

    func embed(
        audio: URL, intervals: [DiarizationInterval]
    ) async throws -> [DiarizationChunkEmbedding]
}
