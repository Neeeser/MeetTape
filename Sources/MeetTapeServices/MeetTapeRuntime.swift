import AppKit
import Foundation
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
    public let applicationName: String
    public let title: String?
    public var id: String { meetingID }
}

/// Owns every subsystem and turns session decisions into real work.
///
/// Detection produces evidence, `SessionController` decides the lifecycle, and
/// this object performs the resulting actions: arming capture, creating the
/// meeting directory, finalising, and handing the recording to processing.
@MainActor
public final class MeetTapeRuntime {
    public private(set) var status = RuntimeStatus()
    public private(set) var recentMeetings: [MeetingSummary] = []
    public private(set) var processing: [String: ProcessingPipeline.Progress] = [:]
    public private(set) var provisionalPrompt: ProvisionalPrompt?
    public private(set) var reviewMeetingID: String?
    public private(set) var settings: AppSettings

    public let repository: MeetingRepository
    public let notifications = NotificationService()
    public let permissions = PermissionsService()

    private let settingsStore: SettingsStore
    private let clock: any Clock
    private var sessionController: SessionController
    private var captureEngine: CaptureEngine!
    private var detectionEngine: DetectionEngine!
    private var pipeline: ProcessingPipeline!
    private var powerObserver: PowerEventObserver?
    private var currentMeeting: (metadata: MeetingMetadata, store: MeetingStore)?
    private var onStatusChange: (@MainActor @Sendable () -> Void)?
    private let relay = RuntimeRelay()

