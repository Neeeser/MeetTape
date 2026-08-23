import AppKit
import MeetTapeCore
import MeetTapeDetection
import MeetTapeIntegrations
import MeetTapeServices
import SwiftUI

/// State behind the setup wizard.
///
/// Holds where the user is, what every permission currently reads as, and what
/// the OpenAI key has been shown to do. Which steps are done and whether setup
/// may finish are not decided here: that is `SetupFlow`, over the snapshot this
/// assembles.
@MainActor
@Observable
public final class SetupModel {
    /// What a stored OpenAI key has been shown to do.
    public enum KeyState: Equatable {
        case absent
        case checking
        case verified
        /// OpenAI answered and refused the key. No amount of retrying helps.
        case rejected(String)
        /// The request never got an answer. The key may be perfectly good.
        case unreachable(String)
    }

    public var current: SetupStepID = .welcome
    public var statuses: [PermissionStatus] = []
    public var apiKey = ""
    public var keyState = KeyState.absent
    /// Set when the user accepts a key that could not be checked because the
    /// request failed for a reason that was not a refusal.
    public var acceptedUnverifiedKey = false
    public var hostStatus: NativeMessagingInstaller.Status?
    public var storagePath = ""

    @ObservationIgnored public let runtime: MeetTapeRuntime
    @ObservationIgnored private let observer: PermissionObserver
    @ObservationIgnored private var hasStoredKey = false

    public init(runtime: MeetTapeRuntime, observer: PermissionObserver = PermissionObserver()) {
        self.runtime = runtime
        self.observer = observer
        self.storagePath = runtime.settings.storageRootPath
    }

    // MARK: - the decision inputs

    public var snapshot: SetupSnapshot {
        var snapshot = SetupSnapshot(
            settings: runtime.settings,
            cloudKeyVerified: keyState == .verified || acceptedUnverifiedKey,
            isDownloadingModels: runtime.localModelState.isBusy,
            nativeHostInstalled: hostStatus?.isReadyForFirefox == true
        )
        snapshot.permissions = Dictionary(
            uniqueKeysWithValues: statuses.map { ($0.kind, $0.state) }
        )
        snapshot.installedUnits = Set(
            LocalModelUnit.allCases.filter { runtime.localModelState.present.bytes(for: $0) != nil }
        )
        return snapshot
    }

    public var steps: [SetupStep] { SetupFlow.steps(for: snapshot) }
    public var canFinish: Bool { SetupFlow.canFinish(snapshot) }
    public var isCurrentStepSatisfied: Bool { SetupFlow.isSatisfied(current, in: snapshot) }

    public func status(for kind: PermissionKind) -> PermissionStatus {
        statuses.first { $0.kind == kind } ?? PermissionStatus(kind: kind, state: .notDetermined)
    }

    // MARK: - lifecycle

    /// Starts watching permissions and opens on the right step.
    ///
    /// The opening step is decided after the first read, not before it, so a
    /// machine that already has everything opens on the finish screen instead of
    /// walking a returning user through nine screens of things already done.
    public func begin() async {
        hostStatus = NativeMessagingInstaller().status()
        await runtime.refreshLocalModelState()
        await readStoredKey()
        statuses = await runtime.permissions.allStatuses()
        current = SetupFlow.openingStep(for: snapshot)
        observer.start { [weak self] statuses in
            self?.statuses = statuses
        }
    }

    public func end() {
        observer.stop()
    }

    // MARK: - navigation

    public func advance() {
        guard let next = SetupFlow.step(after: current) else { return }
        current = next
    }

    public func retreat() {
        guard let previous = SetupFlow.step(before: current) else { return }
        current = previous
    }

    public func jump(to step: SetupStepID) {
        current = step
    }

    public func finish() {
        var settings = runtime.settings
        settings.hasCompletedOnboarding = true
        runtime.update(settings: settings)
        end()
    }

    // MARK: - permissions

    public func request(_ kind: PermissionKind) async {
        let status = await runtime.permissions.request(kind)
        statuses = await runtime.permissions.allStatuses()
        // Accessibility and Screen Recording are only ever switched on in System
        // Settings. The request above is what puts MeetTape into that list, so
        // opening the pane straight after it lands on a row that exists.
        if !status.isUsable, !kind.isGrantedByPrompt {
            runtime.permissions.openSettings(for: kind)
        }
        Log.ui.info(
            "requested \(kind.rawValue, privacy: .public): now \(status.state.rawValue, privacy: .public)"
        )
    }

    public func openSettings(for kind: PermissionKind) {
        runtime.permissions.openSettings(for: kind)
    }

    // MARK: - backend and key

    public func chooseBackend(_ choice: ProcessingBackendChoice) {
        var settings = runtime.settings
        settings.processing.transcription = choice
        settings.processing.diarization = choice
        runtime.update(settings: settings)
        // Both paths need local units, and which ones differ, so the download is
        // re-planned the moment the choice changes rather than at the next step.
        Task { await runtime.installLocalModels() }
    }

    public func chooseLocalModel(_ model: LocalTranscriptionModel) {
        var settings = runtime.settings
        settings.processing.localTranscriptionModel = model
        runtime.update(settings: settings)
        Task { await runtime.installLocalModels() }
    }

    public func startModelDownload() async {
        await runtime.installLocalModels()
    }

    /// Whether an unverified key may be accepted.
    ///
    /// Only when the failure was not a refusal. A key OpenAI has rejected is
    /// wrong now and will be wrong at the first meeting, so there is nothing to
    /// wave through.
    public var mayAcceptUnverifiedKey: Bool {
        if case .unreachable = keyState { return true }
        return false
    }

    public func acceptUnverifiedKey() {
        guard mayAcceptUnverifiedKey else { return }
        acceptedUnverifiedKey = true
    }

    /// Reports whether a key is already in the keychain, without reading it.
    private func readStoredKey() async {
        // `isKnownAbsent` can block on an authorisation prompt, and must not be
        // asked while holding the main actor.
        let absent = await Task.detached { KeychainAPIKeyStore().isKnownAbsent }.value
        hasStoredKey = !absent
        if hasStoredKey, keyState == .absent { keyState = .absent }
    }

    /// Whether the cloud step can offer to check a key the user has not typed.
    public var hasKeyOnDisk: Bool { hasStoredKey }

    public func saveAndVerifyKey() async {
        keyState = .checking
        acceptedUnverifiedKey = false
        let store = KeychainAPIKeyStore()
        if !apiKey.isEmpty {
            guard store.save(apiKey) else {
                keyState = .rejected("Could not write to the keychain")
                return
            }
            apiKey = ""
            hasStoredKey = true
        }
        do {
            try await OpenAIClient(keyProvider: store)
                .verifyCredentials(model: runtime.settings.models.diarization)
            keyState = .verified
        } catch let error as ProcessingError {
            // A refusal is the key being wrong. Everything retryable is the
            // network, a rate limit or OpenAI itself, none of which say anything
            // about the key, and none of which should strand a setup done on a
            // train.
            keyState = error.isRetryable
                ? .unreachable(error.userMessage) : .rejected(error.userMessage)
        } catch {
            keyState = .unreachable("Could not reach OpenAI")
        }
    }

    // MARK: - Firefox and storage

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

    public func revealExtension() {
        let candidates = [
            Bundle.main.url(forResource: "extension", withExtension: nil),
            Bundle.main.resourceURL?.appendingPathComponent("extension"),
        ].compactMap { $0 }
        if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.activateFileViewerSelecting([existing])
        } else {
            NSWorkspace.shared.open(SensorTransport.defaultApplicationSupport)
        }
    }
}
