import Foundation
import MeetTapeCore

/// Audio spans for a test enrolment.
///
/// Every stored vector has to name the audio it came from, so a test that
/// enrols one has to say what that audio was. Two clusters of one meeting are
/// two people, so each key gets its own lane on the timeline: without that,
/// enrolling a second cluster would overlap the first and retract it, and the
/// test would be measuring the fixture rather than the code.
enum VoiceEvidenceFixture {
    /// One contiguous span of `seconds`, in a lane of its own.
    static func evidence(
        meeting: String,
        cluster: String? = nil,
        seconds: Double,
        track: CaptureTrack = .remote,
        source: VoiceEnrollmentSource = .humanConfirmedCluster,
        start: Double? = nil
    ) -> [VoiceEvidence] {
        let begin = start ?? lane(cluster ?? source.rawValue)
        return [VoiceEvidence(
            meetingID: meeting,
            track: track,
            spans: [AudioSpan(start: begin, end: begin + max(seconds, 0.001))],
            confirmation: source,
            analysisID: nil,
            clusterID: cluster
        )]
    }

    /// A stable hour-wide lane per key. Deterministic across runs, which
    /// `hashValue` is not.
    static func lane(_ key: String) -> Double {
        var hash: UInt64 = 5_381
        for byte in key.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Double(hash % 997) * 3_600
    }
}
