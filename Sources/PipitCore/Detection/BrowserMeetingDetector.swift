import Foundation

/// How strongly the evidence says a meeting is happening.
public enum MeetingConfidence: Int, Sendable, Comparable, Codable {
    case none = 0
    /// Something meeting-shaped is happening. Capture starts here, into memory.
    case candidate = 1
    /// The user is in the meeting. Capture becomes files here.
    case confirmed = 2

    public static func < (lhs: MeetingConfidence, rhs: MeetingConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum EvidenceSource: String, Sendable, Codable {
    case browserSensor = "browser_sensor"
    case native
    case accessibility
    case manual
}

/// What one detector currently believes.
public struct ProviderEvidence: Sendable, Equatable {
    public var provider: MeetingProvider
    public var confidence: MeetingConfidence
    public var source: EvidenceSource
    public var meetingID: String?
    public var url: String?
    public var title: String?
    public var muted: Bool?
    public var otherAudibleTabs: Int?
    public var browser: BrowserKind?
    public var applicationBundleID: String?
    /// Bundle-identifier prefixes whose audio belongs to this meeting.
    public var audioBundlePrefixes: [String]

    public init(
        provider: MeetingProvider,
        confidence: MeetingConfidence,
        source: EvidenceSource,
        meetingID: String? = nil,
        url: String? = nil,
        title: String? = nil,
        muted: Bool? = nil,
        otherAudibleTabs: Int? = nil,
        browser: BrowserKind? = nil,
        applicationBundleID: String? = nil,
        audioBundlePrefixes: [String] = []
    ) {
        self.provider = provider
        self.confidence = confidence
        self.source = source
        self.meetingID = meetingID
        self.url = url
        self.title = title
        self.muted = muted
        self.otherAudibleTabs = otherAudibleTabs
        self.browser = browser
        self.applicationBundleID = applicationBundleID
        self.audioBundlePrefixes = audioBundlePrefixes
    }

    /// Ordering between sources at equal confidence. A browser sensor knows more
    /// than a window title, and an explicit user action outranks both.
    public var sourceRank: Int {
        switch source {
        case .manual: 3
        case .browserSensor: 2
        case .accessibility: 1
        case .native: 0
        }
    }

    public static func idle(provider: MeetingProvider, source: EvidenceSource) -> ProviderEvidence {
        ProviderEvidence(provider: provider, confidence: .none, source: source)
    }
}

/// Meeting identity read out of a browser window title.
///
/// Native detection gives the Meet code but not Zoom's numeric ID, which lives
/// only in the URL. Ordering differs by provider too: Zoom changes its title five
/// seconds before acquiring the microphone, Meet the other way around, so nothing
/// here assumes a sequence.
public enum BrowserWindowTitle {
    public struct Parsed: Sendable, Equatable {
        public let provider: MeetingProvider
        public let meetingID: String?
        public let title: String?
        /// The page is a landing or interstitial screen rather than a meeting.
        public let isLanding: Bool
    }

    public static func parse(_ rawTitle: String) -> Parsed? {
        let title = rawTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }

        if title == "Google Meet" || title == "Meet" {
            return Parsed(provider: .googleMeet, meetingID: nil, title: nil, isLanding: true)
        }
        if title.hasPrefix("Meet - ") {
            let code = String(title.dropFirst("Meet - ".count)).trimmingCharacters(in: .whitespaces)
            let isCode = code.range(of: "^[a-z]{3}-[a-z]{4}-[a-z]{3}$", options: [.regularExpression]) != nil
            return Parsed(
                provider: .googleMeet, meetingID: isCode ? code : nil,
                title: isCode ? nil : code, isLanding: false
            )
        }
        if title.localizedCaseInsensitiveContains("zoom") {
            if title.localizedCaseInsensitiveContains("Join from Zoom") {
                return Parsed(provider: .zoom, meetingID: nil, title: nil, isLanding: true)
            }
            // Zoom's browser title carries the meeting name, not the numeric ID.
            let name = title
                .replacingOccurrences(of: " - Zoom", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Parsed(
                provider: .zoom, meetingID: nil,
                title: name.isEmpty || name == "Zoom" ? nil : name,
                isLanding: name.isEmpty || name == "Zoom"
            )
        }
        return nil
    }

    /// The meeting's own name inside a tab title, with the provider's own
    /// decoration taken off.
    ///
    /// The extension relays `document.title` untouched, so a Meet call arrives
    /// as "Meet - Hindsight Daily" and was filed under that. Nil where what is
    /// left is a meeting code or the bare product name, neither of which is a
    /// name anybody chose. A title from a provider with no rules here comes
    /// back as it went in.
    public static func meetingName(_ rawTitle: String) -> String? {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let parsed = parse(trimmed) else { return trimmed }
        return parsed.title
    }
}

/// Combines the browser sensor with native signals for one browser.
///
/// The sensor is authoritative while it is fresh, because native observation
/// cannot tell a Meet prejoin screen from an active call: four minutes spanning
/// prejoin, join and leave produced no system-visible change at all. When the
/// sensor is absent or stale the native path runs on its own and deliberately
/// over-reports, because a recording of a prejoin screen is a smaller failure
/// than a missed meeting.
public struct BrowserMeetingDetector: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// How long the browser must hold the microphone on a provider page before
        /// native-only detection promotes it to confirmed.
        public var nativeConfirmDwellSeconds: Double
        /// How long after the microphone is released before native detection calls
        /// the meeting over. Covers a page refresh, which took 1.5 seconds.
        public var nativeEndGraceSeconds: Double

        /// How long a provider window title is remembered after it stops being
        /// visible, so a closed tab does not keep producing evidence.
        public var titleMemorySeconds: Double

        public init(
            nativeConfirmDwellSeconds: Double = 20,
            nativeEndGraceSeconds: Double = 12,
            titleMemorySeconds: Double = 120
        ) {
            self.nativeConfirmDwellSeconds = nativeConfirmDwellSeconds
            self.nativeEndGraceSeconds = nativeEndGraceSeconds
            self.titleMemorySeconds = titleMemorySeconds
        }
    }

