import Foundation

/// One conversation that was recorded more than once.
///
/// A call that drops and is rejoined produces two recordings. They are two
/// recordings on disk and stay that way: each keeps its own segments, manifest,
/// raw transcription, raw diarization and speaker map, because the second one is
/// the only copy of the second half of the call and nothing derived from it may
/// depend on the first still being where it was.
///
/// What is shared is the reading of them. The user had one meeting, so Recent
/// Meetings shows one row, opening it shows one transcript in time order, and
/// the association can be undone later without moving a byte of audio.
public struct LogicalMeeting: Sendable {
    /// The recording the conversation started with. Its identifier is the
    /// logical meeting's identifier.
    public var primary: RecordedMeeting
    /// What was recorded after each reconnection, in the order it happened.
    public var continuations: [RecordedMeeting]

    public init(primary: RecordedMeeting, continuations: [RecordedMeeting]) {
        self.primary = primary
        self.continuations = continuations.sorted {
            $0.metadata.startedAt < $1.metadata.startedAt
        }
    }

    public var id: String { primary.metadata.id }

    /// Every recording, earliest first.
    public var recordings: [RecordedMeeting] { [primary] + continuations }

    /// How long the conversation ran, counting only what was recorded.
    ///
    /// Summed rather than measured end to end: the gap between the drop and the
    /// rejoin is not on any tape, and reporting it as duration would say a
    /// meeting is longer than the audio it holds.
    public var durationSeconds: Double {
        recordings.reduce(0) { $0 + $1.metadata.durationSeconds }
    }

    public var startedAt: Date { primary.metadata.startedAt }

    public var isSplit: Bool { !continuations.isEmpty }
}

/// One recording on disk: its metadata and the store that reads its files.
public struct RecordedMeeting: Sendable {
    public var metadata: MeetingMetadata
    public var store: MeetingStore

    public init(metadata: MeetingMetadata, store: MeetingStore) {
        self.metadata = metadata
        self.store = store
    }
}

/// One line of a logical meeting's transcript, with the recording it came from.
///
/// Carries a resolved name rather than a speaker key. Keys are only meaningful
/// inside one recording's own diarization, so a combined view that shared them
/// would merge two recordings' `remote-001_speaker_00` into one person. Each
/// line is resolved through its own recording's speaker map, which is also what
/// keeps a correction made in one half from reaching into the other.
public struct CombinedLine: Sendable, Equatable, Identifiable {
    public var recordingID: String
    public var utterance: Utterance
    public var speakerName: String
    /// Seconds from the start of the first recording, so lines from both halves
    /// sort into one sequence.
    public var timelineStart: Double
    /// Whether a person set the speaker on this line.
    public var isCorrected: Bool

    public var id: String { "\(recordingID)/\(utterance.id)" }

    public init(
        recordingID: String, utterance: Utterance, speakerName: String,
        timelineStart: Double, isCorrected: Bool = false
    ) {
        self.recordingID = recordingID
        self.utterance = utterance
        self.speakerName = speakerName
        self.timelineStart = timelineStart
        self.isCorrected = isCorrected
    }
}

/// Consecutive lines spoken by the same person, for display.
///
/// The diarizer prefers splitting over merging and the assembler caps a turn at
/// 30 seconds, so one person talking often arrives as several lines in a row.
/// Grouping happens here, at render time, rather than in the stored transcript:
/// the lines keep their identities, so a correction still targets one line.
public struct CombinedLineBlock: Sendable, Equatable, Identifiable {
    /// Never empty.
    public var lines: [CombinedLine]

    public init(lines: [CombinedLine]) {
        // Every accessor reads the first line, so an empty block is not a
        // block. Caught here rather than at whichever property is read first.
        precondition(!lines.isEmpty, "a block holds at least one line")
        self.lines = lines
    }

    public var id: String { lines[0].id }
    public var speakerName: String { lines[0].speakerName }
    /// Where the block sits on the conversation's timeline, which is what the
    /// header reads.
    public var timelineStart: Double { lines[0].timelineStart }
    public var timelineEnd: Double {
        lines.map { $0.timelineStart + ($0.utterance.end - $0.utterance.start) }.max()
            ?? timelineStart
    }
    /// The recording these lines came from. A block never spans two, because
    /// names are only comparable inside one recording's diarization.
    public var recordingID: String { lines[0].recordingID }
    public var track: CaptureTrack { lines[0].utterance.track }
    /// On the recording's own timeline, which is where a boundary is written.
    public var startSeconds: Double { lines[0].utterance.start }
    public var endSeconds: Double { lines.map(\.utterance.end).max() ?? startSeconds }

