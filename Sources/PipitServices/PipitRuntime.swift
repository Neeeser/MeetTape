import AppKit
import Foundation
import Observation
import PipitAudio
import PipitCore
import PipitDetection
import PipitIntegrations
import PipitLocalAI
import PipitSpeakers

/// What the menu bar and panels display.
public struct RuntimeStatus: Sendable, Equatable {
    public var sessionState: SessionState = .idle
    public var source: MeetingSource?
    public var provider: MeetingProvider = .unknown
    public var title: String?
    public var startedAt: Date?
    public var health = CaptureHealthSnapshot()
    public var isProvisional = false
    public var detectionPaused = false
    public var sensorConnection: BrowserSensorTracker.Connection = .absent
    public var slackState: SlackHuddleDetector.State = .idle
    public var lastWarning: CaptureWarning?

    public init() {}

    /// Audio is being written to disk right now. During the reconnect window
    /// this is false: the segments are closed and capture waits in memory.
    public var isRecording: Bool { sessionState == .recording }
    /// The meeting lost its evidence and is waiting out the reconnect window.
    public var isInReconnectWindow: Bool { sessionState == .reconnecting }
    /// A meeting is open, whether writing or waiting to reconnect.
    public var hasActiveSession: Bool { isRecording || isInReconnectWindow }

    /// Whether the microphone is open, which starts before anything is written.
    ///
    /// Capture is armed on entering `candidate` and runs into the memory ring:
    /// Slack opens the microphone about twelve seconds before the user joins,
    /// and a Meet prejoin screen is invisible to native detection for longer.
    /// That is real capture, so heavy processing has to stand back from it, and
    /// gating on `hasActiveSession` alone let a job take the Neural Engine and
    /// the disk during exactly that window.
    public var isCapturing: Bool {
        hasActiveSession || sessionState == .candidate || sessionState == .ending
    }

    /// Never show a healthy recording while a required source is known to be
    /// failing.
    public var displayHealth: CaptureHealthState {
        isRecording ? health.overall : .idle
    }

    public func elapsed(now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }
}

/// A meeting waiting for the user to say whether to keep it.
public struct ProvisionalPrompt: Sendable, Equatable, Identifiable {
    public let meetingID: String
    public let applicationBundleID: String
    public let applicationName: String
    public let title: String?
    public var id: String { meetingID }

    public init(
        meetingID: String, applicationBundleID: String, applicationName: String, title: String?
    ) {
        self.meetingID = meetingID
        self.applicationBundleID = applicationBundleID
        self.applicationName = applicationName
        self.title = title
    }
}

/// Owns every subsystem and turns session decisions into real work.
///
/// Detection produces evidence, `SessionController` decides the lifecycle, and
/// this object performs the resulting actions: arming capture, creating the
/// meeting directory, finalising, and handing the recording to processing.
@MainActor
@Observable
public final class PipitRuntime {
    public private(set) var status = RuntimeStatus()
    public private(set) var recentMeetings: [MeetingSummary] = []
    public private(set) var processing: [String: ProcessingPipeline.Progress] = [:]
    public private(set) var provisionalPrompt: ProvisionalPrompt?
    public private(set) var settings: AppSettings
    /// Whether the on-device speech models are installed, and how far a
    /// download has got. Recording never waits on this.
    public internal(set) var localModelState: LocalModelState = .notInstalled(LocalModelSnapshot())

    /// Called when a meeting's processing state changes, so an open review
    /// window can reload its files without the user refreshing by hand.
    @ObservationIgnored public var onProcessingUpdate: ((String) -> Void)?

    @ObservationIgnored public let repository: MeetingRepository
    @ObservationIgnored public let notifications = NotificationService()
    @ObservationIgnored public let permissions = PermissionsService()
    /// The OpenAI key, read from the keychain once and held for the process.
    /// Exposed so saving a rotated key updates it without a relaunch.
    @ObservationIgnored public let apiKeys: CachingAPIKeyStore
    /// The on-device speech models, and the local voice memory. Both exist
    /// whichever backends are selected: choosing the cloud diarizer costs the
    /// vectors it would have returned, not the ability to remember a voice.
    @ObservationIgnored public private(set) var models: LocalModelManager!
    @ObservationIgnored public private(set) var speakers: SpeakerRecognitionService?
    @ObservationIgnored public private(set) var speakerStore: SpeakerStore?

    @ObservationIgnored private let settingsStore: SettingsStore
    /// A snapshot the processing actor can read without hopping to the main
    /// actor. `MainActor.assumeIsolated` from an actor's executor is a runtime
    /// trap, not a shortcut.
    @ObservationIgnored private let settingsSnapshot: LockedBox<AppSettings>
    /// The same trick for the recording state, which is what the processing
    /// gate consults. Read on a timer from the processing actor, written here
    /// on every lifecycle transition.
    @ObservationIgnored private let recordingSnapshot: LockedBox<RecordingAwareGate.CaptureState>
    /// Main-actor work is chained so state updates arrive in the order they were
    /// produced; independent tasks give no ordering guarantee.
    @ObservationIgnored private var workChain: Task<Void, Never>?
    @ObservationIgnored private let clock: any Clock
    @ObservationIgnored private var sessionController: SessionController
    @ObservationIgnored private var captureEngine: CaptureEngine!
    @ObservationIgnored private var detectionEngine: DetectionEngine!
    @ObservationIgnored private(set) var pipeline: ProcessingPipeline!
    @ObservationIgnored private var powerObserver: PowerEventObserver?
    @ObservationIgnored private var currentMeeting: (metadata: MeetingMetadata, store: MeetingStore)?
    @ObservationIgnored private var onStatusChange: (@MainActor @Sendable () -> Void)?
    @ObservationIgnored private let relay = RuntimeRelay()

