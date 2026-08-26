import Foundation

/// One reading of Slack's accessibility tree.
public struct SlackAccessibilityObservation: Sendable, Equatable {
    /// An `AXButton` described as "Leave Huddle" exists. This is the only reliable
    /// discriminator between previewing a Huddle and being in one: Slack opens the
    /// microphone about twelve seconds before the user joins.
    public let hasLeaveHuddleControl: Bool
    /// The read produced no usable information: the subtree came back empty, the
    /// walk hit its budget, or accessibility is not available at all. Slack does
    /// this intermittently during a confirmed active Huddle, so it means "no
    /// information", never "left".
    public let subtreeWasEmpty: Bool
    /// Accessibility is not granted, so the join control can never be seen and the
    /// detector has to fall back to audio evidence.
    public let accessibilityUnavailable: Bool
    public let isMuted: Bool?
    public let windowTitle: String?
    /// One entry per person in the huddle grid, and empty outside a huddle.
    ///
    /// Not the same signal as `subtreeWasEmpty`. A truncated read returns the
    /// tiles it did reach, so this can be a partial roster rather than no
    /// information. A tile the walk ran out of budget inside carries no speaking
    /// flag and no mute state, which contributes a name and no turn, so a short
    /// read costs detail rather than correctness.
    public let tiles: [SlackHuddleTile]

    public init(
        hasLeaveHuddleControl: Bool, subtreeWasEmpty: Bool,
        isMuted: Bool? = nil, windowTitle: String? = nil,
        accessibilityUnavailable: Bool = false,
        tiles: [SlackHuddleTile] = []
    ) {
        self.hasLeaveHuddleControl = hasLeaveHuddleControl
        self.subtreeWasEmpty = subtreeWasEmpty
        self.isMuted = isMuted
        self.windowTitle = windowTitle
        self.accessibilityUnavailable = accessibilityUnavailable
        self.tiles = tiles
    }

    public static let empty = SlackAccessibilityObservation(
        hasLeaveHuddleControl: false, subtreeWasEmpty: true
    )

    public static let unavailable = SlackAccessibilityObservation(
        hasLeaveHuddleControl: false, subtreeWasEmpty: true, accessibilityUnavailable: true
    )
}

/// Decides whether a Slack Huddle is in progress.
///
/// Two findings drive the whole design. Microphone acquisition is not a join:
/// Slack held the microphone for 12.2 seconds while the user was still looking at
/// a Huddle preview. And a single missing "Leave Huddle" read is not a leave: the
/// accessibility subtree read empty repeatedly during a confirmed active Huddle.
/// So joining needs the control to appear, and leaving needs several consecutive
/// misses corroborated by the helper process falling silent.
public struct SlackHuddleDetector: Sendable {
    public enum State: String, Sendable, Equatable {
        case idle
        /// Slack holds the microphone but the join control has not appeared.
        case candidate
        case joined
        /// The control has gone missing but not for long enough to end the meeting.
        case leaving
    }

    public struct Configuration: Sendable, Equatable {
        /// Consecutive polls without the control before a Huddle is considered over.
        public var consecutiveMissesToEnd: Int
        /// Grace period before ending, so a flap plus a poll gap cannot end a call.
        public var endGraceSeconds: Double
        /// How long Slack can hold the microphone with no join before the candidate
        /// is dropped.
        public var candidateTimeoutSeconds: Double
        /// Without accessibility the join control is invisible, so a candidate is
        /// promoted on sustained two-way audio instead. Slack opened the
        /// microphone 12.2 s before the user joined, so this sits well past that.
        public var audioOnlyPromotionSeconds: Double

        public init(
            consecutiveMissesToEnd: Int = 4,
            endGraceSeconds: Double = 3.0,
            candidateTimeoutSeconds: Double = 180,
            audioOnlyPromotionSeconds: Double = 25
        ) {
            self.consecutiveMissesToEnd = consecutiveMissesToEnd
            self.endGraceSeconds = endGraceSeconds
            self.candidateTimeoutSeconds = candidateTimeoutSeconds
            self.audioOnlyPromotionSeconds = audioOnlyPromotionSeconds
        }
    }

    public enum Event: Sendable, Equatable {
        case none
        case candidateAppeared
        case joined
        /// Joined on audio evidence alone, because accessibility could not answer.
        case joinedWithoutAccessibility
        case left(reason: String)
        case candidateExpired
        case muteChanged(Bool)
    }

    public private(set) var state: State = .idle
    public private(set) var isMuted: Bool?
    public private(set) var conversationTitle: String?
    public private(set) var consecutiveMisses = 0

