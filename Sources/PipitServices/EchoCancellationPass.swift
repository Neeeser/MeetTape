import Foundation
import PipitAudio
import PipitCore

/// One run of the echo canceller over a recorded pair, block by block.
///
/// This is the alignment, the block loop and the measurement grid. Two callers
/// run it: `MicrophoneCleaner`, which keeps the cleaned samples and writes
/// them, and `EchoMeasurement`, which keeps only the levels. They share this
/// type so that a measurement describes the pass that ships. A second copy of
/// the loop would be a second copy of the offset arithmetic, and that
/// arithmetic has already been wrong once. Subtracting the two lead-ins the
/// other way round moves the pair by twice the offset and puts the echo in the
/// microphone ahead of the far end that caused it. No filter can model that,
/// and no outcome value reports it.
public struct EchoCancellationPass {
    /// The rate both tracks are read at, which is the rate every model above
    /// reads them at too.
    static let readFormat = AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1)
    /// Seconds one measurement window covers, matching the grid the speech
    /// evidence is already sampled on.
    static let windowSeconds = 0.25
    /// A track that never clears this in any window recorded nothing at all.
    static let referenceFloorDBFS = -80.0

    /// One quarter-second of the pass: how loud each track was, and what the
    /// canceller said it had removed by the end of it.
    ///
    /// The four travel together because none of them reads on its own.
    /// `farEndDBFS` decides whether the window is one the canceller can be
    /// judged on, `echoRemovedDB` is what it reported removing over that
    /// window, and the two microphone levels are what the window actually held
    /// before and after subtraction.
    ///
    /// What the canceller reported is not what it did, and keeping the two
    /// apart is the whole of the bypass rule. On the tone with no echo path in
    /// `AudioTests` the canceller reports 2.84 dB removed while taking 39.9 dB
    /// out of a microphone that holds only the user. The low reported figure is
    /// what says the filter never locked on, and that is the reason to throw
    /// its output away.
    public struct Window: Sendable, Equatable {
        public let farEndDBFS: Double
        public let echoRemovedDB: Double
        public let microphoneBeforeDBFS: Double
        public let microphoneAfterDBFS: Double

        public init(
            farEndDBFS: Double, echoRemovedDB: Double, microphoneBeforeDBFS: Double,
            microphoneAfterDBFS: Double
        ) {
            self.farEndDBFS = farEndDBFS
            self.echoRemovedDB = echoRemovedDB
            self.microphoneBeforeDBFS = microphoneBeforeDBFS
            self.microphoneAfterDBFS = microphoneAfterDBFS
        }
    }

    struct Result {
        var frames: Int64
        var windows: [Window]
    }

    /// How far the far end has to move to line up with the microphone.
    ///
    /// The microphone is read from its own first frame, so a position in the
    /// cleaned file is the same position in the recording and every timestamp
    /// downstream still lands where it did. The far end is moved onto that
    /// clock. `leadIn` says how long after the earliest track each one started,
    /// so their difference is how far the far end has to move: a far end that
    /// started later is padded with the silence Pipit did not record, and one
    /// that started earlier has that much of it read and thrown away.
    static func referenceOffset(timeline: RecordingTimeline) -> Double {
        timeline.leadIn(track: .remote) - timeline.leadIn(track: .mic)
    }

    /// Runs the canceller over the pair and hands each cleaned block to `sink`.
    ///
    /// `sink` receives the samples the microphone actually recorded, with the
    /// zero padding the canceller demanded on the final block already trimmed
    /// off. A caller that only wants the levels passes a sink that does
    /// nothing, and nothing is written anywhere.
    ///
    /// - Parameter referenceOffset: seconds the far end has to move to line up
    ///   with the microphone. `referenceOffset(timeline:)` is what a real run
    ///   uses. A caller passing anything else is deliberately measuring a
    ///   misalignment.
    static func run(
        microphone: TrackAudioLocation, reference: TrackAudioLocation,
        referenceOffset: Double, sink: (ArraySlice<Float>) throws -> Void
    ) throws -> Result {
        guard let canceller = EchoCanceller(sampleRate: Int(readFormat.sampleRate)) else {
            throw ProcessingError.localProcessingFailed(
                reason: "the echo canceller refused \(readFormat.sampleRate) Hz",
                retryable: false
            )
        }
        let block = canceller.blockFrames
        let windowFrames = Int((windowSeconds * readFormat.sampleRate).rounded())
        guard block > 0, windowFrames >= block else {
            throw ProcessingError.localProcessingFailed(
                reason: "the echo canceller reported a block of \(block) frames", retryable: false
            )
        }
        let blocksPerWindow = windowFrames / block

        guard let microphoneReader = TimelineTrackReader(
            location: microphone, format: readFormat, offsetSeconds: 0
        ), let referenceReader = TimelineTrackReader(
            location: reference, format: readFormat, offsetSeconds: referenceOffset
        ) else {
            throw ProcessingError.audioUnreadable(path: microphone.directory.lastPathComponent)
        }

        var result = Result(frames: 0, windows: [])
        var blocksInWindow = 0
        var farEndSquares = 0.0
        var micBeforeSquares = 0.0
        var micAfterSquares = 0.0
        var samplesInWindow = 0

        while true {
            var samples = try microphoneReader.next(count: block)
            if samples.isEmpty { break }
            // The canceller takes whole blocks. The tail of the recording is
            // padded to one and trimmed back off before it reaches the sink.
            let recorded = samples.count
            if recorded < block {
                samples += [Float](repeating: 0, count: block - recorded)
            }
            var played = try referenceReader.next(count: block)
            // The far end's tap can stop before the microphone does, and what
            // it did not record is silence.
            if played.count < block {
                played += [Float](repeating: 0, count: block - played.count)
            }
            micBeforeSquares += squares(samples)
            guard canceller.process(microphone: &samples, reference: played) else {
                throw ProcessingError.localProcessingFailed(
                    reason: "the echo canceller refused a block of \(block) frames",
                    retryable: false
                )
            }
            micAfterSquares += squares(samples)

            // The only place the canceller's figure is read, and it is read on
            // the far side of a call that returned true. A block that was never
            // processed and a filter that has not locked on both reach Swift as
            // 0.0, and this is what keeps the first out of the median.
            farEndSquares += squares(played)
            samplesInWindow += block
            blocksInWindow += 1
            if blocksInWindow == blocksPerWindow {
                result.windows.append(Window(
                    farEndDBFS: decibels(squares: farEndSquares, count: samplesInWindow),
                    echoRemovedDB: canceller.echoRemovedDB,
                    microphoneBeforeDBFS: decibels(
                        squares: micBeforeSquares, count: samplesInWindow
                    ),
                    microphoneAfterDBFS: decibels(
                        squares: micAfterSquares, count: samplesInWindow
                    )
                ))
                blocksInWindow = 0
                farEndSquares = 0
                micBeforeSquares = 0
                micAfterSquares = 0
                samplesInWindow = 0
            }

            try sink(samples.prefix(recorded))
            result.frames += Int64(recorded)
        }
        return result
    }

    /// Whether the far end's track holds any audio at all.
    ///
    /// A track that never clears the floor in any window is one the tap opened
    /// on and recorded nothing through. An early exit rather than a rule of its
    /// own: a track this refuses has no window loud enough to count below
    /// either, so the answer is the same. What it saves is cancelling and
    /// encoding a two-hour meeting against silence before saying so.
    static func referenceHoldsAudio(_ location: TrackAudioLocation) throws -> Bool {
        guard let reader = TimelineTrackReader(
            location: location, format: readFormat, offsetSeconds: 0
        ) else { return false }
        let window = Int((windowSeconds * readFormat.sampleRate).rounded())
        while true {
            let samples = try reader.next(count: window)
            if samples.isEmpty { return false }
            if decibels(squares: squares(samples), count: samples.count) > referenceFloorDBFS {
                return true
            }
            if samples.count < window { return false }
        }
    }

    static func decibels(squares: Double, count: Int) -> Double {
        guard count > 0 else { return EmptyTranscriptPolicy.silenceFloorDBFS }
        let rms = (squares / Double(count)).squareRoot()
        guard rms > 0 else { return EmptyTranscriptPolicy.silenceFloorDBFS }
        return max(EmptyTranscriptPolicy.silenceFloorDBFS, 20 * log10(rms))
    }

    /// What one pass decided, and the figures it decided on.
    public struct Judgement: Equatable {
        public let outcome: CleaningOutcome
        public let reason: String
        /// Median of the canceller's own reported enhancement over the
        /// far-end-active windows. Informational: it reads near zero on real
        /// recordings the pass demonstrably cleaned, so nothing is decided
        /// on it.
        public let reportedMedianDB: Double
        public let activeWindows: Int
        public let microphoneFloorDBFS: Double
        /// Windows where the far end was quiet and the microphone held
        /// something, which is the user alone. The only class in which a
        /// level drop is a loss.
        public let userWindows: Int
        public let userHarmMedianDB: Double?
        /// Share of those windows that lost more than `notableLossDB`.
        public let userHarmShare: Double?
    }

    /// Windows of far-end activity the decision needs before it is made at all.
    ///
    /// Ten seconds. The canceller reports nothing for its first 2.5 s of
    /// far-end activity, and counting in far-end-active windows rather than in
    /// seconds of file is what makes the bound hold for a meeting whose far end
    /// stayed quiet for the first minute.
    public static let minimumActiveWindows = 40
    /// A window whose far-end level clears this had the far end playing in it.
    public static let farEndActiveDBFS = -60.0
    /// Windows of the user alone the harm figures need before they mean
    /// anything. Five seconds.
    public static let minimumUserWindows = 20
    /// How far above its own quietest twentieth a microphone has to be before a
    /// window counts as holding something. Speech at a desk runs 20 to 40 dB
    /// over the room it is in.
    public static let microphoneActivationMarginDB = 10.0
    /// The loss to the user's own windows above which the cleaned track is
    /// thrown away: the median drop, and the share of windows that dropped by
    /// more than `notableLossDB`.
    ///
    /// Measured over four recordings on speakers, two the canceller locked on
    /// to and two it reported nothing on: the user-only median moved 0.0 to
    /// 0.5 dB and 1% to 3% of windows lost more than 6 dB. The tone fixtures
    /// gate two boundary windows of twenty-six, which is 8%. The
    /// continuous-tone fixture in `AudioTests`, where the suppressor has an
    /// unrelated reference and nothing else, takes 39.9 dB out of every
    /// window. The limits sit between.
    public static let harmMedianLimitDB = 2.0
    public static let notableLossDB = 10.0
    public static let harmShareLimit = 0.10

    /// Decides whether the pass is worth keeping, from what it measured.
    ///
    /// The canceller's own enhancement figure used to decide this, against a
    /// 6 dB threshold set from tones. On real recordings it read 0.2 to 1.8 dB
    /// on calls the pass had cleaned by 4 to 18 dB in the windows where the far
    /// end played over the user, so the rule refused the meetings it would
    /// have helped. What the bypass exists to prevent is damage to the user's
    /// own speech, and that is measured directly: over the windows where the
    /// far end was quiet and the microphone held something, the level must not
    /// have dropped.
    public static func judge(windows: [Window]) -> Judgement {
        let active = windows.filter { $0.farEndDBFS > farEndActiveDBFS }
        let reported = median(of: active.map(\.echoRemovedDB))
        let quiet = percentile(windows.map(\.microphoneBeforeDBFS), 0.05)
        let floor = microphoneFloorDBFS(quietWindowDBFS: quiet)
        let user = windows.filter {
            $0.farEndDBFS <= farEndActiveDBFS && $0.microphoneBeforeDBFS > floor
        }
        let harm = user.map { $0.microphoneBeforeDBFS - $0.microphoneAfterDBFS }
        let judgeable = user.count >= minimumUserWindows
        let harmMedian = judgeable ? percentile(harm, 0.5) : nil
        let harmShare = judgeable
            ? Double(harm.filter { $0 > notableLossDB }.count) / Double(harm.count) : nil
        func judgement(_ outcome: CleaningOutcome, _ reason: String) -> Judgement {
            Judgement(
                outcome: outcome, reason: reason, reportedMedianDB: reported,
                activeWindows: active.count, microphoneFloorDBFS: floor,
                userWindows: user.count, userHarmMedianDB: harmMedian, userHarmShare: harmShare
            )
        }
        guard active.count >= minimumActiveWindows else {
            return judgement(
                .skippedNoReference,
                "the far end was above \(fixed(farEndActiveDBFS)) dBFS in \(active.count) "
                    + "windows, and the decision needs \(minimumActiveWindows)"
            )
        }
        if let harmMedian, let harmShare,
           harmMedian > harmMedianLimitDB || harmShare > harmShareLimit {
            return judgement(
                .bypassedNoEchoPath,
                "the user's own windows lost \(fixed(harmMedian)) dB at the median, and "
                    + "\(Int((harmShare * 100).rounded()))% of them more than "
                    + "\(fixed(notableLossDB)) dB, over \(user.count) windows"
            )
        }
        let held = harmMedian.map { "lost \(fixed($0)) dB at the median" }
            ?? "held too few windows to judge"
        return judgement(
            .cleaned,
            "the user's own windows \(held) over \(user.count) windows, and the far end "
                + "played in \(active.count)"
        )
    }

    /// The level the microphone clears to count as holding something: this
    /// recording's own quietest twentieth plus `microphoneActivationMarginDB`,
    /// and never below the far end's floor, because nothing under it is speech
    /// either way.
    public static func microphoneFloorDBFS(quietWindowDBFS: Double?) -> Double {
        guard let quietWindowDBFS else { return farEndActiveDBFS }
        return max(farEndActiveDBFS, quietWindowDBFS + microphoneActivationMarginDB)
    }

    /// The value at a fraction of the way up the sorted series, by nearest
    /// rank, so every figure reported is a window that actually happened.
    public static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }

    private static func fixed(_ value: Double) -> String { String(format: "%.1f", value) }

    static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private static func squares(_ samples: [Float]) -> Double {
        samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    }
}
