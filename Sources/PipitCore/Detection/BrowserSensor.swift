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

/// One person a page reports, with the page's own identifier for them.
///
/// Meet names participants `spaces/{space}/devices/{device}`, which is stable
/// for a conference and per device. A display name is a cache beside it, because
/// two people share one and one person changes theirs.
public struct BrowserParticipant: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String?
    public var isSelf: Bool
    /// Nil where the page does not say, which is most of Zoom.
    public var isMuted: Bool?

    public init(
        id: String, displayName: String? = nil, isSelf: Bool = false, isMuted: Bool? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.isSelf = isSelf
        self.isMuted = isMuted
    }
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
    /// The identified roster. Carried beside `participants` rather than
    /// replacing it, so an older extension that only knows how to send names
    /// keeps working.
    public var people: [BrowserParticipant]?
    /// The identifier of whoever holds the floor, matching an entry in `people`.
    public var activeSpeaker: String?
    /// Another tab in the same browser is playing audio, which the process tap
    /// cannot separate from the meeting.
    public var otherAudibleTabs: Int?

    public init(
        browser: BrowserKind, provider: MeetingProvider, state: BrowserMeetingState,
        timestamp: Double, url: String? = nil, meetingID: String? = nil, title: String? = nil,
        muted: Bool? = nil, tabID: Int? = nil, participants: [String]? = nil,
        people: [BrowserParticipant]? = nil,
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
        self.people = people
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
///
/// State is kept per tab. One `lastEvent` per browser would let a second tab
/// opened during a call overwrite the live meeting with `browsing`.
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

        /// Whether the add-on is in the browser and talking to Pipit.
        ///
        /// A loaded add-on connects when the browser starts and holds the
        /// connection open, so it reports itself whether or not a meeting is on
        /// screen. Silence on a held connection means no meeting page, which is
        /// the ordinary state and not a fault.
        public var isLoaded: Bool { self == .fresh || self == .stale }
    }

    struct Entry: Sendable, Equatable {
        var event: BrowserMeetingEvent
        var receivedAt: Double
    }

    /// How long an event is trusted as current. The extension reports on a 500 ms
    /// tick, so anything older than this means it stopped talking.
    public var freshnessWindow: Double
    public private(set) var connection: Connection = .absent
    public private(set) var connectedAt: Double?
    private var entries: [Int: Entry] = [:]

    /// Events with no tab identifier all share one slot.
    private static let unknownTab = -1

    public init(freshnessWindow: Double = 10) {
        self.freshnessWindow = freshnessWindow
    }

    public var lastEvent: BrowserMeetingEvent? {
        entries.values.max { lhs, rhs in lhs.receivedAt < rhs.receivedAt }?.event
    }

    public var lastEventAt: Double? {
        entries.values.map(\.receivedAt).max()
    }

    public mutating func noteConnected(at now: Double) {
        connection = .fresh
        connectedAt = now
    }

    public mutating func noteDisconnected(at now: Double) {
        connection = .disconnected
    }

    public mutating func receive(_ event: BrowserMeetingEvent, at now: Double) {
        let key = event.tabID ?? Self.unknownTab
        // A late-delivered older event must not demote a live meeting.
        if let existing = entries[key], existing.event.timestamp > event.timestamp { return }
        entries[key] = Entry(event: event, receivedAt: now)
        connection = .fresh
    }

    public mutating func closeTab(_ tabID: Int) {
        entries.removeValue(forKey: tabID)
    }

    public mutating func evaluate(at now: Double) -> Connection {
        entries = entries.filter { now - $0.value.receivedAt <= freshnessWindow }
        switch connection {
        case .absent, .disconnected:
            return connection
        case .fresh, .stale:
            guard let latest = lastEventAt else {
                // Connected but never reported: still usable, just not informative.
                if let connectedAt, now - connectedAt > freshnessWindow { connection = .stale }
                return connection
            }
            connection = now - latest > freshnessWindow ? .stale : .fresh
            return connection
        }
    }

    /// The event to act on: the tab reporting the strongest state, or nil when the
    /// sensor is not currently trustworthy.
    public func currentEvent(at now: Double) -> BrowserMeetingEvent? {
        guard connection == .fresh else { return nil }
        let fresh = entries.values.filter { now - $0.receivedAt <= freshnessWindow }
        guard !fresh.isEmpty else { return nil }
        return fresh.max { lhs, rhs in
            let left = lhs.event.state.detectionWeight
            let right = rhs.event.state.detectionWeight
            return left == right ? lhs.receivedAt < rhs.receivedAt : left < right
        }?.event
    }

    public var isUsable: Bool { connection == .fresh }
}

extension BrowserMeetingState {
    /// How strongly this state argues a meeting is happening, used to pick between
    /// tabs when several report at once.
    var detectionWeight: Int {
        switch self {
        case .inCall, .reconnecting: 3
        case .waiting: 2
        case .prejoin: 1
        case .browsing, .ended, .unknown: 0
        }
    }
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
