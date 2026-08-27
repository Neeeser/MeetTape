import AppKit
import Foundation
import Observation
import PipitCore
import PipitServices
import SwiftUI

/// Which part of a meeting the detail pane is showing.
public enum MeetingDetailTab: String, CaseIterable, Identifiable, Sendable {
    case transcript
    case summary
    case notes

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .transcript: "Transcript"
        case .summary: "Summary"
        case .notes: "Notes"
        }
    }
}

/// What the last speaker change did, in one line.
///
/// Shown because the change reaches files the user opens in the Finder, and a
/// rename that silently rewrote `transcript.md` gave no sign it had.
public struct MeetingReceipt: Sendable, Equatable {
    public var text: String
    public var meetingID: String
}

/// The meetings window: everything ever recorded on the left, one of them on the
/// right.
///
/// Replaces the post-meeting review panel, which only existed for as long as
/// somebody left it open. A meeting that scrolled out of the menu's recent list
/// could then only be reached through the Finder, where nothing can rename a
/// speaker.
@MainActor
@Observable
public final class MeetingsWindowModel {
    public var rows: [MeetingRow] = []
    public var filter = MeetingsFilter.all
    public var query = ""
    /// Meetings the user has clicked. More than one puts the batch panel in the
    /// detail pane, as the People window does.
    public var selection: Set<String> = []
    public var tab = MeetingDetailTab.transcript
    public var receipt: MeetingReceipt?
    /// The focused meeting's own model, which owns reading and editing its
    /// files. One at a time: a window holding forty transcripts in memory is a
    /// window that stops scrolling.
    public var detail: MeetingReviewModel?
    public var isLoading = true
    /// Every transcript, lowercased, once the background read has finished.
    /// Until then a search matches titles, speakers and notes alone.
    public var searchesTranscripts = false

    @ObservationIgnored private var transcripts: [String: String] = [:]
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    /// The meetings the index covers, and how many recordings each entry was
    /// read from, so one recorded since it was built is noticed rather than
    /// silently left out of search.
    ///
    /// The count is there because an entry holds every recording of a
    /// conversation. Combining and separating change which words belong to a
    /// row without changing its identifier, and an entry left alone then
    /// answered for words the meeting no longer holds.
    @ObservationIgnored private var indexed: [String: Int] = [:]
    /// Meetings a rewrite dropped from the index while a batch read was in
    /// flight. The batch holds their words as they were before the rewrite, so
    /// it must not put them back.
    @ObservationIgnored private var droppedWhileReading: Set<String> = []
    @ObservationIgnored private var loadTask: Task<[MeetingRow], Never>?
    /// Counts the changes this window has made to the archive itself, which are
    /// combining, separating, archiving and deleting. A read that started before
    /// one of them holds the archive as it was, and assigning it put the rows
    /// back that the user had just taken out.
    @ObservationIgnored private var archiveChanges = 0
    @ObservationIgnored let runtime: PipitRuntime

    public init(runtime: PipitRuntime) {
        self.runtime = runtime
    }

    // MARK: - loading

    /// Reads the archive, keeping whatever is selected selected.
    ///
    /// One read at a time. The window asks for one when it appears and again
    /// whenever it is brought forward, and both arrive together on the first
    /// open, which read every meeting on disk twice.
    public func reload() async {
        if let inFlight = loadTask {
            // The read already running answers this caller too, and whoever
            // started it puts the rows on screen.
            _ = await inFlight.value
            return
        }
        var loaded: [MeetingRow] = []
        while true {
            let changes = archiveChanges
            let task = Task { [runtime] in await runtime.meetingRows() }
            loadTask = task
            loaded = await task.value
            loadTask = nil
            // Read again rather than drawing an archive that has changed under
            // the read. One more read per change the user made, and only while
            // one was already running.
            if changes == archiveChanges { break }
        }
        rows = loaded
        isLoading = false
        // The meeting the pane is showing stays selected even when this read
        // did not see it. A recording that finished after the read began is not
        // in these rows, and dropping it moved the user off the meeting a
        // notification had just opened.
        let present = Set(loaded.map(\.id))
        selection = selection.filter { present.contains($0) || $0 == detail?.meetingID }
        if selection.isEmpty, let first = sections.first?.rows.first {
            select(first.id, extending: false)
        } else if selection.count == 1, let focused = selection.first,
            detail?.meetingID != focused {
            // One at a time, and only what the pane is showing. A set has no
            // order, so taking the first of several selected rows opened a pane
            // on whichever one it happened to hand back, behind the panel that
            // covers a multiple selection.
            openDetail(focused)
        } else if let detail {
            // The pane survives the window being closed and opened again, and
            // the meeting it holds can have finished processing in between.
            await detail.reloadAll()
        }
        startIndexing()
    }

