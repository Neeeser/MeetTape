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
/// Deliberately not Codable. The convention in this archive is that a Codable
/// struct becomes a file in the meeting folder, and a meeting folder is what a
/// user copies, syncs and shares. Nothing encoded one; withholding the
/// conformance means nothing can without saying so.
public struct DiarizationChunkEmbedding: Sendable, Equatable {
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

/// One track embedded as though it held a single speaker.
///
/// Used for the microphone track of a remote call, where the local user's
/// identity is true by construction. The spans are the dominant voice's own
/// intervals, relative to the audio that was submitted, and they are what makes
/// the resulting vector retractable later.
public struct SingleSpeakerSample: Sendable, Equatable {
    public var vector: [Float]
    public var speechSeconds: Double
    public var quality: Double
    public var spans: [AudioSpan]

    public init(vector: [Float], speechSeconds: Double, quality: Double, spans: [AudioSpan]) {
        self.vector = vector
        self.speechSeconds = speechSeconds
        self.quality = quality
        self.spans = AudioSpan.union(spans)
    }
}

/// What a diarization backend returns for one request. Times are relative to the
/// audio that was submitted; the pipeline puts them on the meeting timeline.
public struct DiarizationOutput: Sendable, Equatable {
    public var intervals: [DiarizationInterval]
    public var clusters: [DiarizationCluster]
    /// The words, for a backend that transcribes and diarizes in one request.
    /// Empty for a diarizer that only decides who spoke when.
    public var segments: [RawTranscriptSegment]
    /// Empty when the backend returns labels without vectors, which is the case
    /// for every cloud diarizer. Speaker memory then extracts them locally.
    public var chunkEmbeddings: [DiarizationChunkEmbedding]
    public var configuration: [String: String]
    /// The body as received, for a cloud backend.
    public var rawBody: Data?

    public init(
        intervals: [DiarizationInterval], clusters: [DiarizationCluster],
        segments: [RawTranscriptSegment] = [],
        chunkEmbeddings: [DiarizationChunkEmbedding] = [], configuration: [String: String] = [:],
        rawBody: Data? = nil
    ) {
        self.intervals = intervals
        self.clusters = clusters
        self.segments = segments
        self.chunkEmbeddings = chunkEmbeddings
        self.configuration = configuration
        self.rawBody = rawBody
    }

    public var speakerCount: Int { Set(intervals.map(\.clusterID)).count }
}

/// What timing structure a transcription backend's output carries.
///
/// `.text` is a real capability, not a degenerate `.segments`: the models with
/// the best words return no timings at all, and their output goes through the
/// local alignment stage before it can feed the timeline. Keeping the case
/// explicit means a backend cannot drift into that path by accident.
public enum TranscriptTiming: String, Sendable, Equatable, Codable {
    /// Word timings inside each segment.
    case words
    /// Segment start and end only.
    case segments
    /// Words with no timings; alignment supplies them afterwards.
    case text
}

/// Turns audio into words.
///
/// Local and cloud engines implement this identically, so which one runs is a
/// setting rather than a code path. What timing the words arrive with is the
/// backend's declared capability; the pipeline aligns what needs aligning.
public protocol TranscriptionBackend: Sendable {
    /// Recorded on every chunk, so a transcript says what produced it.
    var identifier: String { get }
    var isLocal: Bool { get }
    var limits: BackendAudioLimits { get }
    var timing: TranscriptTiming { get }

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
    /// Whether the backend returns the words as well as the speakers. The cloud
    /// diarizer does both in one request; the local one decides speakers only,
    /// so its track has to be transcribed separately.
    var producesTranscript: Bool { get }

    func diarize(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DiarizationOutput
}

/// Recovers timings for a transcript whose backend returned none.
///
/// The words are the backend's; only the timings are synthesised, by forcing
/// the known text against the audio. What comes back is segments in the same
/// shape every timed backend produces, so nothing downstream knows the
/// difference.
public protocol TranscriptAligner: Sendable {
    /// Recorded as provenance on every alignment it writes.
    var identifier: String { get }

    func align(audio: URL, text: String) async throws -> [RawTranscriptSegment]
}

/// The aligner found no monotonic path between this text and this audio.
///
/// Distinct from an infrastructure failure on purpose: a refusal is answered
/// with coarse chunk-level timing, while a missing model or unreadable file
/// propagates and fails the stage.
public struct TranscriptAlignmentRefused: Error, Sendable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
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

/// Speech probability sampled on a fixed grid.
public struct VoiceActivityProfile: Sendable, Equatable {
    public var windowSeconds: Double
    /// One probability in 0...1 per window, in order.
    public var values: [Float]

    public init(windowSeconds: Double, values: [Float]) {
        self.windowSeconds = windowSeconds
        self.values = values
    }
}

/// Decides which parts of a track hold a voice.
///
/// Separate from diarization, which asks whose voice it is over a whole meeting
/// and costs a great deal more. This answers only whether anybody is speaking,
/// which is what tells a fabricated sentence from a real one on the local user's
/// track.
///
/// The whole track goes through one call because the detector carries state
/// between windows.
///
/// The detector pulls the samples rather than being handed them, so the read
/// cannot run ahead of the model. Pushing them meant the decoder filled a
/// buffer at its own speed while the model worked through it, and a two-hour
/// track at 16 kHz float32 is over 400 MB to be holding.
public protocol VoiceActivityBackend: Sendable {
    /// Recorded on the evidence, so a reader can tell what judged the audio.
    var identifier: String { get }
    /// The rate the samples must arrive at. The caller reads the track at this
    /// rate or does not call at all: resampling silently to something else
    /// would move every reading in time.
    var sampleRate: Double { get }

    /// - Parameter next: the next block of mono samples at `sampleRate`, or nil
    ///   at the end of the track. Called from inside the detector, one block at
    ///   a time.
    func probabilities(
        reading next: @escaping @Sendable () async throws -> [Float]?
    ) async throws -> VoiceActivityProfile
}
