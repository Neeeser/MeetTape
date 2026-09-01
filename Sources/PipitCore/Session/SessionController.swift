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
    /// The meeting's evidence is gone and the reconnect window has started.
    /// Segments close and capture falls back to the memory ring, so the wait is
    /// not part of the recording.
    case pauseCapture(reason: String)
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
        /// How long a candidate survives with no evidence at all before its
        /// buffered audio is dropped.
        public var candidateEvidenceGraceSeconds: Double

        /// The range Settings offers for each of the two waits the user sets.
        /// Held here so the pickers and a value read off disk agree.
        public static let endGraceRange: ClosedRange<Double> = 2...20
        public static let reconnectWindowRange: ClosedRange<Double> = 10...180

        public init(
            reconnectWindowSeconds: Double = 30,
            candidateTimeoutSeconds: Double = 600,
            endGraceSeconds: Double = 4,
            candidateEvidenceGraceSeconds: Double = 20
        ) {
            self.reconnectWindowSeconds = reconnectWindowSeconds
            self.candidateTimeoutSeconds = candidateTimeoutSeconds
            self.endGraceSeconds = endGraceSeconds
            self.candidateEvidenceGraceSeconds = candidateEvidenceGraceSeconds
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
    private var candidateEvidenceLostAt: Double?
    private var lastConfirmedAt: Double?
    private var evidence: ProviderEvidence?
    private var pendingEnd: Double?
    private var reconnectingSince: Double?
    private var announcedOtherTabs = false
    /// A call the user has answered for: the provisional prompt was declined, or
    /// the recording was stopped by hand.
    ///
    /// Evidence is reasserted on every poll, so an answer the session did not
    /// remember was undone half a second later. A declined prompt went idle,
    /// read the same evidence again and asked again. A stopped huddle went idle
    /// and recorded itself again, which is where the one-second meetings after
    /// every Slack huddle came from. The answer is released once that call stops
    /// producing evidence, which is what makes the next call start afresh.
    ///
    /// The provider is part of the identity because the application alone is a
    /// browser for anything running in a tab. Stopping one call must not stop a
    /// Meet in the same browser from recording.
    private struct SuppressedCall {
        let provider: MeetingProvider
        /// Normalised to the application, so a helper rotating under the call
        /// does not read as a different one.
        let application: String
        /// Set when the call had one. A different identifier on the same provider
        /// is a different meeting, and it records normally.
        let meetingID: String?
        var lastSeen: Double
    }

    private var suppressed: [SuppressedCall] = []
    /// What the open prompt asked about. The evidence moves on while the prompt
    /// waits for an answer, so reading the answer's subject from it recorded
    /// whichever call happened to be strongest when the user clicked.
    private var askedAbout: (provider: MeetingProvider, application: String)?
    /// Bundle prefixes the process tap is currently bound to, so a change of
    /// provider between arming and confirming retargets it instead of recording
    /// the wrong application.
    private var armedPrefixes: [String] = []

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
        ageSuppressedCalls(in: allEvidence, now: now)

        guard !snapshot.isManual else {
            // A manually started recording is the user's, and provider state never
            // ends it. Evidence is still recorded so the meeting gets a title.
            if let best = strongest(of: allEvidence), best.confidence >= .candidate {
                return absorbEvidence(best)
            }
            return []
        }

        guard !policies.detectionPaused else {
            switch snapshot.state {
            case .candidate:
                return finishCandidate(reason: "detection_paused")
            case .recording, .reconnecting, .ending:
                // A session already under way is finished rather than frozen:
                // leaving it in reconnecting keeps writing segments forever and
                // never hands the meeting to processing.
                return finishRecording(reason: "detection_paused")
            case .idle, .ended:
                return []
            }
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
            armedPrefixes = best.audioBundlePrefixes
            actions.append(.armCapture(
                bundlePrefixes: best.audioBundlePrefixes, capturesRemote: true
            ))
            if best.confidence == .confirmed {
                actions.append(contentsOf: confirm(best, now: now, wallClock: wallClock))
            }
            return actions

        case .candidate:
            guard let best, best.confidence >= .candidate else {
                // Measured from when evidence was lost, not from when the
                // candidate began: Slack holds the microphone for 12 s before the
                // user joins, and one flap must not throw the pre-roll away.
                if candidateEvidenceLostAt == nil { candidateEvidenceLostAt = now }
                if let lostAt = candidateEvidenceLostAt,
                   now - lostAt >= configuration.candidateEvidenceGraceSeconds {
                    return finishCandidate(reason: "candidate_evidence_gone")
                }
                return []
            }
            candidateEvidenceLostAt = nil
            actions.append(contentsOf: absorbEvidence(best))
            if best.confidence == .confirmed {
                actions.append(contentsOf: confirm(best, now: now, wallClock: wallClock))
            } else if let since = candidateSince,
                      now - since >= configuration.candidateTimeoutSeconds {
                return finishCandidate(reason: "candidate_timeout")
            }
            return actions

        case .recording:
            if let best, best.confidence == .confirmed, !matchesCurrentMeeting(best) {
                // A different meeting on the same provider is a new meeting, not
                // a continuation; merging them would produce one directory with
                // two calls in it.
                var actions = finishRecording(reason: "meeting_changed")
                actions.append(contentsOf: update(evidence: allEvidence, now: now, wallClock: wallClock))
                return actions
            }
            if let best, best.confidence == .confirmed {
                lastConfirmedAt = now
                pendingEnd = nil
                return absorbEvidence(best)
            }
            // Weaker evidence still means the meeting is there. Only its absence
            // starts the clock, because over-recording is the cheaper failure.
            // The evidence has to come from this meeting's own provider: Slack
            // touching the microphone must not hold a Meet recording open.
            if let best, best.confidence == .candidate, best.provider == snapshot.provider {
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
                // The reconnect window is waiting, not meeting: writing stops
                // now, and a rejoin starts a new run with the ring as pre-roll.
                return [
                    .pauseCapture(reason: "provider_evidence_gone"),
                    .notify(.reconnecting(provider: snapshot.provider)),
                ]
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
            if let best, best.confidence == .confirmed {
                // Confirmed evidence for a different meeting: end this one now
                // rather than losing the first 90 seconds of the next.
                var actions = finishRecording(reason: "meeting_changed")
                actions.append(contentsOf: update(evidence: allEvidence, now: now, wallClock: wallClock))
                return actions
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
        // Starting from a candidate is the common case for Slack, which opens the
        // microphone about twelve seconds before the user joins. Refusing here
        // made the menu item do nothing during exactly that window.
        let wasCandidate = snapshot.state == .candidate
        guard snapshot.state == .idle || snapshot.state == .ended || wasCandidate else { return [] }
        snapshot = Snapshot()
        // This starts a session without going through reset(), so an unanswered
        // question from an earlier one would otherwise still be here to answer.
        askedAbout = nil
        snapshot.state = .recording
        snapshot.source = source
        snapshot.provider = source.provider
        snapshot.isManual = !isProvisional
        snapshot.isProvisional = isProvisional
        snapshot.startedAt = wallClock
        snapshot.title = titles.human ?? titles.provider
        snapshot.runCount = 1
        lastConfirmedAt = now

        // Arming again discards the pre-roll, so a capture that is already running
        // for a candidate is retargeted instead. An in-person recording has no
        // remote track, so that one is rebuilt.
        let reuseArmedCapture = wasCandidate && source.capturesRemoteAudio
        let capture: SessionAction = reuseArmedCapture
            ? .retargetCapture(bundlePrefixes: bundlePrefixes)
            : .armCapture(bundlePrefixes: bundlePrefixes, capturesRemote: source.capturesRemoteAudio)
        armedPrefixes = bundlePrefixes
        var actions: [SessionAction] = [
            capture,
            .commitRecording(CommitRequest(
                source: source, provider: source.provider, titles: titles,
                providerMeetingID: nil, url: nil, browser: nil,
                applicationBundleID: applicationBundleID,
                isProvisional: isProvisional, startedAt: wallClock
            )),
        ]
        if isProvisional, let applicationBundleID {
            askedAbout = (provider: source.provider, application: applicationBundleID)
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

    /// Ends the session on the user's word.
    public mutating func stop(reason: String, now: Double) -> [SessionAction] {
        switch snapshot.state {
        case .recording, .reconnecting, .ending:
            suppressCurrentCall(now: now)
            return finishRecording(reason: reason)
        case .candidate:
            suppressCurrentCall(now: now)
            return finishCandidate(reason: reason)
        case .idle, .ended:
            return []
        }
    }

    /// Remembers the call the session was on, so the evidence that is still
    /// there does not start it again on the next poll. Read before the reset,
    /// which is where the evidence lives.
    private mutating func suppressCurrentCall(now: Double) {
        guard let evidence, let bundle = evidence.applicationBundleID else { return }
        let call = SuppressedCall(
            provider: evidence.provider,
            application: MicrophoneIgnoreList.applicationIdentifier(for: bundle),
            meetingID: evidence.meetingID ?? snapshot.providerMeetingID,
            lastSeen: now
        )
        suppressed.removeAll { existing in
            existing.provider == call.provider
                && existing.application == call.application
                && existing.meetingID == call.meetingID
        }
        suppressed.append(call)
    }

    /// Answer to "This looks like a meeting. Keep recording?".
    public mutating func resolveProvisional(
        keep: Bool, reason: String, now: Double
    ) -> [SessionAction] {
        guard snapshot.isProvisional else { return [] }
        snapshot.isProvisional = false
        if keep { return [] }
        if let asked = askedAbout {
            // The prompt is raised per call, not per meeting, so the question the
            // user answered covers every meeting that application reports.
            suppressed.append(SuppressedCall(
                provider: asked.provider,
                application: MicrophoneIgnoreList.applicationIdentifier(for: asked.application),
                meetingID: nil,
                lastSeen: now
            ))
        }
        return finishRecording(reason: reason, discard: true)
    }

    /// Releases each suppressed call once it is over.
    ///
    /// A call is over when it stops being confirmed, on the same grace the
    /// recording path uses, rather than when its application goes quiet. Slack
    /// idles on the microphone between huddles, so waiting for silence held the
    /// answer over the next huddle too and recorded nothing when the user left
    /// one call and joined another.
    private mutating func ageSuppressedCalls(in allEvidence: [ProviderEvidence], now: Double) {
        suppressed = suppressed.compactMap { call in
            let stillThere = allEvidence.contains { candidate in
                candidate.confidence == .confirmed && Self.matches(call, candidate)
            }
            if stillThere {
                var seen = call
                seen.lastSeen = now
                return seen
            }
            return now - call.lastSeen >= configuration.endGraceSeconds ? nil : call
        }
    }

    private static func matches(_ call: SuppressedCall, _ candidate: ProviderEvidence) -> Bool {
        guard candidate.provider == call.provider,
              let application = candidate.applicationBundleID,
              MicrophoneIgnoreList.applicationIdentifier(for: application) == call.application
        else { return false }
        guard let suppressedID = call.meetingID, let candidateID = candidate.meetingID else {
            return true
        }
        return suppressedID == candidateID
    }

    // MARK: - internals

    /// Picks the evidence to act on.
    ///
    /// Providers the user set to never record are removed first: leaving them in
    /// would let an open Zoom tab suppress a real Meet. The ordering is total, so
    /// the choice does not depend on the order detectors happened to report in.
    private func strongest(of evidence: [ProviderEvidence]) -> ProviderEvidence? {
        evidence
            .filter { $0.confidence > .none }
            .filter { policies.policy(for: $0.provider).autoStart != .never }
            .filter { candidate in
                !suppressed.contains { Self.matches($0, candidate) }
            }
            .max { lhs, rhs in
                if lhs.confidence != rhs.confidence { return lhs.confidence < rhs.confidence }
                if lhs.sourceRank != rhs.sourceRank { return lhs.sourceRank < rhs.sourceRank }
                return lhs.provider.rawValue < rhs.provider.rawValue
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
        // The candidate may have been armed for a different application: a generic
        // call that turns into a Meet tab arms on the unknown app and confirms on
        // Firefox. Retargeting keeps the ring, which arming again would discard.
        if !best.audioBundlePrefixes.isEmpty, best.audioBundlePrefixes != armedPrefixes {
            armedPrefixes = best.audioBundlePrefixes
            actions.insert(.retargetCapture(bundlePrefixes: best.audioBundlePrefixes), at: 0)
        }
        if snapshot.isProvisional, let bundle = best.applicationBundleID {
            askedAbout = (provider: best.provider, application: bundle)
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
        candidateEvidenceLostAt = nil
        lastConfirmedAt = nil
        pendingEnd = nil
        reconnectingSince = nil
        evidence = nil
        announcedOtherTabs = false
        armedPrefixes = []
        askedAbout = nil
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
