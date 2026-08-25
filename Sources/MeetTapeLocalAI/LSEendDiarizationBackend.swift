import FluidAudio
import Foundation
import MeetTapeAudio
import MeetTapeCore

/// On-device diarization with FluidAudio's LS-EEND model, which emits
/// per-speaker activity frame by frame and can therefore say that two people
/// spoke at once. The offline clusterer cannot: it assigns each moment to one
/// speaker, so on a window where 40% of the speech is overlapped the second
/// voice does not exist in its output.
///
/// A benchmark candidate, reachable through `meettape-eval bench --diarizer
/// lseend` and constructed nowhere else until the comparative run says it
/// should be. It reports no embeddings; voice memory embeds its intervals with
/// the same extractor that covers the cloud diarizer.
public struct LSEendDiarizationBackend: DiarizationBackend {
    private let models: LocalModelManager
    private let variant: LSEENDVariant

    /// The checkpoints are domain-named (`ami`, `callhome`, `dihard2/3`) and
    /// domain-brittle: the AMI one ranked best on AMI windows and found one
    /// to two of five speakers on NOTSOFAR's far-field audio. `dihard3` is
    /// the library's own broad-domain default.
    public init(models: LocalModelManager, variant: LSEENDVariant = .ami) {
        self.models = models
        self.variant = variant
    }

    public var identifier: String {
        "\(LocalSpeechStack.lseendBackendIdentifierPrefix)\(variant)-0.15.6"
    }
    public var isLocal: Bool { true }
    public var limits: BackendAudioLimits { .none }
    public var producesEmbeddings: Bool { false }
    public var producesTranscript: Bool { false }

    public func diarize(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DiarizationOutput {
        try await models.lseendDiarize(audio: audio, variant: variant, progress: progress)
    }

    /// The timeline as the pipeline's terms: one interval per segment, one
    /// cluster per speaker track, and overlapping segments from different
    /// speakers kept overlapping.
    public static func output(
        segments: [(speaker: Int, start: Double, end: Double, activity: Double)],
        configuration: [String: String]
    ) -> DiarizationOutput {
        let intervals = segments
            .map {
                DiarizationInterval(
                    start: $0.start, end: $0.end,
                    clusterID: "eend_\($0.speaker)", quality: $0.activity
                )
            }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.clusterID < $1.clusterID
            }
        var speech: [String: Double] = [:]
        var quality: [String: (total: Double, count: Int)] = [:]
        for interval in intervals {
            speech[interval.clusterID, default: 0] += interval.duration
            var entry = quality[interval.clusterID] ?? (0, 0)
            entry.total += interval.quality
            entry.count += 1
            quality[interval.clusterID] = entry
        }
        let clusters = speech.keys.sorted().map { id in
            DiarizationCluster(
                id: id,
                speechSeconds: speech[id] ?? 0,
                quality: quality[id].map { $0.count > 0 ? $0.total / Double($0.count) : 1 } ?? 1,
                chunkCount: 0
            )
        }
        return DiarizationOutput(
            intervals: intervals, clusters: clusters, configuration: configuration
        )
    }
}

extension LocalModelManager {
    /// Diarizes one file with LS-EEND. On the actor for the same reason every
    /// other local model pass is: one heavy job at a time.
    ///
    /// The model caches under the same root the other units live in, and
    /// arrives on first use of this backend: selecting `--diarizer lseend` is
    /// the consent for its download, the way picking any model is.
    func lseendDiarize(
        audio: URL, variant: LSEENDVariant, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DiarizationOutput {
        // The model class is not Sendable, so its whole lifetime stays inside
        // one detached task and only the Sendable output crosses back; loaded
        // on the actor, the stricter toolchains refuse the transfer. The
        // actor method still serializes callers the way every heavy pass
        // does: each call awaits the whole run.
        let root = locations.root
        return try await Task.detached(priority: .userInitiated) {
            let model = try await LSEENDModel.loadFromHuggingFace(
                variant: variant, cacheDirectory: root
            )
            let diarizer = LSEENDDiarizer()
            try diarizer.initialize(model: model)
            let samples = try MonoAudioDecoder.loadMono16k(audio)
            let timeline = try diarizer.processComplete(
                samples, sourceSampleRate: 16_000,
                progressCallback: { done, total, _ in
                    guard total > 0 else { return }
                    progress(min(1, Double(done) / Double(total)))
                }
            )
            var segments: [(speaker: Int, start: Double, end: Double, activity: Double)] = []
            for (index, speaker) in timeline.speakers {
                for segment in speaker.finalizedSegments {
                    segments.append((
                        speaker: index,
                        start: Double(segment.startTime), end: Double(segment.endTime),
                        activity: Double(segment.activity)
                    ))
                }
            }
            progress(1)
            return LSEendDiarizationBackend.output(
                segments: segments,
                configuration: [
                    "backend": "\(LocalSpeechStack.lseendBackendIdentifierPrefix)\(variant)-0.15.6",
                    "pipeline": "ls-eend",
                    "variant": "\(variant)",
                ]
            )
        }.value
    }
}
