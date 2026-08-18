import Foundation

public enum SessionState: String, Sendable, Equatable, Codable {
    case idle
    /// Capture is running into memory; nothing is on disk.
    case candidate
    case recording
    /// The meeting evidence dropped but may come back. Capture keeps running.
    case reconnecting
    case ending
    case ended
}

/// How a provider should be handled when detected.
public struct ProviderPolicy: Codable, Sendable, Equatable {
    public enum AutoStart: String, Codable, Sendable {
        case always
        case ask
        case never
    }

    public var autoStart: AutoStart
    /// Whether provider evidence is allowed to end the recording.
    public var autoStop: Bool

    public init(autoStart: AutoStart = .always, autoStop: Bool = true) {
        self.autoStart = autoStart
        self.autoStop = autoStop
    }
}

public struct ProviderPolicies: Codable, Sendable, Equatable {
    public var slack: ProviderPolicy
    public var googleMeet: ProviderPolicy
    public var zoom: ProviderPolicy
    public var faceTime: ProviderPolicy
    public var unknownCalls: ProviderPolicy
    /// Automatic detection is paused entirely. Manual recording still works.
    public var detectionPaused: Bool

    public init(
        slack: ProviderPolicy = ProviderPolicy(),
        googleMeet: ProviderPolicy = ProviderPolicy(),
        zoom: ProviderPolicy = ProviderPolicy(),
        faceTime: ProviderPolicy = ProviderPolicy(autoStart: .ask),
        unknownCalls: ProviderPolicy = ProviderPolicy(autoStart: .ask),
        detectionPaused: Bool = false
    ) {
        self.slack = slack
        self.googleMeet = googleMeet
        self.zoom = zoom
        self.faceTime = faceTime
        self.unknownCalls = unknownCalls
        self.detectionPaused = detectionPaused
    }

    public func policy(for provider: MeetingProvider) -> ProviderPolicy {
        switch provider {
        case .slack: slack
        case .googleMeet: googleMeet
        case .zoom: zoom
        case .faceTime: faceTime
        case .unknown: unknownCalls
        }
    }
}

/// What the runtime should do next.
public enum SessionAction: Sendable, Equatable {
    /// Start both capture sources into the pre-roll ring.
    case armCapture(bundlePrefixes: [String], capturesRemote: Bool)
    /// Point the remote tap at a different application.
    case retargetCapture(bundlePrefixes: [String])
    /// Create the meeting directory and start writing segments, flushing pre-roll.
    case commitRecording(CommitRequest)
    /// A reconnect landed back in the same meeting.
    case beginRun(reason: String)
    /// Metadata learned after the recording started.
    case updateEvidence(ProviderEvidence)
    /// A candidate that never became a meeting.
    case discardCapture(reason: String)
    case finishRecording(reason: String)
    /// A probable call in an unsupported application: already recording, ask now.
    case askToKeepProvisional(bundleIdentifier: String, title: String?)
    case notify(SessionNotice)
}

public struct CommitRequest: Sendable, Equatable {
    public var source: MeetingSource
    public var provider: MeetingProvider
    public var titles: TitleCandidates
    public var providerMeetingID: String?
    public var url: String?
    public var browser: BrowserKind?
    public var applicationBundleID: String?
    public var isProvisional: Bool
    public var startedAt: Date

    public init(
        source: MeetingSource, provider: MeetingProvider, titles: TitleCandidates,
        providerMeetingID: String?, url: String?, browser: BrowserKind?,
        applicationBundleID: String?, isProvisional: Bool, startedAt: Date
    ) {
        self.source = source
        self.provider = provider
        self.titles = titles
        self.providerMeetingID = providerMeetingID
        self.url = url
        self.browser = browser
        self.applicationBundleID = applicationBundleID
        self.isProvisional = isProvisional
        self.startedAt = startedAt
    }
}

