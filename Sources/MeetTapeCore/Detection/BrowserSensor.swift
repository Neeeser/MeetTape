import Foundation

/// Lifecycle state a browser sensor reports for one tab.
public enum BrowserMeetingState: String, Codable, Sendable, CaseIterable {
    case unknown
    case browsing
    case prejoin
    case waiting
    case inCall = "in_call"
    case reconnecting
    case ended

    public var isActiveCall: Bool { self == .inCall }
}

/// The provider-neutral event a browser extension emits.
///
/// Nothing downstream knows this came from Firefox. A Chrome sensor speaking the
/// same shape needs no changes anywhere else.
public struct BrowserMeetingEvent: Codable, Sendable, Equatable {
    public var browser: BrowserKind
    public var provider: MeetingProvider
    public var state: BrowserMeetingState
    /// When the extension observed this, in seconds since the Unix epoch.
    public var timestamp: Double
    public var url: String?
    public var meetingID: String?
    public var title: String?
    public var muted: Bool?
    public var tabID: Int?
    /// Optional enrichment. Absent rather than guessed when the page does not
    /// expose it reliably.
    public var participants: [String]?
    public var activeSpeaker: String?
    /// Another tab in the same browser is playing audio, which the process tap
    /// cannot separate from the meeting.
    public var otherAudibleTabs: Int?

    public init(
        browser: BrowserKind, provider: MeetingProvider, state: BrowserMeetingState,
        timestamp: Double, url: String? = nil, meetingID: String? = nil, title: String? = nil,
        muted: Bool? = nil, tabID: Int? = nil, participants: [String]? = nil,
        activeSpeaker: String? = nil, otherAudibleTabs: Int? = nil
    ) {
        self.browser = browser
        self.provider = provider
        self.state = state
        self.timestamp = timestamp
        self.url = url
        self.meetingID = meetingID
        self.title = title
        self.muted = muted
        self.tabID = tabID
        self.participants = participants
        self.activeSpeaker = activeSpeaker
        self.otherAudibleTabs = otherAudibleTabs
    }

    public var date: Date { Date(timeIntervalSince1970: timestamp) }
}

/// Tracks browser sensor freshness and decides when to stop trusting it.
///
/// The extension improves precision; it is never the reason a meeting is or is
/// not recorded. When it goes quiet, detection falls back to native signals and
/// an in-progress recording keeps running. A DOM regression should produce extra
/// recording, never a missed meeting.
public struct BrowserSensorTracker: Sendable {
    public enum Connection: String, Sendable, Equatable {
        /// No extension has ever connected.
        case absent
        /// Connected and reporting inside the freshness window.
        case fresh
        /// Connected but silent for longer than the freshness window.
        case stale
        /// The transport dropped.
        case disconnected
    }

    /// How long an event is trusted as current. The extension reports on a 500 ms
    /// tick, so anything older than this means it stopped talking.
    public var freshnessWindow: Double
    public private(set) var connection: Connection = .absent
    public private(set) var lastEvent: BrowserMeetingEvent?
    public private(set) var lastEventAt: Double?
    public private(set) var connectedAt: Double?

    public init(freshnessWindow: Double = 10) {
        self.freshnessWindow = freshnessWindow
    }

    public mutating func noteConnected(at now: Double) {
        connection = .fresh
        connectedAt = now
    }

    public mutating func noteDisconnected(at now: Double) {
        connection = .disconnected
    }

    public mutating func receive(_ event: BrowserMeetingEvent, at now: Double) {
        lastEvent = event
        lastEventAt = now
        connection = .fresh
    }

    public mutating func evaluate(at now: Double) -> Connection {
        switch connection {
        case .absent, .disconnected:
            return connection
        case .fresh, .stale:
            guard let lastEventAt else {
                // Connected but never reported: still usable, just not yet informative.
                if let connectedAt, now - connectedAt > freshnessWindow { connection = .stale }
                return connection
            }
            connection = now - lastEventAt > freshnessWindow ? .stale : .fresh
            return connection
        }
    }

    /// The event to act on, or nil when the sensor is not currently trustworthy.
    public func currentEvent(at now: Double) -> BrowserMeetingEvent? {
        guard connection == .fresh, let lastEvent, let lastEventAt, now - lastEventAt <= freshnessWindow
        else { return nil }
        return lastEvent
    }

    public var isUsable: Bool { connection == .fresh }
}

/// Parses meeting identity out of a provider URL. The extension reports these
/// directly; the same parsing runs natively when a URL is visible another way.
public enum MeetingURLParser {
    public static func provider(forURL url: String) -> MeetingProvider? {
        guard let host = URLComponents(string: url)?.host?.lowercased() else { return nil }
        if host.contains("meet.google.com") { return .googleMeet }
        if host.hasSuffix("zoom.us") || host.contains(".zoom.") { return .zoom }
        if host.contains("slack.com") { return .slack }
        return nil
    }

    /// Meet codes are `xxx-xxxx-xxx`; Zoom IDs are the numeric run in the path.
    public static func meetingID(forURL url: String) -> String? {
        guard let components = URLComponents(string: url) else { return nil }
        let path = components.path
        switch provider(forURL: url) {
        case .googleMeet:
            return firstMatch(in: path, pattern: "([a-z]{3}-[a-z]{4}-[a-z]{3})")
        case .zoom:
            return firstMatch(in: path, pattern: "/(?:j|wc|s)(?:/join)?/(\\d{9,})")
                ?? firstMatch(in: path, pattern: "(\\d{9,})")
        default:
            return nil
        }
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        let captureIndex = match.numberOfRanges > 1 ? 1 : 0
        guard let captured = Range(match.range(at: captureIndex), in: text) else { return nil }
        return String(text[captured])
    }
}
