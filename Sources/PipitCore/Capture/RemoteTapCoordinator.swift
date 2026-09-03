import Foundation
import Synchronization

/// The CoreAudio process-tap operations the remote coordinator needs.
public protocol ProcessTapController: AnyObject, Sendable {
    /// Every audio process object whose bundle identifier starts with one of the
    /// prefixes. Resolved live on every poll, because provider audio moves between
    /// helper processes and survives application restarts under a new PID.
    func resolveTargets(bundlePrefixes: [String]) -> [RemoteAudioTarget]
    func teardown()
    /// Creates the tap and aggregate device, returning what was bound.
    func bind(to targets: [RemoteAudioTarget]) throws -> RemoteTapBinding
}

/// What one successful bind produced.
///
/// The stream index is carried out of the audio layer so the manifest records
/// which buffer of the aggregate was read as the meeting.
public struct RemoteTapBinding: Sendable, Equatable {
    public let format: AudioFormatDescriptor
    /// Input streams the aggregate device publishes. Nil when CoreAudio would
    /// not report it.
    public let streamCount: Int?
    /// Index of the tap's buffer in the IOProc's list, or nil when the count
    /// was unavailable.
    public let tapStreamIndex: Int?

    public init(format: AudioFormatDescriptor, streamCount: Int?, tapStreamIndex: Int?) {
        self.format = format
        self.streamCount = streamCount
        self.tapStreamIndex = tapStreamIndex
    }
}

/// Drives `RemoteRecoveryPolicy` against a real process tap.
public final class RemoteTapCoordinator: Sendable {
    private struct State {
        var policy: RemoteRecoveryPolicy
        var bundlePrefixes: [String] = []
        var activeFormat: AudioFormatDescriptor?
        var health: CaptureHealthState = .idle
        var wakeRequestedAt: Double?
        var bindTimestamps: [Double] = []
        var faultSince: Double?
        /// Backs off a bind that keeps failing, so a denied permission does not
        /// mean tearing down and recreating a tap twice a second all meeting.
        var consecutiveBindFailures = 0
        var nextBindAllowedAt: Double = 0
    }

    private let state: Mutex<State>
    private let controller: ProcessTapController
    private let clock: any Clock
    private let thresholds: CaptureThresholds
    private let delegate: any CaptureCoordinatorDelegate

    public init(
        controller: ProcessTapController,
        clock: any Clock,
        thresholds: CaptureThresholds = .validated,
        delegate: any CaptureCoordinatorDelegate
    ) {
        self.controller = controller
        self.clock = clock
        self.thresholds = thresholds
        self.delegate = delegate
        self.state = Mutex(State(policy: RemoteRecoveryPolicy(thresholds: thresholds)))
    }

    public var health: CaptureHealthState { state.withLock { $0.health } }
    public var activeFormat: AudioFormatDescriptor? { state.withLock { $0.activeFormat } }
    public var bindCount: Int { state.withLock { $0.policy.bindCount } }
    public var boundProcessIDs: [Int32] { state.withLock { $0.policy.boundProcessIDs } }

    public func start(bundlePrefixes: [String]) {
        state.withLock { state in
            state.bundlePrefixes = bundlePrefixes
            state.policy.start()
        }
        bind(reason: .sessionStart)
    }

    public func stop() {
        state.withLock { state in
            state.policy.stop()
            state.faultSince = nil
            state.bindTimestamps = []
            state.wakeRequestedAt = nil
            state.activeFormat = nil
            state.consecutiveBindFailures = 0
        }
        controller.teardown()
        setHealth(.idle, detail: nil)
    }

    /// Records that the tap delivered, without deciding health from it.
    ///
    /// A buffer arriving is not evidence the tap is working. The aggregate
    /// device is clocked by its output sub-device rather than by the tap, so it
    /// runs whether or not the tapped application is emitting and hands over
    /// silence when it is not: one meeting on disk carries 717 MB of digital
    /// zero delivered at full rate for thirty-one minutes.
    ///
    /// Declaring `.healthy` from here also fought the poll. `evaluate` writes
    /// `.idleButBound` on a tick where no target is producing, and the next
    /// buffer overwrote it milliseconds later, so a quiet stretch logged pairs
    /// of transitions 43 ms apart instead of one state. The tapped process's own
    /// output flag is the decidable signal, and now nothing outranks it.
    public func noteBufferArrived(hostTime: Double) {
        state.withLock { state in
            state.policy.noteBufferArrived(at: hostTime)
            state.faultSince = nil
        }
    }

