import Foundation

/// What the audio under one transcript segment holds, as the three measures
/// that separate a person speaking into their own microphone from everything
/// else a speech model writes words for.
///
/// `speechProbability` is a voice activity detector's highest reading anywhere
/// in the span. The two level figures are the loudest window on each track, in
/// dBFS, and `medianDifferenceDB` is the middle of the per-window differences
/// between them. A meeting with one track leaves the far end nil.
public struct SpeechReading: Sendable, Equatable {
    /// The detector's highest reading over the span, or nil where no detector
    /// ran.
    public var speechProbability: Double?
    /// The loudest window on the track the segment came from.
    public var loudestLocalDB: Double
    /// The loudest window on the other track over the same span.
    public var loudestFarDB: Double?
    /// The middle of the per-window differences, local minus far.
    public var medianDifferenceDB: Double?

    public init(
        speechProbability: Double?,
        loudestLocalDB: Double,
        loudestFarDB: Double? = nil,
        medianDifferenceDB: Double? = nil
    ) {
        self.speechProbability = speechProbability
        self.loudestLocalDB = loudestLocalDB
        self.loudestFarDB = loudestFarDB
        self.medianDifferenceDB = medianDifferenceDB
    }
}

/// Whether the local user said the words a transcription backend wrote on their
/// track.
///
/// A speech model handed a microphone track that is mostly not speech invents
/// filler for the parts that are not, and the invention is billed, recorded and
/// assembled like any other answer. Measured over five meetings on disk, 179 of
/// 222 segments on the local user's track were words nobody said. One 29-minute
/// meeting held 36 fabrications after the user's last real sentence at 4:11,
/// among them "We'll be right back.", "Thanks for watching!" and "Good
/// evening.", which is caption boilerplate from the model's training data. A
/// second meeting's whole local track was 125 consecutive segments reading
/// " ♪". A third produced "Thank you." six times and "Terima kasih." once for a
/// user who never spoke.
///
/// Every existing guard is blind to it. `EmptyTranscriptPolicy` asks whether the
/// response was empty and it was not. `DegenerateTranscriptPolicy` asks whether
/// one phrase repeats and each fabrication is different text. The assembler's
/// echo scan asks whether the far end already said it and the far end did not.
/// Nothing compared a returned segment against the audio underneath it.
///
/// Three measures decide, because each one is blind to what the others catch.
/// The text has to hold words at all, which is what a run of " ♪" fails. A
/// voice activity detector has to fire somewhere in the span, which is what
/// fabrication over true silence fails: two segments in the 29-minute meeting
/// sit on audio Silero scores 0.000 and 0.002. And the local user has to be
/// louder than the far end, which is what leakage fails. Leakage is the case
/// the detector cannot judge, because the far end coming back through the
/// speakers into the microphone is speech and the detector correctly says so:
/// on its own the detector removed 80 of 179 fabrications, worse than the level
/// comparison alone.
///
/// Together the three keep 39 of 41 genuine segments and remove 178 of 179
/// invented ones. The two genuine losses are backchannels said while the far end
/// was talking, "yeah" and "Yeah.", where the microphone really does hold more
/// of the far end than of the user. That is the side to be wrong on: a
/// fabricated sentence attributed to the user is worse than a missing "yeah".
public enum LocalSpeechPolicy {
    /// The detector reading a span needs to reach somewhere inside it.
    ///
    /// Silero's conventional speech threshold. Measured over the labelled
    /// segments, every genuine one reaches at least 0.54 and eight fabrications
    /// never pass 0.5. Raising it to FluidAudio's own default of 0.85 removes
    /// one more fabrication and costs one more genuine segment, so it stays at
    /// the conventional value.
    public static let speechProbability = 0.5

    /// How far the local track's loudest window must sit above the far end's
    /// over most of the span for the segment to survive on sustained level
    /// alone.
    ///
    /// The two clauses catch different shapes. A short word spoken over the far
    /// end wins on its peak; a long turn during which the far end is quiet most
    /// of the time wins on the median. Ten decibels is where the genuine
    /// segments sit: 21 of 25 in the meeting that was audited read 22 dB or
    /// more, and every fabrication reads at most 1 dB.
    public static let sustainedMarginDB = 10.0

    public enum Decision: Sendable, Equatable {
        /// Assemble the segment.
        case spoken
        /// Drop it. The words are still in the raw transcript on disk, which
        /// nothing here rewrites.
        case notSpoken
    }

    /// - Parameters:
    ///   - text: the segment's text, exactly as the backend returned it.
    ///   - reading: what the audio under the segment holds.
    public static func decide(text: String, reading: SpeechReading) -> Decision {
        guard holdsWords(text) else { return .notSpoken }
        // No detector ran, so this clause cannot speak either way and the level
        // comparison decides alone. Skipping the segment instead would delete a
        // meeting's local track on a machine where the model is missing.
        if let probability = reading.speechProbability, probability < speechProbability {
            return .notSpoken
        }
        // One track, so there is no far end to be quieter than. Imported audio
        // and a meeting recorded without a tap both land here.
        guard let far = reading.loudestFarDB, let median = reading.medianDifferenceDB else {
            return .spoken
        }
        // At or above, not above. Two tracks reading the same level say nothing
        // about which one the sound came from, and a guard that deletes words
        // has to be the one carrying the doubt. Nothing measured landed on a
        // tie: the closest genuine segment reads 0.2 dB under the far end and
        // the closest fabricated one 1.3 dB over.
        return reading.loudestLocalDB >= far || median > sustainedMarginDB ? .spoken : .notSpoken
    }

    /// Whether the text is words rather than a transcription model's notation.
    ///
    /// One meeting's whole local track came back as 125 consecutive segments of
    /// " ♪", which `DegenerateTranscriptPolicy` scores at zero repetition
    /// because it strips everything that is not a letter or a digit before
    /// counting and is then left with nothing to count.
    public static func holdsWords(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .alphanumerics) != nil
    }
}
