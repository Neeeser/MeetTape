import AppKit
import Foundation
import PipitAudio
import PipitCore
import PipitDetection
import PipitIntegrations
import PipitServices
import PipitSpeakers
import Observation
import SwiftUI

// SwiftUI's `@State` and `@Binding` are macros in the current SDK, and their
// plugin ships with Xcode rather than the Command Line Tools this project builds
// with. View state therefore lives in `@Observable` models that the window
// manager owns, and bindings are built explicitly. The observation macro is
// available, so views still update automatically.

@MainActor
@Observable
public final class SettingsModel {
    public var statuses: [PermissionStatus] = []
    public var hostStatus: NativeMessagingInstaller.Status?
    public var sensorStatus: BrowserSensorServer.Status?
    public var localUserName: String
    public var apiKey = ""
    public var hasStoredKey: Bool
    public var testState = TestState.idle
    public var voiceStatistics: SpeakerStore.Statistics?
    /// Everyone with a name, for choosing which of them is you.
    public var people: [SpeakerDirectoryEntry] = []
    /// Whether the name field holds something a person typed.
    ///
    /// Leaving the pane writes the field, because a name typed and not
    /// submitted is still a name they meant. Writing it unconditionally
    /// re-rendered the markdown of every meeting the local user appears in,
    /// every time the pane was left, and could rename the person just chosen in
    /// the picker to the name of the one before them.
    @ObservationIgnored private var nameEdited = false
    /// What the archive costs on disk. Nil until the first walk finishes, which
    /// is what the Storage page draws "Calculating…" for.
    public var archiveUsage: ArchiveUsage?
    public var isMeasuringArchive = false
    /// Opens the people directory. Set by the window manager, which owns both
    /// this model and that window.
    @ObservationIgnored public var onOpenPeople: (() -> Void)?

    public enum TestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    @ObservationIgnored let runtime: PipitRuntime

    public init(runtime: PipitRuntime) {
        self.runtime = runtime
        self.localUserName = runtime.settings.localUserName
        // Deliberately not read here. A keychain lookup can block on an
        // authorisation prompt, and building a view is not the place to
        // discover that: the panel would hang with nothing on screen.
        self.hasStoredKey = false
    }

    public func refresh() async {
        statuses = await runtime.permissions.allStatuses()
        hostStatus = NativeMessagingInstaller().status()
        sensorStatus = runtime.sensorStatus
        // Off the main actor: this call blocks until the person answers the
        // login-keychain prompt macOS raises when the item's ACL does not
        // trust the binary, which every unsigned rebuild produces. Run inline
        // it froze the whole window, and the panel behind the prompt was the
        // one that would have explained it.
        hasStoredKey = await Task.detached { KeychainAPIKeyStore().hasKey }.value
    }

    public func request(_ kind: PermissionKind) async {
        let status = await runtime.permissions.request(kind)
        statuses = await runtime.permissions.allStatuses()
        // Accessibility and Screen Recording are switched on in System Settings.
        // The request above is what adds Pipit to that list; opening the pane
        // straight after it puts the switch in front of the user.
        if !status.isUsable, kind == .accessibility || kind == .screenRecording {
            runtime.permissions.openSettings(for: kind)
        }
        Log.ui.info(
            "requested \(kind.rawValue, privacy: .public): now \(status.state.rawValue, privacy: .public)"
        )
    }

    public func saveLocalUserName() {
        var settings = runtime.settings
        settings.localUserName = localUserName.isEmpty ? "Me" : localUserName
        runtime.updateSettingsAndIdentity(settings)
    }

    public func saveKey() {
        let saved = apiKey
        hasStoredKey = KeychainAPIKeyStore().save(saved)
        // The runtime holds the key for the process, so a rotated one has to be
        // handed over rather than waiting for a relaunch.
        if hasStoredKey { runtime.apiKeys.adopt(saved) }
        apiKey = ""
        testState = .idle
    }

    public func removeKey() {
        _ = KeychainAPIKeyStore().delete()
        runtime.apiKeys.invalidateCachedKey()
        hasStoredKey = false
        testState = .idle
    }

    public func testConnection() async {
        testState = .testing
        if !apiKey.isEmpty { saveKey() }
        do {
            try await OpenAIClient(keyProvider: runtime.apiKeys)
                .verifyCredentials(model: runtime.settings.models.diarization)
            testState = .success
        } catch let error as ProcessingError {
            testState = .failure(error.userMessage)
        } catch {
            testState = .failure("Could not reach OpenAI")
        }
    }

