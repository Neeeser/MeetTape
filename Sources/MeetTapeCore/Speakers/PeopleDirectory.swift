import Foundation

/// One row of the people directory: who they are, how much voice material
/// stands behind them, and how often they have been heard.
public struct SpeakerDirectoryEntry: Sendable, Equatable, Identifiable {
    public var identity: Identity
    public var profile: VoiceProfileStatus
    public var meetingCount: Int

    public var id: IdentityID { identity.id }

    public init(identity: Identity, profile: VoiceProfileStatus, meetingCount: Int) {
        self.identity = identity
        self.profile = profile
        self.meetingCount = meetingCount
    }
}

/// Which rows the directory is showing.
public enum PeopleFilter: String, Sendable, CaseIterable, Identifiable {
    case all
    case named
    case unnamed
    case withVoiceProfile

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: "All"
        case .named: "Named"
        case .unnamed: "Unnamed"
        case .withVoiceProfile: "Has voice"
        }
    }

    func admits(_ entry: SpeakerDirectoryEntry) -> Bool {
        switch self {
        case .all: true
        case .named: entry.identity.isNamed
        case .unnamed: !entry.identity.isNamed
        case .withVoiceProfile: entry.profile != .none
        }
    }
}

/// One heading in the sidebar and the rows under it.
public struct PeopleDirectorySection: Sendable, Equatable, Identifiable {
    public var title: String
    public var entries: [SpeakerDirectoryEntry]

    public var id: String { title }

    public init(title: String, entries: [SpeakerDirectoryEntry]) {
        self.title = title
        self.entries = entries
    }
}

/// Turns the whole directory into what the sidebar draws.
///
/// Pure, and deliberately outside the view: at a few hundred voices the search
/// and the grouping are the difference between a usable list and a scroll, and
/// neither is worth discovering through a window.
public enum PeopleDirectoryFilter {
    public static let noOrganizationTitle = "No organization"
    public static let unnamedTitle = "Unnamed voices"

    /// Search matches anything the user can see or has typed: the name they
    /// read, the aliases behind it, the organization and their own notes.
    /// Matching only the display name meant the one field people fill in to
    /// tell two similar voices apart could not be searched.
    public static func matches(_ entry: SpeakerDirectoryEntry, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        let identity = entry.identity
        var haystack = [identity.resolvedName]
        haystack.append(contentsOf: identity.aliases)
        if let organization = identity.organization { haystack.append(organization) }
        if let notes = identity.notes { haystack.append(notes) }
        return haystack.contains { $0.lowercased().contains(needle) }
    }

    /// Grouped by organization, with unnamed voices last.
    ///
    /// A directory fills up with voices nobody has named faster than with people
    /// somebody has, so listing them together buries the three names among forty
    /// numbers. They get a section of their own at the bottom, and the people
    /// with no organization get one directly above it.
    public static func sections(
        _ entries: [SpeakerDirectoryEntry], filter: PeopleFilter = .all, query: String = ""
    ) -> [PeopleDirectorySection] {
        let visible = entries.filter { filter.admits($0) && matches($0, query: query) }
        var byOrganization: [String: [SpeakerDirectoryEntry]] = [:]
        var unnamed: [SpeakerDirectoryEntry] = []
        var unaffiliated: [SpeakerDirectoryEntry] = []

        for entry in visible {
            guard entry.identity.isNamed else {
                unnamed.append(entry)
                continue
            }
            let organization = entry.identity.organization?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if organization.isEmpty {
                unaffiliated.append(entry)
            } else {
                byOrganization[organization, default: []].append(entry)
            }
        }

        var sections = byOrganization.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { PeopleDirectorySection(title: $0, entries: sortedByName(byOrganization[$0] ?? [])) }
        if !unaffiliated.isEmpty {
            sections.append(
                PeopleDirectorySection(title: noOrganizationTitle, entries: sortedByName(unaffiliated))
            )
        }
        if !unnamed.isEmpty {
            sections.append(
                PeopleDirectorySection(title: unnamedTitle, entries: sortedByNumber(unnamed))
            )
        }
        return sections
    }

    private static func sortedByName(_ entries: [SpeakerDirectoryEntry]) -> [SpeakerDirectoryEntry] {
        entries.sorted {
            $0.identity.resolvedName.localizedCaseInsensitiveCompare($1.identity.resolvedName)
                == .orderedAscending
        }
    }

    /// By the number in "Anonymous #17", not by its text, so #9 comes before
    /// #10.
    private static func sortedByNumber(_ entries: [SpeakerDirectoryEntry]) -> [SpeakerDirectoryEntry] {
        entries.sorted {
            ($0.identity.anonymousNumber ?? .max, $0.identity.id.rawValue)
                < ($1.identity.anonymousNumber ?? .max, $1.identity.id.rawValue)
        }
    }
}
