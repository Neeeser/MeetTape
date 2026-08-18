import AVFoundation
import Foundation
import MeetTapeCore

/// Live capture health for the menu bar and the manifest.
public struct CaptureHealthSnapshot: Sendable, Equatable {
    public var mic: CaptureHealthState
    public var remote: CaptureHealthState
    public var micSeconds: Double
    public var remoteSeconds: Double
    public var isWritingToDisk: Bool
    public var micRestarts: Int
    public var remoteRebinds: Int
    public var capturesRemote: Bool

    public init(
        mic: CaptureHealthState = .idle, remote: CaptureHealthState = .idle,
        micSeconds: Double = 0, remoteSeconds: Double = 0, isWritingToDisk: Bool = false,
        micRestarts: Int = 0, remoteRebinds: Int = 0, capturesRemote: Bool = true
    ) {
        self.mic = mic
        self.remote = remote
        self.micSeconds = micSeconds
        self.remoteSeconds = remoteSeconds
        self.isWritingToDisk = isWritingToDisk
        self.micRestarts = micRestarts
        self.remoteRebinds = remoteRebinds
        self.capturesRemote = capturesRemote
    }

    /// What the menu bar shows. A recording is never displayed as healthy while a
    /// required source is known to be failing.
    public var overall: CaptureHealthState {
        let sources = capturesRemote ? [mic, remote] : [mic]
        if sources.contains(.failed) { return .failed }
        if sources.contains(.degraded) { return .degraded }
        if sources.contains(.recovering) { return .recovering }
        if sources.allSatisfy(\.isNominal) { return .healthy }
        return .idle
    }
}

public protocol CaptureEngineDelegate: AnyObject, Sendable {
    func captureEngineDidUpdateHealth(_ snapshot: CaptureHealthSnapshot)
    func captureEngineDidRaiseWarning(_ warning: CaptureWarning)
}

/// Owns both capture sources for one recording.
///
/// The lifecycle mirrors the two-stage promotion the detection design needs:
/// `arm` starts both sources into a memory ring, `commit` flushes that ring into
/// segment files, and `discard` throws it away without leaving a directory behind.
public final class CaptureEngine: Sendable {
    public enum Mode: Sendable, Equatable {
        case idle
        /// Capturing into the pre-roll ring only. Nothing is on disk yet.
        case armed
        case recording
    }

    private struct State {
        var mode: Mode = .idle
        var micWriter: SegmentWriter?
        var remoteWriter: SegmentWriter?
        var manifest: ManifestWriter?
        var layout: MeetingLayout?
        var capturesRemote = true
        var lastSnapshot = CaptureHealthSnapshot()
        var warningsRaised: Set<String> = []
    }

    private let state = LockedBox(State())
    private let micPreRoll: PreRollBuffer
    private let remotePreRoll: PreRollBuffer
    private let clock: any Clock
    private let thresholds: CaptureThresholds
    private let segmentSeconds: Double
    private let delegate: any CaptureEngineDelegate
    private let pollQueue = DispatchQueue(label: "com.meettape.capture-poll", qos: .userInitiated)
    private let timerBox = LockedBox<DispatchSourceTimer?>(nil)

    private let micSource: MicrophoneSource
    private let remoteSource: RemoteAudioSource
    private let micCoordinator: MicrophoneRecoveryCoordinator
    private let remoteCoordinator: RemoteTapCoordinator
    private let coordinatorRelay: CoordinatorRelay