public enum SessionNotice: Sendable, Equatable {
    case startedRecording(provider: MeetingProvider, title: String?)
    case finishedRecording(title: String?)
    case reconnecting(provider: MeetingProvider)
    case otherBrowserTabAudible
}

/// Provider-independent meeting lifecycle.
///
/// Provider adapters only produce evidence. This decides what a session is, when
/// capture starts, when it becomes files, and when the meeting is over. A meeting
/// is not the same object as a recording: one meeting can contain several runs
/// separated by a disconnect, and the source segments of each are immutable.
public struct SessionController: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// How long a confirmed meeting stays open after its evidence vanishes.
        /// Covers a page refresh, a browser restart, and a network blip.
        public var reconnectWindowSeconds: Double
        /// How long a candidate can sit unconfirmed before its buffered audio is
        /// dropped. A Meet prejoin screen left open forever should cost nothing.
        public var candidateTimeoutSeconds: Double
        /// Grace after the last confirmed evidence before finishing, so a brief
        /// flap does not end a meeting.
        public var endGraceSeconds: Double

        public init(
            reconnectWindowSeconds: Double = 90,
            candidateTimeoutSeconds: Double = 600,
            endGraceSeconds: Double = 6
        ) {
            self.reconnectWindowSeconds = reconnectWindowSeconds
            self.candidateTimeoutSeconds = candidateTimeoutSeconds
            self.endGraceSeconds = endGraceSeconds
        }
    }

    public struct Snapshot: Sendable, Equatable {
        public var state: SessionState = .idle
        public var source: MeetingSource?
        public var provider: MeetingProvider = .unknown
        public var title: String?
        public var providerMeetingID: String?
        public var startedAt: Date?
        public var isProvisional = false
        public var isManual = false
        public var runCount = 0
    }

    public var configuration: Configuration
    public var policies: ProviderPolicies
    public private(set) var snapshot = Snapshot()

    private var candidateSince: Double?
    private var lastConfirmedAt: Double?
    private var evidence: ProviderEvidence?
    private var pendingEnd: Double?
    private var reconnectingSince: Double?
    private var announcedOtherTabs = false

    public init(
        configuration: Configuration = Configuration(),
        policies: ProviderPolicies = ProviderPolicies()
    ) {
        self.configuration = configuration
        self.policies = policies
    }

    // MARK: - automatic detection

    /// Feeds the strongest current evidence from every detector.
    public mutating func update(
        evidence allEvidence: [ProviderEvidence], now: Double, wallClock: Date
    ) -> [SessionAction] {
        guard !snapshot.isManual else {
            // A manually started recording is the user's, and provider state never
            // ends it. Evidence is still recorded so the meeting gets a title.
            if let best = strongest(of: allEvidence), best.confidence >= .candidate {
                return absorbEvidence(best)
            }
            return []
        }

        guard !policies.detectionPaused else {
            if snapshot.state == .candidate {
                return finishCandidate(reason: "detection_paused")
            }
            return []
        }

        let best = strongest(of: allEvidence)
        var actions: [SessionAction] = []

        switch snapshot.state {
        case .idle, .ended:
            guard let best, best.confidence >= .candidate else { return [] }
            let policy = policies.policy(for: best.provider)
            guard policy.autoStart != .never else { return [] }
            evidence = best
            candidateSince = now
            snapshot.state = .candidate
            snapshot.provider = best.provider
            snapshot.title = best.title
            snapshot.providerMeetingID = best.meetingID
            actions.append(.armCapture(
                bundlePrefixes: best.audioBundlePrefixes, capturesRemote: true
            ))
            if best.confidence == .confirmed {
                actions.append(contentsOf: confirm(best, now: now, wallClock: wallClock))
            }
            return actions

        case .candidate:
            guard let best, best.confidence >= .candidate else {
                if let since = candidateSince, now - since >= configuration.endGraceSeconds {
                    return finishCandidate(reason: "candidate_evidence_gone")
                }
                return []
            }
            actions.append(contentsOf: absorbEvidence(best))
            if best.confidence == .confirmed {
                actions.append(contentsOf: confirm(best, now: now, wallClock: wallClock))
            } else if let since = candidateSince,
                      now - since >= configuration.candidateTimeoutSeconds {
                return finishCandidate(reason: "candidate_timeout")
            }
            return actions

        case .recording:
            if let best, best.confidence == .confirmed {
                lastConfirmedAt = now
                pendingEnd = nil
                return absorbEvidence(best)
            }
            let policy = policies.policy(for: snapshot.provider)
            guard policy.autoStop else { return [] }
            if pendingEnd == nil { pendingEnd = now }
            if let pendingEnd, now - pendingEnd >= configuration.endGraceSeconds {
                snapshot.state = .reconnecting
                reconnectingSince = now
                self.pendingEnd = nil
                return [.notify(.reconnecting(provider: snapshot.provider))]
            }
            return []

        case .reconnecting:
            if let best, best.confidence == .confirmed, matchesCurrentMeeting(best) {
                snapshot.state = .recording
                snapshot.runCount += 1
                reconnectingSince = nil
                lastConfirmedAt = now
                var resumed = absorbEvidence(best)
                resumed.insert(.beginRun(reason: "reconnected"), at: 0)
                if !best.audioBundlePrefixes.isEmpty {
                    resumed.append(.retargetCapture(bundlePrefixes: best.audioBundlePrefixes))
                }
                return resumed
            }
            if let since = reconnectingSince, now - since >= configuration.reconnectWindowSeconds {
                return finishRecording(reason: "provider_ended")
            }
            return []

        case .ending:
            return finishRecording(reason: "ending")
        }
    }

    // MARK: - manual control

    /// Manual remote recording, in-person recording, or a provisional unknown call.
    public mutating func startManual(
        source: MeetingSource, bundlePrefixes: [String], titles: TitleCandidates,
        now: Double, wallClock: Date, isProvisional: Bool = false,
        applicationBundleID: String? = nil
    ) -> [SessionAction] {
        guard snapshot.state == .idle || snapshot.state == .ended else { return [] }
        snapshot = Snapshot()
        snapshot.state = .recording
        snapshot.source = source
        snapshot.provider = source.provider
        snapshot.isManual = !isProvisional
        snapshot.isProvisional = isProvisional
        snapshot.startedAt = wallClock
        snapshot.title = titles.human ?? titles.provider
        snapshot.runCount = 1
        lastConfirmedAt = now

        var actions: [SessionAction] = [
            .armCapture(bundlePrefixes: bundlePrefixes, capturesRemote: source.capturesRemoteAudio),
            .commitRecording(CommitRequest(
                source: source, provider: source.provider, titles: titles,
                providerMeetingID: nil, url: nil, browser: nil,
                applicationBundleID: applicationBundleID,
                isProvisional: isProvisional, startedAt: wallClock
            )),
        ]
        if isProvisional, let applicationBundleID {
            actions.append(.askToKeepProvisional(
                bundleIdentifier: applicationBundleID, title: titles.window
            ))
        } else {
            actions.append(.notify(.startedRecording(
                provider: source.provider, title: titles.resolved
            )))
        }
        return actions
    }

    public mutating func stop(reason: String) -> [SessionAction] {
        switch snapshot.state {
        case .recording, .reconnecting, .ending:
            return finishRecording(reason: reason)
        case .candidate:
            return finishCandidate(reason: reason)
        case .idle, .ended:
            return []
        }
    }

    /// Answer to "This looks like a meeting. Keep recording?".
    public mutating func resolveProvisional(keep: Bool, reason: String) -> [SessionAction] {
        guard snapshot.isProvisional else { return [] }
        snapshot.isProvisional = false
        if keep { return [] }
        return finishRecording(reason: reason, discard: true)
    }

    // MARK: - internals

    private func strongest(of evidence: [ProviderEvidence]) -> ProviderEvidence? {
        evidence
            .filter { $0.confidence > .none }
            .max { lhs, rhs in
                if lhs.confidence != rhs.confidence { return lhs.confidence < rhs.confidence }
                // A browser sensor outranks a heuristic at equal confidence.
                return lhs.source == .native && rhs.source != .native
            }
    }

    private mutating func absorbEvidence(_ best: ProviderEvidence) -> [SessionAction] {
        var actions: [SessionAction] = []
        let previous = evidence
        evidence = best
        if best.title != nil, best.title != snapshot.title { snapshot.title = best.title }
        if let meetingID = best.meetingID { snapshot.providerMeetingID = meetingID }
        if previous != best { actions.append(.updateEvidence(best)) }
        if let count = best.otherAudibleTabs, count > 0, !announcedOtherTabs, snapshot.state == .recording {
            announcedOtherTabs = true
            actions.append(.notify(.otherBrowserTabAudible))
        }
        return actions
    }

    private mutating func confirm(
        _ best: ProviderEvidence, now: Double, wallClock: Date
    ) -> [SessionAction] {
        guard snapshot.state == .candidate else { return [] }
        let policy = policies.policy(for: best.provider)
        let source = Self.source(for: best.provider)
        snapshot.state = .recording
        snapshot.source = source
        snapshot.provider = best.provider
        snapshot.startedAt = wallClock
        snapshot.runCount = 1
        snapshot.isProvisional = policy.autoStart == .ask
        lastConfirmedAt = now
        candidateSince = nil

        var titles = TitleCandidates(
            timestampFallback: MeetingRepository.timestampTitle(startedAt: wallClock, source: source)
        )
        titles.provider = best.title
        if best.title == nil, let meetingID = best.meetingID {
            titles.provider = "\(best.provider.displayName) \(meetingID)"
        }

        var actions: [SessionAction] = [
            .commitRecording(CommitRequest(
                source: source, provider: best.provider, titles: titles,
                providerMeetingID: best.meetingID, url: best.url, browser: best.browser,
                applicationBundleID: best.applicationBundleID,
                isProvisional: snapshot.isProvisional, startedAt: wallClock
            )),
        ]
        if snapshot.isProvisional, let bundle = best.applicationBundleID {
            actions.append(.askToKeepProvisional(bundleIdentifier: bundle, title: best.title))
        } else {
            actions.append(.notify(.startedRecording(provider: best.provider, title: titles.resolved)))
        }
        return actions
    }

    private func matchesCurrentMeeting(_ candidate: ProviderEvidence) -> Bool {
        guard candidate.provider == snapshot.provider else { return false }
        guard let existing = snapshot.providerMeetingID, let incoming = candidate.meetingID else {
            // No identifier either side: same provider inside the reconnect window
            // is treated as the same meeting, which is what a browser restart looks
            // like natively.
            return true
        }
        return existing == incoming
    }

    private mutating func finishCandidate(reason: String) -> [SessionAction] {
        reset()
        return [.discardCapture(reason: reason)]
    }

    private mutating func finishRecording(reason: String, discard: Bool = false) -> [SessionAction] {
        let title = snapshot.title
        reset()
        if discard { return [.discardCapture(reason: reason)] }
        return [.finishRecording(reason: reason), .notify(.finishedRecording(title: title))]
    }

    private mutating func reset() {
        snapshot = Snapshot()
        candidateSince = nil
        lastConfirmedAt = nil
        pendingEnd = nil
        reconnectingSince = nil
        evidence = nil
        announcedOtherTabs = false
    }

    public static func source(for provider: MeetingProvider) -> MeetingSource {
        switch provider {
        case .slack: .slackHuddle
        case .googleMeet: .googleMeet
        case .zoom: .zoom
        case .faceTime: .faceTime
        case .unknown: .genericCall
        }
    }
}
