import Foundation

/// What the audio under one transcript segment holds.
///
/// `speechProbability` is a voice activity detector's highest reading anywhere
/// in the span. The two level figures are the loudest window on each track, in
/// dBFS. A meeting with one track leaves the far end nil, and so does a span
/// the far end's track never reached.
public struct SpeechReading: Sendable, Equatable {
    /// The detector's highest reading over the span, or nil where no detector
    /// ran.
    public var speechProbability: Double?
    /// The loudest window on the track the segment came from.
    public var loudestLocalDB: Double
    /// The loudest window on the other track over the same span.
    public var loudestFarDB: Double?

    public init(speechProbability: Double?, loudestLocalDB: Double, loudestFarDB: Double? = nil) {
        self.speechProbability = speechProbability
        self.loudestLocalDB = loudestLocalDB
        self.loudestFarDB = loudestFarDB
    }
}

/// Whether the local user said the words a transcription backend wrote on their
/// track.
///
/// A speech model handed a microphone track that is mostly not speech invents
/// filler for the parts that are not, and the invention is billed, recorded and
/// assembled like any other answer. Over four meetings on disk, labelled by
/// hand, 181 of the 222 segments on the local user's track were words nobody
/// said. One 29-minute meeting held 37 of them after the user's last real
/// sentence at 4:11, among them "We'll be right back.", "Thanks for watching!"
/// and "Good evening.", which is caption boilerplate from the model's training
/// data. A second meeting's whole local track was 125 consecutive segments
/// reading " ♪". A third produced "Thank you." six times and "Terima kasih."
/// once for a user who never spoke.
///
/// Two measures decide. The text has to hold words at all, which is what a run
/// of " ♪" fails. And a voice activity detector has to fire somewhere in the
/// span, which is what fabrication over silence fails: two segments in the
/// 29-minute meeting sit on audio Silero scores 0.000 and 0.002.
///
/// The far end coming back through the speakers is not judged here any more.
/// It used to be, by comparing the two tracks' levels and by measuring how much
/// of the microphone a filtered copy of the far end accounted for, and both
/// were guesses about whose voice the microphone held. Guessing wrong deleted
/// the user: on a Slack huddle of 3 September 2026 every one of the 3957 words
/// they said was dropped as leakage. The far end is now subtracted out of the
/// microphone before transcription, by `MicrophoneCleaner`, so what reaches
/// this policy holds the user and nothing else, and the detector's reading on
/// it means what it says.
public enum LocalSpeechPolicy {
    /// The detector reading a span needs to reach somewhere inside it.
    ///
    /// Silero's conventional speech threshold. Measured over the labelled
    /// segments, every genuine one reaches at least 0.54 and eight fabrications
    /// never pass 0.5. Raising it to FluidAudio's own default of 0.85 removes
    /// one more fabrication and costs one more genuine segment, so it stays at
    /// the conventional value.
    public static let speechProbability = 0.5

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
        // No detector ran, so nothing can say the words are invented and the
        // segment is kept. Dropping it instead would delete a meeting's local
        // track on a machine where the model is missing.
        if let probability = reading.speechProbability, probability < speechProbability {
            return .notSpoken
        }
        return .spoken
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
