import Foundation

/// Where a participant's name came from.
public enum ParticipantOrigin: String, Codable, Sendable {
    case human
    case calendar
    case browser
    case provider
    case ai
    case localUser = "local_user"
}

public struct Participant: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var email: String?
    public var origin: ParticipantOrigin
    /// True for the person holding the microphone. Their speech is attributed by
    /// construction and never diarized.
    public var isLocalUser: Bool

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        email: String? = nil,
        origin: ParticipantOrigin,
        isLocalUser: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.origin = origin
        self.isLocalUser = isLocalUser
    }
}

/// Title candidates in precedence order. A human title always wins; an AI title is
/// only used when nothing better exists.
public struct TitleCandidates: Codable, Sendable, Equatable {
    public var human: String?
    public var provider: String?
    public var calendar: String?
    public var window: String?
    public var ai: String?
    public var timestampFallback: String

    public init(
        human: String? = nil, provider: String? = nil, calendar: String? = nil,
        window: String? = nil, ai: String? = nil, timestampFallback: String
    ) {
        self.human = human
        self.provider = provider
        self.calendar = calendar
        self.window = window
        self.ai = ai
        self.timestampFallback = timestampFallback
    }

    public var resolved: String {
        for candidate in [human, provider, calendar, window, ai] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
        }
        return timestampFallback
    }

    public var resolvedOrigin: String {
        if human?.isEmpty == false { return "human" }
        if provider?.isEmpty == false { return "provider" }
        if calendar?.isEmpty == false { return "calendar" }
        if window?.isEmpty == false { return "window" }
        if ai?.isEmpty == false { return "ai" }
        return "timestamp"
    }
}

public struct CalendarLink: Codable, Sendable, Equatable {
    public var eventIdentifier: String
    public var title: String
    public var startDate: Date
    public var endDate: Date
    public var organizer: String?
    public var attendees: [String]
    /// How confident the match is, so a weak link can be shown as a suggestion.
    public var confidence: Double

    public init(
        eventIdentifier: String, title: String, startDate: Date, endDate: Date,
        organizer: String?, attendees: [String], confidence: Double
    ) {
        self.eventIdentifier = eventIdentifier
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.organizer = organizer
        self.attendees = attendees
        self.confidence = confidence
    }
}

/// One continuous capture period inside a logical meeting. A disconnect and
/// rejoin produces a second run, not a second meeting.
public struct RecordingRun: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var startedAt: Date
    public var endedAt: Date?
    public var durationSeconds: Double
    public var wasInterrupted: Bool
    public var endReason: String?

    public init(
        id: String, startedAt: Date, endedAt: Date? = nil,
        durationSeconds: Double = 0, wasInterrupted: Bool = false, endReason: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.wasInterrupted = wasInterrupted
        self.endReason = endReason
    }
}

/// `metadata.json`. Mutable by design: titles, notes, participants, calendar
/// linkage and speaker names all change after the fact. The recording itself never
/// does.
public struct MeetingMetadata: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var source: MeetingSource
    public var provider: MeetingProvider
    public var createdAt: Date
    public var startedAt: Date
    public var endedAt: Date?
    public var durationSeconds: Double
    public var titles: TitleCandidates
    public var descriptionText: String?
    public var providerMeetingID: String?
    public var meetingURL: String?
    public var browser: BrowserKind?
    public var applicationBundleID: String?
    public var windowTitle: String?
    public var calendar: CalendarLink?
    public var participants: [Participant]
    public var processing: ProcessingStatus
    public var runs: [RecordingRun]
    /// Meetings folded into this one after the fact. Their directories stay intact.
    public var absorbedMeetingIDs: [String]
    /// Set on the meeting that was folded into another.
    public var mergedIntoMeetingID: String?
    /// Original filename for an imported recording, preserved verbatim.
    public var importedOriginalFilename: String?
    /// Whether the user confirmed a provisionally recorded unknown call.
    public var provisionalDecision: ProvisionalDecision?
    public var captureWarnings: [String]
    /// Another browser tab was audible during the meeting, so the remote track may
    /// contain audio that was not part of the call.
    public var hadOtherAudibleTabs: Bool

    public enum ProvisionalDecision: String, Codable, Sendable {
        case pending
        case kept
        case discarded
    }

    public init(
        id: String,
        source: MeetingSource,
        provider: MeetingProvider,
        createdAt: Date,
        startedAt: Date,
        titles: TitleCandidates,
        schemaVersion: Int = MeetingMetadata.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.source = source
        self.provider = provider
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = nil
        self.durationSeconds = 0
        self.titles = titles
        self.descriptionText = nil
        self.providerMeetingID = nil
        self.meetingURL = nil
        self.browser = nil
        self.applicationBundleID = nil
        self.windowTitle = nil
        self.calendar = nil
        self.participants = []
        self.processing = ProcessingStatus()
        self.runs = []
        self.absorbedMeetingIDs = []
        self.mergedIntoMeetingID = nil
        self.importedOriginalFilename = nil
        self.provisionalDecision = nil
        self.captureWarnings = []
        self.hadOtherAudibleTabs = false
    }

    public var displayTitle: String { titles.resolved }

    public var isProcessingComplete: Bool { processing.state == .complete }
}