    public struct NativeSignals: Sendable, Equatable {
        public var browserHoldsMicrophone: Bool
        public var browserProducesOutput: Bool
        public var windowTitles: [String]

        public init(
            browserHoldsMicrophone: Bool, browserProducesOutput: Bool, windowTitles: [String]
        ) {
            self.browserHoldsMicrophone = browserHoldsMicrophone
            self.browserProducesOutput = browserProducesOutput
            self.windowTitles = windowTitles
        }
    }

    public let browser: BrowserKind
    public var configuration: Configuration
    public private(set) var sensor: BrowserSensorTracker
    public private(set) var evidence: ProviderEvidence

    private var micHeldSince: Double?
    private var micReleasedSince: Double?
    private var lastNativeParse: BrowserWindowTitle.Parsed?
    private var lastNativeParseAt: Double?

    public init(
        browser: BrowserKind = .firefox,
        configuration: Configuration = Configuration(),
        freshnessWindow: Double = 10
    ) {
        self.browser = browser
        self.configuration = configuration
        self.sensor = BrowserSensorTracker(freshnessWindow: freshnessWindow)
        self.evidence = ProviderEvidence.idle(provider: .unknown, source: .native)
    }

    public mutating func sensorConnected(at now: Double) { sensor.noteConnected(at: now) }
    public mutating func sensorDisconnected(at now: Double) { sensor.noteDisconnected(at: now) }

    public mutating func receive(_ event: BrowserMeetingEvent, at now: Double) {
        sensor.receive(event, at: now)
    }

    public mutating func closeTab(_ tabID: Int, at now: Double) {
        sensor.closeTab(tabID)
    }

