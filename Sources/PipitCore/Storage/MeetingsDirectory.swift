import Foundation

/// One speaker of a meeting, as much as the meeting's own files know.
///
/// Read from `speakers.map.json` rather than from the identity store, because
/// the sidebar draws this for every meeting in the archive and the store is one
/// database query per meeting. The identifier is here so the same person keeps
/// the same colour as in the People window.
public struct MeetingRowSpeaker: Sendable, Equatable, Identifiable {
    public var key: String
    /// nil for a cluster nobody has named.
    public var displayName: String?
    public var identityID: IdentityID?
    /// The meeting client's own identifier for the person, where the assignment
    /// carries one. Kept so the row can tell one person's several clusters
    /// apart from several people.
    public var participantID: String?

    public var id: String { key }

    public var isNamed: Bool { !(displayName ?? "").isEmpty }

    public init(
        key: String, displayName: String?, identityID: IdentityID?,
        participantID: String? = nil
    ) {
        self.key = key
        self.displayName = displayName
        self.identityID = identityID
        self.participantID = participantID
    }
}

/// One row of the meetings list: the summary, who was in it, and the text a
/// search can match.
public struct MeetingRow: Sendable, Equatable, Identifiable {
    public var summary: MeetingSummary
    public var speakers: [MeetingRowSpeaker]
    /// The user's own notes, which are searched alongside the title.
    public var notes: String

    public var id: String { summary.id }
    public var title: String { summary.title }
    public var startedAt: Date { summary.startedAt }
    public var namedSpeakers: [MeetingRowSpeaker] { speakers.filter(\.isNamed) }
    public var unnamedCount: Int { speakers.count { !$0.isNamed } }
    /// Whether there is something here for a person to do.
    ///
    /// An interrupted run only counts while processing has not finished.
    /// `wasInterrupted` is also true for a call that dropped and was rejoined,
    /// and that never clears, so treating it as attention on its own filed every
    /// rejoined call under Needs attention forever with nothing to act on.
    public var needsAttention: Bool {
        summary.processingState == .failed
            || (summary.wasInterrupted && summary.processingState != .complete)
    }
    public var isProcessing: Bool {
        summary.processingState != .complete && summary.processingState != .failed
    }
    public var isArchived: Bool { summary.isArchived }

    public init(summary: MeetingSummary, speakers: [MeetingRowSpeaker], notes: String) {
        self.summary = summary
        self.speakers = speakers
        self.notes = notes
    }
}

/// Which rows the meetings list is showing.
public enum MeetingsFilter: String, Sendable, CaseIterable, Identifiable {
    case all
    /// Meetings still holding a voice nobody has named. This is the filter that
    /// turns "somewhere in the archive" into a short list of work.
    case unnamed
    /// Processing failed, or the recording was interrupted.
    case needsAttention
    /// Meetings the user took out of the list. Every file is still on disk, and
    /// this is where they are put back from.
    case archived

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .all: "All"
        case .unnamed: "Unnamed"
        // "Needs attention" at four segments squeezes the other three off the
        // sidebar. The heading over the rows still spells it out.
        case .needsAttention: "Attention"
        case .archived: "Archived"
        }
    }

    /// An archived meeting is in one list and one list only. Leaving it under
    /// All would make archiving a badge rather than a way to put a recording
    /// down, and leaving it under Attention would keep a failed run that the
    /// user has already dismissed in front of them.
    public func admits(_ row: MeetingRow) -> Bool {
        switch self {
        case .archived: row.isArchived
        case .all: !row.isArchived
        case .unnamed: !row.isArchived && row.unnamedCount > 0
        case .needsAttention: !row.isArchived && row.needsAttention
        }
    }
}

public struct MeetingsSection: Sendable, Equatable, Identifiable {
    public var title: String
    public var rows: [MeetingRow]

    public var id: String { title }

    public init(title: String, rows: [MeetingRow]) {
        self.title = title
        self.rows = rows
    }
}