    public init(
        clock: any Clock = SystemClock(),
        thresholds: CaptureThresholds = .validated,
        segmentSeconds: Double = 30,
        preRollSeconds: Double = 15,
        delegate: any CaptureEngineDelegate
    ) {
        self.clock = clock
        self.thresholds = thresholds
        self.segmentSeconds = segmentSeconds
        self.delegate = delegate
        self.micPreRoll = PreRollBuffer(capacitySeconds: preRollSeconds)
        self.remotePreRoll = PreRollBuffer(capacitySeconds: preRollSeconds)

        let relay = CoordinatorRelay()
        self.coordinatorRelay = relay

        let micSink = SinkBox()
        let remoteSink = SinkBox()
        self.micSource = MicrophoneSource(
            sink: { packet in micSink.deliver(packet) },
            onConfigurationChange: { relay.configurationChanged() }
        )
        self.remoteSource = RemoteAudioSource(sink: { packet in remoteSink.deliver(packet) })

        self.micCoordinator = MicrophoneRecoveryCoordinator(
            controller: micSource, clock: clock, thresholds: thresholds, delegate: relay
        )
        self.remoteCoordinator = RemoteTapCoordinator(
            controller: remoteSource, clock: clock, thresholds: thresholds, delegate: relay
        )

        relay.connect(engine: self)
        micSink.connect { [weak self] packet in self?.receive(packet, track: .mic) }
        remoteSink.connect { [weak self] packet in self?.receive(packet, track: .remote) }
    }

    public var mode: Mode { state.withLock { $0.mode } }
    public var health: CaptureHealthSnapshot { state.withLock { $0.lastSnapshot } }

    // MARK: - lifecycle

    /// Starts both sources into the pre-roll ring. Nothing is written to disk.
    public func arm(bundlePrefixes: [String], capturesRemote: Bool) {
        state.withLock { state in
            state.mode = .armed
            state.capturesRemote = capturesRemote
        }
        micPreRoll.discard()
        remotePreRoll.discard()
        micCoordinator.start()
        if capturesRemote, !bundlePrefixes.isEmpty {
            remoteCoordinator.start(bundlePrefixes: bundlePrefixes)
        }
        startPolling()
    }

    /// Promotes the armed capture into a real recording: opens the manifest, opens
    /// the first segments, and flushes the ring into them so the opening sentence
    /// is present.
    public func commit(layout: MeetingLayout, meetingID: String, source: MeetingSource) throws {
        let manifest = try ManifestWriter(url: layout.manifest)
        manifest.append(
            .sessionStart(.init(
                meetingID: meetingID, source: source, segmentSeconds: segmentSeconds,
                appVersion: MeetTapeVersion.current, processID: ProcessInfo.processInfo.processIdentifier
            )),
            hostTime: clock.monotonicSeconds, wallClock: clock.now
        )

        let capturesRemote = state.withLock { $0.capturesRemote }
        let micFormat = format(from: micCoordinator.activeFormat)
            ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let micWriter = SegmentWriter(
            track: .mic, layout: layout, manifest: manifest, format: micFormat,
            segmentSeconds: segmentSeconds, clock: clock,
            onFailure: { [weak self] error in self?.handleWriteFailure(error, track: .mic) }
        )
        var remoteWriter: SegmentWriter?
        if capturesRemote, let remoteFormat = format(from: remoteCoordinator.activeFormat) {
            remoteWriter = SegmentWriter(
                track: .remote, layout: layout, manifest: manifest, format: remoteFormat,
                segmentSeconds: segmentSeconds, clock: clock,
                onFailure: { [weak self] error in self?.handleWriteFailure(error, track: .remote) }
            )
        }

        // Draining and switching mode happen together so no live buffer slips
        // between the ring and the file.
        let (micPackets, remotePackets) = state.withLock { state -> ([AudioBufferPacket], [AudioBufferPacket]) in
            state.manifest = manifest
            state.layout = layout
            state.micWriter = micWriter
            state.remoteWriter = remoteWriter
            let mic = micPreRoll.drain()
            let remote = remotePreRoll.drain()
            state.mode = .recording
            return (mic, remote)
        }

        flush(micPackets, into: micWriter, track: .mic, manifest: manifest)
        if let remoteWriter {
            flush(remotePackets, into: remoteWriter, track: .remote, manifest: manifest)
        }
    }

