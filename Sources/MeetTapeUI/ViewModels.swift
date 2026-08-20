import AppKit
import Foundation
import MeetTapeAudio
import MeetTapeCore
import MeetTapeDetection
import MeetTapeIntegrations
import MeetTapeServices
import MeetTapeSpeakers
import Observation
import SwiftUI

// SwiftUI's `@State` and `@Binding` are macros in the current SDK, and their
// plugin ships with Xcode rather than the Command Line Tools this project builds
// with. View state therefore lives in `@Observable` models that the window
// manager owns, and bindings are built explicitly. The observation macro is
// available, so views still update automatically.

@MainActor
@Observable
public final class OnboardingModel {
    public var statuses: [PermissionStatus] = []
    public var apiKey = ""
    public var apiKeyState = APIKeyState.unknown
    public var hostStatus: NativeMessagingInstaller.Status?
    public var storagePath = ""
    public var isChecking = false

    public enum APIKeyState: Equatable {
        case unknown
        case checking
        case valid
        case invalid(String)
    }

    @ObservationIgnored let runtime: MeetTapeRuntime

    public init(runtime: MeetTapeRuntime) {
        self.runtime = runtime
        self.storagePath = runtime.settings.storageRootPath
    }

    public func refresh() async {
        isChecking = true
        defer { isChecking = false }
        statuses = await runtime.permissions.allStatuses()
        hostStatus = NativeMessagingInstaller().status()
        storagePath = runtime.settings.storageRootPath
    }

    public func request(_ kind: PermissionKind) async {
        let status = await runtime.permissions.request(kind)
        statuses = await runtime.permissions.allStatuses()
        // Accessibility and Screen Recording are switched on in System Settings.
        // The request above is what adds MeetTape to that list; opening the pane
        // straight after it puts the switch in front of the user.
        if !status.isUsable, kind == .accessibility || kind == .screenRecording {
            runtime.permissions.openSettings(for: kind)
        }
        Log.ui.info(
            "requested \(kind.rawValue, privacy: .public): now \(status.state.rawValue, privacy: .public)"
        )
    }

    public func saveAndTestKey() async {
        apiKeyState = .checking
        let store = KeychainAPIKeyStore()
        guard store.save(apiKey) else {
            apiKeyState = .invalid("Could not write to the keychain")
            return
        }
        apiKey = ""
        do {
            try await OpenAIClient(keyProvider: store)
                .verifyCredentials(model: runtime.settings.models.diarization)
            apiKeyState = .valid
        } catch let error as ProcessingError {
            apiKeyState = .invalid(error.userMessage)
        } catch {
            apiKeyState = .invalid("Could not reach OpenAI")
        }
    }

    public func installHost() {
        guard let binary = NativeMessagingInstaller.bundledHostURL() else {
            hostStatus = NativeMessagingInstaller().status()
            return
        }
        hostStatus = try? NativeMessagingInstaller().install(hostBinary: binary)
    }

    public func chooseStorage() {
        guard let url = pickDirectory() else { return }
        var settings = runtime.settings
        settings.storageRootPath = url.path
        runtime.update(settings: settings)
        storagePath = url.path
    }

    public func finish() {
        var settings = runtime.settings
        settings.hasCompletedOnboarding = true
        runtime.update(settings: settings)
    }
}

@MainActor
@Observable
public final class SettingsModel {
    public var statuses: [PermissionStatus] = []
    public var hostStatus: NativeMessagingInstaller.Status?
    public var inputDescription = "Unknown"
    public var sensorStatus: BrowserSensorServer.Status?
    public var localUserName: String
    public var apiKey = ""
    public var hasStoredKey: Bool
    public var testState = TestState.idle
    public var people: [SpeakerDirectoryEntry] = []
    public var recurringVoices: [SpeakerDirectoryEntry] = []
    public var voiceStatistics: SpeakerStore.Statistics?
    public var renaming: SpeakerDirectoryEntry?
    public var renameDraft = ""
    public var renameOrganization = ""
    /// A destructive action waiting on the person who asked for it.
    ///
    /// Deleting a profile removes biometric material with no undo and no source
    /// to re-derive it from, and the local user's own row sits in this list one
    /// menu item away from Rename.
    public var pendingDestructiveAction: DestructiveAction?

