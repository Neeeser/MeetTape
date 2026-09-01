import AppKit
import Foundation
import PipitCore

/// Reading the whole archive for the meetings window.
///
/// Every read here is file work over every meeting on disk, so none of it runs
/// on the main actor: at a few hundred meetings the walk alone is long enough
/// to drop frames in the window that asked for it, and that actor is also the
/// one arming the next recording.
extension PipitRuntime {
    /// Every meeting, with who was in it and the notes a search can match.
    public func meetingRows() async -> [MeetingRow] {
        let repository = self.repository
        return await Task.detached(priority: .userInitiated) {
            repository.listMeetings().map { summary in
                Self.row(summary: summary, stores: repository.stores(ofConversation: summary))
            }
        }.value
    }

    /// One meeting's row again, after something rewrote its files.
    ///
    /// `clusters` is what the pane open on the meeting has already read. The
    /// transcript is the largest file in the folder, so this reads the three
    /// small ones and takes the clusters from the caller. Passing nil reads
    /// them.
    ///
    /// The identifier is resolved through the whole conversation, so a
    /// correction made on the second half of a dropped call reaches the row the
    /// list draws for it. The row is always the conversation's own, which is
    /// what keeps a folded continuation out of the listing while an operation
    /// named by its identifier still lands.
    public func meetingRow(id: String, clusters: [TranscriptSpeaker]?) async -> MeetingRow? {
        let repository = self.repository
        return await Task.detached(priority: .userInitiated) {
            guard let logical = repository.logicalMeeting(id: id),
                  let summary = repository.summary(
                      forDirectory: logical.primary.store.layout.root
                  )
            else { return nil }
            return Self.row(
                summary: summary,
                stores: logical.recordings.map(\.store),
                clusters: clusters
            )
        }.value
    }

    /// A row's speakers are the clusters its transcript uses, named through its
    /// own `speakers.map.json`.
    ///
    /// The map rather than the identity store, which answers one query per
    /// meeting. The identifier on the entry is what keeps a person the same
    /// colour here and in the People window.
    ///
    /// The clusters come from the transcript because the map holds only the
    /// ones that have a name. Reading the speakers from the map alone reported
    /// no voices to name in exactly the meetings holding the most of them.
    /// Every recording of the conversation, because the list draws one row for
    /// a call that dropped and was rejoined. Reading the first half alone meant
    /// a voice that only spoke after the drop was in no row, and the Unnamed
    /// filter under-reported exactly the meetings that are hardest to work
    /// through.
    ///
    /// A cluster identifier names a speaker inside one recording, and both
    /// halves number theirs from zero, so each half's keys are qualified by the
    /// recording they came from before they are put in one list.
    private nonisolated static func row(
        summary: MeetingSummary, stores: [MeetingStore], clusters: [TranscriptSpeaker]? = nil
    ) -> MeetingRow {
        var speakers: [MeetingRowSpeaker] = []
        var notes: [String] = []
        for (index, store) in stores.enumerated() {
            let map = (try? store.readSpeakerMap()) ?? SpeakerMap()
            let named = map.entries
                .compactMap { key, assignment -> MeetingRowSpeaker? in
                    guard !assignment.displayName.isEmpty else { return nil }
                    return MeetingRowSpeaker(
                        key: key,
                        displayName: assignment.displayName,
                        identityID: assignment.identityID,
                        participantID: assignment.participantID
                    )
                }
                .sorted { $0.key < $1.key }
            // The clusters the caller passed belong to the recording the pane
            // is keyed on, which is the first. The rest are read.
            let keys = (index == 0 ? clusters : nil)
                ?? ((try? store.readTranscriptSpeakers()) ?? [])
            speakers.append(contentsOf: MeetingsDirectoryFilter.speakers(
                clusters: keys, named: named, recordingIndex: index
            ))
            let text = store.readNotes()
            if !text.isEmpty { notes.append(text) }
        }
        // Only for a meeting that could still act on one. A filed meeting and a
        // meeting that turned the offer down are the common cases, and neither
        // costs a read.
        let offered = stores.first.flatMap { store -> FolderSuggestion? in
            guard summary.folderName == nil else { return nil }
            guard let metadata = try? store.readMetadata(),
                  metadata.acceptsFolderSuggestion
            else { return nil }
            return store.readFolderSuggestion()
        }
        return MeetingRow(
            summary: summary, speakers: speakers, notes: notes.joined(separator: "\n"),
            folderSuggestion: offered
        )
    }

    /// The transcripts of the meetings named, lowercased, for searching.
    ///
    /// Built in the background after the list is already on screen, and
    /// searched only once it is ready. A search that works on titles
    /// immediately and gains the words a moment later beats a list that waits
    /// for a hundred file reads before it draws.
    ///
    /// The identifiers are named rather than the archive walked, so a rename
    /// and a rebuild each cost one meeting's read instead of the whole archive.
    /// A meeting with nothing written yet is absent from the result rather than
    /// present and empty, which is what lets the caller ask again once it has
    /// words.
    ///
    /// Answers under the conversation's identifier, holding every recording of
    /// it. A call that dropped and was rejoined keeps the second half's words in
    /// the second half's own folder, and the list draws one row for both, so an
    /// index built from the first half alone could not find anything said after
    /// the drop.
    ///
    /// The markdown is read rather than the canonical JSON, because it is the
    /// smaller of the two and holds the same words.
    public func transcriptSearchIndex(for meetingIDs: Set<String>) async -> [String: String] {
        let repository = self.repository
        return await Task.detached(priority: .utility) {
            var index: [String: String] = [:]
            for meetingID in meetingIDs {
                guard let logical = repository.logicalMeeting(id: meetingID) else { continue }
                let text = ([logical.primary] + logical.continuations)
                    .compactMap {
                        try? String(
                            contentsOf: $0.store.layout.transcriptMarkdown, encoding: .utf8
                        )
                    }
                    .joined(separator: "\n")
                guard !text.isEmpty else { continue }
                index[logical.id] = text.lowercased()
            }
            return index
        }.value
    }

    /// Opens the folder holding every meeting.
    public func revealArchive() {
        NSWorkspace.shared.open(repository.archive.root)
    }

    /// Total recorded time across the meetings named, for the footer and the
    /// multiple-selection panel.
    public static func totalDuration(of rows: [MeetingRow]) -> Double {
        rows.reduce(0) { $0 + $1.summary.durationSeconds }
    }
}
