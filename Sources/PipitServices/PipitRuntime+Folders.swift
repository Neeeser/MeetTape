import AppKit
import Foundation
import PipitCore

/// One folder as the meetings window draws it.
public struct FolderRow: Sendable, Equatable, Identifiable {
    public var folder: MeetingFolder
    public var meetingCount: Int
    /// When the newest meeting in it started. Nil for an empty folder, which
    /// sorts to the bottom.
    public var newestAt: Date?
    public var totalDuration: Double
    /// The people who turn up in it most, for the faces on the row.
    public var regulars: [MeetingRowSpeaker]

    public var id: String { folder.name }
    public var name: String { folder.name }
}

/// Making folders, filing meetings into them, and the offer that follows.
///
/// Every read here walks the archive, so it runs off the main actor for the
/// same reason `meetingRows` does.
extension PipitRuntime {
    public var folderStore: MeetingFolderStore { MeetingFolderStore(archive: repository.archive) }

    public func folders() -> [MeetingFolder] { folderStore.folders() }

    /// Every folder with what the row needs, newest first.
    public func folderRows() async -> [FolderRow] {
        let repository = self.repository
        return await Task.detached(priority: .userInitiated) {
            let store = MeetingFolderStore(archive: repository.archive)
            return store.folders().map { folder in
                let summaries = repository.meetings(inFolder: folder.name)
                    .filter { !$0.isArchived }
                var seen: [String: MeetingRowSpeaker] = [:]
                var order: [String] = []
                for summary in summaries.prefix(12) {
                    for store in repository.stores(ofConversation: summary) {
                        guard let map = try? store.readSpeakerMap() else { continue }
                        for entry in map.entries.values where !entry.displayName.isEmpty {
                            let key = entry.displayName
                            if seen[key] == nil {
                                seen[key] = MeetingRowSpeaker(
                                    key: key, displayName: entry.displayName,
                                    identityID: entry.identityID
                                )
                                order.append(key)
                            }
                        }
                    }
                }
                return FolderRow(
                    folder: folder,
                    meetingCount: summaries.count,
                    newestAt: summaries.first?.startedAt,
                    totalDuration: summaries.reduce(0) { $0 + $1.durationSeconds },
                    regulars: order.prefix(3).compactMap { seen[$0] }
                )
            }
            .sorted { left, right in
                switch (left.newestAt, right.newestAt) {
                case (let a?, let b?): a > b
                case (nil, _?): false
                case (_?, nil): true
                case (nil, nil): left.name < right.name
                }
            }
        }.value
    }

    // MARK: making and changing folders

    @discardableResult
    public func createFolder(name: String, about: String = "") throws -> MeetingFolder {
        let folder = try folderStore.create(name: name, about: about)
        refreshRecentMeetings()
        return folder
    }

    public func updateFolder(_ folder: MeetingFolder) throws {
        try folderStore.write(folder)
    }

    @discardableResult
    public func renameFolder(_ name: String, to newName: String) throws -> MeetingFolder {
        let folder = try folderStore.rename(name, to: newName)
        // Every meeting in it moved with the directory, so what the rows say
        // about where they are is now a launch behind.
        refreshRecentMeetings()
        return folder
    }

    /// Takes a folder away, putting everything in it back under `YYYY/MM`.
    ///
    /// The meetings are moved one at a time and the folder is only removed once
    /// they are all out, so a move that fails leaves a folder that still holds
    /// what could not be moved rather than a deletion that lost it.
    public func deleteFolder(_ name: String) -> [String: any Error] {
        var failures: [String: any Error] = [:]
        for summary in repository.meetings(inFolder: name) {
            do {
                try repository.move(meetingID: summary.id, toFolder: nil)
            } catch {
                failures[summary.id] = error
            }
        }
        if failures.isEmpty {
            do { try folderStore.delete(name) } catch { failures[name] = error }
        }
        refreshRecentMeetings()
        return failures
    }

    // MARK: filing