    public struct DestructiveAction: Identifiable, Equatable {
        public enum Kind: Equatable { case forgetVoice, delete }
        public var id: IdentityID { entry.id }
        public var entry: SpeakerDirectoryEntry
        public var kind: Kind

        public var title: String {
            switch kind {
            case .forgetVoice: "Forget \(entry.identity.resolvedName)'s voice?"
            case .delete: "Delete \(entry.identity.resolvedName)?"
            }
        }

        public var message: String {
            switch kind {
            case .forgetVoice:
                "Past transcripts keep the name. MeetTape will not recognise this "
                    + "voice again until someone confirms it on a new recording."
            case .delete:
                "The name and every recording of this voice are removed. "
                    + "This cannot be undone."
            }
        }

        public var confirmLabel: String {
            switch kind {
            case .forgetVoice: "Forget Voice"
            case .delete: "Delete"
            }
        }
    }

    public enum TestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    @ObservationIgnored let runtime: MeetTapeRuntime

    public init(runtime: MeetTapeRuntime) {
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
        inputDescription = CoreAudioSystem.describeDefaultInput()
        sensorStatus = runtime.sensorStatus
        hasStoredKey = KeychainAPIKeyStore().hasKey
    }

    public func request(_ kind: PermissionKind) async {
        let status = await runtime.permissions.request(kind)
        statuses = await runtime.permissions.allStatuses()
        // Accessibility and Screen Recording are switched on in System Settings.
        // The request above is what adds MeetTape to that list; opening the pane
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
        hasStoredKey = KeychainAPIKeyStore().save(apiKey)
        apiKey = ""
        testState = .idle
    }

    public func removeKey() {
        _ = KeychainAPIKeyStore().delete()
        hasStoredKey = false
        testState = .idle
    }

    public func testConnection() async {
        testState = .testing
        if !apiKey.isEmpty { saveKey() }
        do {
            try await OpenAIClient(keyProvider: KeychainAPIKeyStore())
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
    }

    public func refreshPeople() async {
        people = await runtime.speakerDirectory(kind: .person)
        recurringVoices = await runtime.speakerDirectory(kind: .anonymous)
        voiceStatistics = await runtime.voiceMemoryStatistics()
    }

    public func beginRename(_ entry: SpeakerDirectoryEntry) {
        renaming = entry
        renameDraft = entry.identity.kind == .person ? entry.identity.resolvedName : ""
        renameOrganization = entry.identity.organization ?? ""
    }

    public func cancelRename() {
        renaming = nil
        renameDraft = ""
        renameOrganization = ""
    }

    /// Names a person, or gives a recurring unnamed voice a name for the first
    /// time. Every meeting that voice appeared in reads the new name; nothing is
    /// transcribed or diarized again.
    public func commitRename() async {
        guard let entry = renaming else { return }
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return cancelRename() }
        let organization = renameOrganization.trimmingCharacters(in: .whitespacesAndNewlines)
        await runtime.renamePerson(
            entry.id, to: name, organization: organization.isEmpty ? nil : organization
        )
        cancelRename()
        await refreshPeople()
    }

    public func confirmForgetVoice(_ entry: SpeakerDirectoryEntry) {
        pendingDestructiveAction = DestructiveAction(entry: entry, kind: .forgetVoice)
    }

    public func confirmDelete(_ entry: SpeakerDirectoryEntry) {
        pendingDestructiveAction = DestructiveAction(entry: entry, kind: .delete)
    }