    /// The tap reported a format change. Buffers keep arriving labelled with the
    /// old format, so nothing else can detect this.
    public func rebindAfterFormatChange() {
        guard state.withLock({ $0.policy.isRunning }) else { return }
        state.withLock { $0.nextBindAllowedAt = 0 }
        bind(reason: .targetChanged)
    }

    public func noteWake() {
        state.withLock { $0.wakeRequestedAt = clock.monotonicSeconds }
    }

    public func tick() {
        let now = clock.monotonicSeconds

        let wakeDue: Bool = state.withLock { state in
            guard let requestedAt = state.wakeRequestedAt else { return false }
            guard now - requestedAt >= thresholds.wakeSettleDelay else { return false }
            state.wakeRequestedAt = nil
            return state.policy.isRunning
        }
        if wakeDue {
            bind(reason: .wake)
            return
        }

        let (prefixes, running) = state.withLock { ($0.bundlePrefixes, $0.policy.isRunning) }
        guard running else { return }
        let targets = controller.resolveTargets(bundlePrefixes: prefixes)
        let decision = state.withLock { $0.policy.evaluate(targets: targets, at: now) }
        switch decision {
        case .none:
            syncHealth()
        case .bind(let reason):
            if case .producingWithoutCallbacks = reason {
                state.withLock { state in
                    if state.faultSince == nil { state.faultSince = now }
                }
            }
            bind(reason: reason, resolved: targets)
        }
    }

    public func warnings(at now: Double? = nil) -> [CaptureWarning] {
        let instant = now ?? clock.monotonicSeconds
        return state.withLock { state in
            guard let faultSince = state.faultSince else { return [] }
            return [.remoteProducingWithoutCallbacks(seconds: instant - faultSince)]
        }
    }

    private func syncHealth() {
        let implied = state.withLock { $0.policy.health }
        guard implied != health else { return }
        setHealth(implied, detail: nil)
    }

    private func setHealth(_ new: CaptureHealthState, detail: String?) {
        let changed: Bool = state.withLock { state in
            guard state.health != new else { return false }
            state.health = new
            return true
        }
        if changed { delegate.captureHealthChanged(track: .remote, state: new, detail: detail) }
    }

    private func bind(reason: RebuildReason, resolved: [RemoteAudioTarget]? = nil) {
        let now = clock.monotonicSeconds
        let prefixes = state.withLock { $0.bundlePrefixes }
        let backoffUntil = state.withLock { $0.nextBindAllowedAt }
        if reason != .sessionStart, now < backoffUntil { return }
        let targets = resolved ?? controller.resolveTargets(bundlePrefixes: prefixes)

        if reason != .sessionStart {
            delegate.captureDidRestart(track: .remote, reason: reason, restartCount: bindCount)
        }

        controller.teardown()

        guard !targets.isEmpty else {
            state.withLock { state in
                state.policy.noteBound(to: [], at: now)
            }
            setHealth(.degraded, detail: "no matching audio process")
            return
        }

        do {
            let binding = try controller.bind(to: targets)
            let format = binding.format
            let previous = state.withLock { $0.activeFormat }
            if format != previous {
                delegate.captureWillChangeFormat(track: .remote, from: previous, to: format, reason: reason.label)
            }
            let count: Int = state.withLock { state in
                state.activeFormat = format
                state.policy.noteBound(to: targets, at: now)
                state.bindTimestamps.append(now)
                state.bindTimestamps.removeAll { now - $0 > 300 }
                state.consecutiveBindFailures = 0
                state.nextBindAllowedAt = 0
                return state.policy.bindCount
            }
            delegate.captureDidBindRemote(
                targets: targets, reason: reason, bindCount: count, binding: binding
            )
            setHealth(.recovering, detail: reason.label)
        } catch {
            let failures: Int = state.withLock { state in
                state.policy.noteBindFailed()
                state.consecutiveBindFailures += 1
                // 1 s, 2 s, 4 s … capped at 30 s.
                let delay = min(30, pow(2, Double(min(state.consecutiveBindFailures, 5))) / 2)
                state.nextBindAllowedAt = now + delay
                return state.consecutiveBindFailures
            }
            if failures == 3 {
                Log.capture.error("process tap has failed to bind three times running")
            }
            setHealth(.failed, detail: "tap bind failed")
            delegate.captureDidFail(
                track: .remote,
                error: (error as? CaptureError) ?? .processTapCreationFailed(status: -1)
            )
        }
    }
}
