import Foundation

/// What the matcher knows about one meeting. Every field is read from
/// `metadata.json`, so placing a meeting costs no file reads beyond the ones
/// listing the archive already does.
public struct MeetingFacts: Sendable, Equatable {
    public var title: String
    public var provider: MeetingProvider
    /// Shared by every occurrence of a repeating calendar event.
    public var calendarSeriesID: String?
    /// Minutes since local midnight.
    public var startMinute: Int
    /// As `Calendar` numbers them, 1 for Sunday.
    public var weekday: Int
    public var participantNames: [String]
    /// Folders this meeting has been taken out of. It is never offered one of
    /// them again.
    public var excludedFolders: [String]

    public init(
        title: String,
        provider: MeetingProvider,
        calendarSeriesID: String? = nil,
        startMinute: Int,
        weekday: Int,
        participantNames: [String] = [],
        excludedFolders: [String] = []
    ) {
        self.title = title
        self.provider = provider
        self.calendarSeriesID = calendarSeriesID
        self.startMinute = startMinute
        self.weekday = weekday
        self.participantNames = participantNames
        self.excludedFolders = excludedFolders
    }

    public init(
        metadata: MeetingMetadata,
        calendar: Calendar = .current
    ) {
        let parts = calendar.dateComponents(
            [.hour, .minute, .weekday], from: metadata.startedAt
        )
        self.init(
            title: metadata.displayTitle,
            provider: metadata.provider,
            calendarSeriesID: metadata.calendar?.seriesIdentifier,
            startMinute: (parts.hour ?? 0) * 60 + (parts.minute ?? 0),
            weekday: parts.weekday ?? 1,
            participantNames: metadata.participants.map(\.displayName),
            excludedFolders: metadata.removedFromFolders ?? []
        )
    }
}

/// One folder, with enough of its contents to judge a new meeting against it.
public struct FolderProfile: Sendable, Equatable {
    public var name: String
    public var about: String
    public var rule: FolderRule
    public var filesAutomatically: Bool
    public var members: [MeetingFacts]

    public init(
        name: String,
        about: String = "",
        rule: FolderRule = FolderRule(),
        filesAutomatically: Bool = false,
        members: [MeetingFacts] = []
    ) {
        self.name = name
        self.about = about
        self.rule = rule
        self.filesAutomatically = filesAutomatically
        self.members = members
    }

    /// The middle of the folder's meeting times, in minutes since midnight.
    /// Nil for an empty folder.
    public var medianStartMinute: Int? {
        let sorted = members.map(\.startMinute).sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted[sorted.count / 2]
    }
}

/// One folder a model proposed, before any of the rules below have run.
public struct ModelFolderCandidate: Sendable, Equatable, Codable {
    public var folderName: String
    public var confidence: Double
    public var why: String
    public var quote: String?
    public var atSeconds: Double?

    public init(
        folderName: String, confidence: Double, why: String,
        quote: String? = nil, atSeconds: Double? = nil
    ) {
        self.folderName = folderName
        self.confidence = confidence
        self.why = why
        self.quote = quote
        self.atSeconds = atSeconds
    }
}

/// Decides which folder a finished meeting belongs in.
///
/// Four rungs, tried in order, first match winning. The first three read
/// metadata against metadata and cost nothing, which is why a daily standup
/// never reaches a model. Only when all three miss is the fourth asked, and its
/// answer is never allowed to move anything on its own.
public enum FolderMatcher {
    /// How far a title may start from a folder's usual time before a title
    /// match stops being trusted enough to file.
    static let slotToleranceMinutes = 30
    static let titleDemotionMinutes = 120

    /// The first three rungs. Nil when none of them fires.
    ///
    /// Each rung is tried across every folder before the next one is, so a
    /// weaker clause on one folder never beats a stronger clause on another.
    /// Two folders answering the same rung equally well produce nothing, the
    /// way two model candidates a tenth apart do.
    public static func recurrence(
        of meeting: MeetingFacts, in profiles: [FolderProfile], now: Date = Date()
    ) -> FolderSuggestion? {
        let eligible = profiles.filter { !meeting.excludedFolders.contains($0.name) }
        let rungs = [savedRule, calendarSeries, sharedTitle, sameSlot]
        for rung in rungs {
            let hits = eligible.compactMap { rung(meeting, $0, now) }
            guard let best = hits.max(by: { $0.confidence < $1.confidence }) else { continue }
            let tied = hits.filter { $0.confidence == best.confidence }
            // Two folders with an equal claim is not an answer. Say nothing and
            // let the model rung, or the user, decide.
            guard tied.count == 1 else { return nil }
            return best
        }
        return nil
    }

    /// Rung zero: the user wrote a rule and this meeting answers it.
    private static func savedRule(
        _ meeting: MeetingFacts, _ folder: FolderProfile, _ now: Date
    ) -> FolderSuggestion? {
        guard folder.rule.matches(meeting) else { return nil }
        return FolderSuggestion(
            folderName: folder.name, confidence: 1.0, reason: .rule,
            why: FolderRuleSummary.text(folder.rule).lowercased(), generatedAt: now
        )
    }

