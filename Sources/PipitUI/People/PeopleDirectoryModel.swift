import AppKit
import Foundation
import PipitCore
import PipitServices
import PipitSpeakers
import Observation
import SwiftUI

/// Everyone Pipit can recognise, and the edits a person makes to them.
///
/// The list is the whole directory in one array; searching, filtering and
/// grouping happen in `PeopleDirectoryFilter` over that array rather than in a
/// query, because at the scale this exists for the whole thing is a few hundred
/// small rows and re-reading the database on every keystroke would be the
/// slower of the two.
@MainActor
@Observable
public final class PeopleDirectoryModel {
    public var entries: [SpeakerDirectoryEntry] = []
    public var statistics: SpeakerStore.Statistics?
    public var query = ""
    public var filter = PeopleFilter.all
    public var selection: Set<IdentityID> = []
    /// Loaded when a row is about to be drawn, and kept, because scrolling back
    /// up a list of four hundred people would otherwise re-read every image.
    public var avatars: [IdentityID: NSImage] = [:]
    /// The focused person's confirmed platform accounts. Loaded with the
    /// detail pane; empty for everyone else and while nobody is focused.
    public private(set) var handles: [IdentityHandle] = []

    /// The person whose detail pane is on screen, when exactly one is selected.
    public var focused: SpeakerDirectoryEntry? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return entries.first { $0.id == id }
    }

    public var selectedEntries: [SpeakerDirectoryEntry] {
        entries.filter { selection.contains($0.id) }
    }

    public var sections: [PeopleDirectorySection] {
        PeopleDirectoryFilter.sections(entries, filter: filter, query: query)
    }

    public var visibleCount: Int { sections.reduce(0) { $0 + $1.entries.count } }

    // MARK: - editing drafts

    public var nameDraft = ""
    public var organizationDraft = ""
    public var notesDraft = ""
    /// Which identity the drafts above belong to, so a selection change that
    /// arrives before a save does not write one person's notes onto another.
    @ObservationIgnored private var draftOwner: IdentityID?
    /// Notes typed but not yet written, with who they belong to. Held apart from
    /// the timer so that moving the selection flushes them instead of cancelling
    /// them.
    @ObservationIgnored private var unsavedNotes: (owner: IdentityID, text: String)?
    @ObservationIgnored private var notesTimer: Task<Void, Never>?

    public var pendingAction: PeopleAction?
    public var organizationPrompt: OrganizationPrompt?

    @ObservationIgnored let runtime: PipitRuntime

    public init(runtime: PipitRuntime) {
        self.runtime = runtime
    }

    /// A destructive step, held until the person who asked for it confirms.
    ///
    /// Carries everything it needs to run. Reading the model's own state back
    /// when the button is pressed is what made the old confirmation a no-op: the
    /// alert clears its state as it dismisses, and the handler then found
    /// nothing to do.
    public struct PeopleAction: Identifiable, Equatable {
        public enum Kind: Equatable { case forgetVoice, delete, purge }
        public let id = UUID()
        public var targets: [IdentityID]
        public var names: [String]
        public var kind: Kind

        public var title: String {
            switch kind {
            case .forgetVoice: "Forget \(subject)'s voice?"
            case .delete: targets.count == 1 ? "Delete \(subject)?" : "Delete \(targets.count) people?"
            case .purge: "Delete \(targets.count) unnamed voice\(targets.count == 1 ? "" : "s")?"
            }
        }

        public var message: String {
            switch kind {
            case .forgetVoice:
                "Past transcripts keep the name. Pipit will not recognise this "
                    + "voice again until someone confirms it on a new recording."
            case .delete, .purge:
                "The name and every recording of \(targets.count == 1 ? "this voice" : "these voices") "
                    + "are removed. This cannot be undone."
            }
        }

        public var confirmLabel: String {
            switch kind {
            case .forgetVoice: "Forget voice"
            case .delete, .purge: "Delete"
            }
        }

        private var subject: String { names.first ?? "this voice" }
    }

    /// Setting one organization across a selection.
    public struct OrganizationPrompt: Identifiable, Equatable {
        public let id = UUID()
        public var targets: [IdentityID]
        public var draft: String
    }

    // MARK: - loading

    public func reload() async {
        entries = await runtime.speakerDirectory()
        statistics = await runtime.voiceMemoryStatistics()
        // A person deleted elsewhere must not stay selected, or the detail pane
        // keeps editing a row that is gone.
        let live = Set(entries.map(\.id))
        selection.formIntersection(live)
        avatars = avatars.filter { live.contains($0.key) }
        if let focused { loadDrafts(from: focused) }
        refreshHandles()
    }

    /// Reads the focused person's platform accounts, or clears them when the
    /// focus is gone. A merge can carry accounts in, so this runs on reload as
    /// well as on selection.
    private func refreshHandles() {
        guard let focused else { handles = []; return }
        let id = focused.id
        Task { [weak self] in
            guard let self else { return }
            let fetched = await runtime.personHandles(of: id)
            if self.focused?.id == id { self.handles = fetched }
        }
    }

    /// Withdraws one account link. The person and their voice stay.
    public func unlink(_ handle: IdentityHandle) async {
        await runtime.unlinkHandle(handle)
        refreshHandles()
    }

    public func avatarImage(for entry: SpeakerDirectoryEntry) -> NSImage? {
        if let cached = avatars[entry.id] { return cached }
        guard entry.identity.hasAvatar else { return nil }
        Task { [weak self] in
            guard let self, let data = await runtime.avatar(of: entry.id),
                  let image = NSImage(data: data)
            else { return }
            avatars[entry.id] = image
        }
        return nil
    }

    // MARK: - selection and drafts

    public func select(_ id: IdentityID, extending: Bool) {
        // Before the drafts move to somebody else, or the note just typed is
        // overwritten by theirs and never written anywhere.
        Task { await flushNotes() }
        if extending {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
        if let focused { loadDrafts(from: focused) } else { draftOwner = nil }
        refreshHandles()
    }

    private func loadDrafts(from entry: SpeakerDirectoryEntry) {
        guard draftOwner != entry.id else { return }
        draftOwner = entry.id
        nameDraft = entry.identity.isNamed ? entry.identity.resolvedName : ""
        organizationDraft = entry.identity.organization ?? ""
        notesDraft = entry.identity.notes ?? ""
    }

    // MARK: - editing one person

    public func commitName() async {
        await flushNotes()
        guard let entry = focused else { return }
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let organization = organizationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        await runtime.renamePerson(
            entry.id, to: name, organization: organization.isEmpty ? nil : organization
        )
        draftOwner = nil
        await reload()
    }

    /// Notes save a beat after typing stops.
    ///
    /// Writing on every keystroke would re-render the participant block of every
    /// meeting this person appears in, once per character. The text is held
    /// separately from the timer so that anything which moves the drafts on can
    /// flush it: cancelling the timer instead threw away whatever was typed in
    /// the last beat, silently.
    public func notesChanged() {
        guard let owner = draftOwner else { return }
        unsavedNotes = (owner, notesDraft)
        notesTimer?.cancel()
        notesTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await self?.flushNotes()
        }
    }

    /// Writes whatever is typed and not yet stored. Safe to call when there is
    /// nothing outstanding.
    public func flushNotes() async {
        notesTimer?.cancel()
        notesTimer = nil
        guard let pending = unsavedNotes else { return }
        unsavedNotes = nil
        await runtime.setNotes(pending.text, on: pending.owner)
        // Written back in place rather than reloading: a full reload while the
        // field has focus would replace the row being edited.
        if let index = entries.firstIndex(where: { $0.id == pending.owner }) {
            entries[index].identity.notes = pending.text.isEmpty ? nil : pending.text
        }
    }

    public func toggleBadge(_ badge: PersonBadge) async {
        guard let entry = focused else { return }
        var badges = entry.identity.badges
        if let index = badges.firstIndex(of: badge) { badges.remove(at: index) } else {
            badges.append(badge)
        }
        await runtime.setBadges(badges, on: entry.id)
        await reload()
    }

    public func chooseAvatar() async {
        guard let entry = focused else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url), let png = Self.thumbnailPNG(image)
        else { return }
        await runtime.setAvatar(png, on: entry.id)
        avatars[entry.id] = NSImage(data: png)
        await reload()
    }

    public func removeAvatar() async {
        guard let entry = focused else { return }
        await runtime.setAvatar(nil, on: entry.id)
        avatars[entry.id] = nil
        await reload()
    }

    /// Square, 256 points, PNG. Stored rather than the original because a
    /// directory of a few hundred people holding whatever came off a camera is
    /// tens of megabytes to draw a 26 point circle.
    static func thumbnailPNG(_ image: NSImage, side: CGFloat = 256) -> Data? {
        let target = NSSize(width: side, height: side)
        let output = NSImage(size: target)
        output.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let source = image.size
        let scale = max(target.width / max(source.width, 1), target.height / max(source.height, 1))
        let scaled = NSSize(width: source.width * scale, height: source.height * scale)
        image.draw(
            in: NSRect(
                x: (target.width - scaled.width) / 2, y: (target.height - scaled.height) / 2,
                width: scaled.width, height: scaled.height
            ),
            from: .zero, operation: .copy, fraction: 1
        )
        output.unlockFocus()
        guard let tiff = output.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - actions on a selection

    public func confirmDeleteSelection() {
        let targets = selectedEntries
        guard !targets.isEmpty else { return }
        pendingAction = PeopleAction(
            targets: targets.map(\.id), names: targets.map(\.identity.resolvedName), kind: .delete
        )
    }

    public func confirmForgetVoice() {
        guard let entry = focused else { return }
        pendingAction = PeopleAction(
            targets: [entry.id], names: [entry.identity.resolvedName], kind: .forgetVoice
        )
    }

    /// Unnamed voices heard in fewer meetings than this are the ones a purge
    /// takes. Answered from what is already loaded, so the menu item can show
    /// the count and go quiet at zero rather than being a button that does
    /// nothing without saying why.
    public static let purgeThreshold = 2

    public var purgeCandidates: [SpeakerDirectoryEntry] {
        entries.filter { !$0.identity.isNamed && $0.meetingCount < Self.purgeThreshold }
    }

    public func confirmPurge() {
        let targets = purgeCandidates
        guard !targets.isEmpty else { return }
        pendingAction = PeopleAction(
            targets: targets.map(\.id), names: targets.map(\.identity.resolvedName), kind: .purge
        )
    }

    /// Runs a confirmed action. Takes it as an argument rather than reading
    /// `pendingAction`, which the alert's own dismissal has already cleared by
    /// the time this runs.
    public func perform(_ action: PeopleAction) async {
        pendingAction = nil
        // A note typed a moment ago must not be written back onto a row this is
        // about to remove, nor lost when the person survives.
        await flushNotes()
        switch action.kind {
        case .forgetVoice:
            for target in action.targets { await runtime.forgetVoice(of: target) }
        case .delete, .purge:
            await runtime.deletePeople(action.targets)
            selection.subtract(action.targets)
        }
        await reload()
    }

    /// Enabled at exactly two, because "these are the same person" is a
    /// statement about a pair. Three selected is two decisions.
    public var canMerge: Bool { selection.count == 2 }

    public func mergeSelection() async {
        let targets = selectedEntries
        guard targets.count == 2 else { return }
        // Into the named one where there is exactly one, so the surviving row is
        // the one with a name on it. Otherwise into the one heard more often.
        let ordered = targets.sorted { left, right in
            if left.identity.isNamed != right.identity.isNamed { return right.identity.isNamed }
            return left.meetingCount < right.meetingCount
        }
        await runtime.mergeIdentities(ordered[0].id, into: ordered[1].id)
        selection = [ordered[1].id]
        await reload()
    }

    public func beginSetOrganization() {
        let targets = selectedEntries
        guard !targets.isEmpty else { return }
        organizationPrompt = OrganizationPrompt(
            targets: targets.map(\.id),
            draft: targets.count == 1 ? (targets[0].identity.organization ?? "") : ""
        )
    }

    public func commitOrganization(_ prompt: OrganizationPrompt) async {
        organizationPrompt = nil
        // This clears the draft owner and reloads, so an outstanding note goes
        // first or the field reverts to the text before it was typed.
        await flushNotes()
        let trimmed = prompt.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        await runtime.setOrganization(trimmed.isEmpty ? nil : trimmed, on: prompt.targets)
        draftOwner = nil
        await reload()
    }

    // MARK: - bindings

    public func text(_ keyPath: ReferenceWritableKeyPath<PeopleDirectoryModel, String>) -> Binding<String> {
        Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }
}
