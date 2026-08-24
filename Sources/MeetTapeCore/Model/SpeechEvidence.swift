import Foundation

/// What the recorded audio holds, sampled on a fixed grid, so the assembler can
/// ask what was under a segment without reading the audio itself.
///
/// Written once, beside the raw transcript, and read on every assembly. Keeping
/// it on disk rather than recomputing it is what makes re-assembly deterministic:
/// a rebuild on a machine whose detector model has since been deleted would
/// otherwise put the fabricated lines back.
///
/// Anchored to time rather than to segment positions on purpose. The alignment
/// stage rewrites a text-only chunk's segments before assembly sees them, so a
/// reading keyed to a segment's index would be pointing at different words than
/// the ones it measured.
///
/// Levels are whole dBFS and detector readings are whole percent, which keeps a
/// 30-minute meeting near 85 KB. The measures separate by 10 dB and more, so
/// nothing here needs finer resolution.
public struct SpeechEvidence: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// Seconds one level sample covers.
    public var levelWindowSeconds: Double
    /// Seconds one detector reading covers.
    public var speechWindowSeconds: Double
    /// Loudness of each window on the microphone track, in whole dBFS.
    public var micLevels: [Int8]
    /// The same for the track holding the far end. Empty for a meeting recorded
    /// or imported with one track.
    public var remoteLevels: [Int8]
    /// The detector's speech probability per window on the microphone track, in
    /// whole percent. Empty where no detector ran.
    public var micSpeech: [Int8]
    /// What produced `micSpeech`, as provenance. Nil where nothing did.
    public var detector: String?

    public init(
        version: Int = SpeechEvidence.currentVersion,
        levelWindowSeconds: Double,
        speechWindowSeconds: Double,
        micLevels: [Int8],
        remoteLevels: [Int8] = [],
        micSpeech: [Int8] = [],
        detector: String? = nil
    ) {
        self.version = version
        self.levelWindowSeconds = levelWindowSeconds
        self.speechWindowSeconds = speechWindowSeconds
        self.micLevels = micLevels
        self.remoteLevels = remoteLevels
        self.micSpeech = micSpeech
        self.detector = detector
    }

    /// What the audio holds over one span of the meeting timeline, from the
    /// microphone's point of view.
    ///
    /// Returns nil for a span the evidence does not cover, which is what a
    /// segment timed past the end of the recording produces. The caller then
    /// keeps the segment: evidence that was never measured must not read as
    /// evidence of silence.
    public func reading(from start: Double, to end: Double) -> SpeechReading? {
        guard let local = span(micLevels, windowSeconds: levelWindowSeconds, from: start, to: end),
              let loudestLocal = local.max() else { return nil }
        let far = span(remoteLevels, windowSeconds: levelWindowSeconds, from: start, to: end)
        let probability = span(micSpeech, windowSeconds: speechWindowSeconds, from: start, to: end)
            .flatMap { $0.max() }
            .map { Double($0) / 100 }
        guard let far, let loudestFar = far.max() else {
            return SpeechReading(speechProbability: probability, loudestLocalDB: Double(loudestLocal))
        }
        // Zipped rather than indexed: these are slices, so their indices are
        // positions in the whole recording rather than in the span, and the far
        // end's slice is the shorter of the two wherever its track ended first.
        var differences = zip(local, far).map { Double($0) - Double($1) }
        differences.sort()
        // The upper of the two middle values for an even count. The measures
        // separate by 10 dB and more, so which one is taken decides nothing.
        let median = differences.isEmpty ? 0 : differences[differences.count / 2]
        return SpeechReading(
            speechProbability: probability,
            loudestLocalDB: Double(loudestLocal),
            loudestFarDB: Double(loudestFar),
            medianDifferenceDB: median
        )
    }

    /// The samples covering `[start, end)`, or nil where the series is empty or
    /// the span falls outside it. At least one sample where the span is shorter
    /// than a window.
    private func span(
        _ values: [Int8], windowSeconds: Double, from start: Double, to end: Double
    ) -> ArraySlice<Int8>? {
        guard !values.isEmpty, windowSeconds > 0, end >= start else { return nil }
        // A backend supplies these times, and converting a non-finite or
        // astronomically large one to Int traps rather than returning anything.
        guard start.isFinite, end.isFinite, start >= 0,
              start / windowSeconds < Double(values.count) else { return nil }
        let first = Int(start / windowSeconds)
        guard first < values.count else { return nil }
        let reach = min(end / windowSeconds, Double(values.count))
        let last = min(values.count - 1, max(first, Int(reach.rounded(.up)) - 1))
        return values[first...last]
    }

    /// Turns a linear root-mean-square amplitude into the whole dBFS this
    /// stores, with digital silence reported as the same floor
    /// `EmptyTranscriptPolicy` uses rather than as minus infinity.
    public static func decibels(rms: Float) -> Int8 {
        guard rms > 0 else { return Int8(EmptyTranscriptPolicy.silenceFloorDBFS) }
        let value = (20 * log10(Double(rms))).rounded()
        return Int8(max(EmptyTranscriptPolicy.silenceFloorDBFS, min(0, value)))
    }
}