    /// Stops capture and closes the manifest. Safe to call from any state.
    @discardableResult
    public func stop(reason: String) -> CaptureHealthSnapshot {
        stopPolling()
        micCoordinator.stop()
        remoteCoordinator.stop()

        let closing = state.withLock { state -> (SegmentWriter?, SegmentWriter?, ManifestWriter?) in
            let values = (state.micWriter, state.remoteWriter, state.manifest)
            state.mode = .idle
            state.micWriter = nil
            state.remoteWriter = nil
            state.manifest = nil
            return values
        }
        closing.0?.finish(reason: reason)
        closing.1?.finish(reason: reason)
        let snapshot = CaptureHealthSnapshot(
            mic: .idle, remote: .idle,
            micSeconds: closing.0?.stats.totalSeconds ?? 0,
            remoteSeconds: closing.1?.stats.totalSeconds ?? 0,
            isWritingToDisk: false,
            micRestarts: micCoordinator.restartCount,
            remoteRebinds: remoteCoordinator.bindCount
        )
        closing.2?.append(
            .sessionEnd(.init(
                reason: reason, micSeconds: snapshot.micSeconds, remoteSeconds: snapshot.remoteSeconds
            )),
            hostTime: clock.monotonicSeconds, wallClock: clock.now
        )
        closing.2?.close()
        micPreRoll.discard()
        remotePreRoll.discard()
        state.withLock { $0.lastSnapshot = snapshot }
        delegate.captureEngineDidUpdateHealth(snapshot)
        return snapshot
    }

    /// Throws away an armed capture that was never confirmed.
    public func discardArmed() {
        stopPolling()
        micCoordinator.stop()
        remoteCoordinator.stop()
        micPreRoll.discard()
        remotePreRoll.discard()
        state.withLock { state in
            state.mode = .idle
            state.lastSnapshot = CaptureHealthSnapshot()
        }
    }

    public func addMarker(_ label: String) {
        let manifest = state.withLock { $0.manifest }
        manifest?.append(
            .marker(.init(label: label)), hostTime: clock.monotonicSeconds, wallClock: clock.now
        )
    }

    /// Rebinds the remote tap to a new provider target set, which happens when a
    /// meeting moves between applications or a second provider takes over.
    public func retarget(bundlePrefixes: [String]) {
        guard state.withLock({ $0.capturesRemote }) else { return }
        remoteCoordinator.start(bundlePrefixes: bundlePrefixes)
    }

    public func noteSystemWake() {
        micCoordinator.noteWake()
        remoteCoordinator.noteWake()
    }

    // MARK: - internals

    private func receive(_ packet: AudioBufferPacket, track: CaptureTrack) {
        switch track {
        case .mic: micCoordinator.noteBufferArrived(hostTime: packet.hostTime)
        case .remote: remoteCoordinator.noteBufferArrived(hostTime: packet.hostTime)
        }

        let writer = state.withLock { state -> SegmentWriter? in
            switch state.mode {
            case .idle:
                return nil
            case .armed:
                (track == .mic ? micPreRoll : remotePreRoll).append(packet)
                return nil
            case .recording:
                return track == .mic ? state.micWriter : state.remoteWriter
            }
        }
        writer?.enqueue(packet)
    }

    private func flush(
        _ packets: [AudioBufferPacket], into writer: SegmentWriter,
        track: CaptureTrack, manifest: ManifestWriter
    ) {
        guard !packets.isEmpty else { return }
        var frames: Int64 = 0
        var seconds: Double = 0
        for packet in packets {
            writer.enqueue(packet)
            frames += Int64(packet.buffer.frameLength)
            seconds += packet.seconds
        }
        manifest.append(
            .preRollFlushed(.init(
                track: track, frameCount: frames, seconds: seconds,
                earliestHostTime: packets.first?.hostTime
            )),
            hostTime: clock.monotonicSeconds, wallClock: clock.now
        )
    }

    private func format(from descriptor: AudioFormatDescriptor?) -> AVAudioFormat? {
        guard let descriptor, descriptor.isUsable else { return nil }
        return AVAudioFormat(
            standardFormatWithSampleRate: descriptor.sampleRate,
            channels: AVAudioChannelCount(descriptor.channelCount)
        )
    }

    private func startPolling() {
        stopPolling()
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + thresholds.pollInterval, repeating: thresholds.pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        timerBox.withLock { $0 = timer }
    }

    private func stopPolling() {
        timerBox.withLock { timer in
            timer?.cancel()
            timer = nil
        }
    }