    private let configuration: Configuration
    private var missingSince: Double?
    private var candidateSince: Double?
    private var joinedWithoutAccessibility = false

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Feeds one poll.
    ///
    /// - Parameters:
    ///   - observation: the accessibility reading.
    ///   - helperHoldsMicrophone: a Slack process has an input stream running.
    ///   - helperProducingOutput: a Slack process is playing audio, which is
    ///     corroborating evidence that the Huddle is still live.
    public mutating func update(
        observation: SlackAccessibilityObservation,
        helperHoldsMicrophone: Bool,
        helperProducingOutput: Bool,
        at now: Double
    ) -> Event {
        if let title = observation.windowTitle, !title.isEmpty {
            conversationTitle = SlackWindowTitle.parse(title)?.conversation ?? conversationTitle
        }

        var event = Event.none
        if let muted = observation.isMuted, muted != isMuted, state == .joined {
            isMuted = muted
            event = .muteChanged(muted)
        } else if let muted = observation.isMuted {
            isMuted = muted
        }

        switch state {
        case .idle:
            if observation.hasLeaveHuddleControl {
                state = .joined
                consecutiveMisses = 0
                missingSince = nil
                return .joined
            }
            if helperHoldsMicrophone {
                state = .candidate
                candidateSince = now
                return .candidateAppeared
            }
            return event

        case .candidate:
            if observation.hasLeaveHuddleControl {
                state = .joined
                consecutiveMisses = 0
                missingSince = nil
                candidateSince = nil
                return .joined
            }
            if !helperHoldsMicrophone {
                state = .idle
                candidateSince = nil
                return .candidateExpired
            }
            // Without accessibility there is no join control to wait for, so
            // sustained two-way audio is the best evidence available. Missing a
            // huddle entirely is the worse outcome.
            if observation.accessibilityUnavailable,
               helperProducingOutput,
               let since = candidateSince,
               now - since >= configuration.audioOnlyPromotionSeconds {
                state = .joined
                consecutiveMisses = 0
                missingSince = nil
                candidateSince = nil
                joinedWithoutAccessibility = true
                return .joinedWithoutAccessibility
            }
            if let since = candidateSince, now - since > configuration.candidateTimeoutSeconds {
                state = .idle
                candidateSince = nil
                return .candidateExpired
            }
            return event

        case .joined:
            if observation.hasLeaveHuddleControl {
                consecutiveMisses = 0
                missingSince = nil
                joinedWithoutAccessibility = false
                return event
            }
            // A huddle joined on audio evidence must end on audio evidence: there
            // is no control whose absence could mean anything.
            if joinedWithoutAccessibility || observation.accessibilityUnavailable {
                guard !helperHoldsMicrophone, !helperProducingOutput else { return event }
            }
            state = .leaving
            consecutiveMisses = 1
            missingSince = now
            return event

        case .leaving:
            if observation.hasLeaveHuddleControl {
                // The subtree came back. This is the flap the probe recorded, and
                // it must not have ended the recording.
                state = .joined
                consecutiveMisses = 0
                missingSince = nil
                return event
            }
            consecutiveMisses += 1

            // A read that produced no information is not evidence of leaving, so
            // it only counts once the audio side agrees the Huddle is over.
            let audioAgrees = !helperHoldsMicrophone && !helperProducingOutput
            let missedEnough = consecutiveMisses >= configuration.consecutiveMissesToEnd
            let waitedEnough = (missingSince.map { now - $0 >= configuration.endGraceSeconds }) ?? false

            if observation.subtreeWasEmpty || observation.accessibilityUnavailable, !audioAgrees {
                return event
            }
            if missedEnough, waitedEnough, audioAgrees || !observation.subtreeWasEmpty {
                state = .idle
                consecutiveMisses = 0
                missingSince = nil
                joinedWithoutAccessibility = false
                return .left(reason: audioAgrees ? "control_gone_and_audio_stopped" : "control_gone")
            }
            if audioAgrees, waitedEnough {
                state = .idle
                consecutiveMisses = 0
                missingSince = nil
                joinedWithoutAccessibility = false
                return .left(reason: "audio_stopped")
            }
            return event
        }
    }

    public mutating func reset() {
        state = .idle
        consecutiveMisses = 0
        missingSince = nil
        candidateSince = nil
        joinedWithoutAccessibility = false
        isMuted = nil
    }
}

/// Slack window titles, which carry conversation metadata without any private API.
///
/// `<conversation> (<DM|Channel>) - <workspace> - Slack [<window>] <state emoji>`
public enum SlackWindowTitle {
    public struct Parsed: Sendable, Equatable {
        public let conversation: String
        public let kind: Kind
        public let workspace: String?
        public let isHuddlePreview: Bool

        public enum Kind: String, Sendable {
            case directMessage
            case channel
            case unknown
        }
    }

    private static let separators = CharacterSet(charactersIn: " -\u{2013}\u{2014}|\u{00B7}")

    public static func parse(_ title: String) -> Parsed? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "Slack - Huddle Preview" || trimmed.contains("Huddle Preview") {
            return Parsed(
                conversation: "Huddle", kind: .unknown, workspace: nil, isHuddlePreview: true
            )
        }
        // Strip the trailing "[Main] 🏠🔊" window and state decorations.
        var body = trimmed
        if let bracket = body.firstIndex(of: "[") {
            body = String(body[body.startIndex..<bracket]).trimmingCharacters(in: .whitespaces)
        }
        let parts = body.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, parts.last == "Slack" else { return nil }

        let conversationPart = parts[0]
        let workspace = parts.count >= 3 ? parts[parts.count - 2] : nil
        var conversation = conversationPart
        var kind = Parsed.Kind.unknown
        if let open = conversationPart.lastIndex(of: "("), let close = conversationPart.lastIndex(of: ")"),
           open < close {
            let label = String(conversationPart[conversationPart.index(after: open)..<close]).lowercased()
            kind = label == "dm" ? .directMessage : (label == "channel" ? .channel : .unknown)
            conversation = String(conversationPart[conversationPart.startIndex..<open])
                .trimmingCharacters(in: .whitespaces)
        }
        // Slack publishes "- Hindsight - Slack" while a conversation loads, and
        // " (DM) - ..." between conversations. Both parse to a name made only of
        // separators, which was then filed and announced as the meeting's title.
        // Naming nothing lets the last real conversation stand.
        let name = conversation.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty,
              let first = name.unicodeScalars.first, !Self.separators.contains(first)
        else { return nil }
        return Parsed(
            conversation: conversation, kind: kind, workspace: workspace, isHuddlePreview: false
        )
    }
}
