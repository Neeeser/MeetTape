import Foundation
import Synchronization

/// The CoreAudio process-tap operations the remote coordinator needs.
public protocol ProcessTapController: AnyObject, Sendable {
    /// Every audio process object whose bundle identifier starts with one of the
    /// prefixes. Resolved live on every poll, because provider audio moves between
    /// helper processes and survives application restarts under a new PID.
    func resolveTargets(bundlePrefixes: [String]) -> [RemoteAudioTarget]
    func teardown()
    /// Creates the tap and aggregate device, returning the tap's format.
    func bind(to targets: [RemoteAudioTarget]) throws -> AudioFormatDescriptor
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
        state.withLock { $0.policy.stop() }
        controller.teardown()
        setHealth(.idle, detail: nil)
    }

    public func noteBufferArrived(hostTime: Double) {
        let becameHealthy: Bool = state.withLock { state in
            state.policy.noteBufferArrived(at: hostTime)
            guard state.health != .healthy else { return false }
            state.health = .healthy
            state.faultSince = nil
            return true
        }
        if becameHealthy {
            delegate.captureHealthChanged(track: .remote, state: .healthy, detail: nil)
        }
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
            let format = try controller.bind(to: targets)
            let previous = state.withLock { $0.activeFormat }
            if format != previous {
                delegate.captureWillChangeFormat(track: .remote, from: previous, to: format, reason: reason.label)
            }
            state.withLock { state in
                state.activeFormat = format
                state.policy.noteBound(to: targets, at: now)
                state.bindTimestamps.append(now)
                state.bindTimestamps.removeAll { now - $0 > 300 }
            }
            setHealth(.recovering, detail: reason.label)
        } catch {
            state.withLock { $0.policy.noteBindFailed() }
            setHealth(.failed, detail: "tap bind failed")
            delegate.captureDidFail(
                track: .remote,
                error: (error as? CaptureError) ?? .processTapCreationFailed(status: -1)
            )
        }
    }
}