    public init(
        settingsDirectory: URL = SensorTransport.defaultApplicationSupport,
        clock: any Clock = SystemClock()
    ) {
        self.clock = clock
        self.settingsStore = SettingsStore(directory: settingsDirectory)
        let loaded = settingsStore.load()
        self.settings = loaded
        let snapshot = LockedBox(loaded)
        self.settingsSnapshot = snapshot
        let recording = LockedBox(RecordingAwareGate.CaptureState.idle)
        self.recordingSnapshot = recording
        // Reads the current setting on every use, so a folder chosen in Settings
        // applies straight away.
        self.repository = MeetingRepository(rootProvider: { snapshot.withLock { $0.storageRoot } })
        self.sessionController = SessionController(policies: loaded.providers)

        captureEngine = CaptureEngine(
            clock: clock,
            segmentSeconds: loaded.segmentSeconds,
            preRollSeconds: loaded.preRollSeconds,
            makeMicrophone: { sink, onChange in
                MicrophoneSource(
                    sink: sink,
                    onConfigurationChange: onChange,
                    // Read per engine build, so toggling the setting applies to
                    // the next recording without a relaunch.
                    voiceProcessing: { snapshot.withLock { $0.echoCancellation } }
                )
            },
            delegate: relay
        )
        detectionEngine = DetectionEngine(clock: clock, delegate: relay)
        detectionEngine.updateGenericConfiguration(loaded.genericDetectorConfiguration)

        // Release builds read the key from the keychain only. A process
        // environment is readable by any same-user process.
        #if DEBUG
        let keyStore = LayeredAPIKeyStore(providers: [KeychainAPIKeyStore(), EnvironmentAPIKeyStore()])
        #else
        let keyStore: any APIKeyProviding = KeychainAPIKeyStore()
        #endif
        // Read once per process. Every request reading for itself meant a
        // keychain prompt per request on a build the item's access control no
        // longer trusts.
        let cachedKeys = CachingAPIKeyStore(keyStore)
        apiKeys = cachedKeys
        let cloud = OpenAIClient(keyProvider: cachedKeys)
        let modelManager = LocalModelManager(
            applicationSupport: settingsDirectory,
            required: LocalModelUnit.required(for: loaded),
            onStateChange: { [weak relay] state in
                Task { @MainActor in relay?.runtimeForCallbacks?.localModelState = state }
            }
        )
        models = modelManager

        // The identity store is deliberately not in the meeting archive. A
        // speaker embedding is a biometric identifier, and the archive is what a
        // user copies, syncs and shares.
        var recognition: SpeakerRecognitionService?
        do {
            let store = try SpeakerStore(url: SpeakerStore.defaultURL(applicationSupport: settingsDirectory))
            speakerStore = store
            recognition = SpeakerRecognitionService(store: store)
            speakers = recognition
        } catch {
            Log.app.error("voice memory unavailable: \(logSafeDescription(error), privacy: .public)")
        }

        pipeline = ProcessingPipeline(
            repository: repository,
            backend: cloud,
            backends: ProcessingBackends(
                transcription: { settings, model in
                    ProcessingBackends.transcriptionBackend(
                        settings: settings, model: model,
                        local: { choice in
                            switch choice {
                            case .cohere: CohereTranscriptionBackend(models: modelManager)
                            case .canary: CanaryTranscriptionBackend(models: modelManager)
                            case .apple: AppleSpeechTranscriptionBackend()
                            case .parakeet: ParakeetTranscriptionBackend(models: modelManager)
                            case .whisper: WhisperTranscriptionBackend(models: modelManager)
                            }
                        },
                        cloud: {
                            OpenAITranscriptionBackend(
                                backend: cloud, model: $0,
                                keywords: settings.models.keywordList
                            )
                        }
                    )
                },
                diarization: { settings, model in
                    ProcessingBackends.diarizationBackend(
                        settings: settings, model: model,
                        local: { FluidAudioDiarizationBackend(models: modelManager) },
                        cloud: { OpenAIDiarizationBackend(backend: cloud, model: $0) }
                    )
                },
                embeddings: FluidAudioEmbeddingExtractor(models: modelManager),
                speakers: recognition,
                prepareLocalModels: { [snapshot = settingsSnapshot] in
                    let current = snapshot.withLock { $0 }
                    _ = try await modelManager.install(
                        units: LocalModelUnit.required(for: current)
                    )
                },
                // The diarizer by name. Voice memory embeds with those models
                // and needs nothing else, and asking for the whole required set
                // meant that every unit added to it since a machine was
                // installed read as "no models" and skipped voice memory.
                requireLocalModels: { try await modelManager.ensureInstalled(units: [.diarizer]) },
                voiceActivity: FluidAudioVoiceActivityBackend(models: modelManager),
                prepareVoiceActivity: { _ = try await modelManager.install(units: [.voiceActivity]) },
                aligner: CtcTranscriptAligner(models: modelManager),
                prepareAligner: { _ = try await modelManager.install(units: [.ctcAligner]) },
                prepareDiarizer: { _ = try await modelManager.install(units: [.diarizer]) },
                singleSpeakerEmbedding: { url in
                    try await modelManager.embedSingleSpeaker(audio: url)
                },
                reanalyzeDiarization: { meetingID, url, count in
                    try await modelManager.reanalyze(
                        meetingID: meetingID, audio: url, speakerCount: count
                    )
                }
            ),
            gate: RecordingAwareGate(capture: { recording.withLock { $0 } }),
            calendar: CalendarService(),
            clock: clock,
            settingsProvider: { [snapshot = settingsSnapshot] in snapshot.withLock { $0 } },
            onProgress: { [weak relay] progress in
                Task { @MainActor in relay?.runtimeForCallbacks?.apply(progress) }
            },
            onFailure: { [weak relay] meetingID, error in
                Task { @MainActor in
                    relay?.runtimeForCallbacks?.handleProcessingFailure(meetingID, error)
                }
            }
        )
        relay.connect(runtime: self)
    }