    /// Reads the transcripts the index does not hold, in the background, and
    /// turns on full-text search when they land.
    ///
    /// Run again whenever the archive holds a meeting the index does not, so a
    /// recording made while the window is open is searchable by its words too,
    /// and whenever a conversation gained or lost a recording. Only the
    /// meetings it does not already cover, because a rename drops one entry and
    /// re-reading the archive for it costs a file read per meeting on disk.
    private func startIndexing() {
        let counts = Dictionary(
            rows.map { ($0.id, $0.summary.recordingCount) }, uniquingKeysWith: { first, _ in first }
        )
        // An entry whose meeting has left the archive goes with it. Nothing
        // draws a row for that meeting any more, and a window left open for
        // weeks would otherwise still hold the words of every meeting deleted
        // under it.
        transcripts = transcripts.filter { counts[$0.key] != nil }
        indexed = indexed.filter { counts[$0.key] != nil }
        let missing = Set(counts.filter { indexed[$0.key] != $0.value }.keys)
        guard !missing.isEmpty else {
            searchesTranscripts = true
            return
        }
        indexTask?.cancel()
        droppedWhileReading = []
        indexTask = Task { [weak self] in
            guard let self else { return }
            let read = await runtime.transcriptSearchIndex(for: missing)
            guard !Task.isCancelled else { return }
            let stale = droppedWhileReading
            droppedWhileReading = []
            let admissible = MeetingsDirectoryFilter.admissible(
                read: read, droppedWhileReading: stale
            )
            transcripts.merge(admissible) { _, new in new }
            // Only the meetings that had words. A recording still being
            // transcribed has no `transcript.md` yet, and counting it as read
            // meant its words were never picked up once it had them.
            for (id, count) in counts where admissible[id] != nil { indexed[id] = count }
            searchesTranscripts = true
        }
    }

    /// Forgets the words held for one meeting, because a change now running
    /// will rewrite its `transcript.md`.
    ///
    /// One meeting rather than the whole index. Dropping everything meant a
    /// full archive read per click, and the read started before the rewrite it
    /// was waiting for had landed, so it put the same old words back.
    private func dropFromIndex(_ meetingID: String) {
        let conversation = conversationID(of: meetingID)
        transcripts.removeValue(forKey: conversation)
        indexed.removeValue(forKey: conversation)
        droppedWhileReading.insert(conversation)
    }

    /// The identifier the index answers under.
    ///
    /// An entry holds every recording of a conversation under the
    /// conversation's own identifier, while the pane opened on the half a
    /// notification named is keyed on that half. Dropping under the pane's
    /// identifier removed nothing, so a batch read in flight put the
    /// pre-rewrite words back and search answered from them for the life of
    /// the window.
    ///
    /// Answered from what is already in memory. Resolving it through the
    /// archive is a directory walk, and naming one person on thirty corrected
    /// lines would do thirty of them.
    private func conversationID(of meetingID: String) -> String {
        if rows.contains(where: { $0.id == meetingID }) { return meetingID }
        if detail?.meetingID == meetingID, let primary = detail?.recordings.first?.id {
            return primary
        }
        return meetingID
    }

