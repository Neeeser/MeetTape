import Foundation

/// One calendar event, described without EventKit so the choice can be tested.
public struct CalendarCandidate: Sendable, Equatable {
    public var identifier: String
    public var title: String
    public var startDate: Date
    public var endDate: Date
    public var isAllDay: Bool
    /// Notes, location and URL joined together, which is where an invitation
    /// carries the meeting link or ID.
    public var haystack: String

    public init(
        identifier: String, title: String, startDate: Date, endDate: Date,
        isAllDay: Bool, haystack: String
    ) {
        self.identifier = identifier
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.haystack = haystack
    }

    public var durationSeconds: Double { endDate.timeIntervalSince(startDate) }
}

/// Which calendar event a recording belongs to.
///
/// A matching meeting URL or ID is decisive. Everything else is timing, and
/// timing alone is weak evidence: the calendar of a working day is full of
/// entries that contain a meeting without being it.
public enum CalendarMatchPolicy {
    /// Longest event that can name a meeting.
    ///
    /// A recording sits inside a shift, a focus block or a travel day just as
    /// neatly as it sits inside the meeting it belongs to, and the longer entry
    /// wins on overlap every time. Three hours is longer than the meetings
    /// people schedule and shorter than the blocks they use to shape a day.
    public static let longestNamingEventSeconds: Double = 3 * 60 * 60
    public static let minimumScore = 0.25

    public struct Scored: Sendable, Equatable {
        public var candidate: CalendarCandidate
        public var score: Double
        public var reason: String
    }

    /// Scores one event, or returns nil when it cannot name a meeting at all.
    public static func score(
        _ candidate: CalendarCandidate, startedAt: Date, endedAt: Date,
        meetingURL: String?, providerMeetingID: String?
    ) -> Scored? {
        var score = 0.0
        var reasons: [String] = []

        if let providerMeetingID, !providerMeetingID.isEmpty,
           candidate.haystack.localizedCaseInsensitiveContains(providerMeetingID) {
            score += 0.7
            reasons.append("meeting ID in the invitation")
        }
        if let meetingURL, let host = URLComponents(string: meetingURL)?.host,
           candidate.haystack.localizedCaseInsensitiveContains(host) {
            score += 0.15
            reasons.append("provider link in the invitation")
        }

        // An all-day entry or a block spans the recording whatever the recording
        // is, so timing tells us nothing about it. An invitation naming this
        // meeting still does, which is why this is checked after the link and
        // not before.
        let isBlock = candidate.isAllDay
            || candidate.durationSeconds > longestNamingEventSeconds
        if isBlock {
            guard score > 0 else { return nil }
            return Scored(candidate: candidate, score: score, reason: reasons.joined(separator: ", "))
        }

        let overlap = min(candidate.endDate, endedAt)
            .timeIntervalSince(max(candidate.startDate, startedAt))
        if overlap > 0 {
            let recordingLength = max(endedAt.timeIntervalSince(startedAt), 60)
            score += 0.5 * min(1, overlap / recordingLength)
            reasons.append("overlaps the recording")
        } else {
            let distance = abs(candidate.startDate.timeIntervalSince(startedAt))
            if distance <= 15 * 60 {
                score += 0.25 * (1 - distance / (15 * 60))
                reasons.append("starts near the recording")
            }
        }

        guard score > 0 else { return nil }
        return Scored(candidate: candidate, score: score, reason: reasons.joined(separator: ", "))
    }

    /// The event a recording belongs to, or nil when nothing is close enough.
    public static func best(
        among candidates: [CalendarCandidate], startedAt: Date, endedAt: Date,
        meetingURL: String?, providerMeetingID: String?
    ) -> Scored? {
        var best: Scored?
        for candidate in candidates {
            guard let scored = score(
                candidate, startedAt: startedAt, endedAt: endedAt,
                meetingURL: meetingURL, providerMeetingID: providerMeetingID
            ) else { continue }
            if scored.score > (best?.score ?? 0) { best = scored }
        }
        guard let best, best.score >= minimumScore else { return nil }
        return best
    }
}
