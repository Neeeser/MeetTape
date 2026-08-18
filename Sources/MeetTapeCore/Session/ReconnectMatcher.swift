import Foundation

/// Decides whether two finished recordings are the same logical meeting.
///
/// A disconnect inside the reconnect window is handled by the session itself. This
/// covers the slower case: the meeting ended, a new one started minutes later, and
/// the evidence says it is a continuation. High confidence merges automatically;
/// anything weaker is offered to the user after the call rather than guessed at.
public struct ReconnectMatcher: Sendable {
    public struct Candidate: Sendable, Equatable {
        public var meetingID: String
        public var provider: MeetingProvider
        public var providerMeetingID: String?
        public var url: String?
        public var title: String?
        public var calendarEventID: String?
        public var applicationBundleID: String?
        public var startedAt: Date
        public var endedAt: Date?

        public init(
            meetingID: String, provider: MeetingProvider, providerMeetingID: String? = nil,
            url: String? = nil, title: String? = nil, calendarEventID: String? = nil,
            applicationBundleID: String? = nil, startedAt: Date, endedAt: Date? = nil
        ) {
            self.meetingID = meetingID
            self.provider = provider
            self.providerMeetingID = providerMeetingID
            self.url = url
            self.title = title
            self.calendarEventID = calendarEventID
            self.applicationBundleID = applicationBundleID
            self.startedAt = startedAt
            self.endedAt = endedAt
        }
    }

    public enum Decision: Sendable, Equatable {
        case unrelated
        /// Ask the user: "These recordings may be the same meeting. Combine them?"
        case possible(score: Double, reason: String)
        case sameMeeting(score: Double, reason: String)
    }

    public struct Configuration: Sendable, Equatable {
        /// Beyond this gap a new recording is a new meeting regardless of evidence.
        public var maximumGapSeconds: Double
        public var automaticThreshold: Double
        public var suggestionThreshold: Double

        public init(
            maximumGapSeconds: Double = 15 * 60,
            automaticThreshold: Double = 0.8,
            suggestionThreshold: Double = 0.45
        ) {
            self.maximumGapSeconds = maximumGapSeconds
            self.automaticThreshold = automaticThreshold
            self.suggestionThreshold = suggestionThreshold
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func compare(_ earlier: Candidate, _ later: Candidate) -> Decision {
        guard earlier.provider == later.provider else { return .unrelated }
        let earlierEnd = earlier.endedAt ?? earlier.startedAt
        let gap = later.startedAt.timeIntervalSince(earlierEnd)
        guard gap >= -60, gap <= configuration.maximumGapSeconds else { return .unrelated }

        var score = 0.0
        var reasons: [String] = []

        // A matching provider meeting identifier is close to proof.
        if let left = earlier.providerMeetingID, let right = later.providerMeetingID {
            if left == right {
                score += 0.7
                reasons.append("same meeting ID")
            } else {
                return .unrelated
            }
        }
        if let left = earlier.url, let right = later.url, normalise(left) == normalise(right) {
            score += 0.25
            reasons.append("same URL")
        }
        if let left = earlier.calendarEventID, let right = later.calendarEventID, left == right {
            score += 0.4
            reasons.append("same calendar event")
        }
        if let left = earlier.title, let right = later.title, !left.isEmpty,
           left.compare(right, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            score += 0.2
            reasons.append("same title")
        }
        if let left = earlier.applicationBundleID, let right = later.applicationBundleID, left == right {
            score += 0.1
            reasons.append("same application")
        }
        // A short gap is itself evidence; a long one is evidence against.
        if gap <= 120 {
            score += 0.25
            reasons.append("resumed within two minutes")
        } else if gap <= 5 * 60 {
            score += 0.1
        } else {
            score -= 0.1
        }

        let reason = reasons.isEmpty ? "same provider" : reasons.joined(separator: ", ")
        if score >= configuration.automaticThreshold {
            return .sameMeeting(score: min(score, 1), reason: reason)
        }
        if score >= configuration.suggestionThreshold {
            return .possible(score: score, reason: reason)
        }
        return .unrelated
    }

    private func normalise(_ url: String) -> String {
        guard var components = URLComponents(string: url) else { return url }
        components.query = nil
        components.fragment = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.string?.lowercased() ?? url.lowercased()
    }
}
