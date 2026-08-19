import Foundation
import FluidAudio
import MeetTapeAudio
import MeetTapeCore

/// On-device diarization with the FluidAudio offline VBx pipeline.
///
/// Not the classic WeSpeaker pipeline: on the same 15-minute call the offline
/// one ran at RTFx 250 against 99 and found two speakers where the classic one
/// invented a third.
public struct FluidAudioDiarizationBackend: DiarizationBackend {
    private let models: LocalModelManager
    /// Cached under this key so "re-analyze speakers" can skip segmentation and
    /// embedding extraction, which are 97% of the work.
    private let cacheKey: String?

    public init(models: LocalModelManager, cacheKey: String? = nil) {
        self.models = models
        self.cacheKey = cacheKey
    }

    public var identifier: String { LocalSpeechStack.diarizerBackendIdentifier }
    public var isLocal: Bool { true }
    public var limits: BackendAudioLimits { .none }
    public var producesEmbeddings: Bool { true }

    public func diarize(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DiarizationOutput {
        try await models.diarize(
            audio: audio, cacheKey: cacheKey, speakerCount: nil, progress: progress
        )
    }
}

/// Extracts speaker vectors for intervals another backend decided.
///
/// What keeps voice memory local when diarization is not: choosing the cloud
/// diarizer costs the vectors, and this puts them back without a second
/// diarization pass.
public struct FluidAudioEmbeddingExtractor: SpeakerEmbeddingExtractor {
    private let models: LocalModelManager

    public init(models: LocalModelManager) {
        self.models = models
    }

    public var model: EmbeddingModelIdentifier { .fluidAudioOffline }

    public func embed(
        audio: URL, intervals: [DiarizationInterval]
    ) async throws -> [DiarizationChunkEmbedding] {
        try await models.embed(audio: audio, intervals: intervals)
    }
}

extension LocalModelManager {
    /// The configuration MeetTape ships, with the one tuned field applied.
    static func diarizerConfiguration(speakerCount: Int?) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default
        config.exposeChunkEmbeddings = true
        config.clustering.warmStartFa = LocalDiarizationTuning.warmStartFa
        // Never set from a participant list, a calendar or a guess. Only a
        // person asking for a specific count on the re-analysis control reaches
        // this, and then it is their number under their review.
        config.clustering.numSpeakers = speakerCount
        return config
    }

    /// The provenance recorded with every run, so a result can be explained.
    static func diarizerProvenance(speakerCount: Int?) -> [String: String] {
        var provenance = [
            "backend": LocalSpeechStack.diarizerBackendIdentifier,
            "warmStartFa": String(LocalDiarizationTuning.warmStartFa),
            "pipeline": "offline-vbx",
        ]
        if let speakerCount { provenance["numSpeakers"] = String(speakerCount) }
        return provenance
    }

    /// Diarizes one file.
    ///
    /// When `cacheKey` is given, segmentation and embedding extraction are kept
    /// so a later run at a different speaker count re-clusters instead of
    /// starting again. On a 60-minute meeting that is about 1.2 seconds instead
    /// of about 15.
    func diarize(
        audio: URL,
        cacheKey: String?,
        speakerCount: Int?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DiarizationOutput {
        let models = try await loadedDiarizerModels()
        let config = Self.diarizerConfiguration(speakerCount: speakerCount)
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)

        let result: DiarizationResult
        if let cacheKey, let cached = preparedDiarization(for: cacheKey) {
            progress(0.9)
            result = try manager.cluster(cached)
        } else {
            let factory = AudioSourceFactory()
            let (source, loadSeconds) = try factory.makeDiskBackedSource(
                from: audio, targetSampleRate: config.segmentation.sampleRate
            )
            let prepared = try await manager.prepare(
                audioSource: source,
                audioLoadingSeconds: loadSeconds,
                progressCallback: { done, total in
                    guard total > 0 else { return }
                    progress(min(0.9, Double(done) / Double(total) * 0.9))
                }
            )
            result = try manager.cluster(prepared)
            if let cacheKey {
                cachePreparedDiarization(prepared, source: source, for: cacheKey)
            } else {
                source.cleanup()
            }
        }
        progress(1)
        return Self.output(from: result, configuration: Self.diarizerProvenance(speakerCount: speakerCount))
    }