    public init(
        settingsDirectory: URL = SensorTransport.defaultApplicationSupport,
        clock: any Clock = SystemClock()
    ) {
        self.clock = clock
        self.settingsStore = SettingsStore(directory: settingsDirectory)
        let loaded = settingsStore.load()
        self.settings = loaded
        self.repository = MeetingRepository(root: loaded.storageRoot)
        self.sessionController = SessionController(policies: loaded.providers)

        captureEngine = CaptureEngine(
            clock: clock,
            segmentSeconds: loaded.segmentSeconds,
            preRollSeconds: loaded.preRollSeconds,
            delegate: relay
        )
        detectionEngine = DetectionEngine(clock: clock, delegate: relay)
        detectionEngine.updateGenericConfiguration(loaded.genericDetectorConfiguration)

        let keyStore = LayeredAPIKeyStore(providers: [KeychainAPIKeyStore(), EnvironmentAPIKeyStore()])
        pipeline = ProcessingPipeline(
            repository: repository,
            backend: OpenAIClient(keyProvider: keyStore),
            calendar: CalendarService(),
            clock: clock,
            settingsProvider: { [weak self] in
                MainActor.assumeIsolated { self?.settings ?? AppSettings() }
            },
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
        detectionEngine.start()
        powerObserver = PowerEventObserver(
            onWake: { [weak self] in
                Task { @MainActor in self?.captureEngine.noteSystemWake() }
            },
            onSleep: {}
        )
        refreshRecentMeetings()
        Task { await recoverAndResume() }
    }

    public func stop() {
        detectionEngine.stop()
        if status.isRecording { stopRecording(reason: "app_quit") }
    }

    /// Startup recovery, then resumption of anything left mid-processing.
    private func recoverAndResume() async {
        let scanner = RecoveryScanner(
            repository: repository, inspector: AudioFileInspector(), clock: clock
        )
        let report = scanner.scan()
        for recovered in report.recovered {
            Log.app.notice(
                "recovered interrupted meeting \(recovered.meetingID, privacy: .public), \(recovered.adoptedSegments) crash tails"
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

        for event in snapshot.genericEvents {
            guard case .callLikely(let candidate) = event else { continue }
            handleGenericCandidate(candidate)
        }

        let actions = sessionController.update(
            evidence: snapshot.evidence, now: clock.monotonicSeconds, wallClock: clock.now
        )
        perform(actions)
        syncStatusFromSession()
    }

    private func handleGenericCandidate(_ candidate: GenericCallDetector.Candidate) {
        guard sessionController.snapshot.state == .idle else { return }
        guard settings.providers.unknownCalls.autoStart != .never else { return }
        guard !settings.providers.detectionPaused else { return }

        var titles = TitleCandidates(
            timestampFallback: MeetingRepository.timestampTitle(
                startedAt: clock.now, source: .genericCall
            )
        )
        titles.window = candidate.windowTitle
        let actions = sessionController.startManual(
            source: .genericCall,
            bundlePrefixes: [candidate.bundleIdentifier],
            titles: titles,
            now: clock.monotonicSeconds,
            wallClock: clock.now,
            isProvisional: !candidate.isPreapproved,
            applicationBundleID: candidate.bundleIdentifier
        )
        perform(actions)
        syncStatusFromSession()
    }

    func captureHealthDidUpdate(_ snapshot: CaptureHealthSnapshot) {
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
        perform(sessionController.startManual(
            source: .manual, bundlePrefixes: bundlePrefixes, titles: titles,
            now: clock.monotonicSeconds, wallClock: clock.now
        ))
        syncStatusFromSession()
    }

    public func startInPersonRecording() {
        let titles = TitleCandidates(
            timestampFallback: MeetingRepository.timestampTitle(startedAt: clock.now, source: .inPerson)
        )
        perform(sessionController.startManual(
            source: .inPerson, bundlePrefixes: [], titles: titles,
            now: clock.monotonicSeconds, wallClock: clock.now
        ))
        syncStatusFromSession()
    }

    public func stopRecording(reason: String = "user_stopped") {
        perform(sessionController.stop(reason: reason))
        syncStatusFromSession()
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
        guard let prompt = provisionalPrompt else { return }
        provisionalPrompt = nil
        if keep, !settings.alwaysRecordApplications.contains(prompt.applicationName) {
            // Remembering the choice is offered separately; keeping is per meeting.
        }
        perform(sessionController.resolveProvisional(
            keep: keep, reason: keep ? "kept" : "user_discarded"
        ))
        syncStatusFromSession()
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
        try? settingsStore.save(newSettings)
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
        let importer = AudioImporter(segmentSeconds: settings.segmentSeconds, clock: clock)
        let result = try importer.import(
            source: url, into: created.store, meetingID: created.metadata.id
        )

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

    public func refreshRecentMeetings() {
        recentMeetings = repository.listMeetings(limit: 40)
        onStatusChange?()
    }

    public func retryProcessing(meetingID: String) {
        Task {
            await pipeline.retry(meetingID: meetingID)
            refreshRecentMeetings()
        }
    }

    public func assignSpeaker(name: String, key: String, meetingID: String) {
        try? pipeline.applySpeakerName(name, to: key, meetingID: meetingID)
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

    private func perform(_ actions: [SessionAction]) {
        for action in actions {
            switch action {
            case .armCapture(let prefixes, let capturesRemote):
                captureEngine.arm(bundlePrefixes: prefixes, capturesRemote: capturesRemote)
            case .retargetCapture(let prefixes):
                captureEngine.retarget(bundlePrefixes: prefixes)
            case .commitRecording(let request):
                commit(request)
            case .beginRun(let reason):
                beginRun(reason: reason)
            case .updateEvidence(let evidence):
                applyEvidence(evidence)
            case .discardCapture(let reason):
                discard(reason: reason)
            case .finishRecording(let reason):
                finish(reason: reason)
            case .askToKeepProvisional(let bundleIdentifier, let title):
                askToKeep(bundleIdentifier: bundleIdentifier, title: title)
            case .notify(let notice):
                deliver(notice)
            }
        }
    }

    private func commit(_ request: CommitRequest) {
        do {
            let created = try repository.createMeeting(
                source: request.source, provider: request.provider,
                startedAt: request.startedAt, titles: request.titles, now: clock.now
            )
            var metadata = created.metadata
            metadata.providerMeetingID = request.providerMeetingID
            metadata.meetingURL = request.url
            metadata.browser = request.browser
            metadata.applicationBundleID = request.applicationBundleID
            metadata.provisionalDecision = request.isProvisional ? .pending : nil
            metadata.runs = [RecordingRun(id: "run-001", startedAt: request.startedAt)]
            try created.store.writeMetadata(metadata)

            try captureEngine.commit(
                layout: created.store.layout, meetingID: metadata.id, source: request.source
            )
            currentMeeting = (metadata, created.store)
            refreshRecentMeetings()
        } catch {
            Log.app.error("commit failed: \(logSafeDescription(error), privacy: .public)")
            captureEngine.discardArmed()
            _ = sessionController.stop(reason: "commit_failed")
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

    private func discard(reason: String) {
        captureEngine.discardArmed()
        if let meeting = currentMeeting {
            _ = captureEngine.stop(reason: reason)
            // A provisional recording the user declined leaves nothing behind.
            try? FileManager.default.removeItem(at: meeting.store.layout.root)
            currentMeeting = nil
            refreshRecentMeetings()
        }
        provisionalPrompt = nil
    }

    private func finish(reason: String) {
        let snapshot = captureEngine.stop(reason: reason)
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

    private func askToKeep(bundleIdentifier: String, title: String?) {
        let name = applicationName(for: bundleIdentifier)
        provisionalPrompt = ProvisionalPrompt(
            meetingID: currentMeeting?.metadata.id ?? bundleIdentifier,
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
