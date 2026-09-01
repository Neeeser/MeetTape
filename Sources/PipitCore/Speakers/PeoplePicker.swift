import Foundation

/// Why a person is offered before the rest of the directory.
public enum PeoplePickerContext: String, Sendable, Equatable, CaseIterable {
    /// Already named on a chip in this meeting.
    case onAChip
    /// Named on the invite or by the meeting platform, and not heard yet.
    case expected
}

/// One person as the picker draws them: the row, and the line under the name
/// saying why they are here.
public struct PeoplePickerRow: Sendable, Equatable, Identifiable {
    public var entry: SpeakerDirectoryEntry
    /// Empty when there is nothing to say about them.
    public var detail: String

    public var id: IdentityID { entry.id }

    public init(entry: SpeakerDirectoryEntry, detail: String) {
        self.entry = entry
        self.detail = detail
    }
}

/// One heading in the picker and the rows under it.
public struct PeoplePickerSection: Sendable, Equatable, Identifiable {
    public var title: String
    public var rows: [PeoplePickerRow]

    public var id: String { title }

    public init(title: String, rows: [PeoplePickerRow]) {
        self.title = title
        self.rows = rows
    }
}

/// Orders the directory for the question "who is this voice?".
///
/// Alphabetical order answers a different question. The people already in this
/// meeting are the answer nearly every time, and at forty voices they were
/// scattered through a list sorted by first letter. They come first, then
/// whoever was heard most recently, then everybody else.
///
/// Pure, and deliberately outside the view: four surfaces ask this and each one
/// drew its own flat menu.
public enum PeoplePickerRanking {
    public static let inThisMeetingTitle = "In this meeting"
    public static let recentTitle = "Recent"
    public static let everyoneTitle = "Everyone"

    /// How many recently-heard people are offered before the full list. Five is
    /// what fits above the fold beside the meeting's own speakers.
    public static let recentLimit = 5

    public static func sections(
        _ entries: [SpeakerDirectoryEntry],
        context: [IdentityID: PeoplePickerContext] = [:],
        query: String = ""
    ) -> [PeoplePickerSection] {
        let visible = entries.filter { PeopleDirectoryFilter.matches($0, query: query) }
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let here = visible.filter { context[$0.id] != nil }
        let rest = visible.filter { context[$0.id] == nil }

        var sections: [PeoplePickerSection] = []
        if !here.isEmpty {
            // On a chip above expected, because a voice that has already been
            // heard is a likelier answer than a name off the invite.
            let ordered = byName(here.filter { context[$0.id] == .onAChip })
                + byName(here.filter { context[$0.id] == .expected })
            sections.append(PeoplePickerSection(
                title: inThisMeetingTitle, rows: ordered.map { row($0, context: context[$0.id]) }
            ))
        }

        // While searching, everyone left is one list. Splitting five recent
        // names off the top of three results hides the split's own reason.
        var remaining = rest
        if !searching {
            let recent = rest
                .compactMap { entry in entry.identity.lastSeenAt.map { (entry, $0) } }
                .sorted { $0.1 > $1.1 }
                .prefix(recentLimit)
                .map(\.0)
            if !recent.isEmpty {
                sections.append(PeoplePickerSection(
                    title: recentTitle, rows: recent.map { row($0, context: nil) }
                ))
                let taken = Set(recent.map(\.id))
                remaining = rest.filter { !taken.contains($0.id) }
            }
        }

        if !remaining.isEmpty {
            sections.append(PeoplePickerSection(
                title: everyoneTitle, rows: byName(remaining).map { row($0, context: nil) }
            ))
        }
        return sections
    }

    /// The line under a name. Their organization, then either why they are in
    /// the top section or how often they have been heard.
    public static func detail(
        of entry: SpeakerDirectoryEntry, context: PeoplePickerContext? = nil
    ) -> String {
        var parts: [String] = []
        let organization = entry.identity.organization?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !organization.isEmpty { parts.append(organization) }
        switch context {
        case .onAChip: parts.append("already on a chip here")
        case .expected: parts.append("expected here, not heard yet")
        case nil:
            if entry.meetingCount > 0 {
                parts.append("heard in \(entry.meetingCount) meeting\(entry.meetingCount == 1 ? "" : "s")")
            }
        }
        let joined = parts.joined(separator: " · ")
        guard let first = joined.first else { return "" }
        return first.uppercased() + joined.dropFirst()
    }

    private static func row(
        _ entry: SpeakerDirectoryEntry, context: PeoplePickerContext?
    ) -> PeoplePickerRow {
        PeoplePickerRow(entry: entry, detail: detail(of: entry, context: context))
    }

    private static func byName(_ entries: [SpeakerDirectoryEntry]) -> [SpeakerDirectoryEntry] {
        entries.sorted {
            $0.identity.resolvedName.localizedCaseInsensitiveCompare($1.identity.resolvedName)
                == .orderedAscending
        }
    }
}