    /// Whether the index holds this meeting's words. For tests, which cannot
    /// otherwise tell a read that was skipped from one that found nothing.
    public func indexHolds(_ meetingID: String) -> Bool {
        transcripts[meetingID] != nil
    }

    /// Reads one meeting's words again, once the rewrite has landed.
    ///
    /// Merged rather than assigned by the identifier that was asked for. The
    /// read answers under the conversation's identifier, and a correction made
    /// on the second half of a dropped call names the second half.
    private func refreshIndexEntry(_ meetingID: String) async {
        let read = await runtime.transcriptSearchIndex(for: [meetingID])
        transcripts.merge(read) { _, new in new }
        for id in read.keys {
            // An identifier with no row of its own is left out rather than
            // recorded as covered, so the next read of the archive picks it up.
            indexed[id] = rows.first { $0.id == id }?.summary.recordingCount
        }
    }

    public func end() {
        indexTask?.cancel()
        indexTask = nil
        detail?.saveEdits()
    }

    // MARK: - the list

    public var sections: [MeetingsSection] {
        MeetingsDirectoryFilter.sections(
            rows, filter: filter, query: query, transcripts: transcripts
        )
    }

    public var selectedRows: [MeetingRow] {
        rows.filter { selection.contains($0.id) }
    }

    /// The rows this filter holds, before the search query narrows them. What
    /// the footer counts against, because with anything archived the archive's
    /// own total is a number no list on screen adds up to.
    public var filteredRows: [MeetingRow] { rows.filter { filter.admits($0) } }

    /// The total of the meetings this filter holds, for the footer.
    public var totalDuration: Double { PipitRuntime.totalDuration(of: filteredRows) }