    public func performPendingDestructiveAction() async {
        guard let action = pendingDestructiveAction else { return }
        pendingDestructiveAction = nil
        switch action.kind {
        case .forgetVoice: await runtime.forgetVoice(of: action.entry.id)
        case .delete: await runtime.deletePerson(action.entry.id)
        }
        await refreshPeople()
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

/// Loads and edits one meeting's files.
@MainActor
@Observable
public final class MeetingReviewModel {
    public var metadata: MeetingMetadata?
    public var transcript: CanonicalTranscript?
    public var speakers = SpeakerMap()
    public var notes = ""
    public var title = ""
    public var summary: String?
    public var errorMessage: String?
    public var draftNames: [String: String] = [:]
    /// Detected speakers with how each was decided, refreshed alongside the
    /// transcript.
    public var speakerRows: [MeetingSpeakerRow] = []
    /// Everyone MeetTape could put on a line, for the pickers.
    public var knownPeople: [SpeakerDirectoryEntry] = []
    public var expectedParticipants: [String] = []
    public var participantDraft = ""
    /// The line waiting for a name that is not in the list yet.
    public var namingUtterance: Utterance?
    /// The line waiting for a name, with the recording it belongs to.
    public var namingLine: CombinedLine?
    public var namingCluster: String?
    public var newPersonDraft = ""
    public var reanalyzeCount = ""
    public var isReanalyzing = false

    @ObservationIgnored let runtime: MeetTapeRuntime
    @ObservationIgnored public let meetingID: String
    /// What the last read put on screen, so an edit made since is recognisable.
    @ObservationIgnored private var lastLoadedTitle = ""
    @ObservationIgnored private var lastLoadedNotes = ""

    public init(runtime: MeetTapeRuntime, meetingID: String) {
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

    public var speakerKeys: [String] { transcript?.speakerKeys ?? [] }

    /// Reloads the files and then the parts that need the identity store.
    ///
    /// The panel opens as soon as the audio is safe, which is before there is a
    /// transcript, so a one-shot load left the Speakers card reading "No
    /// speakers identified yet" for the life of the window and every line's
    /// menu offering nobody to pick.
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
        speakers = (try? found.store.readSpeakerMap()) ?? SpeakerMap()
        transcript = try? found.store.readCanonicalTranscript()
        expectedParticipants = found.metadata.participants
            .filter { $0.origin == .human }
            .map(\.displayName)
    }

    /// The parts that need the identity store, which the file read does not.
    public func reloadSpeakers() async {
        speakerRows = await runtime.speakers(inMeeting: meetingID)
        knownPeople = await runtime.speakerDirectory(kind: .person)
    }

    /// Names one speaker's whole cluster. Applies immediately, re-renders the
    /// transcript, and does not re-run transcription or diarization.
    public func assignCluster(_ clusterID: String, to entry: SpeakerDirectoryEntry) {
        runtime.assignSpeaker(
            name: entry.identity.resolvedName, key: clusterID, meetingID: meetingID,
            identityID: entry.id
        )
    }

    public func assignCluster(_ clusterID: String, toNewPerson name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        runtime.assignSpeaker(name: trimmed, key: clusterID, meetingID: meetingID)
    }

    public func clearCluster(_ clusterID: String) {
        runtime.assignSpeaker(name: "", key: clusterID, meetingID: meetingID)
    }

    /// Changes the speaker on one line only. Every other line in the same
    /// cluster keeps its name.
    public func assignUtterance(_ line: CombinedLine, to entry: SpeakerDirectoryEntry) {
        runtime.assignUtteranceSpeaker(
            name: entry.identity.resolvedName, utteranceID: line.utterance.id,
            meetingID: line.recordingID, identityID: entry.id
        )
        applyLocalOverride(line, name: entry.identity.resolvedName, identityID: entry.id)
    }

    public func assignUtterance(_ line: CombinedLine, toNewPerson name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        runtime.assignUtteranceSpeaker(
            name: trimmed, utteranceID: line.utterance.id, meetingID: line.recordingID
        )
        applyLocalOverride(line, name: trimmed, identityID: nil)
    }

    public func clearUtterance(_ line: CombinedLine) {
        runtime.assignUtteranceSpeaker(
            name: "", utteranceID: line.utterance.id, meetingID: line.recordingID
        )
        if line.recordingID == meetingID { speakers.clearOverride(for: line.utterance) }
        correctedLines.remove(line.id)
        if let index = combinedLines.firstIndex(where: { $0.id == line.id }) {
            combinedLines[index].speakerName = SpeakerMap.fallbackName(
                for: line.utterance.speakerKey
            )
        }
    }

    /// Separates a recording from the conversation it was linked to.
    public func detach(_ recordingID: String) {
        runtime.detachContinuation(meetingID: recordingID)
        reload()
    }

    /// Shows the correction straight away.
    ///
    /// The write goes through the pipeline actor so it cannot race a resolution
    /// stage, and re-reading every file for one line would make editing a long
    /// transcript unusable.
    private func applyLocalOverride(_ line: CombinedLine, name: String, identityID: IdentityID?) {
        correctedLines.insert(line.id)
        if let index = combinedLines.firstIndex(where: { $0.id == line.id }) {
            combinedLines[index].speakerName = name
        }
        guard line.recordingID == meetingID else { return }
        let utterance = line.utterance
        speakers.overrideUtterance(
            utterance,
            with: SpeakerAssignment(
                displayName: name, origin: .human, identityID: identityID,
                provenance: .human()
            ),
            at: Date()
        )
    }

    public func beginNamingUtterance(_ line: CombinedLine) {
        namingLine = line
        namingUtterance = line.utterance
        namingCluster = nil
        newPersonDraft = ""
    }

    public func beginNamingCluster(_ clusterID: String) {
        namingCluster = clusterID
        namingLine = nil
        namingUtterance = nil
        newPersonDraft = ""
    }

    public func cancelNaming() {
        namingLine = nil
        namingUtterance = nil
        namingCluster = nil
        newPersonDraft = ""
    }

    public func commitNaming() {
        if let line = namingLine {
            assignUtterance(line, toNewPerson: newPersonDraft)
        } else if let cluster = namingCluster {
            assignCluster(cluster, toNewPerson: newPersonDraft)
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
    public func save() {
        runtime.saveTitle(title, meetingID: meetingID)
        runtime.saveNotes(notes, meetingID: meetingID)
        reload()
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

    /// Renaming edits a side file: raw diarization is untouched and no request is
    /// made.
    public func commitName(for key: String) {
        guard let name = draftNames[key], !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }
        runtime.assignSpeaker(name: name, key: key, meetingID: meetingID)
        draftNames[key] = nil
        reload()
    }

    public func retry() { runtime.retryProcessing(meetingID: meetingID) }

    /// How far the current stage has got, when the backend reports it. A local
    /// transcription has no chunks to count, and a stage showing nothing for
    /// four minutes reads as hung.
    public var progress: ProcessingPipeline.Progress? { runtime.processing[meetingID] }

    public func text(_ keyPath: ReferenceWritableKeyPath<MeetingReviewModel, String>) -> Binding<String> {
        Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }

    /// Re-assembles the transcript from the raw chunks on disk. No API call.
    public func rebuildTranscript() {
        runtime.rebuildTranscript(meetingID: meetingID) { [weak self] in
            self?.reload()
        }
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
        Binding(get: { self.title }, set: { self.title = $0 })
    }

    public func notesBinding() -> Binding<String> {
        Binding(get: { self.notes }, set: { self.notes = $0 })
    }

    public func nameBinding(for key: String) -> Binding<String> {
        Binding(
            get: { self.draftNames[key] ?? self.speakers.displayName(for: key) ?? "" },
            set: { self.draftNames[key] = $0 }
        )
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
