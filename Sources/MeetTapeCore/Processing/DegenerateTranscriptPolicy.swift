import Foundation

/// Whether a chunk's text is speech or a decoder that started looping.
///
/// A speech model given a window with little in it can fall into repeating one
/// phrase for the length of the window. Six of sixteen chunks of ES2003a came
/// back with the same fabricated paragraph, 438 invented words against a
/// 386-word reference, and the meeting reported success: 266 insertions, 153
/// repeated 8-grams and 193% DER, all of it downstream of text nobody said.
///
/// A loop is visible in the text alone. Ordinary conversation almost never says
/// the same five words twice in one chunk, and a loop says little else.
public enum DegenerateTranscriptPolicy {
    /// The phrase length the measure counts. Five words is long enough that
    /// speech repeats it by accident only rarely and short enough to catch a
    /// loop whose wording drifts.
    public static let phraseWords = 5

    /// Share of a chunk's phrases that may be ones it has already said. A
    /// six-minute AMI transcript repeats about 2% of its 8-grams, so half is
    /// far above anything conversation produces and far below a loop, which
    /// runs above 0.8.
    public static let repeatedShareLimit = 0.5

    /// Below this the measure has too few phrases to mean anything, and a short
    /// chunk cannot hold much fabrication either.
    public static let minimumWords = 40

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
    /// somewhere else in the same chunk. Zero for a chunk too short to measure.
    public static func repeatedShare(of text: String) -> Double {
        let words = TextSimilarity.normalise(text)
        guard words.count >= minimumWords, words.count >= phraseWords else { return 0 }
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