    /// Files meetings into a folder, or takes them out when `folder` is nil.
    /// Returns the ones that would not move, with why.
    @discardableResult
    public func file(meetingIDs: [String], in folder: String?) -> [String: any Error] {
        var failures: [String: any Error] = [:]
        for id in meetingIDs {
            do {
                try repository.move(meetingID: id, toFolder: folder)
            } catch {
                failures[id] = error
                Log.app.error("filing failed: \(logSafeDescription(error), privacy: .public)")
            }
        }
        refreshRecentMeetings()
        return failures
    }

    // MARK: the offer

    /// The folder this meeting was offered, or nil when it was offered none,
    /// has already been filed, or turned the offer down.
    public func folderSuggestion(for meetingID: String) -> FolderSuggestion? {
        guard let found = repository.findMeeting(id: meetingID) else { return nil }
        guard found.metadata.acceptsFolderSuggestion else { return nil }
        guard let suggestion = found.store.readFolderSuggestion() else { return nil }
        // A folder can be renamed or deleted between the offer and the reading
        // of it, and an offer to file into somewhere that is gone is worse than
        // no offer.
        guard folderStore.exists(suggestion.folderName) else { return nil }
        return suggestion
    }

    /// Takes the offer. Returns the proposal to make a rule out of it, when
    /// there is a series behind the meeting worth offering one for.
    @discardableResult
    public func acceptFolderSuggestion(for meetingID: String) -> RecurringProposal? {
        guard let suggestion = folderSuggestion(for: meetingID) else { return nil }
        guard file(meetingIDs: [meetingID], in: suggestion.folderName).isEmpty else { return nil }
        return recurringProposal(for: meetingID)
    }

    /// Turns the offer down, for good. The suggestion stays on disk as the
    /// record of what was thought; the flag is what stops it being asked again.
    public func dismissFolderSuggestion(for meetingID: String) {
        guard let found = repository.findMeeting(id: meetingID) else { return }
        do {
            _ = try found.store.updateMetadata { $0.folderSuggestionDeclined = true }
        } catch {
            Log.app.error(
                "folder suggestion not dismissed: \(logSafeDescription(error), privacy: .public)"
            )
        }
        refreshRecentMeetings()
    }

    /// What else in the archive looks like this meeting, after it has been
    /// filed. Nil when nothing does, or when the user turned the offer off.
    public func recurringProposal(for meetingID: String) -> RecurringProposal? {
        guard settings.enrichment.noticesRecurringMeetings else { return nil }
        guard let found = repository.findMeeting(id: meetingID) else { return nil }
        guard let folder = found.metadata.folderName else { return nil }
        // A folder that already files on its own has been through this once.
        guard folderStore.folder(named: folder)?.filesAutomatically != true else { return nil }
        let facts = MeetingFacts(metadata: found.metadata)
        let archive = repository.listMeetings().compactMap { summary -> MeetingFacts? in
            guard summary.id != meetingID else { return nil }
            guard let metadata = try? MeetingStore(
                layout: MeetingLayout(root: summary.directory)
            ).readMetadata() else { return nil }
            return MeetingFacts(metadata: metadata)
        }
        return RecurringSeries.propose(for: facts, among: archive)
    }

    /// Saves the rule the recurring offer produced, and switches the folder on.
    public func saveRule(
        _ rule: FolderRule, on folderName: String, filesAutomatically: Bool = true
    ) throws {
        guard var folder = folderStore.folder(named: folderName) else {
            throw MeetingFolderError.folderNotFound(folderName)
        }
        folder.rule = rule
        folder.filesAutomatically = filesAutomatically
        try folderStore.write(folder)
    }

    /// How many meetings on disk a rule would take, for the line under the
    /// offer. The same predicate that files them, so the number cannot promise
    /// something filing does not do.
    public func meetingsMatching(_ rule: FolderRule) -> Int {
        guard !rule.isEmpty else { return 0 }
        return repository.listMeetings().count { summary in
            guard let metadata = try? MeetingStore(
                layout: MeetingLayout(root: summary.directory)
            ).readMetadata() else { return false }
            return rule.matches(MeetingFacts(metadata: metadata))
        }
    }

    public func revealFolder(_ name: String) {
        NSWorkspace.shared.activateFileViewerSelecting([
            repository.archive.folderDirectory(name),
        ])
    }
}