    /// Rung one: the calendar already says these are the same series.
    private static func calendarSeries(
        _ meeting: MeetingFacts, _ folder: FolderProfile, _ now: Date
    ) -> FolderSuggestion? {
        guard let series = meeting.calendarSeriesID, !series.isEmpty else { return nil }
        let held = folder.members.count { $0.calendarSeriesID == series }
            + folder.rule.calendarSeriesIDs.count { $0 == series }
        guard held >= 2 else { return nil }
        return FolderSuggestion(
            folderName: folder.name, confidence: 1.0, reason: .calendarSeries,
            why: "same calendar series as \(held) \(held == 1 ? "meeting" : "meetings") in it",
            generatedAt: now
        )
    }

    /// Rung two: three or more meetings in the folder are called this, on this
    /// provider.
    ///
    /// Demoted when the meeting starts hours away from when the folder usually
    /// meets. A standup title on a Saturday afternoon is the case that costs
    /// nothing to be careful about.
    private static func sharedTitle(
        _ meeting: MeetingFacts, _ folder: FolderProfile, _ now: Date
    ) -> FolderSuggestion? {
        let wanted = normalized(meeting.title)
        guard !wanted.isEmpty else { return nil }
        let same = folder.members.filter {
            normalized($0.title) == wanted && $0.provider == meeting.provider
        }
        guard same.count >= 3 else { return nil }
        let median = folder.medianStartMinute
        let drift = median.map { abs($0 - meeting.startMinute) } ?? 0
        if drift > titleDemotionMinutes {
            return FolderSuggestion(
                folderName: folder.name, confidence: 0.7, reason: .title,
                why: "same title, outside the hours it usually meets", generatedAt: now
            )
        }
        return FolderSuggestion(
            folderName: folder.name, confidence: 0.95, reason: .title,
            why: "the \(ordinal(same.count + 1)) meeting with this title", generatedAt: now
        )
    }

    /// Rung three: the standup nobody put on a calendar and nobody named the
    /// same way twice. Provider, time of day and two of the same people.
    private static func sameSlot(
        _ meeting: MeetingFacts, _ folder: FolderProfile, _ now: Date
    ) -> FolderSuggestion? {
        guard folder.members.count >= 3 else { return nil }
        let onProvider = folder.members.filter { $0.provider == meeting.provider }
        guard onProvider.count >= 3 else { return nil }
        guard let median = folder.medianStartMinute,
              abs(median - meeting.startMinute) <= slotToleranceMinutes
        else { return nil }

        let mine = Set(meeting.participantNames.map(normalized))
        let theirs = Set(onProvider.flatMap { $0.participantNames.map(normalized) })
        guard mine.intersection(theirs).count >= 2 else { return nil }

        let meets = Set(onProvider.map(\.weekday))
        if meets.contains(meeting.weekday) {
            return FolderSuggestion(
                folderName: folder.name, confidence: 0.8, reason: .slot,
                why: "same time and people as \(onProvider.count) meetings in it", generatedAt: now
            )
        }
        return FolderSuggestion(
            folderName: folder.name, confidence: 0.6, reason: .slot,
            why: "same time and people, on a day it does not usually meet", generatedAt: now
        )
    }

    /// The fourth rung, once a model has answered.
    ///
    /// The model is asked for up to two folders so that a close call can be
    /// recognised as one. Everything here is a reason to say nothing: a folder
    /// that does not exist, an answer with no line of transcript behind it, two
    /// answers a tenth apart, or a best answer under the floor the user set.
    public static func fromModel(
        _ candidates: [ModelFolderCandidate],
        meeting: MeetingFacts,
        profiles: [FolderProfile],
        reach: SuggestionReach,
        now: Date = Date()
    ) -> FolderSuggestion? {
        guard reach.asksAModel else { return nil }
        let known = Set(profiles.map(\.name))
        let usable = candidates
            .filter { known.contains($0.folderName) }
            .filter { !meeting.excludedFolders.contains($0.folderName) }
            .filter { !($0.quote ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.confidence > $1.confidence }
        guard let best = usable.first else { return nil }
        if usable.count > 1, best.confidence - usable[1].confidence < 0.1 { return nil }
        guard best.confidence >= reach.modelFloor else { return nil }
        return FolderSuggestion(
            folderName: best.folderName, confidence: best.confidence, reason: .model,
            why: best.why, quote: best.quote, atSeconds: best.atSeconds, generatedAt: now
        )
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func ordinal(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Whether a suggestion may move the meeting without being offered first.
    ///
    /// Three things have to agree: the reason allows it, the folder has its own
    /// switch on, and the confidence clears the filing floor. A model's answer
    /// fails the first of those at any confidence.
    public static func mayFileWithoutAsking(
        _ suggestion: FolderSuggestion?, in profiles: [FolderProfile]
    ) -> Bool {
        guard let suggestion, suggestion.reason.mayFileWithoutAsking else { return false }
        guard suggestion.confidence >= filingFloor else { return false }
        return profiles.first { $0.name == suggestion.folderName }?.filesAutomatically == true
    }

    /// The confidence a recurrence match needs before it may file on its own.
    public static let filingFloor = 0.75
}