    public func installHost() {
        guard let binary = NativeMessagingInstaller.bundledHostURL() else { return }
        hostStatus = try? NativeMessagingInstaller().install(hostBinary: binary)
    }

    public func chooseStorage() {
        guard let url = pickDirectory() else { return }
        var settings = runtime.settings
        settings.storageRootPath = url.path
        runtime.update(settings: settings)
        // The measurement belongs to the folder it was taken in, and the
        // Storage page draws it under whatever path is current.
        archiveUsage = nil
        Task { await refreshArchiveUsage() }
    }

    /// The counts the Storage page draws. Nothing about who you are, so a pane
    /// that only wants numbers cannot reach into the name field.
    public func refreshVoiceStatistics() async {
        voiceStatistics = await runtime.voiceMemoryStatistics()
    }

    /// The directory and the name beside it, for the pane that picks who you
    /// are.
    ///
    /// The field is left alone while it holds something typed. Reading the
    /// directory suspends for as long as it takes to score every profile, and a
    /// straggling read landing after somebody started typing would put the
    /// stored name back under them and drop what they wrote.
    public func refreshPeople() async {
        await refreshVoiceStatistics()
        people = await runtime.speakerDirectory(kind: .person)
        guard !nameEdited else { return }
        localUserName = runtime.settings.localUserName
    }

    /// The name field. Writes through the identity, and remembers that somebody
    /// typed in it.
    public var localUserNameField: Binding<String> {
        Binding(
            get: { self.localUserName },
            set: { typed in
                self.localUserName = typed
                self.nameEdited = true
            }
        )
    }

    /// Which person in the directory is you, or nil before one is picked.
    public var localUserIdentityID: IdentityID? {
        runtime.settings.processing.localUserIdentityID
    }

    /// Points the microphone track at an existing person.
    ///
    /// Their profile then carries everything the track teaches, and an imported
    /// recording naming you lands on the same row rather than a second one.
    public func chooseLocalUser(_ identityID: IdentityID) async {
        await runtime.setLocalUser(identityID)
        // Before the reads below, which await. A name half typed for the person
        // who was you a moment ago must not survive into the window where
        // Settings already names somebody else: leaving the tab there would
        // rename the person just chosen to what was in the field.
        localUserName = runtime.settings.localUserName
        nameEdited = false
        await refreshPeople()
    }

    /// Renames whoever is you, or names them for the first time.
    ///
    /// Through the identity where there is one, so the name in Settings and the
    /// name in People cannot drift apart.
    public func commitLocalUserName() async {
        guard nameEdited else { return }
        let name = localUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            localUserName = runtime.settings.localUserName
            nameEdited = false
            return
        }
        guard name != runtime.settings.localUserName else {
            nameEdited = false
            return
        }
        if let identityID = localUserIdentityID {
            await runtime.renamePerson(identityID, to: name)
        } else {
            saveLocalUserName()
        }
        // The field is now what the identity says, so it is no longer something
        // typed. Cleared before the read below, which leaves the field alone
        // while this is true.
        nameEdited = false
        await refreshPeople()
    }

    public func openPeople() { onOpenPeople?() }

    /// Measures the archive off the main actor.
    ///
    /// A walk of every file of every meeting ever recorded, so it is kept for
    /// the life of the window and only redone when asked. Opening Storage a
    /// second time shows the number it already has.
    public func refreshArchiveUsage(force: Bool = false) async {
        guard !isMeasuringArchive else { return }
        guard force || archiveUsage == nil else { return }
        isMeasuringArchive = true
        defer { isMeasuringArchive = false }
        let repository = runtime.repository
        archiveUsage = await Task.detached(priority: .utility) { repository.usage() }.value
    }

    /// What the installed speech models take, as the local model state reports
    /// it. Zero before that state has been read.
    public var installedModelBytes: Int64 {
        LocalModelUnit.allCases.reduce(Int64(0)) { total, unit in
            total + (runtime.localModelState.present.bytes(for: unit) ?? 0)
        }
    }

    public func installLocalModels() async {
        await runtime.installLocalModels()
    }

    /// Reads and writes one settings value in place.
    public func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.runtime.settings[keyPath: keyPath] },
            set: { newValue in
                var settings = self.runtime.settings
                settings[keyPath: keyPath] = newValue
                self.runtime.update(settings: settings)
            }
        )
    }

    public func text(_ keyPath: ReferenceWritableKeyPath<SettingsModel, String>) -> Binding<String> {
        Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }
}

