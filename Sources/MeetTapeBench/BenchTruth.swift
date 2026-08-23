import Foundation

/// The reference a benchmark case is scored against.
///
/// Written by `scripts/build-bench-truth.py` from the AMI manual annotations
/// and committed under `Benchmarks/ground-truth`. It carries no audio: a case
/// names a window on a published recording, and the harness cuts that window
/// itself.
public struct BenchTruth: Codable, Sendable, Equatable {
    public struct Word: Codable, Sendable, Equatable {
        /// Seconds from the start of the scored window.
        public var start: Double
        public var end: Double
        public var text: String
        /// The global AMI speaker identifier.
        public var speaker: String
        /// Cut off mid-word by the speaker. Excluded from the filler-stripped
        /// reference, where a partial word is noise rather than a miss.
        public var truncated: Bool

        public init(
            start: Double, end: Double, text: String, speaker: String, truncated: Bool
        ) {
            self.start = start
            self.end = end
            self.text = text
            self.speaker = speaker
            self.truncated = truncated
        }
    }

    public struct Turn: Codable, Sendable, Equatable {
        public var speaker: String
        public var start: Double
        public var end: Double

        public init(speaker: String, start: Double, end: Double) {
            self.speaker = speaker
            self.start = start
            self.end = end
        }
    }

    public var meeting: String
    /// The published recording the window is cut from.
    public var source: String
    /// Where the window starts in the recording. Absent means the whole file,
    /// which is what the long cases score.
    public var windowStart: Double?
    /// How long the scored span is. DER counts frames across it.
    public var windowSeconds: Double
    /// Share of the window's speech time carrying two or more voices at once.
    /// Reported alongside the scores because it is what separates one case's
    /// difficulty from another's.
    public var overlapRatio: Double?
    public var speakers: [String]
    public var agentToSpeaker: [String: String]
    public var words: [Word]
    public var turns: [Turn]

    public init(
        meeting: String, source: String, windowStart: Double?, windowSeconds: Double,
        speakers: [String], agentToSpeaker: [String: String],
        words: [Word], turns: [Turn], overlapRatio: Double? = nil
    ) {
        self.meeting = meeting
        self.source = source
        self.windowStart = windowStart
        self.windowSeconds = windowSeconds
        self.speakers = speakers
        self.agentToSpeaker = agentToSpeaker
        self.words = words
        self.turns = turns
        self.overlapRatio = overlapRatio
    }

    public static func read(from url: URL) throws -> BenchTruth {
        try JSONDecoder().decode(BenchTruth.self, from: Data(contentsOf: url))
    }
}

/// One line of a transcript, as the scorer needs it.
///
/// Deliberately not `Utterance`: the scorer is a measuring instrument and takes
/// the four fields it measures, so a control transcript can be written by hand
/// in a test without building a meeting folder.
public struct BenchUtterance: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public var speakerKey: String

    public init(start: Double, end: Double, text: String, speakerKey: String) {
        self.start = start
        self.end = end
        self.text = text
        self.speakerKey = speakerKey
    }
}