    private func poll() {
        micCoordinator.tick()
        if state.withLock({ $0.capturesRemote }) { remoteCoordinator.tick() }
        publishHealth()
        for warning in micCoordinator.warnings() + remoteCoordinator.warnings() {
            raise(warning)
        }
    }

    fileprivate func publishHealth() {
        let snapshot = state.withLock { state -> CaptureHealthSnapshot in
            let snapshot = CaptureHealthSnapshot(
                mic: micCoordinator.health,
                remote: state.capturesRemote ? remoteCoordinator.health : .idle,
                micSeconds: state.micWriter?.stats.totalSeconds ?? 0,
                remoteSeconds: state.remoteWriter?.stats.totalSeconds ?? 0,
                isWritingToDisk: state.mode == .recording,
                micRestarts: micCoordinator.restartCount,
                remoteRebinds: remoteCoordinator.bindCount,
                capturesRemote: state.capturesRemote
            )
            state.lastSnapshot = snapshot
            return snapshot
        }
        delegate.captureEngineDidUpdateHealth(snapshot)
    }

    private func raise(_ warning: CaptureWarning) {
        let key = String(describing: warning).prefix(40).description
        let isNew = state.withLock { state in state.warningsRaised.insert(key).inserted }
        guard isNew else { return }
        delegate.captureEngineDidRaiseWarning(warning)
    }

    private func handleWriteFailure(_ error: CaptureError, track: CaptureTrack) {
        raise(.segmentWriteFailed(track: track))
        Log.capture.error("segment write failed: \(error.logSafeDescription, privacy: .public)")
    }

    fileprivate func recordManifest(_ event: ManifestEvent) {
        let manifest = state.withLock { $0.manifest }
        manifest?.append(event, hostTime: clock.monotonicSeconds, wallClock: clock.now)
    }

    fileprivate func applyFormatChange(track: CaptureTrack, to descriptor: AudioFormatDescriptor, reason: String) {
        guard let format = format(from: descriptor) else { return }
        let writer = state.withLock { state in track == .mic ? state.micWriter : state.remoteWriter }
        writer?.changeFormat(format, reason: reason)
    }

    fileprivate func noteConfigurationChange() {
        micCoordinator.noteConfigurationChange()
    }
}

/// Bridges the coordinators' delegate callbacks onto the engine. It exists so the
/// engine can be fully initialised before the coordinators are handed a reference
/// to it.
private final class CoordinatorRelay: CaptureCoordinatorDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private weak var engine: CaptureEngine?

    func connect(engine: CaptureEngine) {
        lock.lock()
        defer { lock.unlock() }
        self.engine = engine
    }

    private var target: CaptureEngine? {
        lock.lock()
        defer { lock.unlock() }
        return engine
    }

    func configurationChanged() {
        target?.noteConfigurationChange()
    }

    func captureWillChangeFormat(
        track: CaptureTrack, from: AudioFormatDescriptor?, to: AudioFormatDescriptor, reason: String
    ) {
        target?.applyFormatChange(track: track, to: to, reason: reason)
    }

    func captureDidRestart(track: CaptureTrack, reason: RebuildReason, restartCount: Int) {
        target?.recordManifest(
            .captureRestart(.init(track: track, reason: reason.label, restartCount: restartCount))
        )
    }

    func captureHealthChanged(track: CaptureTrack, state: CaptureHealthState, detail: String?) {
        target?.recordManifest(.sourceHealth(.init(track: track, state: state, detail: detail)))
        target?.publishHealth()
    }

    func captureDidFail(track: CaptureTrack, error: CaptureError) {
        target?.recordManifest(
            .sourceHealth(.init(track: track, state: .failed, detail: error.logSafeDescription))
        )
    }
}

/// Lets a source be constructed before its consumer exists.
private final class SinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (AudioBufferPacket) -> Void)?

    func connect(_ handler: @escaping @Sendable (AudioBufferPacket) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    func deliver(_ packet: AudioBufferPacket) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(packet)
    }
}

public enum MeetTapeVersion {
    public static let current: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }()
}
