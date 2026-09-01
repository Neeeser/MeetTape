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
    /// The persistent identity this participant is, when the user has linked
    /// one. Present only as a soft prior for speaker recognition: it relaxes the
    /// margin the identity needs and never restricts the search.
    public var identityID: IdentityID?

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        email: String? = nil,
        origin: ParticipantOrigin,
        isLocalUser: Bool = false,
        identityID: IdentityID? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.origin = origin
        self.isLocalUser = isLocalUser
        self.identityID = identityID
    }
}

/// Title candidates in precedence order. A human title always wins, and the
/// generated one is used when nothing a person or a meeting client supplied is
/// there.
public struct TitleCandidates: Codable, Sendable, Equatable {
    public var human: String?
    public var provider: String?
    public var calendar: String?
    /// What an imported recording's file was called, without its extension.
    ///
    /// Ranked above the generated title and apart from `window`, because the two
    /// are not the same kind of evidence. A window title is scraped, and for a
    /// call it reads "Meet - abc-defg-hij". A filename is something a person
    /// chose.
    public var filename: String?
    public var window: String?
    public var ai: String?
    public var timestampFallback: String

    public init(
        human: String? = nil, provider: String? = nil, calendar: String? = nil,
        filename: String? = nil, window: String? = nil, ai: String? = nil,
        timestampFallback: String
    ) {
        self.human = human
        self.provider = provider
        self.calendar = calendar
        self.filename = filename
        self.window = window
        self.ai = ai
        self.timestampFallback = timestampFallback
    }

    /// The order titles are trusted in.
    ///
    /// The generated title sits above `window` because a scraped window title is
    /// usually the meeting client's own noise, and a sentence read off the
    /// transcript beats it. It stays below `provider` and `calendar`: those are
    /// what the meeting is called by the people in it, and a recurring meeting
    /// keeps one name across every instance only if they win.
    public var resolved: String {
        for candidate in [human, provider, calendar, filename, ai, window] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
        }
        return timestampFallback
    }

    /// The generated title, when it is worth offering and is not already the
    /// name.
    ///
    /// Nil where there is nothing to decide: no generated title, one the user
    /// typed themselves (they have answered this question), or a generated
    /// title that already won because nothing outranks it. What is left is a
    /// meeting named by a huddle, a calendar event or a file, where the
    /// generated title is the alternative nobody has been shown.
    public var unusedGeneratedTitle: String? {
        guard let ai = ai?.trimmingCharacters(in: .whitespacesAndNewlines), !ai.isEmpty else {
            return nil
        }
        guard human?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            return nil
        }
        guard resolvedOrigin != "ai" else { return nil }
        let shown = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ai.caseInsensitiveCompare(shown) != .orderedSame else { return nil }
        return ai
    }

    public var resolvedOrigin: String {
        if human?.isEmpty == false { return "human" }
        if provider?.isEmpty == false { return "provider" }
        if calendar?.isEmpty == false { return "calendar" }
        if filename?.isEmpty == false { return "filename" }
        if ai?.isEmpty == false { return "ai" }
        if window?.isEmpty == false { return "window" }
        return "timestamp"
    }
}

public struct CalendarLink: Codable, Sendable, Equatable {
    public var eventIdentifier: String
    /// Shared by every occurrence of a repeating event, where `eventIdentifier`
    /// is unique per occurrence. It is what lets a folder recognise the next
    /// meeting in a series it already holds, whatever the occurrence is called
    /// that week. Absent on meetings linked before folders existed.
    public var seriesIdentifier: String?
    public var title: String
    public var startDate: Date
    public var endDate: Date
    public var organizer: String?
    public var attendees: [String]
    /// How confident the match is, so a weak link can be shown as a suggestion.
    public var confidence: Double