    public mutating func update(native signals: NativeSignals, at now: Double) -> ProviderEvidence {
        _ = sensor.evaluate(at: now)

        if signals.browserHoldsMicrophone {
            if micHeldSince == nil { micHeldSince = now }
            micReleasedSince = nil
        } else {
            if micHeldSince != nil, micReleasedSince == nil { micReleasedSince = now }
            micHeldSince = nil
        }

        let parsed = signals.windowTitles.compactMap(BrowserWindowTitle.parse)
            .sorted { lhs, _ in !lhs.isLanding }
            .first

        // A window title seen minutes ago is not evidence of a meeting now.
        if let parsed {
            lastNativeParse = parsed
            lastNativeParseAt = now
        } else if let seenAt = lastNativeParseAt, now - seenAt > configuration.titleMemorySeconds {
            lastNativeParse = nil
            lastNativeParseAt = nil
        }

        let native = nativeEvidence(native: signals, parsed: parsed ?? lastNativeParse, at: now)
        guard let event = sensor.currentEvent(at: now) else {
            evidence = native
            return evidence
        }
        let sensed = evidenceFromSensor(event, native: signals, parsed: parsed)
        // The two are combined rather than the sensor replacing the native path.
        // A provider changing the label on its leave button would otherwise take
        // a live meeting from confirmed to nothing.
        //
        // The exception is a fresh sensor saying the user is still on a prejoin or
        // waiting screen. Native evidence cannot tell that apart from a joined
        // call, and telling them apart is what the extension is for, so a prejoin
        // stays a candidate and commits nothing to disk.
        let sensorSaysNotJoinedYet = event.state == .prejoin || event.state == .waiting
        if native.confidence > sensed.confidence, !sensorSaysNotJoinedYet {
            var merged = native
            merged.meetingID = sensed.meetingID ?? native.meetingID
            merged.url = sensed.url ?? native.url
            merged.title = sensed.title ?? native.title
            merged.muted = sensed.muted
            merged.otherAudibleTabs = sensed.otherAudibleTabs
            evidence = merged
            return evidence
        }
        evidence = sensed
        return evidence
    }

    private func evidenceFromSensor(
        _ event: BrowserMeetingEvent, native: NativeSignals, parsed: BrowserWindowTitle.Parsed?
    ) -> ProviderEvidence {
        let confidence: MeetingConfidence = switch event.state {
        case .inCall, .reconnecting: .confirmed
        case .prejoin, .waiting: .candidate
        case .browsing, .ended, .unknown: .none
        }
        return ProviderEvidence(
            provider: event.provider == .unknown ? (parsed?.provider ?? .unknown) : event.provider,
            confidence: confidence,
            source: .browserSensor,
            meetingID: event.meetingID ?? parsed?.meetingID,
            url: event.url,
            title: event.title.flatMap(BrowserWindowTitle.meetingName) ?? parsed?.title,
            muted: event.muted,
            otherAudibleTabs: event.otherAudibleTabs,
            browser: browser,
            applicationBundleID: browser.bundleIdentifiers.first,
            audioBundlePrefixes: browser.bundleIdentifiers
        )
    }

    /// Native fallback. Deliberately generous: a provider page plus the microphone
    /// is treated as a meeting once it has lasted, because that set is a superset
    /// of every real join.
    private func nativeEvidence(
        native: NativeSignals, parsed: BrowserWindowTitle.Parsed?, at now: Double
    ) -> ProviderEvidence {
        guard let parsed, parsed.provider != .unknown else {
            return .idle(provider: .unknown, source: .native)
        }

        var confidence = MeetingConfidence.none
        if native.browserHoldsMicrophone {
            let held = micHeldSince.map { now - $0 } ?? 0
            let looksLikeMeeting = !parsed.isLanding || parsed.meetingID != nil
            if looksLikeMeeting {
                confidence = held >= configuration.nativeConfirmDwellSeconds ? .confirmed : .candidate
            } else {
                confidence = .candidate
            }
        } else if let releasedAt = micReleasedSince, now - releasedAt < configuration.nativeEndGraceSeconds {
            // A refresh drops the microphone for about 1.5 seconds and comes back
            // with the same meeting. Hold the meeting open across that gap.
            confidence = .candidate
        }

        return ProviderEvidence(
            provider: parsed.provider,
            confidence: confidence,
            source: .native,
            meetingID: parsed.meetingID,
            url: nil,
            title: parsed.title,
            muted: nil,
            otherAudibleTabs: nil,
            browser: browser,
            applicationBundleID: browser.bundleIdentifiers.first,
            audioBundlePrefixes: browser.bundleIdentifiers
        )
    }
}
