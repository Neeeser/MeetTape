import Foundation
import FluidAudio
import PipitAudio
import PipitCore

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
    /// Speakers only. The track's words come from the transcription backend,
    /// whichever one that is.
    public var producesTranscript: Bool { false }

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
    /// The configuration Pipit ships, with the one tuned field applied.
    public static func diarizerConfiguration(speakerCount: Int?) -> OfflineDiarizerConfig {
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
    public static func diarizerProvenance(speakerCount: Int?) -> [String: String] {
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
            do {
                result = try manager.cluster(cached)
            } catch {
                guard let empty = Self.silentMeeting(error, speakerCount: speakerCount)
                else { throw error }
                progress(1)
                return empty
            }
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
            do {
                result = try manager.cluster(prepared)
            } catch {
                guard let empty = Self.silentMeeting(error, speakerCount: speakerCount) else {
                    if cacheKey == nil { source.cleanup() }
                    throw error
                }
                if cacheKey == nil { source.cleanup() }
                progress(1)
                return empty
            }
            if let cacheKey {
                cachePreparedDiarization(prepared, source: source, for: cacheKey)
            } else {
                source.cleanup()
            }
        }
        progress(1)
        return Self.output(from: result, configuration: Self.diarizerProvenance(speakerCount: speakerCount))
    }

    /// A diarizer that found no speech has not failed.
    ///
    /// A recording where nobody spoke holds no speaker turns, which is an
    /// answer. Raised as an error it failed the meeting: the transcript,
    /// the markdown and the mixdown were never written, and a recording that
    /// captured exactly what happened was filed as needing attention.
    public static func silentMeeting(_ error: any Error, speakerCount: Int?) -> DiarizationOutput? {
        guard case OfflineDiarizationError.noSpeechDetected = error else { return nil }
        return DiarizationOutput(
            intervals: [], clusters: [],
            configuration: diarizerProvenance(speakerCount: speakerCount)
        )
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
        let result: DiarizationResult
        do {
            result = try manager.cluster(cached)
        } catch {
            guard let empty = Self.silentMeeting(error, speakerCount: speakerCount)
            else { throw error }
            return empty
        }
        return Self.output(
            from: result, configuration: Self.diarizerProvenance(speakerCount: speakerCount)
        )
    }

    /// Re-analysis entry point. Uses the prepared state from the meeting's
    /// first pass when it is still in memory, and pays the full pass when it is
    /// not: `PreparedDiarization` holds decoded audio and cannot be persisted.
    public func reanalyze(
        meetingID: String, audio: URL, speakerCount: Int?
    ) async throws -> DiarizationOutput {
        if let cached = try await recluster(cacheKey: meetingID, speakerCount: speakerCount) {
            return cached
        }
        return try await diarize(
            audio: audio, cacheKey: meetingID, speakerCount: speakerCount, progress: { _ in }
        )
    }

    /// Diarizes at a given acoustic scaling, for the developer evaluation tool.
    ///
    /// The production path never takes this parameter: `warmStartFa` is a tuned
    /// constant, not a setting. This exists so the A/B that produced the number
    /// can be repeated on real meeting audio.
    public func evaluateDiarization(
        audio: URL, warmStartFa: Double, speakerCount: Int? = nil
    ) async throws -> DiarizationOutput {
        let models = try await loadedDiarizerModels()
        var config = Self.diarizerConfiguration(speakerCount: speakerCount)
        config.clustering.warmStartFa = warmStartFa
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        let result = try await manager.process(audio)
        var provenance = Self.diarizerProvenance(speakerCount: speakerCount)
        provenance["warmStartFa"] = String(warmStartFa)
        return Self.output(from: result, configuration: provenance)
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
        var chunkCounts: [String: Int] = [:]
        for chunk in chunks { chunkCounts[chunk.clusterID, default: 0] += 1 }

        let clusters = speechByCluster.keys.sorted().map { id -> DiarizationCluster in
            let quality = qualityByCluster[id].map { $0.count > 0 ? $0.total / Double($0.count) : 1 } ?? 1
            return DiarizationCluster(
                id: id,
                speechSeconds: speechByCluster[id] ?? 0,
                quality: quality,
                chunkCount: chunkCounts[id] ?? 0
            )
        }
        return DiarizationOutput(
            intervals: intervals, clusters: clusters, chunkEmbeddings: chunks,
            configuration: configuration
        )
    }

    // MARK: - embedding a track whose speakers are already known

    /// One vector for the dominant voice in a file that should hold one person.
    ///
    /// Used on the microphone track of a remote call. It is not forced to a
    /// single cluster: a user on speakers records the remote side onto their own
    /// track, which the transcript assembler already exists to undo, and forcing
    /// one cluster would fold that person into the local user's profile. This is
    /// the one profile built without a human confirmation, so it refuses
    /// anything it cannot attribute cleanly.
    ///
    /// Returns nil when the track's dominant voice does not clearly dominate.
    public func embedSingleSpeaker(
        audio: URL, minimumDominantShare: Double = 0.75
    ) async throws -> SingleSpeakerSample? {
        let models = try await loadedDiarizerModels()
        var config = Self.diarizerConfiguration(speakerCount: nil)
        config.exposeChunkEmbeddings = true
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        let result = try await manager.process(audio)
        guard !result.segments.isEmpty else { return nil }

        var speech: [String: Double] = [:]
        for segment in result.segments {
            speech[segment.speakerId, default: 0] +=
                Double(segment.endTimeSeconds - segment.startTimeSeconds)
        }
        let total = speech.values.reduce(0, +)
        guard total > 0, let dominant = speech.max(by: { $0.value < $1.value }) else { return nil }
        guard dominant.value / total >= minimumDominantShare else {
            Log.processing.notice(
                "mic track not enrolled: dominant voice holds \(Int(dominant.value / total * 100), privacy: .public)% of speech"
            )
            return nil
        }

        let vectors = (result.chunkEmbeddings ?? [])
            .filter { $0.speakerId == dominant.key }
            .map(\.embedding256)
        guard !vectors.isEmpty else { return nil }
        let ownSegments = result.segments.filter { $0.speakerId == dominant.key }
        let quality = ownSegments.isEmpty
            ? 1.0
            : ownSegments.reduce(0.0) { $0 + Double($1.qualityScore) } / Double(ownSegments.count)
        return SingleSpeakerSample(
            vector: VoiceVector.centroid(vectors),
            speechSeconds: dominant.value,
            quality: quality,
            spans: ownSegments.map {
                AudioSpan(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
            }
        )
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
