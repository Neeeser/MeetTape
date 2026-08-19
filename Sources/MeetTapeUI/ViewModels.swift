import AppKit
import Foundation
import MeetTapeAudio
import MeetTapeCore
import MeetTapeDetection
import MeetTapeIntegrations
import MeetTapeServices
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
        _ = await runtime.permissions.request(kind)
        statuses = await runtime.permissions.allStatuses()
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
        self.hasStoredKey = KeychainAPIKeyStore().hasKey
    }

    public func refresh() async {
        statuses = await runtime.permissions.allStatuses()
        hostStatus = NativeMessagingInstaller().status()
        inputDescription = CoreAudioSystem.describeDefaultInput()
        sensorStatus = runtime.sensorStatus
    }

    public func request(_ kind: PermissionKind) async {
        _ = await runtime.permissions.request(kind)
        statuses = await runtime.permissions.allStatuses()
    }

    public func saveLocalUserName() {
        var settings = runtime.settings
        settings.localUserName = localUserName.isEmpty ? "Me" : localUserName
        runtime.update(settings: settings)
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

    @ObservationIgnored private let runtime: MeetTapeRuntime
    @ObservationIgnored public let meetingID: String

    public init(runtime: MeetTapeRuntime, meetingID: String) {
        self.runtime = runtime
        self.meetingID = meetingID
        reload()
    }

    public var directory: URL? {
        runtime.repository.findMeeting(id: meetingID)?.store.layout.root
    }

    public var speakerKeys: [String] { transcript?.speakerKeys ?? [] }

    public func reload() {
        guard let found = runtime.repository.findMeeting(id: meetingID) else {
            errorMessage = "This meeting is no longer on disk."
            return
        }
        metadata = found.metadata
        title = found.metadata.titles.human ?? found.metadata.displayTitle
        notes = found.store.readNotes()
        summary = found.store.readSummary()
        speakers = (try? found.store.readSpeakerMap()) ?? SpeakerMap()
        transcript = try? found.store.readCanonicalTranscript()
    }

    /// Saved straight away, even while transcription is still running.
    public func save() {
        runtime.saveTitle(title, meetingID: meetingID)
        runtime.saveNotes(notes, meetingID: meetingID)
        reload()
    }

    public func saveNotes() {
        runtime.saveNotes(notes, meetingID: meetingID)
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

    /// The earlier meeting this one may continue, and why.
    public var continuationSuggestion: (title: String, reason: String)? {
        guard let earlierID = metadata?.possibleContinuationOf,
              let reason = metadata?.possibleContinuationReason,
              let earlier = runtime.repository.findMeeting(id: earlierID)
        else { return nil }
        return (earlier.metadata.displayTitle, reason)
    }

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
