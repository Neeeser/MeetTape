import Foundation

/// A folder in the meetings archive, and the rule that decides what belongs in
/// it.
///
/// A folder is an ordinary directory under `Meetings/Folders`, holding the
/// meeting directories themselves. `folder.json` sits beside them and holds
/// what the directory listing cannot say: what the folder is about, and what
/// Pipit may file into it without asking.
public struct MeetingFolder: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// The directory name, and what the folder is called everywhere.
    public var name: String
    /// One line saying what the folder is for, written when the folder is made
    /// and editable in the folder pane. It is what separates two clients from
    /// each other when the model is deciding between them.
    public var about: String
    /// Which colour the folder draws in. An index rather than a colour, so the
    /// palette can change without rewriting every folder on disk.
    public var tintIndex: Int
    public var rule: FolderRule
    /// Whether a meeting matching `rule` moves in without being offered first.
    /// Off until the user turns it on, and never granted to a model's guess.
    public var filesAutomatically: Bool
    public var createdAt: Date

    public var id: String { name }

    /// How many colours the folder palette holds. The index wraps, so a new
    /// folder takes the next one along rather than always taking the first.
    public static let tintCount = 6

    public init(
        name: String,
        about: String = "",
        tintIndex: Int = 0,
        rule: FolderRule = FolderRule(),
        filesAutomatically: Bool = false,
        createdAt: Date = Date(),
        schemaVersion: Int = MeetingFolder.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.about = about
        self.tintIndex = tintIndex
        self.rule = rule
        self.filesAutomatically = filesAutomatically
        self.createdAt = createdAt
    }
}

/// What a folder accepts without a model being asked.
///
/// Every clause reads a field of `metadata.json`, so a rule runs against the
/// whole archive without opening a transcript. An empty rule matches nothing:
/// a folder with no rule is filed by hand.
public struct FolderRule: Codable, Sendable, Equatable {
    /// Calendar series this folder holds. `EKEvent` gives every occurrence of a
    /// repeating event the same external identifier, so this is the one clause
    /// that needs no inference at all.
    public var calendarSeriesIDs: [String]
    /// The exact resolved title, compared case-insensitively.
    public var titleIs: String?
    public var provider: MeetingProvider?
    /// Weekdays as `Calendar` numbers them, 1 for Sunday.
    public var weekdays: [Int]
    /// Minutes since local midnight, inclusive, when the meeting starts.
    public var startsAfterMinute: Int?
    public var startsBeforeMinute: Int?
    /// Display names that have to be on the roster. Two of them is the
    /// threshold the slot clause uses; one alone is never enough on its own.
    public var participants: [String]

    public init(
        calendarSeriesIDs: [String] = [],
        titleIs: String? = nil,
        provider: MeetingProvider? = nil,
        weekdays: [Int] = [],
        startsAfterMinute: Int? = nil,
        startsBeforeMinute: Int? = nil,
        participants: [String] = []
    ) {
        self.calendarSeriesIDs = calendarSeriesIDs
        self.titleIs = titleIs
        self.provider = provider
        self.weekdays = weekdays
        self.startsAfterMinute = startsAfterMinute
        self.startsBeforeMinute = startsBeforeMinute
        self.participants = participants
    }

    /// Whether this rule admits a meeting. Every clause has to hold, and an
    /// empty rule admits nothing: a folder with no rule is filed by hand, and
    /// a rule that matched everything would be the worst possible default.
    public func matches(_ meeting: MeetingFacts) -> Bool {
        guard !isEmpty else { return false }
        if !calendarSeriesIDs.isEmpty {
            guard let series = meeting.calendarSeriesID, calendarSeriesIDs.contains(series)
            else { return false }
        }
        if let titleIs {
            guard titleIs.compare(meeting.title, options: [.caseInsensitive]) == .orderedSame
            else { return false }
        }
        if let provider { guard provider == meeting.provider else { return false } }
        if !weekdays.isEmpty { guard weekdays.contains(meeting.weekday) else { return false } }
        if let startsAfterMinute { guard meeting.startMinute >= startsAfterMinute else { return false } }
        if let startsBeforeMinute { guard meeting.startMinute <= startsBeforeMinute else { return false } }
        if !participants.isEmpty {
            let roster = Set(meeting.participantNames.map { $0.lowercased() })
            let wanted = participants.map { $0.lowercased() }
            guard wanted.allSatisfy(roster.contains) else { return false }
        }
        return true
    }

    public var isEmpty: Bool {
        calendarSeriesIDs.isEmpty && titleIs == nil && provider == nil && weekdays.isEmpty
            && startsAfterMinute == nil && startsBeforeMinute == nil && participants.isEmpty
    }
}

/// Where a folder suggestion came from, which decides both the icon the bar
/// draws and whether the suggestion is allowed to file anything.
public enum FolderMatchReason: String, Codable, Sendable, Equatable {
    /// The rule the user saved on the folder says this meeting belongs in it.
    /// Nothing outranks it, because nothing else was written by hand.
    case rule
    /// The calendar says this meeting is another occurrence of a series the
    /// folder already holds.
    case calendarSeries = "calendar_series"
    /// The resolved title is one the folder's meetings share.
    case title
    /// Same provider, weekday and time of day as the folder's meetings.
    case slot
    /// A model read the summary against the folder catalogue.
    case model