/// Turns the archive into what the sidebar draws.
///
/// Pure and outside the view, for the same reason the people directory's filter
/// is: at a few hundred meetings the grouping and the search are the difference
/// between a list and a scroll, and neither is worth discovering through a
/// window.
public enum MeetingsDirectoryFilter {
    /// Search matches what the user can see and what they wrote: the title,
    /// the kind of recording, the speaker names, their own notes and, once the
    /// index has been built, every word of the transcript. The kind is in there
    /// because the row draws it as an icon, and "zoom" is a thing a person
    /// remembers about a meeting they are looking for.
    ///
    /// The transcript text is passed in rather than read here. Reading a
    /// hundred transcripts is file work, and this runs on every keystroke.
    public static func matches(
        _ row: MeetingRow, query: String, transcript: String? = nil
    ) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        var haystack = [row.title, row.notes, row.summary.source.displayName]
        haystack.append(contentsOf: row.speakers.compactMap(\.displayName))
        if haystack.contains(where: { $0.lowercased().contains(needle) }) { return true }
        guard let transcript else { return false }
        return transcript.contains(needle)
    }

    /// The speakers of one meeting: one per cluster its transcript uses, named
    /// where the meeting's own speaker map names it.
    ///
    /// The clusters come from the transcript because the map only holds the
    /// ones that have a name. `assign` deletes an entry rather than storing a
    /// blank, so a meeting nobody has worked through has an empty map, and
    /// counting the unnamed from the map alone reported no work to do in
    /// exactly the meetings holding the most of it.
    ///
    /// A meeting with no transcript yet keeps whatever the map named, so a row
    /// never loses a face while processing runs. The words no diarization
    /// interval claimed are left out, the way the speaker strip leaves them
    /// out: they belong to no cluster and there is nobody to name.
    ///
    /// A cluster holding under half a second is left out for the same reason
    /// the strip leaves it out, unless the map already names it. The strip is
    /// where a name is given, so counting a cluster the strip refuses to draw
    /// put a meeting under Unnamed that offers nothing to name.
    /// `recordingIndex` qualifies the keys, because a cluster identifier names
    /// a speaker inside one recording and both halves of a rejoined call number
    /// theirs from zero. Without it the two halves' `remote-001_speaker_00`
    /// collided and one of them vanished from the row.
    public static func speakers(
        clusters: [TranscriptSpeaker], named: [MeetingRowSpeaker], recordingIndex: Int = 0
    ) -> [MeetingRowSpeaker] {
        let byKey = Dictionary(named.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        func qualified(_ key: String) -> String {
            recordingIndex == 0 ? key : "\(recordingIndex)/\(key)"
        }
        let keys = clusters
            .filter { !$0.key.hasSuffix(SpeakerLabel.unattributed) }
            .filter { $0.isAudible || byKey[$0.key] != nil }
            .map(\.key)
        guard !keys.isEmpty else {
            return onePerPerson(named, qualifiedBy: qualified)
        }
        return onePerPerson(
            keys.map { key in
                let speaker = byKey[key]
                return MeetingRowSpeaker(
                    key: key,
                    displayName: speaker?.displayName,
                    identityID: speaker?.identityID,
                    participantID: speaker?.participantID
                )
            },
            qualifiedBy: qualified
        )
    }

    /// One face per person rather than one per diarization cluster.
    ///
    /// The same rule the speaker strip collapses by. The diarizer splits a voice
    /// into several clusters and the meeting client names each of them, so a
    /// call with one other person in it drew that person's face three times.
    /// The named member of a group leads it, because a face with a name on it
    /// says more than a grey circle standing for the same voice.
    ///
    /// Grouped on the recording's own keys and qualified afterwards. A sensor
    /// key carries the participant identifier in the key itself, and the
    /// qualifying prefix hides it.
    private static func onePerPerson(
        _ speakers: [MeetingRowSpeaker], qualifiedBy qualified: (String) -> String
    ) -> [MeetingRowSpeaker] {
        let byKey = Dictionary(
            speakers.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let groups = SpeakerGrouping.groups(speakers.map {
            SpeakerGroupMember(
                key: $0.key, displayName: $0.displayName, identityID: $0.identityID,
                participantID: $0.participantID
            )
        })
        return groups.compactMap { group -> MeetingRowSpeaker? in
            let members = group.compactMap { byKey[$0.key] }
            guard var leader = members.first(where: \.isNamed) ?? members.first else { return nil }
            leader.key = qualified(leader.key)
            return leader
        }
    }

    /// What a finished read of the transcripts may put into the index.
    ///
    /// A read that was in flight when a rewrite landed holds the words as they
    /// were before it. Merging those back, with the meeting marked as covered,
    /// left search answering from the old transcript for the life of the
    /// window, because nothing asks for a meeting the index believes it holds.
    /// The meetings dropped while the read ran are therefore left out of both.
    public static func admissible(
        read: [String: String], droppedWhileReading: Set<String>
    ) -> [String: String] {
        read.filter { !droppedWhileReading.contains($0.key) }
    }

    /// Grouped by when, newest first: today, yesterday, the rest of this month,
    /// then one section per month.
    ///
    /// By when rather than by anything else, because the question a person
    /// arrives with is "the call about the audio SDK, some time in July".
    public static func sections(
        _ rows: [MeetingRow],
        filter: MeetingsFilter = .all,
        query: String = "",
        transcripts: [String: String] = [:],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [MeetingsSection] {
        let visible = rows
            .filter { filter.admits($0) && matches($0, query: query, transcript: transcripts[$0.id]) }
            .sorted { $0.startedAt > $1.startedAt }

        // One formatter for the whole grouping. Building one costs about
        // 0.13 ms, and search regroups every meeting in the archive on every
        // keystroke: 500 meetings spread over two years spent 69 ms of the main
        // actor per keystroke building 500 of these.
        let months = monthFormatter(calendar: calendar)
        var sections: [MeetingsSection] = []
        var current: (title: String, rows: [MeetingRow])?
        for row in visible {
            let title = sectionTitle(for: row.startedAt, now: now, calendar: calendar, months: months)
            if current?.title == title {
                current?.rows.append(row)
            } else {
                if let current { sections.append(MeetingsSection(title: current.title, rows: current.rows)) }
                current = (title, [row])
            }
        }
        if let current { sections.append(MeetingsSection(title: current.title, rows: current.rows)) }
        return sections
    }

    /// The heading a meeting belongs under.
    ///
    /// A date in the future gets today's heading rather than one of its own: an
    /// imported file whose device clock ran ahead should not open a section
    /// above today.
    public static func sectionTitle(
        for date: Date, now: Date, calendar: Calendar = .current
    ) -> String {
        sectionTitle(for: date, now: now, calendar: calendar, months: monthFormatter(calendar: calendar))
    }

    private static func sectionTitle(
        for date: Date, now: Date, calendar: Calendar, months: DateFormatter
    ) -> String {
        // Against `now` rather than through `isDateInToday`, which reads the
        // system clock and would ignore the date it was handed.
        if calendar.isDate(date, inSameDayAs: now) || date > now { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return "Earlier this month" }
        return months.string(from: date)
    }

    /// The month and year, in the reader's own language and order.
    private static func monthFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }
}