    public func select(_ id: String, extending: Bool) {
        if extending {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
        // The detail model writes what was typed into it before the pane shows
        // another meeting. Without this, moving the selection while a title was
        // half-edited threw the edit away.
        if selection.count == 1, let focused = selection.first {
            openDetail(focused)
        } else {
            detail?.saveEdits()
            detail = nil
        }
    }

    /// Opens one meeting, whether or not it is in the list the filter is
    /// showing. A notification about a meeting that has just finished has to
    /// land on it even while the sidebar is filtered to Unnamed.
    public func show(meetingID: String) {
        let resolved = runtime.repository.logicalMeeting(id: meetingID)?.id ?? meetingID
        selection = [resolved]
        openDetail(resolved)
    }

    private func openDetail(_ id: String) {
        guard detail?.meetingID != id else { return }
        detail?.saveEdits()
        receipt = nil
        tab = .transcript
        let opened = MeetingReviewModel(runtime: runtime, meetingID: id)
        // A title or a note written from the pane changes what the list shows.
        // The write happens a moment after typing stops, so the row is read
        // again when it lands rather than when the pane is left.
        opened.onEditsSaved = { [weak self] in
            guard let self else { return }
            Task { await self.refreshRow(id) }
        }
        detail = opened
        Task { [weak self] in await self?.detail?.reloadAll() }
    }

    /// Reads one meeting again, after processing moved on or somebody changed a
    /// speaker.
    ///
    /// The runtime reports at a stage boundary and after every speaker change,
    /// so a rename arrives here too. The row is read again with it, because a
    /// rename rewrites the speaker map the list draws its faces from and the
    /// stage it is in has not changed.
    ///
    /// Whether or not the pane is showing that meeting. The report names
    /// whichever meeting the change happened to, and a recording finishing while
    /// the user reads an older one is the ordinary case. Gating this on the pane
    /// left every other row in the list showing the stage its meeting was in
    /// when the window opened. One row rather than the archive, because a
    /// correction on a line reports the same way and there can be one per click.
    public func refresh(meetingID: String) async {
        await reread(meetingID)
    }

    /// Links the meeting the pane is showing to the earlier one it continues,
    /// then reads the archive again.
    ///
    /// The listing hides a folded continuation, so this takes a row out of the
    /// list rather than changing one, which is more than reading one row back
    /// can do. The selection moves to the conversation, because the identifier
    /// the pane was opened on is the half that has just been folded in.
    ///
    /// Moved before the archive read, in the same turn as the combine. The
    /// merge is already on disk when `combineWithEarlier` returns, so the
    /// folded identifier resolves to the conversation immediately. Moving it
    /// after the read left the selection dangling on the folded row for as
    /// long as the pane took to reload, which the archive read waits on.
    public func combineWithEarlier() {
        guard let detail else { return }
        let meetingID = detail.meetingID
        detail.combineWithEarlier()
        archiveChanges += 1
        show(meetingID: meetingID)
        Task { [weak self] in await self?.reload() }
    }

    /// Undoes that link, then reads the archive again. The recording that comes
    /// back is a row of its own, and nothing short of a read knows it is there.
    public func separate(_ recordingID: String) {
        detail?.detach(recordingID)
        archiveChanges += 1
        Task { [weak self] in await self?.reload() }
    }

    /// Reads one meeting's files again: the pane if it is showing that meeting,
    /// then the row and the words search holds for it.
    private func reread(_ meetingID: String) async {
        if detail?.meetingID == meetingID { await detail?.reloadAll() }
        await refreshRow(meetingID)
        await refreshIndexEntry(meetingID)
    }

    /// Reads one row again, taking the clusters from the pane that is open on
    /// it. The transcript is the largest file in the folder and the pane has
    /// just read it.
    ///
    /// Placed by the identifier the row came back with rather than the one that
    /// was asked for. A recording folded into another answers under the
    /// conversation's identifier, and keying the replacement on the identifier
    /// of the half that changed put a second row for the same conversation in
    /// the list.
    private func refreshRow(_ meetingID: String) async {
        let clusters = detail?.meetingID == meetingID ? detail?.transcript?.speakers : nil
        guard let row = await runtime.meetingRow(id: meetingID, clusters: clusters) else { return }
        if let index = rows.firstIndex(where: { $0.id == row.id }) {
            rows[index] = row
        } else {
            rows.append(row)
        }
    }

    // MARK: - speakers

    /// Names a whole cluster and says what it changed.
    public func assignCluster(_ row: MeetingSpeakerRow, to entry: SpeakerDirectoryEntry) {
        applyClusterChange(row, name: entry.identity.resolvedName) {
            self.detail?.assignCluster(row.clusterID, in: row.recordingID, to: entry)
        }
    }

    public func assignCluster(_ row: MeetingSpeakerRow, toNewPerson name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        applyClusterChange(row, name: trimmed) {
            self.detail?.assignCluster(row.clusterID, in: row.recordingID, toNewPerson: trimmed)
        }
    }

    public func clearCluster(_ row: MeetingSpeakerRow) {
        applyClusterChange(row, name: nil) {
            self.detail?.clearCluster(row.clusterID, in: row.recordingID)
        }
    }

    /// Counts the lines before the change, applies it, and records what
    /// happened. Counted first because the assignment re-resolves the names the
    /// count is taken from.
    private func applyClusterChange(
        _ row: MeetingSpeakerRow, name: String?, _ apply: () -> Void
    ) {
        guard let detail else { return }
        let meetingID = detail.meetingID
        // The lines of the recording this writes the speaker map of. A cluster
        // identifier names a speaker inside one recording, and both halves of a
        // rejoined call number their speakers from zero, so the same identifier
        // in the other half is somebody else and this change does not reach it.
        //
        // A line whose speaker a person set is left out. A correction on the
        // line beats the cluster's entry, so that line reads the same after
        // this as before it, and counting it made the receipt claim a line
        // nothing had changed.
        let lines = detail.combinedLines.count {
            $0.recordingID == row.recordingID && $0.utterance.speakerKey == row.clusterID
                && !$0.isCorrected
        }
        apply()
        let what = name.map { "Named \($0)" } ?? "Cleared the name"
        receipt = MeetingReceipt(
            text: "\(what) on \(lines) \(lines == 1 ? "line" : "lines"). "
                + "transcript.md and the speaker map are rewritten.",
            meetingID: meetingID
        )
        dropFromIndex(meetingID)
    }

    /// Records a correction made on the words themselves.
    public func noteLineCorrection(_ name: String, lines: Int) {
        guard let meetingID = detail?.meetingID else { return }
        receipt = MeetingReceipt(
            text: "Gave \(lines) \(lines == 1 ? "line" : "lines") to \(name). "
                + "transcript.md and the speaker map are rewritten.",
            meetingID: meetingID
        )
        dropFromIndex(meetingID)
    }

    public func dismissReceipt() { receipt = nil }

    // MARK: - archiving and trashing

    /// A move to the Trash, held until the person who asked for it confirms.
    ///
    /// Carries the meetings it will move rather than reading the selection back
    /// when the button is pressed. The alert clears its own state as it
    /// dismisses, and a handler that reads it there finds nothing to do.
    public struct MeetingsTrash: Identifiable, Equatable {
        public let id = UUID()
        public var targets: [String]
        public var names: [String]
        /// The folder of each meeting, from the meetings root down, so the
        /// confirmation names what leaves the archive.
        public var folders: [String]
        /// How many folders go. A call that dropped and was rejoined is one row
        /// over two of them, and naming one while moving both understated what
        /// the button does.
        public var folderCount: Int

        public var title: String {
            targets.count == 1
                ? "Move \(names.first ?? "this meeting") to the Trash?"
                : "Move \(targets.count) meetings to the Trash?"
        }

        public var message: String {
            if folderCount == 1 {
                return "The folder \(folders.first ?? "") and everything in it, the audio "
                    + "included, is moved to the Trash rather than deleted."
            }
            if targets.count == 1 {
                return "This call was recorded in \(folderCount) folders. All of them and "
                    + "everything in them, the audio included, are moved to the Trash rather "
                    + "than deleted."
            }
            return "\(folderCount) meeting folders and everything in them, the audio included, "
                + "are moved to the Trash rather than deleted."
        }
    }

    public var pendingTrash: MeetingsTrash?

    /// What a right-click acts on. The whole selection when the row is part of
    /// it, and that row alone otherwise. Right-clicking a row outside the
    /// selection acting on some other row is the way this goes wrong.
    public func contextTargets(for row: MeetingRow) -> [MeetingRow] {
        selection.contains(row.id) ? selectedRows : [row]
    }

    public func confirmTrash(_ rows: [MeetingRow]) {
        guard !rows.isEmpty else { return }
        pendingTrash = MeetingsTrash(
            targets: rows.map(\.id),
            names: rows.map(\.title),
            folders: rows.map { Self.archivePath(of: $0.summary.directory) },
            folderCount: rows.reduce(0) { $0 + $1.summary.recordingCount }
        )
    }

    /// The folder from the meetings root down. The absolute path is long enough
    /// to push an alert wide, and the part a person recognises is the end.
    static func archivePath(of directory: URL) -> String {
        directory.pathComponents.suffix(3).joined(separator: "/")
    }

    /// What the move could not do. The window says it in an alert, because the
    /// row simply coming back says nothing at all.
    public var trashProblem: String?

    /// Runs a confirmed move. Takes it as an argument rather than reading
    /// `pendingTrash`, which the alert's dismissal has already cleared.
    public func performTrash(_ trash: MeetingsTrash) async {
        pendingTrash = nil
        // Counted before the first await. A read of the archive that finishes
        // inside the move below holds meetings this is taking out, and
        // assigning it put them back and opened the pane on one of them.
        archiveChanges += 1
        // The pane is holding a read of files that are about to go. What was
        // typed into it is written first anyway, because the move can be
        // refused and the meeting is then still there to hold it.
        if let focused = detail?.meetingID, trash.targets.contains(focused) {
            detail?.saveEdits()
            detail = nil
        }
        for id in trash.targets { dropFromIndex(id) }
        let outcomes = await runtime.trashMeetings(trash.targets)
        var recording: String?
        var failed: [String] = []
        var gone: Set<String> = []
        var noTrash: [String] = []
        for (index, id) in trash.targets.enumerated() {
            let name = trash.names.indices.contains(index) ? trash.names[index] : id
            switch outcomes[id] ?? .notFound {
            // Out of the archive either way. A meeting nothing can find was
            // already gone before this row was drawn.
            case .trashed, .notFound: gone.insert(id)
            case .refusedWhileRecording: recording = name
            case .folderNotMoved: failed.append(name)
            case .volumeHasNoTrash: noTrash.append(name)
            }
        }
        // Only what actually went. A meeting that was refused keeps its row and
        // its place in the selection, and reload opens the pane on it again.
        rows.removeAll { gone.contains($0.id) }
        selection.subtract(gone)
        trashProblem = Self.problemText(recording: recording, failed: failed, noTrash: noTrash)
        await reload()
    }

    /// What is still in the archive, and why. Nil when everything went.
    ///
    /// Each cause gets its own sentence. A folder that would not move,
    /// reported as a recording in progress, sent the reader looking for a call
    /// that had already ended. `recording` is one meeting at most, because one
    /// is all this Mac records at a time.
    public nonisolated static func problemText(
        recording: String?, failed: [String], noTrash: [String] = []
    ) -> String? {
        var sentences: [String] = []
        if let recording {
            sentences.append(
                "\(recording) is being recorded, and is kept until the recording stops."
            )
        }
        if failed.count == 1 {
            sentences.append("\(failed[0]) has a folder this Mac would not move to the Trash.")
        } else if failed.count > 1 {
            sentences.append(
                "\(failed.count) meetings have folders this Mac would not move to the Trash."
            )
        }
        if !noTrash.isEmpty {
            // The meetings folder can be anywhere the user pointed it, and a
            // network share and an exFAT disk have no Trash at all. Without
            // this the alert read as a fault on one meeting and the same thing
            // happened to every one of them.
            sentences.append(
                "The meetings folder is on a volume with no Trash, so nothing was moved. "
                    + "The Finder can delete these folders."
            )
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// Takes meetings out of the list, or puts them back. Nothing on disk
    /// moves.
    public func setArchived(_ archived: Bool, _ rows: [MeetingRow]) {
        guard !rows.isEmpty else { return }
        let ids = rows.map(\.id)
        runtime.setArchived(archived, meetingIDs: ids)
        archiveChanges += 1
        // The rows leave whichever list is on screen, so the pane must not stay
        // open on one of them. What was typed into it is written first. The
        // files stay where they are, so a title half-typed when the row was
        // archived still belongs to a meeting.
        if let focused = detail?.meetingID, ids.contains(focused) {
            detail?.saveEdits()
            detail = nil
        }
        selection.subtract(ids)
        Task { [weak self] in await self?.reload() }
    }

    // MARK: - actions on the selection

    public func revealSelection() { revealTargets(selectedRows) }

    public func revealTargets(_ rows: [MeetingRow]) {
        for row in rows { runtime.revealInFinder(meetingID: row.id) }
    }

    public func revealArchive() { runtime.revealArchive() }

    public func rebuildSelection() { rebuildTargets(selectedRows) }

    public func rebuildTargets(_ rows: [MeetingRow]) {
        for row in rows { rebuild(row.id) }
    }

    /// Re-assembles the meeting the pane is showing.
    public func rebuildFocusedMeeting() {
        guard let detail else { return }
        rebuild(detail.meetingID)
    }

    /// Re-assembles one transcript and reads back what it wrote.
    ///
    /// Nothing else watches a rebuild finish, and it rewrites the file search
    /// reads and the speaker map the row draws its faces from. Waiting for the
    /// next reload left the list and the index describing the transcript the
    /// meeting used to have.
    private func rebuild(_ meetingID: String) {
        dropFromIndex(meetingID)
        runtime.rebuildTranscript(meetingID: meetingID) { [weak self] in
            Task { await self?.reread(meetingID) }
        }
    }

    public func text(_ keyPath: ReferenceWritableKeyPath<MeetingsWindowModel, String>) -> Binding<String> {
        Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }
}