    public func observeStatus(_ handler: @escaping @MainActor @Sendable () -> Void) {
        onStatusChange = handler
    }

    // MARK: - lifecycle

    public func start() {
        notifications.registerCategories()
        installNativeMessagingHost()
        // A job killed mid-export leaves a partial track behind. Nothing ever
        // swept it, so it accumulated once per interrupted meeting.
        ProcessingScratch(root: ProcessingScratch.defaultRoot()).pruneIncomplete()
        powerObserver = PowerEventObserver(
            onWake: { [weak self] in
                Task { @MainActor in self?.captureEngine.noteSystemWake() }
            },
            onSleep: {}
        )
        refreshRecentMeetings()
        // The recovery scan runs before detection, so a meeting that starts
        // during launch can never be scanned as an interrupted one and finalised
        // underneath itself. Resuming the processing of what it found runs
        // after, because that can take minutes and detection must be watching
        // before it does.
        Task { @MainActor in
            await recover()
            detectionEngine.start()
            await ensureLocalUserIdentity()
            await refreshLocalModelState()
            await pruneVoiceMemory()
            await pipeline.resumeInterrupted()
            refreshRecentMeetings()
            // After resume, so a meeting that was mid-pipeline is finished
            // before its storage is compacted. Runs through the pipeline's own
            // slot, so it pauses while anything records.
            await pipeline.compactPending()
        }
    }

    public func stop() {
        detectionEngine.stop()
        if status.hasActiveSession { stopRecording(reason: "app_quit") }
    }

    /// Stops and waits for the recording to be finalised.
    ///
    /// `stop()` only enqueues the work, and at quit the main run loop stops
    /// before it runs, which leaves the last segment open and the meeting stuck
    /// in `recording` until the next launch recovers it. Quitting awaits this.
    public func stopAndWait() async {
        stop()
        await workChain?.value
    }

    /// Chains main-actor work so updates apply in the order they were produced.
    ///
    /// For short state updates only. Quitting waits on this chain, and a
    /// capture action queued behind a multi-minute processing job would mean the
    /// meeting that just started is never armed. Long work goes through
    /// `runProcessing`.
    func enqueue(_ body: @escaping @MainActor @Sendable () async -> Void) {
        let previous = workChain
        workChain = Task { @MainActor in
            await previous?.value
            await body()
        }
    }

    /// Runs pipeline work that can take minutes, off the ordered chain.
    ///
    /// The pipeline is an actor, so its own calls still serialise against each
    /// other; what this avoids is holding capture lifecycle actions and quit
    /// behind a job that is waiting out a live recording.
    func runProcessing(_ body: @escaping @MainActor @Sendable () async -> Void) {
        Task { @MainActor in await body() }
    }

    /// Adopts anything a crash left behind, before detection can see it.
    private func recover() async {
        // Folders written by an earlier build move to the raw/ layout first, so
        // recovery and processing only ever see one layout. Renames only.
        let migration = repository.migrateLayouts()
        if migration.migrated > 0 || migration.failed > 0 {
            Log.app.notice(
                "layout migration: \(migration.migrated) moved, \(migration.failed) failed"
            )
        }
        let scanner = RecoveryScanner(
            repository: repository, inspector: AudioFileInspector(), clock: clock
        )
        let report = scanner.scan()
        for recovered in report.recovered {
            // The identifier embeds the meeting title, so it stays private.
            Log.app.notice(
                "recovered an interrupted meeting: \(recovered.adoptedSegments) crash tails, \(Int(recovered.recoveredSeconds))s"
            )
        }
        refreshRecentMeetings()
    }

    private func installNativeMessagingHost() {
        guard let hostBinary = NativeMessagingInstaller.bundledHostURL() else {
            Log.app.notice("native messaging host binary not found in the bundle")
            return
        }
        do {
            _ = try NativeMessagingInstaller().install(hostBinary: hostBinary)
        } catch {
            Log.app.error("host install failed: \(logSafeDescription(error), privacy: .public)")
        }
    }

    // MARK: - detection

    func detectionDidUpdate(_ snapshot: DetectionSnapshot) {
        status.sensorConnection = snapshot.browserSensor
        status.slackState = snapshot.slackState

        // Unsupported calls arrive as ordinary evidence rather than a one-shot
        // event, so the session lifecycle governs them like any other provider.
        let actions = sessionController.update(
            evidence: snapshot.evidence, now: clock.monotonicSeconds, wallClock: clock.now
        )
        syncStatusFromSession()
        guard !actions.isEmpty else { return }
        enqueue { [weak self] in await self?.perform(actions) }
    }

    func captureHealthDidUpdate(_ snapshot: CaptureHealthSnapshot) {
        // A stale snapshot must not overwrite the terminal one from stop().
        guard status.isRecording || snapshot.isWritingToDisk == false else { return }
        status.health = snapshot
        onStatusChange?()
    }

