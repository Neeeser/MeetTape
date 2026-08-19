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
/// The lifecycle mirrors the two-stage promotion detection needs: `arm` starts
/// both sources into a memory ring, `commit` flushes that ring into segment
/// files, and `discardArmed` throws it away without leaving a directory behind.
///
/// Two rules make the threading safe. Every operation that builds or tears down a
/// device runs on one serial control queue, so a poll-driven rebuild can never
/// interleave with a user-driven stop. And the audio callback does nothing but
/// copy, record arrival, and hand the buffer to the writer queue: no file I/O,
/// no manifest write, and no device work ever happens on a render thread.
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
        /// Incremented on every stop so a poll already in flight is discarded.
        var generation = 0
    }

    private let state = LockedBox(State())
    private let micPreRoll: PreRollBuffer
    private let remotePreRoll: PreRollBuffer
    private let clock: any Clock
    private let thresholds: CaptureThresholds
    private let segmentSeconds: Double
    private let delegate: any CaptureEngineDelegate
    /// Everything that builds, tears down or polls a device happens here.
    private let controlQueue = DispatchQueue(label: "com.meettape.capture-control", qos: .userInitiated)
    private let timerBox = LockedBox<DispatchSourceTimer?>(nil)

    private let micSource: MicrophoneEngineController
    private let remoteSource: ProcessTapController
    private let micCoordinator: MicrophoneRecoveryCoordinator
    private let remoteCoordinator: RemoteTapCoordinator
    private let coordinatorRelay: CoordinatorRelay

    /// Builds the capture sources. The defaults are the real AVFoundation and
    /// CoreAudio implementations; tests substitute fakes so the engine's own
    /// behaviour can be exercised without audio hardware.
    public typealias MicrophoneFactory = @Sendable (
        @escaping AudioBufferSink, @escaping @Sendable () -> Void
    ) -> MicrophoneEngineController
    public typealias TapFactory = @Sendable (
        @escaping AudioBufferSink, @escaping @Sendable () -> Void
    ) -> ProcessTapController

    public init(
        clock: any Clock = SystemClock(),
        thresholds: CaptureThresholds = .validated,
        segmentSeconds: Double = 30,
        preRollSeconds: Double = 15,
        makeMicrophone: MicrophoneFactory = { sink, onChange in
            MicrophoneSource(sink: sink, onConfigurationChange: onChange)
        },
        makeTap: @escaping TapFactory = { sink, onFormatChanged in
            RemoteAudioSource(sink: sink, onFormatChanged: onFormatChanged)
        },
        delegate: any CaptureEngineDelegate
    ) {
        self.clock = clock
        self.thresholds = thresholds
        self.segmentSeconds = segmentSeconds
        self.delegate = delegate
        self.micPreRoll = PreRollBuffer(capacitySeconds: preRollSeconds)
        self.remotePreRoll = PreRollBuffer(capacitySeconds: preRollSeconds)

        let relay = CoordinatorRelay(queue: controlQueue)
        self.coordinatorRelay = relay

        let micSink = SinkBox()
        let remoteSink = SinkBox()
        let rebindOnFormatChange = RebindRequest()
        self.micSource = makeMicrophone(
            { packet in micSink.deliver(packet) },
            { relay.configurationChanged() }
        )
        self.remoteSource = makeTap(
            { packet in remoteSink.deliver(packet) },
            { rebindOnFormatChange.fire() }
        )

        self.micCoordinator = MicrophoneRecoveryCoordinator(
            controller: micSource, clock: clock, thresholds: thresholds, delegate: relay
        )
        self.remoteCoordinator = RemoteTapCoordinator(
            controller: remoteSource, clock: clock, thresholds: thresholds, delegate: relay
        )
        rebindOnFormatChange.connect { [remoteCoordinator, controlQueue] in
            // The tap's format changed underneath us; rebinding is the only way to
            // start labelling buffers correctly again.
            controlQueue.async { remoteCoordinator.rebindAfterFormatChange() }
        }

        relay.connect(engine: self)
        micSink.connect { [weak self] packet in self?.receive(packet, track: .mic) }
        remoteSink.connect { [weak self] packet in self?.receive(packet, track: .remote) }
    }

    public var mode: Mode { state.withLock { $0.mode } }
    public var health: CaptureHealthSnapshot { state.withLock { $0.lastSnapshot } }

    // MARK: - lifecycle

    /// Starts both sources into the pre-roll ring. Nothing is written to disk.
    ///
    /// Building an `AVAudioEngine` and creating a process tap take hundreds of
    /// milliseconds, so this returns once the work is done on the control queue
    /// rather than doing it on the caller's thread.
    public func arm(bundlePrefixes: [String], capturesRemote: Bool) async {
        await onControlQueue {
            self.state.withLock { state in
                state.mode = .armed
                state.capturesRemote = capturesRemote
                // Warnings are per meeting; a failure in the last one must not
                // suppress the same warning in this one.
                state.warningsRaised.removeAll()
            }
            self.micPreRoll.discard()
            self.remotePreRoll.discard()
            self.micCoordinator.start()
            if capturesRemote, !bundlePrefixes.isEmpty {
                self.remoteCoordinator.start(bundlePrefixes: bundlePrefixes)
            }
            self.startPolling()
        }
    }

    /// Promotes the armed capture into a real recording: opens the manifest and
    /// the first segments, and flushes the ring into them so the opening sentence
    /// is present.
    public func commit(layout: MeetingLayout, meetingID: String, source: MeetingSource) async throws {
        try await onControlQueueThrowing {
            let manifest = try ManifestWriter(url: layout.manifest)
            manifest.append(
                .sessionStart(.init(
                    meetingID: meetingID, source: source, segmentSeconds: self.segmentSeconds,
                    appVersion: MeetTapeVersion.current,
                    processID: ProcessInfo.processInfo.processIdentifier
                )),
                hostTime: self.clock.monotonicSeconds, wallClock: self.clock.now
            )

            let capturesRemote = self.state.withLock { $0.capturesRemote }
            // The writer holds this closure and the engine holds the writer, so
            // the reference back has to be weak or the pair never deallocates.
            let engine = WeakEngine(self)
            let micFormat = self.format(from: self.micCoordinator.activeFormat)
                ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let micWriter = SegmentWriter(
                track: .mic, layout: layout, manifest: manifest, format: micFormat,
                segmentSeconds: self.segmentSeconds, clock: self.clock,
                onFailure: { error in engine.value?.handleWriteFailure(error, track: .mic) }
            )
            var remoteWriter: SegmentWriter?
            if capturesRemote, let remoteFormat = self.format(from: self.remoteCoordinator.activeFormat) {
                remoteWriter = SegmentWriter(
                    track: .remote, layout: layout, manifest: manifest, format: remoteFormat,
                    segmentSeconds: self.segmentSeconds, clock: self.clock,
                    onFailure: { error in engine.value?.handleWriteFailure(error, track: .remote) }
                )
            }

            // The ring is drained and handed to the writer queues inside the same
            // locked region that flips the mode, so a live buffer can never be
            // written ahead of the pre-roll it should follow.
            let flushed: [(CaptureTrack, Int64, Double, Double?)] = self.state.withLock { state in
                state.manifest = manifest
                state.layout = layout
                state.micWriter = micWriter
                state.remoteWriter = remoteWriter

                var summaries: [(CaptureTrack, Int64, Double, Double?)] = []
                let micPackets = self.micPreRoll.drain()
                if !micPackets.isEmpty {
                    var frames: Int64 = 0
                    var seconds: Double = 0
                    let earliest = micPackets.first?.hostTime
                    for packet in micPackets {
                        frames += Int64(packet.buffer.frameLength)
                        seconds += packet.seconds
                        micWriter.enqueue(packet)
                    }
                    summaries.append((.mic, frames, seconds, earliest))
                }
                if let remoteWriter {
                    let remotePackets = self.remotePreRoll.drain()
                    if !remotePackets.isEmpty {
                        var frames: Int64 = 0
                        var seconds: Double = 0
                        let earliest = remotePackets.first?.hostTime
                        for packet in remotePackets {
                            frames += Int64(packet.buffer.frameLength)
                            seconds += packet.seconds
                            remoteWriter.enqueue(packet)
                        }
                        summaries.append((.remote, frames, seconds, earliest))
                    }
                }
                state.mode = .recording
                return summaries
            }

            for (track, frames, seconds, earliest) in flushed {
                manifest.append(
                    .preRollFlushed(.init(
                        track: track, frameCount: frames, seconds: seconds, earliestHostTime: earliest
                    )),
                    hostTime: self.clock.monotonicSeconds, wallClock: self.clock.now
                )
            }
        }
    }

    /// Stops capture and closes the manifest. Safe to call from any state.
    @discardableResult
    public func stop(reason: String) async -> CaptureHealthSnapshot {
        await onControlQueue { self.stopOnControlQueue(reason: reason) }
    }

    /// Throws away an armed capture that was never confirmed.
    public func discardArmed() async {
        await onControlQueue {
            self.stopPolling()
            self.state.withLock { $0.generation += 1 }
            self.micCoordinator.stop()
            self.remoteCoordinator.stop()
            self.micPreRoll.discard()
            self.remotePreRoll.discard()
            self.state.withLock { state in
                state.mode = .idle
                state.lastSnapshot = CaptureHealthSnapshot()
            }
        }
    }

    public func addMarker(_ label: String) {
        let manifest = state.withLock { $0.manifest }
        guard let manifest else { return }
        controlQueue.async { [clock] in
            manifest.append(
                .marker(.init(label: label)), hostTime: clock.monotonicSeconds, wallClock: clock.now
            )
        }
    }

    /// Rebinds the remote tap to a new provider target set, which happens when a
    /// meeting moves between applications or a second provider takes over.
    public func retarget(bundlePrefixes: [String]) async {
        guard state.withLock({ $0.capturesRemote }) else { return }
        await onControlQueue {
            self.remoteCoordinator.start(bundlePrefixes: bundlePrefixes)
        }
    }

    public func noteSystemWake() {
        micCoordinator.noteWake()
        remoteCoordinator.noteWake()
    }

    // MARK: - control queue

    private func onControlQueue<Result: Sendable>(
        _ body: @escaping @Sendable () -> Result
    ) async -> Result {
        await withCheckedContinuation { continuation in
            controlQueue.async { continuation.resume(returning: body()) }
        }
    }

    private func onControlQueueThrowing(_ body: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            controlQueue.async {
                do {
                    try body()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    @discardableResult
    private func stopOnControlQueue(reason: String) -> CaptureHealthSnapshot {
        stopPolling()
        state.withLock { $0.generation += 1 }
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
        let capturesRemote = state.withLock { $0.capturesRemote }
        let snapshot = CaptureHealthSnapshot(
            mic: .idle, remote: .idle,
            micSeconds: closing.0?.stats.totalSeconds ?? 0,
            remoteSeconds: closing.1?.stats.totalSeconds ?? 0,
            isWritingToDisk: false,
            micRestarts: micCoordinator.restartCount,
            remoteRebinds: remoteCoordinator.bindCount,
            capturesRemote: capturesRemote
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

    // MARK: - audio thread

    /// Called on the microphone tap thread and the CoreAudio IOProc thread.
    ///
    /// Everything here is bounded: two lock acquisitions and one `async` hand-off.
    /// Health changes are reported through the relay, which moves the manifest
    /// write onto the control queue rather than doing it here.
    private func receive(_ packet: AudioBufferPacket, track: CaptureTrack) {
        let engine = WeakEngine(self)
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
                if track == .mic { return state.micWriter }
                // The remote tap often binds after the meeting is committed: a
                // provider's audio process may not exist yet at commit time. The
                // writer is opened on the first packet so that audio is never
                // dropped for the rest of the meeting.
                if let existing = state.remoteWriter { return existing }
                guard state.capturesRemote, let layout = state.layout, let manifest = state.manifest
                else { return nil }
                let writer = SegmentWriter(
                    track: .remote, layout: layout, manifest: manifest,
                    format: packet.buffer.format, segmentSeconds: self.segmentSeconds,
                    clock: self.clock,
                    onFailure: { error in engine.value?.handleWriteFailure(error, track: .remote) }
                )
                state.remoteWriter = writer
                return writer
            }
        }
        writer?.enqueue(packet)
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
        let generation = state.withLock { $0.generation }
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + thresholds.pollInterval, repeating: thresholds.pollInterval)
        timer.setEventHandler { [weak self] in self?.poll(generation: generation) }
        timerBox.withLock { existing in
            existing?.cancel()
            existing = timer
        }
        timer.resume()
    }

    private func stopPolling() {
        timerBox.withLock { timer in
            timer?.cancel()
            timer = nil
        }
    }

    /// Runs on the control queue, so it is serialised against arm, commit and stop.
    private func poll(generation: Int) {
        // A stop that happened while this tick was queued makes it stale.
        guard state.withLock({ $0.generation }) == generation else { return }
        micCoordinator.tick()
        if state.withLock({ $0.capturesRemote }) { remoteCoordinator.tick() }
        publishHealth()
        for warning in micCoordinator.warnings() + remoteCoordinator.warnings() {
            raise(warning)
        }
    }

    fileprivate func publishHealth() {
        // Writer statistics are read outside the engine lock: `SegmentWriter.stats`
        // takes its own lock, and a render thread waiting on the engine lock must
        // never be parked behind it.
        let (micWriter, remoteWriter, capturesRemote, mode) = state.withLock { state in
            (state.micWriter, state.remoteWriter, state.capturesRemote, state.mode)
        }
        // A remote source reporting healthy while its writer failed to open is
        // exactly the state that must never read as healthy.
        var remoteHealth = capturesRemote ? remoteCoordinator.health : .idle
        if capturesRemote, mode == .recording, let remoteWriter, remoteWriter.stats.writeFailures > 0 {
            remoteHealth = .failed
        }
        var micHealth = micCoordinator.health
        if mode == .recording, let micWriter, micWriter.stats.writeFailures > 0 {
            micHealth = .failed
        }
        let snapshot = CaptureHealthSnapshot(
            mic: micHealth,
            remote: remoteHealth,
            micSeconds: micWriter?.stats.totalSeconds ?? 0,
            remoteSeconds: remoteWriter?.stats.totalSeconds ?? 0,
            isWritingToDisk: mode == .recording,
            micRestarts: micCoordinator.restartCount,
            remoteRebinds: remoteCoordinator.bindCount,
            capturesRemote: capturesRemote
        )
        state.withLock { $0.lastSnapshot = snapshot }
        delegate.captureEngineDidUpdateHealth(snapshot)
    }

    private func raise(_ warning: CaptureWarning) {
        // Keyed by case, not payload: the time-carrying warnings change on every
        // poll and would otherwise notify twice a second for a whole outage.
        let isNew = state.withLock { state in state.warningsRaised.insert(warning.dedupKey).inserted }
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

    fileprivate func applyFormatChange(
        track: CaptureTrack, to descriptor: AudioFormatDescriptor, reason: String
    ) {
        guard let format = format(from: descriptor) else { return }
        let writer = state.withLock { state in track == .mic ? state.micWriter : state.remoteWriter }
        writer?.changeFormat(format, reason: reason)
    }

    fileprivate func noteConfigurationChange() {
        micCoordinator.noteConfigurationChange()
    }
}

/// Bridges the coordinators' delegate callbacks onto the capture engine.
///
/// Every callback is moved onto the control queue before it touches the manifest
/// or reads writer statistics, because `noteBufferArrived` reaches this from the
/// audio thread and a manifest append performs `write` and `fsync`.
private final class CoordinatorRelay: CaptureCoordinatorDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private weak var engine: CaptureEngine?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

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
        // Called from the control queue during a rebuild, and the segment has to
        // rotate before the new engine delivers its first buffer, so this one is
        // deliberately synchronous.
        target?.applyFormatChange(track: track, to: to, reason: reason)
    }

    func captureDidRestart(track: CaptureTrack, reason: RebuildReason, restartCount: Int) {
        let engine = target
        queue.async {
            engine?.recordManifest(
                .captureRestart(.init(track: track, reason: reason.label, restartCount: restartCount))
            )
        }
    }

    func captureHealthChanged(track: CaptureTrack, state: CaptureHealthState, detail: String?) {
        let engine = target
        queue.async {
            engine?.recordManifest(.sourceHealth(.init(track: track, state: state, detail: detail)))
            engine?.publishHealth()
        }
    }

    func captureDidFail(track: CaptureTrack, error: CaptureError) {
        let engine = target
        queue.async {
            engine?.recordManifest(
                .sourceHealth(.init(track: track, state: .failed, detail: error.logSafeDescription))
            )
        }
    }
}

/// A weak reference the writer's failure callback can hold without keeping the
/// engine alive.
private final class WeakEngine: @unchecked Sendable {
    weak var value: CaptureEngine?

    init(_ value: CaptureEngine) { self.value = value }
}

/// Carries the tap's format-change notification to the coordinator, which does
/// not exist yet when the source is built.
private final class RebindRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?

    func connect(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    func fire() {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?()
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
