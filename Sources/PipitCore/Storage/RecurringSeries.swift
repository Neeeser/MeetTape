import Foundation

/// A rule offered after a meeting is filed by hand, with each clause separate
/// so the user ticks the ones they mean.
public struct RecurringProposal: Sendable, Equatable {
    /// Every clause the archive supports, whether or not it is ticked.
    public var clauses: [Clause]
    /// How many meetings in the archive look like this one, this one included.
    public var lookalikeCount: Int

    public struct Clause: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Equatable {
            case calendarSeries
            case title
            case provider
            case slot
            case participants
        }

        public var kind: Kind
        public var label: String
        /// What the archive says about this clause, shown under the label.
        public var detail: String
        public var isOnByDefault: Bool

        public var id: String { kind.rawValue }
    }

    public var weekdays: [Int]
    public var window: (after: Int, before: Int)
    public var participants: [String]
    public var calendarSeriesIDs: [String]

    /// The rule the ticked clauses add up to, ready to save on the folder.
    public func rule(ticking kinds: Set<Clause.Kind>, from meeting: MeetingFacts) -> FolderRule {
        FolderRule(
            calendarSeriesIDs: kinds.contains(.calendarSeries) ? calendarSeriesIDs : [],
            titleIs: kinds.contains(.title) ? meeting.title : nil,
            provider: kinds.contains(.provider) ? meeting.provider : nil,
            weekdays: kinds.contains(.slot) ? weekdays : [],
            startsAfterMinute: kinds.contains(.slot) ? window.after : nil,
            startsBeforeMinute: kinds.contains(.slot) ? window.before : nil,
            participants: kinds.contains(.participants) ? participants : []
        )
    }

    public var defaultTicks: Set<Clause.Kind> {
        Set(clauses.filter(\.isOnByDefault).map(\.kind))
    }

    public static func == (lhs: RecurringProposal, rhs: RecurringProposal) -> Bool {
        lhs.clauses == rhs.clauses && lhs.lookalikeCount == rhs.lookalikeCount
            && lhs.weekdays == rhs.weekdays && lhs.window == rhs.window
            && lhs.participants == rhs.participants
            && lhs.calendarSeriesIDs == rhs.calendarSeriesIDs
    }
}

/// Looks for the series a meeting belongs to, so filing one by hand can offer
/// to file the rest.
///
/// Everything it reads is in `metadata.json`, which is why the offer can say how
/// many meetings a rule would catch without opening one transcript.
public enum RecurringSeries {
    /// How far either side of the observed times the slot clause reaches.
    static let windowPaddingMinutes = 15
    /// How many meetings have to look alike before a rule is worth offering.
    static let threshold = 3

    public static func propose(
        for meeting: MeetingFacts, among archive: [MeetingFacts]
    ) -> RecurringProposal? {
        let title = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lookalikes = archive.filter {
            $0.title.compare(title, options: [.caseInsensitive]) == .orderedSame
        }
        let series = meeting.calendarSeriesID.map { id in
            archive.contains { $0.calendarSeriesID == id } ? [id] : [id]
        } ?? []
        // A calendar series is worth offering on its own, whatever the titles
        // say: the next occurrence is already known to be one.
        guard lookalikes.count >= threshold || !series.isEmpty else { return nil }

        let sameProvider = lookalikes.filter { $0.provider == meeting.provider }
        let minutes = lookalikes.map(\.startMinute)
        let window = (
            after: max(0, (minutes.min() ?? meeting.startMinute) - windowPaddingMinutes),
            before: min(1_439, (minutes.max() ?? meeting.startMinute) + windowPaddingMinutes)
        )
        let weekdays = Array(Set(lookalikes.map(\.weekday))).sorted()
        let regulars = frequentParticipants(in: lookalikes)

        var clauses: [RecurringProposal.Clause] = []
        if !series.isEmpty {
            clauses.append(.init(
                kind: .calendarSeries,
                label: "In the same calendar series",
                detail: "The calendar already says the next one is this meeting again",
                isOnByDefault: true
            ))
        }
        if lookalikes.count >= threshold {
            clauses.append(.init(
                kind: .title,
                label: "Title is \(title)",
                detail: "\(lookalikes.count) meetings on disk carry it",
                // A calendar series is the better clause when there is one, so
                // the title is left for the user to add rather than assumed.
                isOnByDefault: series.isEmpty
            ))
            clauses.append(.init(
                kind: .provider,
                label: "Recorded from \(meeting.provider.displayName)",
                detail: sameProvider.count == lookalikes.count
                    ? "All \(lookalikes.count) were"
                    : "\(sameProvider.count) of \(lookalikes.count) were",
                isOnByDefault: series.isEmpty && sameProvider.count == lookalikes.count
            ))
            clauses.append(.init(
                kind: .slot,
                label: "\(dayLabel(weekdays)), \(FolderRuleSummary.clock(window.after)) to \(FolderRuleSummary.clock(window.before))",
                detail: "Where every one of them started",
                isOnByDefault: false
            ))
        }
        if regulars.count >= 2 {
            clauses.append(.init(
                kind: .participants,
                label: "\(regulars.prefix(2).joined(separator: " and ")) are in it",
                detail: "On the roster of most of them, not read from the voices",
                isOnByDefault: false
            ))
        }
        guard !clauses.isEmpty else { return nil }

        var proposal = RecurringProposal(
            clauses: clauses,
            lookalikeCount: max(lookalikes.count, 1),
            weekdays: weekdays,
            window: window,
            participants: Array(regulars.prefix(2)),
            calendarSeriesIDs: series
        )
        // Reported against the ticks it opens with, so the number under the
        // sheet answers the rule the user is actually about to save.
        proposal.lookalikeCount = archive.count {
            proposal.rule(ticking: proposal.defaultTicks, from: meeting).matches($0)
        }
        return proposal
    }

    /// Names on the roster of at least two thirds of the meetings.
    private static func frequentParticipants(in meetings: [MeetingFacts]) -> [String] {
        guard !meetings.isEmpty else { return [] }
        var counts: [String: (name: String, count: Int)] = [:]
        for meeting in meetings {
            for name in Set(meeting.participantNames) {
                let key = name.lowercased()
                counts[key] = (name, (counts[key]?.count ?? 0) + 1)
            }
        }
        let needed = max(2, (meetings.count * 2) / 3)
        return counts.values
            .filter { $0.count >= needed }
            .sorted { $0.count > $1.count }
            .map(\.name)
    }

    private static func dayLabel(_ weekdays: [Int]) -> String {
        let sorted = weekdays.sorted()
        if sorted == [2, 3, 4, 5, 6] { return "Weekdays" }
        if sorted.count == 1 { return names[max(1, min(7, sorted[0])) - 1] }
        return "\(sorted.count) days a week"
    }

    private static let names = [
        "Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays",
    ]
}