    func captureDidWarn(_ warning: CaptureWarning) {
        status.lastWarning = warning
        if settings.showNotifications { notifications.captureProblem(warning) }
        onStatusChange?()
    }

    // MARK: - manual commands

    public func startManualRecording() {
        let bundlePrefixes = BrowserKind.firefox.bundleIdentifiers + ["com.tinyspeck.slackmacgap"]
        var titles = TitleCandidates(
            timestampFallback: MeetingRepository.timestampTitle(startedAt: clock.now, source: .manual)
        )
        titles.window = nil
        let actions = sessionController.startManual(
            source: .manual, bundlePrefixes: bundlePrefixes, titles: titles,
            now: clock.monotonicSeconds, wallClock: clock.now
        )
        syncStatusFromSession()
        enqueue { [weak self] in await self?.perform(actions) }
    }

    public func startInPersonRecording() {
        let titles = TitleCandidates(
            timestampFallback: MeetingRepository.timestampTitle(startedAt: clock.now, source: .inPerson)
        )
        let actions = sessionController.startManual(
            source: .inPerson, bundlePrefixes: [], titles: titles,
            now: clock.monotonicSeconds, wallClock: clock.now
        )
        syncStatusFromSession()
        enqueue { [weak self] in await self?.perform(actions) }
    }

    public func stopRecording(reason: String = "user_stopped") {
        let actions = sessionController.stop(reason: reason)
        syncStatusFromSession()
        enqueue { [weak self] in await self?.perform(actions) }
    }

    public func addNote(_ text: String) {
        captureEngine.addMarker(text)
        guard let meeting = currentMeeting else { return }
        do {
            try meeting.store.appendNote(text, at: clock.now)
        } catch {
            Log.app.error("note not saved: \(logSafeDescription(error), privacy: .public)")
        }
    }

    public func resolveProvisional(keep: Bool) {
        guard provisionalPrompt != nil else { return }
        provisionalPrompt = nil
        let actions = sessionController.resolveProvisional(
            keep: keep, reason: keep ? "kept" : "user_discarded", now: clock.monotonicSeconds
        )
        syncStatusFromSession()
        enqueue { [weak self] in await self?.perform(actions) }
    }

    public func alwaysRecord(applicationBundleID: String) {
        let application = MicrophoneIgnoreList.applicationIdentifier(for: applicationBundleID)
        var updated = settings
        if !updated.alwaysRecordApplications.contains(application) {
            updated.alwaysRecordApplications.append(application)
        }
        updated.neverRecordApplications.removeAll { $0 == application }
        update(settings: updated)
    }

    public func neverRecord(applicationBundleID: String) {
        // The prompt names the process that opened the microphone, which for an
        // Electron application is one of several helpers. The user answered about
        // the application, so that is what is stored.
        let application = MicrophoneIgnoreList.applicationIdentifier(for: applicationBundleID)
        var updated = settings
        if !updated.neverRecordApplications.contains(application) {
            updated.neverRecordApplications.append(application)
        }
        updated.alwaysRecordApplications.removeAll { $0 == application }
        update(settings: updated)
    }

    public func setDetectionPaused(_ paused: Bool) {
        var updated = settings
        updated.providers.detectionPaused = paused
        update(settings: updated)
    }

    public func update(settings newSettings: AppSettings) {
        var newSettings = newSettings
        // Speakers follow the words: settings carry one knob, and any stale
        // pairing a previous build stored normalizes on the next save.
        newSettings.coupleDiarization()
        let rootChanged = newSettings.storageRootPath != settings.storageRootPath
        settings = newSettings
        settingsSnapshot.withLock { $0 = newSettings }
        do {
            try settingsStore.save(newSettings)
        } catch {
            Log.app.error("settings not saved: \(logSafeDescription(error), privacy: .public)")
        }
        // A newly chosen root can be a restored archive in the old layout, and
        // only launch ran the migration until now. Without this, every read of
        // an unmigrated meeting's transcript or speaker map misses until the
        // next relaunch.
        if rootChanged {
            let migration = repository.migrateLayouts()
            if migration.migrated > 0 || migration.failed > 0 {
                Log.app.notice(
                    "layout migration on root change: \(migration.migrated) moved, \(migration.failed) failed"
                )
            }
        }
        sessionController.policies = newSettings.providers
        detectionEngine.updateGenericConfiguration(newSettings.genericDetectorConfiguration)
        status.detectionPaused = newSettings.providers.detectionPaused
        // A different model choice changes which units count as installed. On
        // the ordered chain rather than a bare task: two quick changes as
        // unordered tasks could land the older set last, leaving the manager
        // judging itself against an engine nobody chose. The Cloud tab's custom
        // model field is the one control that changes the required set and
        // starts no download, so this write is what keeps it right.
        if let models {
            let units = LocalModelUnit.required(for: newSettings)
            enqueue { await models.setRequired(units) }
        }
        onStatusChange?()
    }

    /// Applies a settings change that also has to reach the identity store,
    /// which is where the local user's name lives once they have a profile.
    public func updateSettingsAndIdentity(_ newSettings: AppSettings) {
        let renamed = newSettings.localUserName != settings.localUserName
        update(settings: newSettings)
        guard renamed else { return }
        enqueue { [weak self] in await self?.ensureLocalUserIdentity() }
    }

    // MARK: - import

