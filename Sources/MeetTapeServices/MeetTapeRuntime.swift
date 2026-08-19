import AppKit
import Foundation
import Observation
import MeetTapeAudio
import MeetTapeCore
import MeetTapeDetection
import MeetTapeIntegrations

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

    public var isRecording: Bool { sessionState == .recording || sessionState == .reconnecting }

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
public final class MeetTapeRuntime {
    public private(set) var status = RuntimeStatus()
    public private(set) var recentMeetings: [MeetingSummary] = []
    public private(set) var processing: [String: ProcessingPipeline.Progress] = [:]
    public private(set) var provisionalPrompt: ProvisionalPrompt?
    public private(set) var reviewMeetingID: String?
    public private(set) var settings: AppSettings

    @ObservationIgnored public let repository: MeetingRepository
    @ObservationIgnored public let notifications = NotificationService()
    @ObservationIgnored public let permissions = PermissionsService()

    @ObservationIgnored private let settingsStore: SettingsStore
    /// A snapshot the processing actor can read without hopping to the main
    /// actor. `MainActor.assumeIsolated` from an actor's executor is a runtime
    /// trap, not a shortcut.
    @ObservationIgnored private let settingsSnapshot: LockedBox<AppSettings>
    /// Main-actor work is chained so state updates arrive in the order they were
    /// produced; independent tasks give no ordering guarantee.
    @ObservationIgnored private var workChain: Task<Void, Never>?
    @ObservationIgnored private let clock: any Clock
    @ObservationIgnored private var sessionController: SessionController
    @ObservationIgnored private var captureEngine: CaptureEngine!
    @ObservationIgnored private var detectionEngine: DetectionEngine!
    @ObservationIgnored private var pipeline: ProcessingPipeline!
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
        // Reads the current setting on every use, so a folder chosen in Settings
        // applies straight away.
        self.repository = MeetingRepository(rootProvider: { snapshot.withLock { $0.storageRoot } })
        self.sessionController = SessionController(policies: loaded.providers)

        captureEngine = CaptureEngine(
            clock: clock,
            segmentSeconds: loaded.segmentSeconds,
            preRollSeconds: loaded.preRollSeconds,
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
        pipeline = ProcessingPipeline(
            repository: repository,
            backend: OpenAIClient(keyProvider: keyStore),
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
        powerObserver = PowerEventObserver(
            onWake: { [weak self] in
                Task { @MainActor in self?.captureEngine.noteSystemWake() }
            },
            onSleep: {}
        )
        refreshRecentMeetings()
        // Recovery runs before detection, so a meeting that starts during launch
        // can never be scanned as an interrupted one and finalised underneath
        // itself.
        Task { @MainActor in
            await recoverAndResume()
            detectionEngine.start()
        }
    }

    public func stop() {
        detectionEngine.stop()
        if status.isRecording { stopRecording(reason: "app_quit") }
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
    private func enqueue(_ body: @escaping @MainActor @Sendable () async -> Void) {
        let previous = workChain
        workChain = Task { @MainActor in
            await previous?.value
            await body()
        }
    }

    /// Startup recovery, then resumption of anything left mid-processing.
    private func recoverAndResume() async {
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
        await pipeline.resumeInterrupted()
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
            keep: keep, reason: keep ? "kept" : "user_discarded"
        )
        syncStatusFromSession()
        enqueue { [weak self] in await self?.perform(actions) }
    }

    public func alwaysRecord(applicationBundleID: String) {
        var updated = settings
        if !updated.alwaysRecordApplications.contains(applicationBundleID) {
            updated.alwaysRecordApplications.append(applicationBundleID)
        }
        updated.neverRecordApplications.removeAll { $0 == applicationBundleID }
        update(settings: updated)
    }

    public func neverRecord(applicationBundleID: String) {
        var updated = settings
        if !updated.neverRecordApplications.contains(applicationBundleID) {
            updated.neverRecordApplications.append(applicationBundleID)
        }
        updated.alwaysRecordApplications.removeAll { $0 == applicationBundleID }
        update(settings: updated)
    }

    public func setDetectionPaused(_ paused: Bool) {
        var updated = settings
        updated.providers.detectionPaused = paused
        update(settings: updated)
    }

    public func update(settings newSettings: AppSettings) {
        settings = newSettings
        settingsSnapshot.withLock { $0 = newSettings }
        do {
            try settingsStore.save(newSettings)
        } catch {
            Log.app.error("settings not saved: \(logSafeDescription(error), privacy: .public)")
        }
        sessionController.policies = newSettings.providers
        detectionEngine.updateGenericConfiguration(newSettings.genericDetectorConfiguration)
        status.detectionPaused = newSettings.providers.detectionPaused
        onStatusChange?()
    }

    // MARK: - import

    /// Imports an existing recording. The original is copied in and left untouched.
    public func importRecording(from url: URL) async throws -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let started = (attributes?[.creationDate] as? Date) ?? clock.now
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
        metadata.runs = [RecordingRun(
            id: "run-001", startedAt: metadata.startedAt, endedAt: metadata.endedAt,
            durationSeconds: result.durationSeconds
        )]
        metadata.processing.advance(to: .finalizing, at: clock.now)
        metadata.processing.advance(to: .audioSafe, at: clock.now)
        try created.store.writeMetadata(metadata)

        refreshRecentMeetings()
        reviewMeetingID = metadata.id
        let meetingID = metadata.id
        Task { await pipeline.process(meetingID: meetingID) }
        return meetingID
    }