    /// Re-clusters a meeting already prepared in this session.
    ///
    /// Returns nil when nothing is cached, which happens after a relaunch:
    /// `PreparedDiarization` holds decoded audio and has no public initializer,
    /// so it cannot be written to disk and re-read. The caller falls back to a
    /// full re-diarization.
    func recluster(cacheKey: String, speakerCount: Int?) async throws -> DiarizationOutput? {
        guard let cached = preparedDiarization(for: cacheKey) else { return nil }
        let models = try await loadedDiarizerModels()
        let manager = OfflineDiarizerManager(config: Self.diarizerConfiguration(speakerCount: speakerCount))
        manager.initialize(models: models)
        let result = try manager.cluster(cached)
        return Self.output(
            from: result, configuration: Self.diarizerProvenance(speakerCount: speakerCount)
        )
    }

    func hasPreparedDiarization(cacheKey: String) -> Bool {
        preparedDiarization(for: cacheKey) != nil
    }

    private static func output(
        from result: DiarizationResult, configuration: [String: String]
    ) -> DiarizationOutput {
        let intervals = result.segments.map {
            DiarizationInterval(
                start: Double($0.startTimeSeconds),
                end: Double($0.endTimeSeconds),
                clusterID: $0.speakerId,
                quality: Double($0.qualityScore)
            )
        }
        let chunks = (result.chunkEmbeddings ?? []).map {
            DiarizationChunkEmbedding(
                clusterID: $0.speakerId,
                start: $0.startTimeSeconds,
                end: $0.endTimeSeconds,
                vector: $0.embedding256
            )
        }
        var speechByCluster: [String: Double] = [:]
        var qualityByCluster: [String: (total: Double, count: Int)] = [:]
        for interval in intervals {
            speechByCluster[interval.clusterID, default: 0] += interval.duration
            var entry = qualityByCluster[interval.clusterID] ?? (0, 0)
            entry.total += interval.quality
            entry.count += 1
            qualityByCluster[interval.clusterID] = entry
        }
        var vectorsByCluster: [String: [[Float]]] = [:]
        for chunk in chunks { vectorsByCluster[chunk.clusterID, default: []].append(chunk.vector) }

        let clusters = speechByCluster.keys.sorted().map { id -> DiarizationCluster in
            let quality = qualityByCluster[id].map { $0.count > 0 ? $0.total / Double($0.count) : 1 } ?? 1
            let vectors = vectorsByCluster[id] ?? []
            return DiarizationCluster(
                id: id,
                speechSeconds: speechByCluster[id] ?? 0,
                quality: quality,
                embedding: vectors.isEmpty ? nil : VoiceVector.centroid(vectors),
                embeddingModel: vectors.isEmpty ? nil : EmbeddingModelIdentifier.fluidAudioOffline.rawValue,
                chunkCount: vectors.count
            )
        }
        return DiarizationOutput(
            intervals: intervals, clusters: clusters, chunkEmbeddings: chunks,
            configuration: configuration
        )
    }

    // MARK: - embedding a track whose speakers are already known

