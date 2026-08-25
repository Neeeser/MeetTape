import Foundation

/// Whether a chunk's text is speech or a decoder that started looping.
///
/// A speech model given a window with little in it can fall into repeating one
/// phrase for the length of the window. Five of sixteen chunks of ES2003a came
/// back with the same fabricated paragraph, 438 invented words against a
/// 386-word reference, and the meeting reported success: 266 insertions, 153
/// repeated 8-grams and 193% DER, all of it downstream of text nobody said.
///
/// A loop is visible in the text alone. Ordinary conversation almost never says
/// the same five words twice in one chunk, and a loop says little else.
///
/// The measure is a window's, not a meeting's: a chunk it fails is retried and
/// then dropped, and a whole track transcribed in one request is failed on
/// every attempt rather than dropped, because there dropping the one chunk
/// empties the meeting.
public enum DegenerateTranscriptPolicy {
    /// The phrase length the measure counts. Five words is long enough that
    /// speech repeats it by accident only rarely and short enough to catch a
    /// loop whose wording drifts.
    public static let phraseWords = 5

    /// Share of a chunk's phrases that may be ones it has already said.
    ///
    /// Measured over the sixteen chunks of ES2003a: the eleven that hold speech
    /// score between 0.00 and 0.03, and the five that came back with the same
    /// fabricated paragraph all score 0.28. The count of fabricated chunks
    /// varies from run to run, since a sampled decoder loops on some passes and
    /// not others; the separation between the two groups does not. A fifth is
    /// between them with room on both sides, and the cost of being wrong is one
    /// window retried and then dropped.
    public static let repeatedShareLimit = 0.2

    /// Below this the measure has too few phrases to mean anything, and a short
    /// chunk cannot hold much fabrication either.
    public static let minimumWords = 40

    /// Distinct words a chunk needs before its repetition is measured at all.
    ///
    /// Counting repeated phrase positions saturates on speech that is genuinely
    /// repetitive, because a speaker with few words to say repeats every phrase
    /// they have: 48 words of backchannel ("yeah yeah right yeah okay yeah
    /// right okay" six times) and somebody counting to ten four times both
    /// score 1.00 ungated, five times the limit, and 35 s of listening noise on
    /// a remote track clears the forty-word floor easily. The two cases part on
    /// vocabulary rather than on repetition: the backchannel window holds 3
    /// distinct words and the counting window 10, while the fabricated
    /// paragraph holds 36 of its 76 and ordinary dialogue 71 of 87. Twenty sits
    /// between with the nearest real case at half of it.
    ///
    /// The cost is a decoder that loops on a phrase of two or three words for a
    /// whole window, which reads as a small vocabulary and is kept. It is the
    /// side to be wrong on: that text is short, and the alternative deletes
    /// somebody who was listening.
    public static let minimumDistinctWords = 20

    public enum Decision: Sendable, Equatable {
        /// Record the chunk as it came back.
        case accept
        /// Fail the chunk so the stage retries, and so a chunk that keeps
        /// looping leaves the meeting failed and retryable rather than
        /// poisoning the transcript with invented words.
        case fail
    }

    public static func decide(text: String) -> Decision {
        repeatedShare(of: text) > repeatedShareLimit ? .fail : .accept
    }

    /// The share of the chunk's phrase positions holding a phrase that appears
    /// somewhere else in the same chunk. Zero for a chunk too short to measure,
    /// and zero for one whose vocabulary is too narrow for repetition to say
    /// anything: measured, the fabricated paragraph scores 0.28, ordinary
    /// dialogue 0.00, and the backchannel and counting windows 0.00 where
    /// counting positions alone gave them 1.00.
    public static func repeatedShare(of text: String) -> Double {
        let words = TextSimilarity.normalise(text)
        guard words.count >= minimumWords, words.count >= phraseWords else { return 0 }
        guard Set(words).count >= minimumDistinctWords else { return 0 }
        var counts: [String: Int] = [:]
        var phrases: [String] = []
        phrases.reserveCapacity(words.count - phraseWords + 1)
        for start in 0...(words.count - phraseWords) {
            let phrase = words[start..<(start + phraseWords)].joined(separator: " ")
            phrases.append(phrase)
            counts[phrase, default: 0] += 1
        }
        let repeated = phrases.filter { (counts[$0] ?? 0) > 1 }.count
        return Double(repeated) / Double(phrases.count)
    }
}