    // MARK: - meeting actions

    /// Transport-level state of the browser sensor, including connections refused
    /// because the peer was not MeetTape's own relay.
    public var sensorStatus: BrowserSensorServer.Status? {
        detectionEngine.sensorStatus
    }

    public func refreshRecentMeetings() {
        recentMeetings = repository.listMeetings(limit: 40)
        onStatusChange?()
    }

    public func retryProcessing(meetingID: String) {
        enqueue { [weak self] in
            guard let self else { return }
            await pipeline.retry(meetingID: meetingID)
            refreshRecentMeetings()
        }
    }

    public func assignSpeaker(name: String, key: String, meetingID: String) {
        enqueue { [weak self] in
            guard let self else { return }
            do {
                try await pipeline.applySpeakerName(name, to: key, meetingID: meetingID)
            } catch {
                Log.app.error("speaker not saved: \(logSafeDescription(error), privacy: .public)")
            }
        }
    }

    /// A human title always wins over every other candidate.
    public func saveTitle(_ title: String, meetingID: String) {
        guard let found = repository.findMeeting(id: meetingID) else { return }
        do {
            _ = try found.store.updateMetadata { $0.titles.human = title.isEmpty ? nil : title }
        } catch {
            Log.app.error("title not saved: \(logSafeDescription(error), privacy: .public)")
        }
        refreshRecentMeetings()
    }

    public func saveNotes(_ notes: String, meetingID: String) {
        guard let found = repository.findMeeting(id: meetingID) else { return }
        try? found.store.writeNotes(notes)
    }

    public func revealInFinder(meetingID: String) {
        guard let found = repository.findMeeting(id: meetingID) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([found.store.layout.root])
    }

    public func closeReview() {
        reviewMeetingID = nil
        onStatusChange?()
    }

    public func openReview(meetingID: String) {
        reviewMeetingID = meetingID
        onStatusChange?()
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
            case .beginRun(let reason):
                beginRun(reason: reason)
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
            linkContinuation(of: updated, store: meeting.store)
            reviewMeetingID = updated.id
            if settings.showNotifications {
                notifications.meetingSaved(
                    title: updated.displayTitle,
                    path: meeting.store.layout.root.path,
                    meetingID: updated.id
                )
            }
            refreshRecentMeetings()
            let meetingID = updated.id
            Task { await pipeline.process(meetingID: meetingID) }
        } catch {
            Log.app.error("finalise failed: \(logSafeDescription(error), privacy: .public)")
        }
    }

    /// Associates a finished meeting with an earlier one it continues.
    ///
    /// Strong evidence merges on its own; anything weaker is recorded as a
    /// suggestion for the review panel. Neither path moves or rewrites a source
    /// segment: combining is a link, not a copy.
    private func linkContinuation(of metadata: MeetingMetadata, store: MeetingStore) {
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
                return
            case .possible(_, let reason):
                _ = try? store.updateMetadata { updated in
                    updated.possibleContinuationOf = earlier.id
                    updated.possibleContinuationReason = reason
                }
                return
            }
        }
    }

    /// Folds one meeting into another. Both directories stay exactly as they are.
    public func combine(meetingID: String, into earlierID: String, reason: String) {
        guard let later = repository.findMeeting(id: meetingID),
              let earlier = repository.findMeeting(id: earlierID)
        else { return }
        _ = try? later.store.updateMetadata { metadata in
            metadata.mergedIntoMeetingID = earlierID
            metadata.possibleContinuationOf = nil
        }
        _ = try? earlier.store.updateMetadata { metadata in
            if !metadata.absorbedMeetingIDs.contains(meetingID) {
                metadata.absorbedMeetingIDs.append(meetingID)
            }
            metadata.runs.append(contentsOf: later.metadata.runs)
            metadata.durationSeconds += later.metadata.durationSeconds
        }
        Log.app.info("combined a meeting into an earlier one: \(reason, privacy: .public)")
        refreshRecentMeetings()
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

    private func applicationName(for bundleIdentifier: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { FileManager.default.displayName(atPath: $0.path) }
            ?? bundleIdentifier
    }

    func apply(_ progress: ProcessingPipeline.Progress) {
        if progress.state == .complete {
            processing.removeValue(forKey: progress.meetingID)
        } else {
            processing[progress.meetingID] = progress
        }
        refreshRecentMeetings()
    }

    func handleProcessingFailure(_ meetingID: String, _ error: ProcessingError) {
        processing.removeValue(forKey: meetingID)
        if settings.showNotifications {
            notifications.processingProblem(error, meetingID: meetingID)
        }
        refreshRecentMeetings()
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
        onStatusChange?()
    }
}

/// Bridges background callbacks onto the main actor.
final class RuntimeRelay: CaptureEngineDelegate, DetectionEngineDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private weak var runtime: MeetTapeRuntime?

    func connect(runtime: MeetTapeRuntime) {
        lock.lock()
        self.runtime = runtime
        lock.unlock()
    }

    private var target: MeetTapeRuntime? {
        lock.lock()
        defer { lock.unlock() }
        return runtime
    }

    /// Reached from the pipeline callbacks, which already hop to the main actor.
    var runtimeForCallbacks: MeetTapeRuntime? { target }

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
        case .beginRun: "begin_run"
        case .updateEvidence: "evidence"
        case .discardCapture(let reason): "discard(\(reason))"
        case .finishRecording(let reason): "finish(\(reason))"
        case .askToKeepProvisional: "ask_keep"
        case .notify: "notify"
        }
    }
}