    /// Imports an existing recording. The original is copied in and left untouched.
    public func importRecording(from url: URL) async throws -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        // What the recorder said, before what the copy said. A file that
        // arrived by AirDrop, download or a drag off a phone has today's
        // creation date and last month's audio, and an archive sorted by date
        // is only useful if the date is the recording's.
        let recorded = RecordedDatePolicy.choose(
            metadata: await MediaCreationDateReader().creationDate(of: url),
            filename: RecordedDatePolicy.dateInFilename(url.lastPathComponent),
            fileCreated: attributes?[.creationDate] as? Date,
            now: clock.now
        )
        let started = recorded.date
        Log.app.info(
            "imported recording dated \(recorded.source.rawValue, privacy: .public)"
        )
        var titles = TitleCandidates(
            timestampFallback: MeetingRepository.timestampTitle(startedAt: started, source: .imported)
        )
        titles.window = url.deletingPathExtension().lastPathComponent
        let created = try repository.createMeeting(
            source: .imported, provider: .unknown, startedAt: started,
            titles: titles, now: clock.now
        )
        // Decoding, transcoding and copying the original are file-bound work, and
        // this runtime is on the main actor, so it runs off it.
        let importer = AudioImporter(segmentSeconds: settings.segmentSeconds, clock: clock)
        let store = created.store
        let meetingIdentifier = created.metadata.id
        let result = try await Task.detached(priority: .userInitiated) {
            try importer.import(source: url, into: store, meetingID: meetingIdentifier)
        }.value

        var metadata = created.metadata
        metadata.durationSeconds = result.durationSeconds
        metadata.endedAt = started.addingTimeInterval(result.durationSeconds)
        metadata.importedOriginalFilename = result.originalFilename
        metadata.recordedDateSource = recorded.source
        metadata.runs = [RecordingRun(
            id: "run-001", startedAt: metadata.startedAt, endedAt: metadata.endedAt,
            durationSeconds: result.durationSeconds
        )]
        metadata.processing.advance(to: .finalizing, at: clock.now)
        metadata.processing.advance(to: .audioSafe, at: clock.now)
        try created.store.writeMetadata(metadata)