    /// Whether a match for this reason may move a meeting without being
    /// offered first. A model's guess never may, at any confidence.
    public var mayFileWithoutAsking: Bool {
        switch self {
        case .rule, .calendarSeries, .title, .slot: true
        case .model: false
        }
    }
}

/// What the pane offers, written to `raw/folder.suggestion.json`.
///
/// Deliberately not written into the folder itself: this is a proposal, and the
/// meeting's location is the conclusion. The same split `speaker.suggestions.json`
/// keeps from `speakers.map.json`.
public struct FolderSuggestion: Codable, Sendable, Equatable {
    public var folderName: String
    public var confidence: Double
    public var reason: FolderMatchReason
    /// One clause naming the evidence, shown after the folder name.
    public var why: String
    /// A verbatim line from the transcript, for a model's guess. A model answer
    /// arriving without one is dropped before it reaches the pane.
    public var quote: String?
    public var atSeconds: Double?
    public var generatedAt: Date

    public init(
        folderName: String,
        confidence: Double,
        reason: FolderMatchReason,
        why: String,
        quote: String? = nil,
        atSeconds: Double? = nil,
        generatedAt: Date = Date()
    ) {
        self.folderName = folderName
        self.confidence = confidence
        self.reason = reason
        self.why = why
        self.quote = quote
        self.atSeconds = atSeconds
        self.generatedAt = generatedAt
    }
}

/// How far a suggestion may reach, as the Settings picker sets it.
public enum SuggestionReach: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Recurrence only. No model is asked, and no transcript is read for this.
    case recurringOnly = "recurring_only"
    /// The default. A model may answer when it is confident.
    case clearTopics = "clear_topics"
    /// More offers, and more of them wrong.
    case anyLikely = "any_likely"

    public var id: String { rawValue }

    /// The confidence a model's answer has to clear to be shown at all.
    public var modelFloor: Double {
        switch self {
        case .recurringOnly: 1.1
        case .clearTopics: 0.75
        case .anyLikely: 0.5
        }
    }

    public var asksAModel: Bool { self != .recurringOnly }

    public var label: String {
        switch self {
        case .recurringOnly: "Recurring meetings only"
        case .clearTopics: "Recurring, and clear topic matches"
        case .anyLikely: "Any likely match"
        }
    }

    public var detail: String {
        switch self {
        case .recurringOnly:
            "A calendar series, or the same title in the same slot. No model reads the transcript."
        case .clearTopics: "The client or project is named through the meeting."
        case .anyLikely: "More offers, and more of them wrong."
        }
    }
}

/// A rule written out the way a person reads it.
///
/// One place, because three surfaces show the same rule: the chips in the
/// folder pane, the row in Settings, and the line the model is given about what
/// a folder already files.
public enum FolderRuleSummary {
    public static func clauses(_ rule: FolderRule) -> [String] {
        var out: [String] = []
        if !rule.calendarSeriesIDs.isEmpty {
            let count = rule.calendarSeriesIDs.count
            out.append(count == 1 ? "In this calendar series" : "In \(count) calendar series")
        }
        if let title = rule.titleIs, !title.isEmpty { out.append("Title is \(title)") }
        if let provider = rule.provider { out.append("Recorded from \(provider.displayName)") }
        if !rule.weekdays.isEmpty { out.append(dayPhrase(rule.weekdays)) }
        if let window = timePhrase(rule) { out.append(window) }
        if !rule.participants.isEmpty {
            out.append("\(list(rule.participants)) \(rule.participants.count == 1 ? "is" : "are") in it")
        }
        return out
    }

    public static func text(_ rule: FolderRule) -> String {
        clauses(rule).joined(separator: ", ")
    }

    private static func dayPhrase(_ weekdays: [Int]) -> String {
        let sorted = weekdays.sorted()
        if sorted == [2, 3, 4, 5, 6] { return "Weekdays" }
        if sorted == [1, 7] { return "Weekends" }
        return list(sorted.map { names[max(1, min(7, $0)) - 1] })
    }

    private static func timePhrase(_ rule: FolderRule) -> String? {
        switch (rule.startsAfterMinute, rule.startsBeforeMinute) {
        case (let after?, let before?): "\(clock(after)) to \(clock(before))"
        case (let after?, nil): "after \(clock(after))"
        case (nil, let before?): "before \(clock(before))"
        case (nil, nil): nil
        }
    }

    /// `11:00 AM`, matching the folder names on disk rather than the locale, so
    /// a rule and the folders it files read the same way.
    public static func clock(_ minutes: Int) -> String {
        let wrapped = ((minutes % 1_440) + 1_440) % 1_440
        let hour24 = wrapped / 60
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        return String(format: "%d:%02d %@", hour12, wrapped % 60, hour24 < 12 ? "AM" : "PM")
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: "\(items.dropLast().joined(separator: ", ")) and \(items[items.count - 1])"
        }
    }

    private static let names = [
        "Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays",
    ]
}