    /// Groups consecutive lines with the same resolved name, in the same
    /// recording and on the same track. Names are only comparable within one
    /// recording: the two halves of a dropped call can both show "Speaker 1"
    /// and mean different people. Track matters for the same reason, since the
    /// microphone and the far end are diarized separately.
    public static func blocks(from lines: [CombinedLine]) -> [CombinedLineBlock] {
        var out: [CombinedLineBlock] = []
        for line in lines {
            if let last = out.last, last.lines[0].recordingID == line.recordingID,
                last.lines[0].utterance.track == line.utterance.track,
                last.speakerName == line.speakerName {
                out[out.count - 1].lines.append(line)
            } else {
                out.append(CombinedLineBlock(lines: [line]))
            }
        }
        return out
    }

    /// The block as one paragraph, with the moment behind every word in it.
    ///
    /// The text is the lines' own text joined, so what the reader selects is
    /// what the transcript says. Each word is located inside it by searching
    /// forward from the last one, which either finds the word where it is or
    /// finds nothing, in which case the line contributes one span covering the
    /// whole of it and can still be divided at its edges. Nothing here
    /// estimates a position from a proportion of the characters: the spans
    /// decide where a boundary is written, and a boundary decides which seconds
    /// of audio a correction hands to a voice profile.
    public func paragraph() -> (text: String, spans: [TranscriptWordSpan]) {
        var text = ""
        var spans: [TranscriptWordSpan] = []
        for line in lines {
            let lineText = line.utterance.text
            guard !lineText.isEmpty else { continue }
            if !text.isEmpty { text += " " }
            let offset = (text as NSString).length
            text += lineText
            spans.append(contentsOf: TranscriptWordSpan.spans(
                in: lineText, offset: offset, of: line
            ))
        }
        return (text, spans)
    }
}

/// One word of a rendered block: where it is in the paragraph and when it was
/// spoken, in the recording's own coordinates.
public struct TranscriptWordSpan: Sendable, Equatable {
    /// UTF-16 offset into the paragraph, so it addresses the same characters
    /// AppKit does.
    public var location: Int
    public var length: Int
    public var startSeconds: Double
    public var endSeconds: Double
    public var lineID: String

    public init(
        location: Int, length: Int, startSeconds: Double, endSeconds: Double, lineID: String
    ) {
        self.location = location
        self.length = length
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.lineID = lineID
    }

    static func spans(
        in lineText: String, offset: Int, of line: CombinedLine
    ) -> [TranscriptWordSpan] {
        let whole = [TranscriptWordSpan(
            location: offset, length: (lineText as NSString).length,
            startSeconds: line.utterance.start, endSeconds: line.utterance.end,
            lineID: line.id
        )]
        guard let words = line.utterance.words, !words.isEmpty else { return whole }
        let text = lineText as NSString
        var found: [TranscriptWordSpan] = []
        var cursor = 0
        for word in words {
            let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, cursor < text.length else { continue }
            let range = text.range(
                of: token, options: .literal,
                range: NSRange(location: cursor, length: text.length - cursor)
            )
            // The words and the text disagree, which no backend should produce
            // and one may. The line then divides at its edges and not inside,
            // rather than at a position nothing verified.
            guard range.location != NSNotFound else { return whole }
            found.append(TranscriptWordSpan(
                location: offset + range.location, length: range.length,
                startSeconds: word.start, endSeconds: word.end, lineID: line.id
            ))
            cursor = range.location + range.length
        }
        return found.isEmpty ? whole : found
    }
}

extension LogicalMeeting {
    /// Every recording's transcript, in the order the conversation happened.
    ///
    /// Each recording's own timeline starts at zero, so the lines are placed by
    /// how far each recording started after the first. Nothing is rewritten: the
    /// offset is applied here and the files keep their own coordinates, which is
    /// what lets a continuation be detached later and still read correctly on
    /// its own.
    public func combinedTranscript() -> [CombinedLine] {
        var out: [CombinedLine] = []
        for recording in recordings {
            guard let transcript = (try? recording.store.readCanonicalTranscript()) ?? nil
            else { continue }
            // Already divided by the store, so a piece is named on its own
            // rather than on the line it was cut out of.
            let lines = transcript.utterances
            let speakers = (try? recording.store.readSpeakerMap()) ?? SpeakerMap()
            let offset = recording.metadata.startedAt.timeIntervalSince(startedAt)
            for utterance in lines {
                out.append(CombinedLine(
                    recordingID: recording.metadata.id,
                    utterance: utterance,
                    speakerName: speakers.resolvedName(for: utterance),
                    timelineStart: offset + utterance.start,
                    isCorrected: speakers.hasOverride(for: utterance)
                ))
            }
        }
        out.sort { $0.timelineStart < $1.timelineStart }
        return out
    }

    /// Whether every recording has finished processing.
    public var isFullyProcessed: Bool {
        recordings.allSatisfy { $0.metadata.processing.state == .complete }
    }
}