        refreshRecentMeetings()
        let meetingID = metadata.id
        Task { await pipeline.process(meetingID: meetingID) }
        return meetingID
    }

    // MARK: - meeting actions

    /// Transport-level state of the browser sensor, including connections refused
    /// because the peer was not Pipit's own relay.
    public var sensorStatus: BrowserSensorServer.Status? {
        detectionEngine.sensorStatus
    }

    public func refreshRecentMeetings() {
        recentMeetings = repository.listMeetings(limit: 40)
        onStatusChange?()
    }

    public func retryProcessing(meetingID: String) {
        runProcessing { [weak self] in
            guard let self else { return }
            await pipeline.retry(meetingID: meetingID)
            refreshRecentMeetings()
        }
    }

    /// Re-assembles the transcript from the raw chunks already on disk.
    public func rebuildTranscript(meetingID: String, completion: @escaping @Sendable @MainActor () -> Void = {}) {
        runProcessing { [weak self] in
            guard let self else { return }
            do {
                try await pipeline.rebuildTranscript(meetingID: meetingID)
            } catch {
                Log.app.error("transcript rebuild failed: \(logSafeDescription(error), privacy: .public)")
            }
            completion()
        }
    }

    /// Names a whole cluster.
    ///
    /// A confirmation, so it also enrols the cluster's own vector against that
    /// person once the audio clears the quality gates. That and the microphone
    /// track are the only two things that ever write a voice profile.
    public func assignSpeaker(
        name: String, key: String, meetingID: String, identityID: IdentityID? = nil
    ) {
        runProcessing { [weak self] in
            guard let self else { return }
            do {
                _ = try await pipeline.applySpeakerName(
                    name, to: key, meetingID: meetingID, identityID: identityID
                )
            } catch {
                Log.app.error("speaker not saved: \(logSafeDescription(error), privacy: .public)")
            }
            onProcessingUpdate?(meetingID)
        }
    }

    /// A human title always wins over every other candidate.
    public func saveTitle(_ title: String, meetingID: String) {
        guard let found = repository.findMeeting(id: meetingID, includingMerged: true) else { return }
        do {
            _ = try found.store.updateMetadata { $0.titles.human = title.isEmpty ? nil : title }
        } catch {
            Log.app.error("title not saved: \(logSafeDescription(error), privacy: .public)")
        }
        refreshRecentMeetings()
    }

    public func saveNotes(_ notes: String, meetingID: String) {
        guard let found = repository.findMeeting(id: meetingID, includingMerged: true) else { return }
        try? found.store.writeNotes(notes)
    }

    public func revealInFinder(meetingID: String) {
        guard let found = repository.findMeeting(id: meetingID, includingMerged: true) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([found.store.layout.root])
    }

    // MARK: - action execution

    private func perform(_ actions: [SessionAction]) async {
        if !actions.isEmpty {
            // Notice rather than info: these are the session's lifecycle
            // decisions, and they need to survive into `log show`.
            Log.session.notice(
                "actions: \(actions.map(\.logLabel).joined(separator: ", "), privacy: .public)"
            )
        }
        for action in actions {
            switch action {
            case .armCapture(let prefixes, let capturesRemote):
                await captureEngine.arm(bundlePrefixes: prefixes, capturesRemote: capturesRemote)
            case .retargetCapture(let prefixes):
                await captureEngine.retarget(bundlePrefixes: prefixes)
            case .commitRecording(let request):
                // A commit that fails leaves nothing behind and cancels the rest
                // of the batch, so no "recording started" notice is delivered for
                // a meeting that does not exist.
                guard await commit(request) else { return }
            case .pauseCapture(let reason):
                await captureEngine.pause(reason: reason)
            case .beginRun(let reason):
                beginRun(reason: reason)
                await captureEngine.resume()
            case .updateEvidence(let evidence):
                applyEvidence(evidence)
            case .discardCapture(let reason):
                await discard(reason: reason)
            case .finishRecording(let reason):
                await finish(reason: reason)
            case .askToKeepProvisional(let bundleIdentifier, let title):
                askToKeep(bundleIdentifier: bundleIdentifier, title: title)
            case .notify(let notice):
                deliver(notice)
            }
        }
    }

    @discardableResult
    private func commit(_ request: CommitRequest) async -> Bool {
        var createdDirectory: URL?
        do {
            let created = try repository.createMeeting(
                source: request.source, provider: request.provider,
                startedAt: request.startedAt, titles: request.titles, now: clock.now
            )
            createdDirectory = created.store.layout.root
            var metadata = created.metadata
            metadata.providerMeetingID = request.providerMeetingID
            metadata.meetingURL = request.url
            metadata.browser = request.browser
            metadata.applicationBundleID = request.applicationBundleID
            metadata.provisionalDecision = request.isProvisional ? .pending : nil
            metadata.runs = [RecordingRun(id: "run-001", startedAt: request.startedAt)]
            try created.store.writeMetadata(metadata)

            try await captureEngine.commit(
                layout: created.store.layout, meetingID: metadata.id, source: request.source
            )
            currentMeeting = (metadata, created.store)
            refreshRecentMeetings()
            return true
        } catch {
            Log.app.error("commit failed: \(logSafeDescription(error), privacy: .public)")
            await captureEngine.discardArmed()
            // A half-created meeting must not be left for recovery to adopt.
            if let createdDirectory { try? FileManager.default.removeItem(at: createdDirectory) }
            currentMeeting = nil
            _ = sessionController.stop(reason: "commit_failed")
            syncStatusFromSession()
            refreshRecentMeetings()
            return false
        }
    }

    private func beginRun(reason: String) {
        guard let meeting = currentMeeting else { return }
        captureEngine.addMarker("run:\(reason)")
        let updated = try? meeting.store.updateMetadata { metadata in
            let index = metadata.runs.count + 1
            metadata.runs.append(RecordingRun(
                id: String(format: "run-%03d", index), startedAt: self.clock.now
            ))
        }
        if let updated { currentMeeting = (updated, meeting.store) }
    }

    private func applyEvidence(_ evidence: ProviderEvidence) {
        guard let meeting = currentMeeting else { return }
        let updated = try? meeting.store.updateMetadata { metadata in
            if let title = evidence.title, metadata.titles.provider == nil {
                metadata.titles.provider = title
            }
            if let meetingID = evidence.meetingID { metadata.providerMeetingID = meetingID }
            if let url = evidence.url { metadata.meetingURL = url }
            if let tabs = evidence.otherAudibleTabs, tabs > 0 { metadata.hadOtherAudibleTabs = true }
        }
        if let updated { currentMeeting = (updated, meeting.store) }
    }

    private func discard(reason: String) async {
        await captureEngine.discardArmed()
        if let meeting = currentMeeting {
            _ = await captureEngine.stop(reason: reason)
            // A provisional recording the user declined leaves nothing behind.
            try? FileManager.default.removeItem(at: meeting.store.layout.root)
            currentMeeting = nil
            refreshRecentMeetings()
        }
        provisionalPrompt = nil
    }

    private func finish(reason: String) async {
        let snapshot = await captureEngine.stop(reason: reason)
        provisionalPrompt = nil
        guard let meeting = currentMeeting else { return }
        currentMeeting = nil

        do {
            let timeline = try meeting.store.readTimeline()
            let updated = try meeting.store.updateMetadata { metadata in
                metadata.endedAt = self.clock.now
                metadata.durationSeconds = timeline.duration
                metadata.provisionalDecision = metadata.provisionalDecision == .pending
                    ? .kept : metadata.provisionalDecision
                if var run = metadata.runs.last, run.endedAt == nil {
                    run.endedAt = self.clock.now
                    run.durationSeconds = timeline.duration
                    run.endReason = reason
                    metadata.runs[metadata.runs.count - 1] = run
                }
                metadata.captureWarnings = snapshot.overall.isLosingAudio
                    ? metadata.captureWarnings + ["capture ended in state \(snapshot.overall.rawValue)"]
                    : metadata.captureWarnings
                metadata.processing.advance(to: .finalizing, at: self.clock.now)
                metadata.processing.advance(to: .audioSafe, at: self.clock.now)
            }
            // Returns the meeting that now owns this recording, which is a
            // different one when this was a reconnection.
            let owner = linkContinuation(of: updated, store: meeting.store)
            if settings.showNotifications {
                notifications.meetingSaved(
                    title: updated.displayTitle,
                    path: meeting.store.layout.root.path,
                    meetingID: updated.id
                )
            }
            refreshRecentMeetings()
            // This meeting's own identifier, whatever it was folded into: the
            // audio is in this folder and combine moves nothing. Routing to the
            // survivor instead handed the pipeline a meeting that has none of
            // the second half of the call, and it is usually already complete,
            // so nothing was transcribed at all.
            let meetingID = updated.id
            if owner != nil {
                Log.app.info("processing a folded meeting under its own identifier")
            }
            Task { await pipeline.process(meetingID: meetingID) }
        } catch {
            Log.app.error("finalise failed: \(logSafeDescription(error), privacy: .public)")
        }
    }

    /// Associates a finished meeting with an earlier one it continues.
    ///
    /// Strong evidence merges on its own; anything weaker is recorded as a
    /// suggestion the meetings window offers. Neither path moves or rewrites a source
    /// segment: combining is a link, not a copy.
    @discardableResult
    private func linkContinuation(
        of metadata: MeetingMetadata, store: MeetingStore
    ) -> String? {
        let matcher = ReconnectMatcher()
        let later = ReconnectMatcher.Candidate(
            meetingID: metadata.id, provider: metadata.provider,
            providerMeetingID: metadata.providerMeetingID, url: metadata.meetingURL,
            title: metadata.titles.provider ?? metadata.titles.window,
            calendarEventID: metadata.calendar?.eventIdentifier,
            applicationBundleID: metadata.applicationBundleID,
            startedAt: metadata.startedAt, endedAt: metadata.endedAt
        )

        for summary in repository.listMeetings(limit: 6) where summary.id != metadata.id {
            guard let found = repository.findMeeting(id: summary.id) else { continue }
            let earlier = found.metadata
            guard earlier.mergedIntoMeetingID == nil else { continue }
            let candidate = ReconnectMatcher.Candidate(
                meetingID: earlier.id, provider: earlier.provider,
                providerMeetingID: earlier.providerMeetingID, url: earlier.meetingURL,
                title: earlier.titles.provider ?? earlier.titles.window,
                calendarEventID: earlier.calendar?.eventIdentifier,
                applicationBundleID: earlier.applicationBundleID,
                startedAt: earlier.startedAt, endedAt: earlier.endedAt
            )
            switch matcher.compare(candidate, later) {
            case .unrelated:
                continue
            case .sameMeeting(_, let reason):
                combine(meetingID: metadata.id, into: earlier.id, reason: reason)
                return earlier.id
            case .possible(_, let reason):
                _ = try? store.updateMetadata { updated in
                    updated.possibleContinuationOf = earlier.id
                    updated.possibleContinuationReason = reason
                }
                // A suggestion only. This meeting stays its own.
                return nil
            }
        }
        return nil
    }

    /// Links one recording to the conversation an earlier one started.
    ///
    /// Both directories stay exactly as they are: two files gain a pointer at
    /// each other and nothing else changes. The second recording is the only
    /// copy of the second half of the call, so it keeps its own segments,
    /// manifest, raw transcription, raw diarization and speaker map, and stays
    /// reachable under its own identifier.
    ///
    /// The earlier recording's own duration and runs are not touched. Adding the
    /// later half into them made the combined figure a stored total, so undoing
    /// the link became a subtraction; a subtraction that goes wrong reports a
    /// duration no file on disk supports. The combined figure is derived when it
    /// is read.
    public func combine(meetingID: String, into earlierID: String, reason: String) {
        guard let later = repository.findMeeting(id: meetingID),
              repository.findMeeting(id: earlierID) != nil
        else { return }
        // A chain would make the earlier recording both a continuation and the
        // start of one, and `logicalMeeting` would resolve past it.
        guard let target = repository.logicalMeeting(id: earlierID),
              target.id != meetingID
        else { return }
        _ = try? later.store.updateMetadata { metadata in
            metadata.mergedIntoMeetingID = target.id
            metadata.possibleContinuationOf = nil
            metadata.possibleContinuationReason = nil
        }
        _ = try? target.primary.store.updateMetadata { metadata in
            if !metadata.absorbedMeetingIDs.contains(meetingID) {
                metadata.absorbedMeetingIDs.append(meetingID)
            }
        }
        Log.app.info("combined a meeting into an earlier one: \(reason, privacy: .public)")
        refreshRecentMeetings()
        onProcessingUpdate?(target.id)
    }

    /// Separates a recording from the conversation it was linked to.
    ///
    /// The association is the only thing undone: both recordings keep every file
    /// they had, and each is its own row again. Offered because the match that
    /// linked them is a heuristic over provider identifiers and timing, and being
    /// wrong about it must not be permanent.
    public func detachContinuation(meetingID: String) {
        guard let later = repository.findMeeting(id: meetingID, includingMerged: true),
              let parentID = later.metadata.mergedIntoMeetingID
        else { return }
        _ = try? later.store.updateMetadata { metadata in
            metadata.mergedIntoMeetingID = nil
        }
        if let parent = repository.findMeeting(id: parentID, includingMerged: true) {
            _ = try? parent.store.updateMetadata { metadata in
                metadata.absorbedMeetingIDs.removeAll { $0 == meetingID }
            }
        }
        Log.app.info("separated a continuation from the meeting it was linked to")
        refreshRecentMeetings()
        onProcessingUpdate?(parentID)
    }

    /// Declines a suggested continuation, so it is not offered again.
    public func keepSeparate(meetingID: String) {
        guard let found = repository.findMeeting(id: meetingID) else { return }
        _ = try? found.store.updateMetadata { metadata in
            metadata.possibleContinuationOf = nil
            metadata.possibleContinuationReason = nil
        }
        refreshRecentMeetings()
    }

    private func askToKeep(bundleIdentifier: String, title: String?) {
        let name = applicationName(for: bundleIdentifier)
        provisionalPrompt = ProvisionalPrompt(
            meetingID: currentMeeting?.metadata.id ?? bundleIdentifier,
            applicationBundleID: bundleIdentifier,
            applicationName: name,
            title: title
        )
        if settings.showNotifications {
            notifications.askToKeep(
                applicationName: name, meetingID: currentMeeting?.metadata.id ?? ""
            )
        }
        onStatusChange?()
    }

    private func deliver(_ notice: SessionNotice) {
        guard settings.showNotifications else { return }
        switch notice {
        case .startedRecording(let provider, let title):
            notifications.recordingStarted(provider: provider, title: title)
        case .finishedRecording:
            break  // the saved notification is posted once finalisation succeeds
        case .reconnecting:
            break  // a reconnect is not worth interrupting the user for
        case .otherBrowserTabAudible:
            notifications.post(
                title: "Another tab is playing audio",
                body: "Meeting audio may include sound from another browser tab.",
                category: .captureProblem
            )
        }
    }

    /// The name to show for a process that opened the microphone.
    ///
    /// Helpers are not registered with LaunchServices, so asking for the name of
    /// `com.hnc.Discord.helper.Renderer` gets that string back and the prompt
    /// read as an identifier rather than an application.
    private func applicationName(for bundleIdentifier: String) -> String {
        let application = MicrophoneIgnoreList.applicationIdentifier(for: bundleIdentifier)
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: application)
            .map { FileManager.default.displayName(atPath: $0.path) }
            ?? application
    }

    func apply(_ progress: ProcessingPipeline.Progress) {
        let previous = processing[progress.meetingID]?.state
        if progress.state == .complete {
            processing.removeValue(forKey: progress.meetingID)
            // Not for a meeting folded into an earlier one. The notification
            // for the meeting it was folded into already covers it, and a
            // second one saying a meeting is ready would open the same pane.
            let isFolded = repository.findMeeting(
                id: progress.meetingID, includingMerged: true
            )?.metadata.mergedIntoMeetingID != nil
            if settings.showNotifications, !isFolded {
                notifications.readyToReview(title: progress.title, meetingID: progress.meetingID)
            }
        } else {
            processing[progress.meetingID] = progress
        }
        // The archive scan reads and decodes every metadata.json on disk, and
        // it runs on the actor that also carries arming and committing a
        // recording. A local transcription reports about twice a second and the
        // diarizer hundreds of times in a few seconds, none of which changes
        // what the list holds: only a stage boundary does. Rescanning on every
        // tick queued that work ahead of the capture action for the meeting
        // that had just started, which is the one moment a job is running.
        // Both are gated on the stage boundary. The panel's own progress line
        // reads the observable dictionary above, so a fraction changing needs no
        // reload; what a reload picks up, the transcript and the speaker rows,
        // only changes when a stage finishes. Reloading per tick queued
        // hundreds of archive scans and transcript decodes on the actor that
        // also arms the next recording.
        guard previous != progress.state else { return }
        refreshRecentMeetings()
        onProcessingUpdate?(progress.meetingID)
    }

    func handleProcessingFailure(_ meetingID: String, _ error: ProcessingError) {
        processing.removeValue(forKey: meetingID)
        if settings.showNotifications {
            notifications.processingProblem(error, meetingID: meetingID)
        }
        refreshRecentMeetings()
        onProcessingUpdate?(meetingID)
    }

    private func syncStatusFromSession() {
        let snapshot = sessionController.snapshot
        status.sessionState = snapshot.state
        status.source = snapshot.source
        status.provider = snapshot.provider
        status.title = currentMeeting?.metadata.displayTitle ?? snapshot.title
        status.startedAt = snapshot.startedAt
        status.isProvisional = snapshot.isProvisional
        status.detectionPaused = settings.providers.detectionPaused
        // Read by the processing gate from another executor, so a job started
        // before a meeting parks between stages instead of competing with the
        // capture that is running now.
        // Candidate carries when it started, so a prejoin left open all
        // afternoon stops holding processing after a couple of minutes: it is
        // real capture, but it is not a meeting.
        recordingSnapshot.withLock { existing in
            if status.hasActiveSession || status.sessionState == .ending {
                existing = .recording
            } else if status.sessionState == .candidate {
                if case .candidate = existing {} else { existing = .candidate(since: clock.now) }
            } else {
                existing = .idle
            }
        }
        onStatusChange?()
    }
}

