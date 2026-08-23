import Foundation

/// Applies the boundaries a person put in the transcript.
///
/// The diarization behind a line is immutable and stays that way. A cut is held
/// in `speakers.map.json` beside the corrections, and the transcript is divided
/// here, on the way to being read, so the panel, the markdown and the plain text
/// all see the same lines and nothing on disk is rewritten.
///
/// Division happens at a word, not at a proportion of the text. A piece's span
/// is what a correction on it hands to voice memory, and a span guessed from
/// character positions would enrol seconds of somebody else's voice into the
/// corrected person's profile. A line whose backend reported no word timings is
/// therefore left whole.
public enum LineDivision {
    /// Divides every line the cuts fall inside, keeping the order.
    public static func apply(_ cuts: [LineCut], to utterances: [Utterance]) -> [Utterance] {
        guard !cuts.isEmpty else { return utterances }
        return utterances.flatMap { divide($0, at: cuts) }
    }

    /// One line as its pieces, or as itself where nothing divides it.
    public static func divide(_ utterance: Utterance, at cuts: [LineCut]) -> [Utterance] {
        let dividing = cuts.filter { $0.divides(utterance) }.sorted { $0.atSeconds < $1.atSeconds }
        guard !dividing.isEmpty, let words = utterance.words, words.count > 1 else {
            return [utterance]
        }
        var boundaries: [Int] = []
        for cut in dividing {
            // The first word that starts at or after the cut. A word straddling
            // the moment stays with the piece it started in, because that is
            // where its audio began.
            guard let index = words.firstIndex(where: { $0.start >= cut.atSeconds }),
                  index > 0, index < words.count, boundaries.last != index
            else { continue }
            boundaries.append(index)
        }
        guard !boundaries.isEmpty else { return [utterance] }

        var pieces: [Utterance] = []
        for (offset, start) in ([0] + boundaries).enumerated() {
            let end = offset < boundaries.count ? boundaries[offset] : words.count
            let slice = Array(words[start..<end])
            guard let first = slice.first, let last = slice.last else { continue }
            let text = slice.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            // The outer edges keep the line's own times. A decoder's first word
            // often starts a moment after the segment does, and shrinking the
            // line would leave that audio belonging to nobody.
            let pieceStart = start == 0 ? utterance.start : first.start
            let pieceEnd = end == words.count ? utterance.end : last.end
            pieces.append(Utterance(
                id: Utterance.identifier(
                    chunkID: utterance.chunkID, track: utterance.track,
                    start: pieceStart, end: pieceEnd
                ),
                start: pieceStart,
                end: max(pieceEnd, pieceStart + 0.001),
                track: utterance.track,
                rawSpeakerLabel: utterance.rawSpeakerLabel,
                speakerKey: utterance.speakerKey,
                text: text,
                chunkID: utterance.chunkID,
                model: utterance.model,
                words: slice
            ))
        }
        return pieces.count > 1 ? pieces : [utterance]
    }

    /// Where a line would divide for a cut at this moment, as the moment the
    /// division would actually land on.
    ///
    /// The view asks before it writes, so a click between two words records the
    /// boundary the reader saw rather than the pixel they hit. Nil when the line
    /// carries no timings, or when the moment is already a boundary.
    public static func boundary(in utterance: Utterance, near seconds: Double) -> Double? {
        guard let words = utterance.words, words.count > 1 else { return nil }
        guard let index = words.firstIndex(where: { $0.start >= seconds }),
              index > 0, index < words.count
        else { return nil }
        return words[index].start
    }
}
