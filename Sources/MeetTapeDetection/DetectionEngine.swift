import AppKit
import Foundation
import MeetTapeAudio
import MeetTapeCore

public struct DetectionSnapshot: Sendable, Equatable {
    public var evidence: [ProviderEvidence]
    public var genericEvents: [GenericCallDetector.Event]
    public var slackState: SlackHuddleDetector.State
    public var browserSensor: BrowserSensorTracker.Connection
    public var hasAccessibility: Bool
    public var hasWindowTitles: Bool

    public init(
        evidence: [ProviderEvidence] = [],
        genericEvents: [GenericCallDetector.Event] = [],
        slackState: SlackHuddleDetector.State = .idle,
        browserSensor: BrowserSensorTracker.Connection = .absent,
        hasAccessibility: Bool = false,
        hasWindowTitles: Bool = false
    ) {
        self.evidence = evidence
        self.genericEvents = genericEvents
        self.slackState = slackState
        self.browserSensor = browserSensor
        self.hasAccessibility = hasAccessibility
        self.hasWindowTitles = hasWindowTitles
    }
}

public protocol DetectionEngineDelegate: AnyObject, Sendable {
    func detectionEngineDidUpdate(_ snapshot: DetectionSnapshot)
}

/// Turns OS observations into provider evidence on a fixed poll.
///
/// Every provider adapter here only reports what it sees. Nothing in this file
/// decides whether to record; `SessionController` does, from the evidence.
public final class DetectionEngine: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var pollInterval: Double
        public var slackBundleIdentifier: String
        public var slackAudioPrefixes: [String]
        public var browsers: [BrowserKind]
        public var genericDetection: Bool

        public init(
            pollInterval: Double = 0.5,
            slackBundleIdentifier: String = "com.tinyspeck.slackmacgap",
            slackAudioPrefixes: [String] = ["com.tinyspeck.slackmacgap"],
            browsers: [BrowserKind] = [.firefox, .chrome],
            genericDetection: Bool = true
        ) {
            self.pollInterval = pollInterval
            self.slackBundleIdentifier = slackBundleIdentifier
            self.slackAudioPrefixes = slackAudioPrefixes
            self.browsers = browsers
            self.genericDetection = genericDetection
        }
    }

    private let configuration: Configuration
    private let clock: any Clock
    private let delegate: any DetectionEngineDelegate
    private let queue = DispatchQueue(label: "com.meettape.detection", qos: .userInitiated)
    private let lock = NSLock()

    private let slackReader: SlackAccessibilityReader
    private let windowReader = WindowTitleReader()
    private let audioObserver = AudioProcessObserver()

    private var slackDetector = SlackHuddleDetector()
    private var browserDetectors: [BrowserKind: BrowserMeetingDetector] = [:]
    private var genericDetector = GenericCallDetector()
    private var timer: DispatchSourceTimer?
    private var sensorServer: BrowserSensorServer?
    private var lastSnapshot = DetectionSnapshot()
    private var previousEvidence: [String] = []

    public init(
        configuration: Configuration = Configuration(),
        clock: any Clock = SystemClock(),
        delegate: any DetectionEngineDelegate
    ) {
        self.configuration = configuration
        self.clock = clock
        self.delegate = delegate
        self.slackReader = SlackAccessibilityReader(bundleIdentifier: configuration.slackBundleIdentifier)
        for browser in configuration.browsers {
            browserDetectors[browser] = BrowserMeetingDetector(browser: browser)
        }
    }

    public var snapshot: DetectionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return lastSnapshot
    }

    public func updateGenericConfiguration(_ configuration: GenericCallDetector.Configuration) {
        lock.lock()
        genericDetector.configuration = configuration
        lock.unlock()
    }

    /// Idempotent: a second call replaces the timer rather than orphaning it.
    public func start() {
        stop()
        startSensorServer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: configuration.pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        lock.lock()
        self.timer = timer
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let timer = self.timer
        self.timer = nil
        let server = sensorServer
        sensorServer = nil
        lock.unlock()
        timer?.cancel()
        server?.stop()
    }

    /// Bundle-identifier prefixes whose audio belongs to a Slack huddle.
    public var slackAudioPrefixes: [String] { configuration.slackAudioPrefixes }

    private func startSensorServer() {
        let server = BrowserSensorServer(
            onMessage: { [weak self] message in self?.handleSensor(message) },
            onConnectionChange: { [weak self] count in self?.handleSensorConnectionChange(count) }
        )
        do {
            try server.start()
            lock.lock()
            sensorServer = server
            lock.unlock()
        } catch {
            Log.detection.error("sensor server failed to start: \(logSafeDescription(error), privacy: .public)")
        }
    }

    public var sensorStatus: BrowserSensorServer.Status? {
        lock.lock()
        defer { lock.unlock() }
        return sensorServer?.currentStatus
    }

    private func handleSensor(_ message: SensorMessage) {
        let now = clock.monotonicSeconds
        lock.lock()
        defer { lock.unlock() }
        switch message {
        case .hello(let hello):
            browserDetectors[hello.browser]?.sensorConnected(at: now)
        case .event(let event):
            browserDetectors[event.browser]?.receive(event, at: now)
        case .tabClosed(let tabID):
            // Only that tab's state goes; another tab may still be in a call.
            for (browser, var detector) in browserDetectors {
                detector.closeTab(tabID, at: now)
                browserDetectors[browser] = detector
            }
        case .goodbye(let browser):
            // One browser's host exiting says nothing about another's.
            browserDetectors[browser]?.sensorDisconnected(at: now)
        }
    }

    private func handleSensorConnectionChange(_ count: Int) {
        let now = clock.monotonicSeconds
        lock.lock()
        defer { lock.unlock() }
        guard count == 0 else { return }
        // No relay is connected at all, so no browser sensor is reporting.
        for (browser, var detector) in browserDetectors {
            detector.sensorDisconnected(at: now)
            browserDetectors[browser] = detector
        }
    }

    private func poll() {
        let now = clock.monotonicSeconds
        let audioStates = audioObserver.snapshot()
        let titles = windowReader.allTitles()
        let windowTitlesByBundle = windowReader.titlesByBundleIdentifier(from: titles)

        var evidence: [ProviderEvidence] = []
        var genericEvents: [GenericCallDetector.Event] = []

        // Read accessibility before taking the lock: the walk crosses into
        // another process and can block for seconds when Slack is busy.
        let slackObservation = slackReader.read()

        lock.lock()

        // Slack
        let slackHoldsMic = audioObserver.holdsMicrophone(
            bundlePrefixes: configuration.slackAudioPrefixes, in: audioStates
        )
        let slackProducesOutput = audioObserver.producesOutput(
            bundlePrefixes: configuration.slackAudioPrefixes, in: audioStates
        )
        _ = slackDetector.update(
            observation: slackObservation,
            helperHoldsMicrophone: slackHoldsMic,
            helperProducingOutput: slackProducesOutput,
            at: now
        )
        let slackConfidence: MeetingConfidence = switch slackDetector.state {
        case .joined, .leaving: .confirmed
        case .candidate: .candidate
        case .idle: .none
        }
        if slackConfidence > .none {
            evidence.append(ProviderEvidence(
                provider: .slack,
                confidence: slackConfidence,
                source: .accessibility,
                title: slackDetector.conversationTitle,
                muted: slackDetector.isMuted,
                applicationBundleID: configuration.slackBundleIdentifier,
                audioBundlePrefixes: configuration.slackAudioPrefixes
            ))
        }

        // Browsers
        for (browser, var detector) in browserDetectors {
            let ownerTitles = browser.windowOwnerNames.flatMap { titles[$0] ?? [] }
            let native = BrowserMeetingDetector.NativeSignals(
                browserHoldsMicrophone: audioObserver.holdsMicrophone(
                    bundlePrefixes: browser.bundleIdentifiers, in: audioStates
                ),
                browserProducesOutput: audioObserver.producesOutput(
                    bundlePrefixes: browser.bundleIdentifiers, in: audioStates
                ),
                windowTitles: ownerTitles
            )
            let result = detector.update(native: native, at: now)
            browserDetectors[browser] = detector
            if result.confidence > .none { evidence.append(result) }
        }

        // Unsupported applications
        if configuration.genericDetection {
            let knownPrefixes = configuration.slackAudioPrefixes
                + configuration.browsers.flatMap(\.bundleIdentifiers)
            let unknownStates = audioStates
                .filter { state in !knownPrefixes.contains { state.bundleIdentifier.hasPrefix($0) } }
                .map { state in
                    ApplicationAudioState(
                        bundleIdentifier: state.bundleIdentifier,
                        processID: state.processID,
                        holdsMicrophone: state.holdsMicrophone,
                        producesOutput: state.producesOutput,
                        isFrontmost: state.isFrontmost,
                        windowTitle: windowTitlesByBundle[state.bundleIdentifier]
                    )
                }
            genericEvents = genericDetector.update(states: unknownStates, at: now)
            evidence.append(contentsOf: genericDetector.currentEvidence())
        }

        let snapshot = DetectionSnapshot(
            evidence: evidence,
            genericEvents: genericEvents,
            slackState: slackDetector.state,
            browserSensor: browserDetectors[.firefox]?.sensor.connection ?? .absent,
            hasAccessibility: AccessibilityBridge.isTrusted,
            hasWindowTitles: !titles.isEmpty || windowReader.hasTitleAccess
        )
        let labels = evidence.map { item in
            "\(item.provider.rawValue):\(item.confidence.rawValue):\(item.source.rawValue)"
        }
        let evidenceChanged = previousEvidence != labels
        previousEvidence = labels
        lastSnapshot = snapshot
        lock.unlock()

        if evidenceChanged {
            Log.detection.info(
                "evidence: \(labels.isEmpty ? "none" : labels.joined(separator: ", "), privacy: .public)"
            )
        }
        delegate.detectionEngineDidUpdate(snapshot)
    }
}

extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}

extension BrowserKind {
    /// The name CoreGraphics reports as the window owner.
    var windowOwnerNames: [String] {
        switch self {
        case .firefox: ["firefox", "Firefox", "Firefox Developer Edition", "Nightly"]
        case .chrome: ["Google Chrome", "Brave Browser", "Microsoft Edge"]
        case .safari: ["Safari"]
        case .unknown: []
        }
    }
}
