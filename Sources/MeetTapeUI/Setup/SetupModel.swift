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

    /// Called when the wizard has to come back in front of the user.
    ///
    /// A permission prompt is a separate window owned by another process, and
    /// dismissing it hands focus back to whatever was in front before rather
    /// than to an accessory application with no Dock icon.
    @ObservationIgnored public var onNeedsFocus: (() -> Void)?

    @ObservationIgnored public let runtime: MeetTapeRuntime
    @ObservationIgnored private let observer: PermissionObserver
    /// Answers whether a key is in the keychain. Injected so a test can count the
    /// calls, since the defect this guards against is making one at all.
    @ObservationIgnored private let keyPresence: @Sendable () async -> Bool
    @ObservationIgnored private var hasStoredKey = false
    @ObservationIgnored private var hasCheckedForStoredKey = false
    /// Fetches a unit set. Injected so a test can read which units a choice
    /// asked for without a 2.1 GB download standing in the way of the answer.
    @ObservationIgnored
    private let install: @MainActor (MeetTapeRuntime, Set<LocalModelUnit>) async -> Void

    public init(
        runtime: MeetTapeRuntime,
        observer: PermissionObserver = PermissionObserver(),
        keyPresence: @escaping @Sendable () async -> Bool = {
            // `isKnownAbsent` can block on the keychain's authorisation prompt and
            // must not be asked while holding the main actor.
            await Task.detached { !KeychainAPIKeyStore().isKnownAbsent }.value
        },
        install: @escaping @MainActor (MeetTapeRuntime, Set<LocalModelUnit>) async -> Void = {
            runtime, units in await runtime.installLocalModels(units)
        }
    ) {
        self.runtime = runtime
        self.observer = observer
        self.keyPresence = keyPresence
        self.install = install
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
        } else {
            // The prompt has just closed. Focus went back to whatever was in
            // front of MeetTape before it opened, which leaves the next
            // instruction behind another application.
            onNeedsFocus?()
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
        Task { await install(runtime, requiredUnits) }
        if choice == .openAI { Task { await lookUpStoredKeyIfNeeded() } }
    }

    /// Which engine the Speech models step shows as selected. The stored
    /// setting, so a returning user sees what they already run.
    public var localModel: LocalTranscriptionModel {
        runtime.settings.processing.localTranscriptionModel
    }

    /// The engines the step offers, in the order they are shown.
    public var localModelChoices: [LocalTranscriptionModel] { LocalTranscriptionModel.allCases }

    /// Picking an engine mid-setup re-targets the pending install at that
    /// engine's units. A 2.1 GB download arrives because someone chose it here,
    /// never because a default or an upgrade decided for them.
    public func chooseLocalModel(_ model: LocalTranscriptionModel) async {
        await install(runtime, runtime.applyLocalTranscriptionModel(model))
    }

    public func startModelDownload() async {
        await install(runtime, requiredUnits)
    }

    /// What the current settings need on disk.
    private var requiredUnits: Set<LocalModelUnit> {
        LocalModelUnit.required(for: runtime.settings)
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

    /// Looks up whether a key is already stored, once, and only when it matters.
    ///
    /// Asking at all can raise the keychain's password prompt: a login-keychain
    /// item enforces its access control on the search as well as on the read, and
    /// a build re-signed since the item was created is no longer trusted by it.
    /// Called from `begin()`, that prompt appeared over the wizard on every open,
    /// for every user, including the ones who never leave the local default and
    /// have no key at all.
    public func lookUpStoredKeyIfNeeded() async {
        guard !hasCheckedForStoredKey, !runtime.settings.processing.isFullyLocal else { return }
        hasCheckedForStoredKey = true
        hasStoredKey = await keyPresence()
    }

    /// Whether the cloud step can offer to check a key the user has not typed.
    public var hasKeyOnDisk: Bool { hasStoredKey }

    public func saveAndVerifyKey() async {
        keyState = .checking
        acceptedUnverifiedKey = false
        let store = KeychainAPIKeyStore()
        if !apiKey.isEmpty {
            let typed = apiKey
            guard store.save(typed) else {
                keyState = .rejected("Could not write to the keychain")
                return
            }
            // Handed straight to the process-wide store, so checking the key
            // does not read back what was just written and raise a second
            // keychain prompt to do it.
            runtime.apiKeys.adopt(typed)
            apiKey = ""
            hasStoredKey = true
            hasCheckedForStoredKey = true
        }
        do {
            try await OpenAIClient(keyProvider: runtime.apiKeys)
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
