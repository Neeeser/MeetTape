import Foundation

/// One request-sized slice of a track.
public struct ChunkPlan: Sendable, Equatable, Identifiable {
    public let index: Int
    /// Where the audio sent to the model begins, including the overlap tail of the
    /// previous chunk.
    public let start: Double
    public let end: Double
    /// Everything before this belongs to the previous chunk and is only present so
    /// a sentence crossing the boundary is not lost.
    public let overlapEnd: Double

    public var id: Int { index }
    public var duration: Double { end - start }
    public var overlapDuration: Double { overlapEnd - start }

    public var chunkID: String { SpeakerLabel.chunkID(index: index) }

    public init(index: Int, start: Double, end: Double, overlapEnd: Double) {
        self.index = index
        self.start = start
        self.end = end
        self.overlapEnd = overlapEnd
    }
}

/// Splits a long recording into request-sized chunks at natural pauses.
///
/// The diarization endpoint rejects audio longer than 1400 seconds, so anything
/// over about 23 minutes has to be chunked. Cutting blindly every N seconds
/// severs sentences, so each boundary is nudged to the quietest point within a
/// search window, and adjacent chunks overlap so a sentence that still lands on a
/// boundary appears in full in one of them.
public struct ChunkPlanner: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Where boundaries are aimed. Comfortably under the model limit.
        public var targetChunkSeconds: Double
        /// Hard ceiling for the audio sent in one request, overlap included.
        public var maxChunkSeconds: Double
        /// Shortest chunk worth cutting.
        public var minChunkSeconds: Double
        /// How far either side of the ideal boundary to look for a pause.
        public var searchWindowSeconds: Double
        /// How much of the previous chunk each chunk repeats.
        public var overlapSeconds: Double

        public init(
            targetChunkSeconds: Double = 1_140,
            maxChunkSeconds: Double = 1_300,
            minChunkSeconds: Double = 60,
            searchWindowSeconds: Double = 60,
            overlapSeconds: Double = 8
        ) {
            self.targetChunkSeconds = targetChunkSeconds
            self.maxChunkSeconds = maxChunkSeconds
            self.minChunkSeconds = minChunkSeconds
            self.searchWindowSeconds = searchWindowSeconds
            self.overlapSeconds = overlapSeconds
        }

        /// Measured limits: 1400 s per diarization request, 25 MiB per request body.
        public static let openAIDiarization = Configuration()
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .openAIDiarization) {
        self.configuration = configuration
    }

    public func plan(durationSeconds: Double, energy: EnergyProfile = .empty) -> [ChunkPlan] {
        guard durationSeconds > 0 else { return [] }
        if durationSeconds <= configuration.maxChunkSeconds {
            return [ChunkPlan(index: 1, start: 0, end: durationSeconds, overlapEnd: 0)]
        }

        var boundaries: [Double] = [0]
        var cursor: Double = 0
        while durationSeconds - cursor > configuration.maxChunkSeconds {
            let ideal = cursor + configuration.targetChunkSeconds
            let lowerBound = cursor + configuration.minChunkSeconds
            let upperBound = min(cursor + configuration.maxChunkSeconds, durationSeconds)
            let boundary = quietestBoundary(
                near: ideal, lowerBound: lowerBound, upperBound: upperBound, energy: energy
            )
            // Never move backwards, and never emit a chunk shorter than the minimum.
            guard boundary > cursor else { break }
            boundaries.append(boundary)
            cursor = boundary
        }
        boundaries.append(durationSeconds)

        var plans: [ChunkPlan] = []
        for index in 0..<(boundaries.count - 1) {
            let rawStart = boundaries[index]
            let start = index == 0 ? rawStart : max(0, rawStart - configuration.overlapSeconds)
            plans.append(ChunkPlan(
                index: index + 1,
                start: start,
                end: boundaries[index + 1],
                overlapEnd: index == 0 ? 0 : rawStart
            ))
        }
        return plans
    }

    /// Scores candidate cut points by mean energy over a short span and picks the
    /// quietest, preferring points near the ideal when the track has no profile.
    private func quietestBoundary(
        near ideal: Double, lowerBound: Double, upperBound: Double, energy: EnergyProfile
    ) -> Double {
        let low = max(lowerBound, ideal - configuration.searchWindowSeconds)
        let high = min(upperBound, ideal + configuration.searchWindowSeconds)
        guard high > low else { return min(max(ideal, lowerBound), upperBound) }
        guard !energy.values.isEmpty else { return min(max(ideal, lowerBound), upperBound) }

        let step = max(energy.windowSeconds, 0.25)
        let span = 0.6
        var best = min(max(ideal, lowerBound), upperBound)
        var bestScore = Float.greatestFiniteMagnitude
        var candidate = low
        while candidate <= high {
            let score = energy.meanEnergy(from: candidate - span / 2, to: candidate + span / 2)
            // Break ties toward the ideal so chunks stay evenly sized.
            let distancePenalty = Float(abs(candidate - ideal) / max(1, configuration.searchWindowSeconds)) * 1e-4
            let total = score + distancePenalty
            if total < bestScore {
                bestScore = total
                best = candidate
            }
            candidate += step
        }
        return best
    }
}
