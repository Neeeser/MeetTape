import Foundation

/// How repeated runs of one case become the single score the baseline gate
/// reads.
///
/// It lives here rather than in the eval executable because it decides whether
/// a run passes or fails, and a target no test can import is a decision nobody
/// can pin. `scripts/build-bench-baselines.py` records baselines the same way.
public enum BenchAggregate {
    /// The score the baseline check reads when a case ran more than once.
    ///
    /// The averaged fields are the ones the rule compares. Repeated 8-grams
    /// take the worst of the runs rather than the mean, because that rule is a
    /// budget and a defect seen once is a defect. Everything else keeps the
    /// first run's value: the counts and the mapping describe a particular
    /// transcript, and an average of two mappings is not a mapping.
    public static func deciding(over runs: [BenchScore]) -> BenchScore? {
        guard var score = runs.first else { return nil }
        guard runs.count > 1 else { return score }
        score.wer = mean(runs.map(\.wer))
        score.werNoFiller = mean(runs.map(\.werNoFiller))
        score.werConversational = mean(runs.map(\.werConversational))
        score.attribution = mean(runs.map(\.attribution))
        score.attributionMerged = mean(runs.map(\.attributionMerged))
        score.attributionOfLabelled = mean(runs.map(\.attributionOfLabelled))
        let ders = runs.compactMap(\.der)
        score.der = ders.isEmpty ? nil : mean(ders)
        let strict = runs.compactMap(\.derStrict)
        score.derStrict = strict.isEmpty ? nil : mean(strict)
        let cp = runs.compactMap(\.cpWer)
        score.cpWer = cp.isEmpty ? nil : mean(cp)
        let tcp = runs.compactMap(\.tcpWer)
        score.tcpWer = tcp.isEmpty ? nil : mean(tcp)
        score.repeatedNgrams = runs.map(\.repeatedNgrams).max() ?? score.repeatedNgrams
        return score
    }

    public static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