/// A stretch of one track that is about to change speaker.
///
/// In the recording's own coordinates, not the conversation's, because that is
/// where a boundary is written and a continuation keeps its own timeline.
public struct SpeakerRangeTarget: Sendable, Equatable {
    public var recordingID: String
    public var track: CaptureTrack
    /// One window per line the reader was pointing at. Chunks overlap, so two
    /// lines of one turn routinely hold the same second and a single range over
    /// the track would reach the wrong one.
    public var parts: [SpeakerRangePart]

    public init(recordingID: String, track: CaptureTrack, parts: [SpeakerRangePart]) {
        self.recordingID = recordingID
        self.track = track
        self.parts = parts
    }
}

/// Loads and edits one meeting's files.
@MainActor
@Observable
public final class MeetingReviewModel {
    public var metadata: MeetingMetadata?
    public var transcript: CanonicalTranscript?
    public var notes = ""
    public var title = ""
    public var summary: String?
    public var errorMessage: String?
    /// Detected speakers with how each was decided, refreshed alongside the
    /// transcript.
    public var speakerRows: [MeetingSpeakerRow] = []
    /// Names the model heard for speakers nothing else could name. Never
    /// applied on its own: the strip draws them and the user decides.
    public var speakerSuggestions: [MeetingSuggestionRow] = []
    /// Everyone Pipit could put on a line, for the pickers.
    public var knownPeople: [SpeakerDirectoryEntry] = []
    public var expectedParticipants: [String] = []
    public var participantDraft = ""
    /// The cluster waiting for a typed name, and the recording it belongs to.
    public var namingCluster: (clusterID: String, recordingID: String)?
    /// The stretch of one track waiting for a name, after a split or a
    /// selection whose speaker is not in the list yet.
    public var namingRange: SpeakerRangeTarget?
    /// The turn waiting for a name.
    public var namingBlock: CombinedLineBlock?
    public var newPersonDraft = ""
    public var reanalyzeCount = ""
    public var isReanalyzing = false

    @ObservationIgnored let runtime: PipitRuntime
    @ObservationIgnored public let meetingID: String
    /// Called when a title or a note reached disk, so the list around this pane
    /// can read the row again.
    @ObservationIgnored public var onEditsSaved: (() -> Void)?
    /// What the last read put on screen, so an edit made since is recognisable.
    @ObservationIgnored private var lastLoadedTitle = ""
    @ObservationIgnored private var lastLoadedNotes = ""
    @ObservationIgnored private var pendingEditSave: Task<Void, Never>?

    public init(runtime: PipitRuntime, meetingID: String) {
        self.runtime = runtime
        self.meetingID = meetingID
        reload()
    }

    /// Where the meeting lives, resolved when the files were last read.
    ///
    /// Stored rather than computed. `findMeeting` walks the archive root, then
    /// every year and month directory, and decodes a metadata.json; the panel's
    /// body reads this alongside the processing fraction, so a computed property
    /// ran that walk on the main actor for every progress tick. Local
    /// diarization reports hundreds of times in a few seconds, and the actor
    /// doing the walking is the one arming the next recording.
    public private(set) var directory: URL?

    /// Every recording of this conversation, earliest first, and their lines in
    /// one sequence.
    ///
    /// A call that dropped and was rejoined is two recordings on disk. It was one
    /// meeting, so it reads as one: the panel opens on the recording it started
    /// with and shows both halves in order. Corrections still go to the recording
    /// the line came from, because each keeps its own diarization and speaker
    /// map.
    public private(set) var recordings: [MeetingMetadata] = []
    public private(set) var combinedLines: [CombinedLine] = []
    /// Line identifiers the user has set the speaker on, for the pencil marker.
    public private(set) var correctedLines: Set<String> = []

    public var isSplitRecording: Bool { recordings.count > 1 }

    /// Reloads the files and then the parts that need the identity store.
    ///
    /// The pane opens as soon as the audio is safe, which is before there is a
    /// transcript, so a one-shot load left the speaker strip empty for the life
    /// of the window and every line's menu offering nobody to pick.
    public func reloadAll() async {
        reload()
        await reloadSpeakers()
    }