    public init(
        eventIdentifier: String, seriesIdentifier: String? = nil, title: String,
        startDate: Date, endDate: Date,
        organizer: String?, attendees: [String], confidence: Double
    ) {
        self.eventIdentifier = eventIdentifier
        self.seriesIdentifier = seriesIdentifier
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
    /// The folder name Pipit last wrote for this meeting.
    ///
    /// The identifier used to be the folder name. It no longer is, so that a
    /// folder can be called what the meeting is called while the identifier
    /// stays fixed for the speakers database. Absent on every meeting recorded
    /// before that change, and on a folder a person renamed in Finder, and in
    /// both cases Pipit leaves the folder alone.
    public var directoryName: String?
    /// Set when the user turned down the generated title for this meeting, so
    /// the offer is never made again.
    ///
    /// A flag rather than clearing `titles.ai`, because the generated title is
    /// still the fallback if the user later clears a title of their own.
    public var generatedTitleDeclined: Bool?
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
    /// An earlier meeting this one might be a continuation of. Recorded rather
    /// than acted on: an uncertain match is offered to the user, never guessed.
    public var possibleContinuationOf: String?
    public var possibleContinuationReason: String?
    /// Original filename for an imported recording, preserved verbatim.
    public var importedOriginalFilename: String?
    /// Where an imported recording's `startedAt` came from. Absent on captured
    /// meetings, whose start is the moment capture began, and on imports made
    /// before the file's own timestamp was read.
    public var recordedDateSource: RecordedDateSource?
    /// Whether the user confirmed a provisionally recorded unknown call.
    public var provisionalDecision: ProvisionalDecision?
    public var captureWarnings: [String]
    /// Another browser tab was audible during the meeting, so the remote track may
    /// contain audio that was not part of the call.
    public var hadOtherAudibleTabs: Bool
    /// Set once the PCM segments have been transcoded to verified archive files
    /// and deleted. Nil while the segments are still the source representation.
    public var audioArchive: AudioArchive?
    /// When the user took this meeting out of the list. Every file it holds
    /// stays where it is. Archiving changes which list a meeting is in and
    /// nothing else.
    public var archivedAt: Date?
    /// The folder this meeting is filed in, which is also the directory holding
    /// it. Nil for a meeting still under `Meetings/YYYY/MM`. The path is the
    /// truth and this is the record of it, so a folder renamed in Finder is
    /// noticed the same way a meeting folder renamed in Finder is.
    public var folderName: String?
    /// Set when the user turned down the offered folder, so the bar is never
    /// shown for this meeting again. The same shape as `generatedTitleDeclined`,
    /// and for the same reason: the suggestion stays on disk as evidence.
    public var folderSuggestionDeclined: Bool?
    /// Folders the user has taken this meeting out of. Never offered again,
    /// because being moved out is a clearer answer than any rule.
    public var removedFromFolders: [String]?

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
        self.directoryName = nil
        self.generatedTitleDeclined = nil
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
        self.possibleContinuationOf = nil
        self.possibleContinuationReason = nil
        self.importedOriginalFilename = nil
        self.recordedDateSource = nil
        self.provisionalDecision = nil
        self.captureWarnings = []
        self.hadOtherAudibleTabs = false
        self.audioArchive = nil
        self.archivedAt = nil
        self.folderName = nil
        self.folderSuggestionDeclined = nil
        self.removedFromFolders = nil
    }

    public var displayTitle: String { titles.resolved }

    public var isArchived: Bool { archivedAt != nil }

    /// The generated title to offer the user, or nil when there is nothing to
    /// ask about. Declining once settles it for good.
    public var titleSuggestion: String? {
        generatedTitleDeclined == true ? nil : titles.unusedGeneratedTitle
    }

    public var isProcessingComplete: Bool { processing.state == .complete }

    /// Whether this meeting may be offered a folder at all. One offer per
    /// meeting for its whole life, and none once it is already filed.
    public var acceptsFolderSuggestion: Bool {
        folderSuggestionDeclined != true && folderName == nil
    }
}
