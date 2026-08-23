import Foundation

/// How loud a piece of audio is, as the two measures that separate speech from
/// an idle input: the loudest sample and the average level, both in dBFS.
///
/// Digital silence has no logarithm, so both are reported as
/// `EmptyTranscriptPolicy.silenceFloorDBFS` rather than as minus infinity.
public struct AudioLevel: Sendable, Equatable {
    public var peakDBFS: Double
    public var rmsDBFS: Double

    public init(peakDBFS: Double, rmsDBFS: Double) {
        self.peakDBFS = peakDBFS
        self.rmsDBFS = rmsDBFS
    }
}

/// Whether a transcription response that carried neither segments nor text is a
/// finished chunk or a failed one.
///
/// A backend that returns nothing is indistinguishable, from the response
/// alone, from audio that genuinely holds no speech. Filing both as success
/// cost 47% of one meeting's words: a 168-second chunk of ordinary conversation
/// came back as `{"text":""}` with HTTP 200, was billed, was appended as a
/// completed chunk, and the meeting reported `complete`. The audio decides
/// which of the two it was.
public enum EmptyTranscriptPolicy {
    /// Reported for audio with no signal at all, where dBFS is undefined.
    public static let silenceFloorDBFS: Double = -120

    /// Peak level at or below which a chunk holds no speech to lose.
    ///
    /// -50 dBFS is about 0.3% of full scale. A muted microphone, a paused
    /// meeting application and a lossily encoded silent chunk all sit far below
    /// it; the chunk that was silently dropped measured -39 dB *mean*, with
    /// peaks well above that. The gap between the two is more than 10 dB, so
    /// neither ordinary room tone nor quiet speech reads as silence here.
    public static let silentPeakDBFS: Double = -50

    /// Mean level required alongside the peak, so that one stray sample of
    /// interference cannot make an otherwise empty chunk fail forever.
    public static let silentRMSDBFS: Double = -60

    public enum Decision: Sendable, Equatable {
        /// Record the chunk as it came back.
        case accept
        /// Fail the chunk so the stage retries and, if it keeps failing, the
        /// meeting is left failed and retryable rather than falsely complete.
        case fail
    }

    /// - Parameters:
    ///   - hasSegments: the response carried at least one segment.
    ///   - hasText: the response carried non-empty text.
    ///   - level: the level of the audio that was sent.
    public static func decide(hasSegments: Bool, hasText: Bool, level: AudioLevel) -> Decision {
        guard !hasSegments, !hasText else { return .accept }
        let silent = level.peakDBFS <= silentPeakDBFS && level.rmsDBFS <= silentRMSDBFS
        return silent ? .accept : .fail
    }
}