    public func reload() {
        // Resolved through the whole conversation, so opening a continuation by
        // its own identifier lands on the recording the meeting started with
        // rather than on "no longer on disk". A notification posted before two
        // recordings were linked still carries that identifier.
        guard let logical = runtime.repository.logicalMeeting(id: meetingID) else {
            errorMessage = "This meeting is no longer on disk."
            return
        }
        // Cleared on a read that found it, so a meeting that came back, or one
        // opened after a folder went missing, does not keep the notice.
        errorMessage = nil
        let found = (metadata: logical.primary.metadata, store: logical.primary.store)
        recordings = logical.recordings.map(\.metadata)
        combinedLines = logical.combinedTranscript()
        correctedLines = Set(combinedLines.filter(\.isCorrected).map(\.id))
        metadata = found.metadata
        directory = found.store.layout.root
        continuationSuggestion = found.metadata.possibleContinuationOf
            .flatMap { runtime.repository.findMeeting(id: $0) }
            .flatMap { earlier in
                found.metadata.possibleContinuationReason
                    .map { (title: earlier.metadata.displayTitle, reason: $0) }
            }
        // Title and notes are only written to disk on save, so taking the
        // file's copy while the user is typing throws away what they typed.
        // Progress ticks and every speaker action come through here.
        let storedTitle = found.metadata.titles.human ?? found.metadata.displayTitle
        if title == lastLoadedTitle { title = storedTitle }
        lastLoadedTitle = storedTitle
        let storedNotes = found.store.readNotes()
        if notes == lastLoadedNotes { notes = storedNotes }
        lastLoadedNotes = storedNotes
        summary = found.store.readSummary()
        transcript = try? found.store.readCanonicalTranscript()
        expectedParticipants = found.metadata.participants
            .filter { $0.origin == .human }
            .map(\.displayName)
    }

    /// The parts that need the identity store, which the file read does not.
    public func reloadSpeakers() async {
        speakerRows = await runtime.speakers(inMeeting: meetingID).filter(\.hasSpeechToShow)
        speakerSuggestions = runtime.speakerSuggestions(inMeeting: meetingID)
        knownPeople = await runtime.speakerDirectory(kind: .person)
    }

    /// Names one cluster in the recording it was diarized in. Applies
    /// immediately, re-renders the transcript, and does not re-run
    /// transcription or diarization.
    ///
    /// The recording rather than the conversation. A call recorded in two
    /// halves keeps a speaker map per half, and both number their speakers from
    /// zero, so a name written against the conversation landed on a different
    /// person in the other half.
    public func assignCluster(
        _ clusterID: String, in recordingID: String, to entry: SpeakerDirectoryEntry
    ) {
        runtime.assignSpeaker(
            name: entry.identity.resolvedName, key: clusterID, meetingID: recordingID,
            identityID: entry.id
        )
    }

    public func assignCluster(_ clusterID: String, in recordingID: String, toNewPerson name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        runtime.assignSpeaker(name: trimmed, key: clusterID, meetingID: recordingID)
    }

    public func clearCluster(_ clusterID: String, in recordingID: String) {
        runtime.assignSpeaker(name: "", key: clusterID, meetingID: recordingID)
    }

    /// Renames every line of one turn.
    ///
    /// The header stands for the whole block, and the lines under it no longer
    /// carry a menu of their own. Naming only the first would rename the first
    /// thirty seconds of a three-minute answer and tear the paragraph in two on
    /// the next reload.
    public func assignBlock(_ block: CombinedLineBlock, to entry: SpeakerDirectoryEntry) {
        assignBlock(block, name: entry.identity.resolvedName, identityID: entry.id)
    }

    public func assignBlock(_ block: CombinedLineBlock, toNewPerson name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        assignBlock(block, name: trimmed, identityID: nil)
    }

    /// Hands the block back to whatever its cluster says.
    public func clearBlock(_ block: CombinedLineBlock) {
        assignBlock(block, name: "", identityID: nil)
    }

