import Foundation

/// A recorded result for one meeting under one configuration, and the
/// tolerances a later run is judged against.
///
/// Baselines come from a deciding run and are committed from its output. The
/// tolerances are absolute percentage points, wide enough to absorb the
/// run-to-run variation a Neural Engine decode produces and narrow enough that
/// a real regression trips them.
public struct BenchBaselines: Codable, Sendable, Equatable {
    public struct Tolerances: Codable, Sendable, Equatable {
        /// How much worse the word error rate may get, in points.
        public var wer: Double
        /// How much attribution accuracy may drop, in points.
        public var attribution: Double
        /// How much worse the diarization error rate may get, in points.
        public var der: Double

        public init(wer: Double = 1.5, attribution: Double = 1.0, der: Double = 2.0) {
            self.wer = wer
            self.attribution = attribution
            self.der = der
        }
    }

    public struct Entry: Codable, Sendable, Equatable {
        public var wer: Double
        public var werNoFiller: Double
        public var attribution: Double
        public var der: Double?
        /// Repeated 8-grams the deciding run produced for this case. A budget,
        /// not a tolerance: a case may not produce more than it did, and a
        /// case recorded at zero may not produce any.
        public var repeatedNgrams: Int

        public init(
            wer: Double, werNoFiller: Double, attribution: Double, der: Double?,
            repeatedNgrams: Int = 0
        ) {
            self.wer = wer
            self.werNoFiller = werNoFiller
            self.attribution = attribution
            self.der = der
            self.repeatedNgrams = repeatedNgrams
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            wer = try container.decode(Double.self, forKey: .wer)
            werNoFiller = try container.decode(Double.self, forKey: .werNoFiller)
            attribution = try container.decode(Double.self, forKey: .attribution)
            der = try container.decodeIfPresent(Double.self, forKey: .der)
            repeatedNgrams = try container.decodeIfPresent(Int.self, forKey: .repeatedNgrams) ?? 0
        }
    }

    public var tolerances: Tolerances
    /// Keyed "<engine>/<diarizer>/<meeting>", so one file covers every
    /// configuration the suite is run under.
    public var entries: [String: Entry]

    public init(tolerances: Tolerances = Tolerances(), entries: [String: Entry] = [:]) {
        self.tolerances = tolerances
        self.entries = entries
    }

    public static func key(engine: String, diarizer: String, meeting: String) -> String {
        "\(engine)/\(diarizer)/\(meeting)"
    }

    public static func read(from url: URL) throws -> BenchBaselines {
        try JSONDecoder().decode(BenchBaselines.self, from: Data(contentsOf: url))
    }

    /// What a result breaks, if anything. An empty list is a pass.
    ///
    /// Repeated 8-grams ratchet rather than run on a tolerance: one sentence
    /// transcribed twice is a defect at any margin, so a case may never produce
    /// more of them than its entry records, and a case with no entry, or an
    /// entry recording none, may produce none at all. Two cases carry a nonzero
    /// budget until the chunk-seam work that removes them lands.
    public func regressions(key: String, score: BenchScore) -> [String] {
        var broken: [String] = []
        let budget = entries[key]?.repeatedNgrams ?? 0
        if score.repeatedNgrams > budget {
            broken.append("\(score.repeatedNgrams) repeated 8-grams against \(budget)")
        }
        guard let baseline = entries[key] else { return broken }
        let werDrift = (score.werNoFiller - baseline.werNoFiller) * 100
        if werDrift > tolerances.wer {
            broken.append(String(
                format: "filler-stripped WER %.1f%% against %.1f%%",
                score.werNoFiller * 100, baseline.werNoFiller * 100
            ))
        }
        let attributionDrift = (baseline.attribution - score.attribution) * 100
        if attributionDrift > tolerances.attribution {
            broken.append(String(
                format: "attribution %.1f%% against %.1f%%",
                score.attribution * 100, baseline.attribution * 100
            ))
        }
        if let baselineDer = baseline.der, let der = score.der, (der - baselineDer) * 100 > tolerances.der {
            broken.append(String(format: "DER %.1f%% against %.1f%%", der * 100, baselineDer * 100))
        }
        return broken
    }
}
