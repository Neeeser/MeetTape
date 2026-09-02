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
    /// How much of each window's microphone energy a filtered copy of the far
    /// end accounts for, in tenths of a decibel. Empty for a meeting with one
    /// track, and for every meeting measured before this pass existed.
    ///
    /// Tenths rather than whole decibels because the readings that matter are
    /// fractions of one: genuine speech reads 0.01 dB and the gate drops at 0.4.
    public var micEchoReturnLoss: [Int16]
    /// What produced `micSpeech`, as provenance. Nil where nothing did.
    public var detector: String?

    public init(
        version: Int = SpeechEvidence.currentVersion,
        levelWindowSeconds: Double,
        speechWindowSeconds: Double,
        micLevels: [Int8],
        remoteLevels: [Int8] = [],
        micSpeech: [Int8] = [],
        micEchoReturnLoss: [Int16] = [],
        detector: String? = nil
    ) {
        self.version = version
        self.levelWindowSeconds = levelWindowSeconds
        self.speechWindowSeconds = speechWindowSeconds
        self.micLevels = micLevels
        self.remoteLevels = remoteLevels
        self.micSpeech = micSpeech
        self.micEchoReturnLoss = micEchoReturnLoss
        self.detector = detector
    }

    /// Decoded by hand only so that a file written before the echo pass existed
    /// still reads. Every meeting already on disk has no echo series, and a
    /// synthesised decoder would reject the file rather than leave the series
    /// empty.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        levelWindowSeconds = try container.decode(Double.self, forKey: .levelWindowSeconds)
        speechWindowSeconds = try container.decode(Double.self, forKey: .speechWindowSeconds)
        micLevels = try container.decode([Int8].self, forKey: .micLevels)
        remoteLevels = try container.decodeIfPresent([Int8].self, forKey: .remoteLevels) ?? []
        micSpeech = try container.decodeIfPresent([Int8].self, forKey: .micSpeech) ?? []
        micEchoReturnLoss =
            try container.decodeIfPresent([Int16].self, forKey: .micEchoReturnLoss) ?? []
        detector = try container.decodeIfPresent(String.self, forKey: .detector)
    }

    /// The share of far-end windows that has to rise above the silence floor
    /// before the far end counts as recorded rather than merely present.
    ///
    /// Measured over the twenty recordings on disk carrying speech evidence.
    /// The nineteen whose tap worked rise above the floor in 62.3% to 99.6% of
    /// their windows; the one whose tap produced nothing reads 0 of 7469. There
    /// is no middle, so this only has to sit inside a gap that wide, and it
    /// sits 62x below the lowest working recording so that a tap which died
    /// part way through still reads as recorded.
    public static let farEndSignalShare = 0.01

    /// Whether the far-end track holds anything at all.
    ///
    /// `remoteLevels` being non-empty says a track was recorded, not that
    /// anything reached it. A CoreAudio process tap delivers buffers at full
    /// rate whether or not the tapped application is emitting, because the
    /// aggregate device is clocked by its output sub-device, so a tap bound to
    /// a silent application writes hours of digital zero and every window then
    /// reads the floor `decibels(rms:)` clamps to. One meeting on disk is
    /// exactly that: 7469 windows, all -120.
    ///
    /// Everything that calls the microphone the local user's own track depends
    /// on the far end being somewhere else, so each of those questions has to
    /// ask this one first.
    public var farEndCarriesSignal: Bool {
        guard !remoteLevels.isEmpty else { return false }
        let floor = Int8(EmptyTranscriptPolicy.silenceFloorDBFS)
        let above = remoteLevels.reduce(into: 0) { count, level in
            if level > floor { count += 1 }
        }
        return Double(above) / Double(remoteLevels.count) >= Self.farEndSignalShare
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
        // A far end that never rose above the floor is not a reference. Reading
        // it as one makes every comparison against it trivially true: the
        // microphone outreads -120 dB everywhere, and a filtered copy of
        // silence accounts for none of the microphone's energy, so the level
        // and echo clauses both answer yes to whatever they are asked. The
        // honest shape for it is the one-track shape.
        let carriesSignal = farEndCarriesSignal
        let far = carriesSignal
            ? span(remoteLevels, windowSeconds: levelWindowSeconds, from: start, to: end)
            : nil
        let probability = span(micSpeech, windowSeconds: speechWindowSeconds, from: start, to: end)
            .flatMap { $0.max() }
            .map { Double($0) / 100 }
        let echo = carriesSignal ? echoReturnLoss(from: start, to: end) : nil
        guard let far, let loudestFar = far.max() else {
            return SpeechReading(
                speechProbability: probability, loudestLocalDB: Double(loudestLocal),
                echoReturnLossDB: echo
            )
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
            medianDifferenceDB: median,
            echoReturnLossDB: echo
        )
    }

    /// The echo return loss over a span, weighted by where the microphone's
    /// energy actually is.
    ///
    /// A segment's windows are not equally worth measuring. Backend segment
    /// boundaries are approximate and routinely take in a beat of silence either
    /// side of the words, and a plain average would let that silence talk down
    /// the measurement of the words. Weighting by the window's own energy is
    /// what makes a loud second surrounded by quiet ones report the loud second.
    private func echoReturnLoss(from start: Double, to end: Double) -> Double? {
        guard !micEchoReturnLoss.isEmpty,
              let echo = span(
                  micEchoReturnLoss, windowSeconds: levelWindowSeconds, from: start, to: end
              ),
              let levels = span(micLevels, windowSeconds: levelWindowSeconds, from: start, to: end)
        else { return nil }
        var weighted = 0.0
        var total = 0.0
        // Zipped rather than indexed: both are slices of the whole recording, and
        // the echo series ends where the far end's track did.
        for (value, level) in zip(echo, levels) {
            let weight = pow(10, Double(level) / 10)
            weighted += weight * Double(value) / 10
            total += weight
        }
        guard total > 0 else { return nil }
        return weighted / total
    }

    /// The samples covering `[start, end)`, or nil where the series is empty or
    /// the span falls outside it. At least one sample where the span is shorter
    /// than a window.
    private func span<Value>(
        _ values: [Value], windowSeconds: Double, from start: Double, to end: Double
    ) -> ArraySlice<Value>? {
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