    private func assignBlock(
        _ block: CombinedLineBlock, name: String, identityID: IdentityID?
    ) {
        runtime.assignUtteranceSpeakers(
            name: name, utteranceIDs: block.lines.map(\.utterance.id),
            meetingID: block.recordingID, identityID: identityID
        )
        for line in block.lines {
            if name.isEmpty {
                correctedLines.remove(line.id)
            } else {
                correctedLines.insert(line.id)
            }
            guard let index = combinedLines.firstIndex(where: { $0.id == line.id }) else { continue }
            combinedLines[index].speakerName = name.isEmpty
                ? SpeakerMap.fallbackName(for: line.utterance.speakerKey)
                : name
            // Written on the line as well as into `correctedLines`, because a
            // receipt counts the lines the cluster's entry still names. Updating
            // only the set meant naming the speaker right after correcting a
            // turn reported that turn's lines, which the entry no longer names.
            combinedLines[index].isCorrected = !name.isEmpty
        }
    }

    /// Divides a turn and hands the stretch to someone.
    ///
    /// No optimistic update: a division changes where the lines are, so the
    /// panel shows it once the write lands and the reload that follows it
    /// rebuilds the blocks. Naming a whole line moves one name and can be shown
    /// straight away; this cannot without rebuilding the same thing twice.
    public func assignRange(_ target: SpeakerRangeTarget, to entry: SpeakerDirectoryEntry) {
        runtime.assignSpeakerRange(
            name: entry.identity.resolvedName, meetingID: target.recordingID,
            track: target.track, parts: target.parts, identityID: entry.id
        )
    }

    public func assignRange(_ target: SpeakerRangeTarget, toNewPerson name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        runtime.assignSpeakerRange(
            name: trimmed, meetingID: target.recordingID, track: target.track,
            parts: target.parts
        )
    }

    public func beginNamingRange(_ target: SpeakerRangeTarget) {
        namingRange = target
        namingBlock = nil
        namingCluster = nil
        newPersonDraft = ""
    }

    /// Whether anything in the transcript is waiting for a name.
    public var isNaming: Bool { namingRange != nil || namingBlock != nil }

    public func beginNamingBlock(_ block: CombinedLineBlock) {
        namingBlock = block
        namingRange = nil
        namingCluster = nil
        newPersonDraft = ""
    }

    /// Separates a recording from the conversation it was linked to.
    public func detach(_ recordingID: String) {
        runtime.detachContinuation(meetingID: recordingID)
        reload()
    }

    public func beginNamingCluster(_ clusterID: String, in recordingID: String) {
        namingCluster = (clusterID, recordingID)
        namingRange = nil
        namingBlock = nil
        newPersonDraft = ""
    }

    public func cancelNaming() {
        namingCluster = nil
        namingRange = nil
        namingBlock = nil
        newPersonDraft = ""
    }

    public func commitNaming() {
        if let target = namingRange {
            assignRange(target, toNewPerson: newPersonDraft)
        } else if let block = namingBlock {
            assignBlock(block, toNewPerson: newPersonDraft)
        } else if let cluster = namingCluster {
            assignCluster(cluster.clusterID, in: cluster.recordingID, toNewPerson: newPersonDraft)
        }
        cancelNaming()
    }

    public func addParticipant() {
        let trimmed = participantDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        expectedParticipants.append(trimmed)
        participantDraft = ""
        saveParticipants()
    }

    public func removeParticipant(_ name: String) {
        expectedParticipants.removeAll { $0 == name }
        saveParticipants()
    }

    /// Records who the user says was present and re-runs identity resolution
    /// alone. No audio is read and nothing is transcribed again.
    public func saveParticipants() {
        let names = expectedParticipants
        Task { [runtime, meetingID] in
            await runtime.setExpectedParticipants(names, meetingID: meetingID)
        }
    }

    /// Re-runs clustering, optionally at a speaker count the user chose. The
    /// words are untouched.
    /// The typed speaker count, if it is one a clusterer can use.
    ///
    /// Blank means decide automatically, which is the tuned configuration and
    /// beat the exact true count on word attribution. Anything else has to be a
    /// real count: zero or a negative went straight into the clusterer, and the
    /// result overwrote the good run with no undo in the panel.
    /// The typed count, or nil for "decide automatically".
    ///
    /// Whether the number is one a clusterer can act on is `hasValidReanalyzeCount`,
    /// which is what the Run button and `reanalyze()` are gated on.
    public var reanalyzeSpeakerCount: Int? {
        let trimmed = reanalyzeCount.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Int(trimmed)
    }

