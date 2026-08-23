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

    public var id: String { lines[0].id }
    public var speakerName: String { lines[0].speakerName }

    /// Groups consecutive lines with the same resolved name in the same
    /// recording. Names are only comparable within one recording: the two
    /// halves of a dropped call can both show "Speaker 1" and mean different
    /// people, so a block never crosses a recording boundary.
    public static func blocks(from lines: [CombinedLine]) -> [CombinedLineBlock] {
        var out: [CombinedLineBlock] = []
        for line in lines {
            if let last = out.last, last.lines[0].recordingID == line.recordingID,
                last.speakerName == line.speakerName {
                out[out.count - 1].lines.append(line)
            } else {
                out.append(CombinedLineBlock(lines: [line]))
            }
        }
        return out
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