/// Bridges background callbacks onto the main actor.
final class RuntimeRelay: CaptureEngineDelegate, DetectionEngineDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private weak var runtime: PipitRuntime?

    func connect(runtime: PipitRuntime) {
        lock.lock()
        self.runtime = runtime
        lock.unlock()
    }

    private var target: PipitRuntime? {
        lock.lock()
        defer { lock.unlock() }
        return runtime
    }

    /// Reached from the pipeline callbacks, which already hop to the main actor.
    var runtimeForCallbacks: PipitRuntime? { target }

    func captureEngineDidUpdateHealth(_ snapshot: CaptureHealthSnapshot) {
        let runtime = target
        Task { @MainActor in runtime?.captureHealthDidUpdate(snapshot) }
    }

    func captureEngineDidRaiseWarning(_ warning: CaptureWarning) {
        let runtime = target
        Task { @MainActor in runtime?.captureDidWarn(warning) }
    }

    func detectionEngineDidUpdate(_ snapshot: DetectionSnapshot) {
        let runtime = target
        Task { @MainActor in runtime?.detectionDidUpdate(snapshot) }
    }
}

extension SessionAction {
    /// A short operational label. Carries no meeting content.
    var logLabel: String {
        switch self {
        case .armCapture: "arm"
        case .retargetCapture: "retarget"
        case .commitRecording(let request): "commit(\(request.source.rawValue))"
        case .pauseCapture(let reason): "pause(\(reason))"
        case .beginRun: "begin_run"
        case .updateEvidence: "evidence"
        case .discardCapture(let reason): "discard(\(reason))"
        case .finishRecording(let reason): "finish(\(reason))"
        case .askToKeepProvisional: "ask_keep"
        case .notify: "notify"
        }
    }
}