    /// Re-analysis runs the on-device diarizer whatever the meeting was
    /// processed with, so it needs the models. Without this the Run button
    /// started a 650 MB download from a control that says nothing about one.
    public var localModelsReady: Bool { runtime.localModelState.isUsable }

    /// Whether the typed count is one a clusterer can act on. Empty is valid
    /// and means decide automatically.
    public var hasValidReanalyzeCount: Bool {
        let trimmed = reanalyzeCount.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        guard let count = Int(trimmed) else { return false }
        return (1...50).contains(count)
    }

    public var canReanalyze: Bool {
        !isReanalyzing && localModelsReady && hasValidReanalyzeCount
    }

    public func reanalyzeSpeakers() {
        guard canReanalyze else { return }
        isReanalyzing = true
        runtime.reanalyzeSpeakers(
            meetingID: meetingID,
            speakerCount: reanalyzeSpeakerCount
        ) { [weak self] in
            self?.isReanalyzing = false
        }
    }

    /// Saved straight away, even while transcription is still running.
    ///
    /// Through the same write as the debounced save, so it reports what it
    /// wrote. Writing here directly told nobody, and Return in the title field
    /// left the row in the list showing the old title, which is the one moment
    /// the user is watching for it to change. Writing the notes unconditionally
    /// also threw away a note added from the menu bar while the pane was open.
    public func save() {
        saveEdits()
        reload()
    }

    /// Writes what has been typed a moment after typing stops.
    ///
    /// Notes reached disk only when the panel closed and the title only when
    /// Return was pressed, under a card that says editing is saved immediately.
    /// Quitting with the panel open lost both, and `onDisappear` does not run
    /// on termination, so closing the window was the only path that saved.
    private func scheduleEditSave() {
        pendingEditSave?.cancel()
        pendingEditSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.saveEdits()
        }
    }

    /// Writes the title and notes, each only when the user changed it.
    ///
    /// Reports back when either reached disk, because the meetings list draws
    /// the title and searches the notes.
    public func saveEdits() {
        var wrote = false
        if title != lastLoadedTitle {
            runtime.saveTitle(title, meetingID: meetingID)
            lastLoadedTitle = title
            wrote = true
        }
        if notes != lastLoadedNotes {
            saveNotes()
            wrote = true
        }
        if wrote { onEditsSaved?() }
    }

    /// Writes the notes only when the user changed them.
    ///
    /// Called when the panel closes, and it writes the whole file. A quick note
    /// added from the menu bar while the panel was open appends to that file
    /// directly, so an unconditional write on close threw it away: the panel had
    /// loaded the notes before the append and still held the older text.
    public func saveNotes() {
        guard notes != lastLoadedNotes else { return }
        runtime.saveNotes(notes, meetingID: meetingID)
        lastLoadedNotes = notes
    }

    public func retry() { runtime.retryProcessing(meetingID: meetingID) }

    /// How far the current stage has got, when the backend reports it. A local
    /// transcription has no chunks to count, and a stage showing nothing for
    /// four minutes reads as hung.
    public var progress: ProcessingPipeline.Progress? { runtime.processing[meetingID] }

    public func text(_ keyPath: ReferenceWritableKeyPath<MeetingReviewModel, String>) -> Binding<String> {
        Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }

    /// The earlier meeting this one may continue, and why.
    ///
    /// Resolved at reload for the same reason `directory` is: reading it needed
    /// a second archive walk, in the panel body, in exactly the case where a new
    /// recording is most likely to be starting.
    public private(set) var continuationSuggestion: (title: String, reason: String)?

    public func combineWithEarlier() {
        guard let earlierID = metadata?.possibleContinuationOf else { return }
        runtime.combine(meetingID: meetingID, into: earlierID, reason: "confirmed by the user")
        reload()
    }

    public func keepSeparate() {
        runtime.keepSeparate(meetingID: meetingID)
        reload()
    }
    public func reveal() { runtime.revealInFinder(meetingID: meetingID) }

    public func titleBinding() -> Binding<String> {
        Binding(get: { self.title }, set: { self.title = $0; self.scheduleEditSave() })
    }

    public func notesBinding() -> Binding<String> {
        Binding(get: { self.notes }, set: { self.notes = $0; self.scheduleEditSave() })
    }
}

@MainActor
func pickDirectory() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Use Folder"
    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK else { return nil }
    return panel.url
}