    /// One vector for a whole file assumed to hold one speaker.
    ///
    /// Used on the microphone track of a remote call, where the speaker is the
    /// local user by construction, so there is nothing to cluster.
    func embedSingleSpeaker(
        audio: URL
    ) async throws -> (vector: [Float], speechSeconds: Double, quality: Double)? {
        let models = try await loadedDiarizerModels()
        var config = Self.diarizerConfiguration(speakerCount: 1)
        config.exposeChunkEmbeddings = true
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        let result = try await manager.process(audio)
        let vectors = (result.chunkEmbeddings ?? []).map(\.embedding256)
        guard !vectors.isEmpty else { return nil }
        let speech = result.segments.reduce(0.0) {
            $0 + Double($1.endTimeSeconds - $1.startTimeSeconds)
        }
        let quality = result.segments.isEmpty
            ? 1.0
            : result.segments.reduce(0.0) { $0 + Double($1.qualityScore) } / Double(result.segments.count)
        return (VoiceVector.centroid(vectors), speech, quality)
    }

    /// Vectors for intervals another backend decided.
    ///
    /// Each cluster's audio is concatenated and embedded in one pass, because a
    /// single interval is often under a second and the embedding model needs
    /// more than that. The returned times are mapped back onto the original
    /// timeline, so a later line-level correction can find the vectors that
    /// cover it.
    func embed(audio: URL, intervals: [DiarizationInterval]) async throws -> [DiarizationChunkEmbedding] {
        guard !intervals.isEmpty else { return [] }
        let models = try await loadedDiarizerModels()
        let samples = try MonoAudioDecoder.loadMono16k(audio)
        guard !samples.isEmpty else { return [] }
        let rate = 16_000.0

        var byCluster: [String: [DiarizationInterval]] = [:]
        for interval in intervals where interval.duration > 0 {
            byCluster[interval.clusterID, default: []].append(interval)
        }

        var config = Self.diarizerConfiguration(speakerCount: 1)
        config.exposeChunkEmbeddings = true

        var output: [DiarizationChunkEmbedding] = []
        for (clusterID, clusterIntervals) in byCluster {
            let ordered = clusterIntervals.sorted { $0.start < $1.start }
            var concatenated: [Float] = []
            // Where each concatenated span came from, so an embedding's time can
            // be translated back.
            var mapping: [(concatStart: Double, concatEnd: Double, originalStart: Double)] = []
            for interval in ordered {
                let first = max(0, Int(interval.start * rate))
                let last = min(samples.count, Int(interval.end * rate))
                guard last > first else { continue }
                let concatStart = Double(concatenated.count) / rate
                concatenated.append(contentsOf: samples[first..<last])
                mapping.append((
                    concatStart: concatStart,
                    concatEnd: Double(concatenated.count) / rate,
                    originalStart: interval.start
                ))
            }
            // Below a second the embedding model has nothing to work with.
            guard concatenated.count >= Int(rate) else { continue }

            let manager = OfflineDiarizerManager(config: config)
            manager.initialize(models: models)
            let result = try await manager.process(audio: concatenated)
            for chunk in result.chunkEmbeddings ?? [] {
                let (start, end) = Self.originalSpan(
                    concatStart: chunk.startTimeSeconds, concatEnd: chunk.endTimeSeconds, mapping: mapping
                )
                output.append(DiarizationChunkEmbedding(
                    clusterID: clusterID, start: start, end: end, vector: chunk.embedding256
                ))
            }
        }
        return output.sorted { $0.start < $1.start }
    }

    /// Translates a span in the concatenated audio back to the timeline.
    ///
    /// A span that crosses a join is reported against the piece its start fell
    /// in and clamped to that piece's end, so a returned span never covers audio
    /// the speaker was not in.
    private static func originalSpan(
        concatStart: Double,
        concatEnd: Double,
        mapping: [(concatStart: Double, concatEnd: Double, originalStart: Double)]
    ) -> (Double, Double) {
        for piece in mapping where concatStart >= piece.concatStart && concatStart < piece.concatEnd {
            let offset = concatStart - piece.concatStart
            let length = min(concatEnd, piece.concatEnd) - concatStart
            return (piece.originalStart + offset, piece.originalStart + offset + max(length, 0))
        }
        guard let last = mapping.last else { return (concatStart, concatEnd) }
        return (last.originalStart, last.originalStart + (concatEnd - concatStart))
    }
}
