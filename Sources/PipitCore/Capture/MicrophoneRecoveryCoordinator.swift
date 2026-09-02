import Foundation
import Synchronization

/// The AVAudioEngine operations the recovery coordinator needs. Implemented for
/// real in PipitAudio and by a fake in the regression tests, so the tests
/// exercise the shipping algorithm rather than a copy of it.
public protocol MicrophoneEngineController: AnyObject, Sendable {
    /// Reads the current input device format from the hardware. Must be read fresh
    /// on every rebuild: a device re-enumerated underneath a running engine keeps
    /// the old format cached.
    func currentInputFormat() -> AudioFormatDescriptor?
    /// Removes the tap and stops the engine.
    func teardown()
    /// Builds a new engine, installs the tap and starts it, returning the format
    /// the tap is actually running at.
    ///
    /// The hardware has the last word: `preferred` is what the coordinator chose
    /// after rejecting an unusable reading, but the device may have settled on
    /// something else by the time the engine is built, and the returned value is
    /// what segments must be written in.
    @discardableResult
    func buildAndStart(preferred: AudioFormatDescriptor) throws -> AudioFormatDescriptor
    /// Stops or resumes asking for echo cancellation on subsequent builds.
    ///
    /// The voice-processing unit can build without error and then deliver
    /// nothing, which no build-time check can see, so giving up on it is a
    /// decision only the coordinator can reach. Cleared at the start of each
    /// capture session, because the pairing that broke it may be gone. A source
    /// with no voice unit implements this as nothing.
    func setVoiceProcessingSuppressed(_ suppressed: Bool)
}

public protocol CaptureCoordinatorDelegate: AnyObject, Sendable {
    func captureWillChangeFormat(
        track: CaptureTrack, from: AudioFormatDescriptor?, to: AudioFormatDescriptor, reason: String
    )
    func captureDidRestart(track: CaptureTrack, reason: RebuildReason, restartCount: Int)
    /// What the process tap was pointed at, and what CoreAudio said about each
    /// target's output at that moment. Recorded so a track that came back
    /// silent can be told from a track nobody was playing into.
    func captureDidBindRemote(
        targets: [RemoteAudioTarget], reason: RebuildReason, bindCount: Int
    )
    func captureHealthChanged(track: CaptureTrack, state: CaptureHealthState, detail: String?)
    func captureDidFail(track: CaptureTrack, error: CaptureError)
}

/// Drives `MicRecoveryPolicy` against a real engine.
///
/// Everything the stress test found lives here: the 400 ms configuration
/// debounce, the 1.5 s post-rebuild grace, the 2 s frame watchdog, refusal to
/// adopt a transient zero-channel device, and a proactive rebuild after wake.
public final class MicrophoneRecoveryCoordinator: Sendable {
    private struct State {
        var policy: MicRecoveryPolicy
        var activeFormat: AudioFormatDescriptor?
        var health: CaptureHealthState = .idle
        var wakeRequestedAt: Double?
        var restartTimestamps: [Double] = []
        var unhealthySince: Double?
        var lastRebuildFailedAt: Double?
        var consecutiveBuildFailures = 0
        var nextRebuildAllowedAt: Double?
        var gaveUpOnVoiceProcessing = false

        /// The first retry is immediate, on the next poll. Each further failure
        /// doubles the wait, up to the ceiling.
        mutating func noteBuildFailure(at now: Double, thresholds: CaptureThresholds) {
            lastRebuildFailedAt = now
            consecutiveBuildFailures += 1
            let steps = Double(min(consecutiveBuildFailures - 1, 6))
            let delay = min(thresholds.rebuildBackoffCeiling, thresholds.pollInterval * pow(2, steps))
            nextRebuildAllowedAt = now + delay
        }
    }

    private let state: Mutex<State>
    private let controller: MicrophoneEngineController
    private let clock: any Clock
    private let thresholds: CaptureThresholds
    private let delegate: any CaptureCoordinatorDelegate

    public init(
        controller: MicrophoneEngineController,
        clock: any Clock,
        thresholds: CaptureThresholds = .validated,
        delegate: any CaptureCoordinatorDelegate
    ) {
        self.controller = controller
        self.clock = clock
        self.thresholds = thresholds
        self.delegate = delegate
        self.state = Mutex(State(policy: MicRecoveryPolicy(thresholds: thresholds)))
    }

    public var health: CaptureHealthState { state.withLock { $0.health } }
    public var activeFormat: AudioFormatDescriptor? { state.withLock { $0.activeFormat } }
    public var restartCount: Int { state.withLock { $0.policy.restartCount } }
    public var suppressedWatchdogTrips: Int { state.withLock { $0.policy.suppressedWatchdogTrips } }

    /// Starts capture. Safe to call once; further starts are rebuilds.
    public func start() {
        // The pairing that broke the voice unit last time may be gone, so every
        // session asks for echo cancellation again.
        state.withLock { $0.gaveUpOnVoiceProcessing = false }
        controller.setVoiceProcessingSuppressed(false)
        rebuild(reason: .sessionStart, isInitial: true)
    }

    public func stop() {
        state.withLock { state in
            state.policy.stop()
            // Fault bookkeeping is per meeting: carrying it over makes the next
            // recording warn about the previous one's problems.
            state.unhealthySince = nil
            state.restartTimestamps = []
            state.lastRebuildFailedAt = nil
            state.consecutiveBuildFailures = 0
            state.nextRebuildAllowedAt = nil
            state.wakeRequestedAt = nil
            state.activeFormat = nil
            state.gaveUpOnVoiceProcessing = false
        }
        controller.teardown()
        setHealth(.idle, detail: nil)
    }

    /// `AVAudioEngineConfigurationChange`. Does not rebuild on its own, because
    /// the notification arrives in bursts and one of them can describe a device
    /// that is mid-teardown.
    public func noteConfigurationChange() {
        let now = clock.monotonicSeconds
        state.withLock { state in
            state.policy.noteConfigurationChange(at: now)
            // The hardware changed, so a device that could not be built a moment
            // ago may exist now. The backoff starts again from nothing.
            state.nextRebuildAllowedAt = nil
            state.consecutiveBuildFailures = 0
        }
    }

    /// Called from the audio thread for every delivered buffer.
    public func noteBufferArrived(hostTime: Double) {
        let becameHealthy: Bool = state.withLock { state in
            state.policy.noteBufferArrived(at: hostTime)
            guard state.health != .healthy else { return false }
            state.health = .healthy
            state.unhealthySince = nil
            return true
        }
        if becameHealthy {
            delegate.captureHealthChanged(track: .mic, state: .healthy, detail: nil)
        }
    }

    /// System wake. The rebuild is deferred by the settle delay because the audio
    /// stack is still re-enumerating devices immediately after wake.
    public func noteWake() {
        let now = clock.monotonicSeconds
        state.withLock { $0.wakeRequestedAt = now }
    }

    /// Poll. Call every `thresholds.pollInterval`.
    public func tick() {
        let now = clock.monotonicSeconds

        let wakeDue: Bool = state.withLock { state in
            guard let requestedAt = state.wakeRequestedAt else { return false }
            guard now - requestedAt >= thresholds.wakeSettleDelay else { return false }
            state.wakeRequestedAt = nil
            return state.policy.isRunning
        }
        if wakeDue {
            state.withLock { state in
                state.nextRebuildAllowedAt = nil
                state.consecutiveBuildFailures = 0
            }
            rebuild(reason: .wake, isInitial: false)
            return
        }

        // A rebuild that could not find a usable device is retried, with a
        // backoff. Retrying every poll against an absent device produced eight
        // manifest fsyncs a second for as long as the device stayed away.
        let retryFailedBuild: Bool = state.withLock { state in
            guard state.lastRebuildFailedAt != nil, state.policy.isRunning else { return false }
            if let allowedAt = state.nextRebuildAllowedAt, now < allowedAt { return false }
            state.lastRebuildFailedAt = nil
            return true
        }
        if retryFailedBuild {
            rebuild(reason: .manual, isInitial: false)
            return
        }

        let decision = state.withLock { $0.policy.evaluate(at: now) }
        switch decision {
        case .none:
            refreshHealth(at: now)
        case .rebuild(let reason):
            rebuild(reason: reason, isInitial: false)
        }
    }

    /// Warning conditions, evaluated against the validated rules: unrecovered for
    /// more than five seconds, or more than three rebuilds inside a minute.
    public func warnings(at now: Double? = nil) -> [CaptureWarning] {
        let instant = now ?? clock.monotonicSeconds
        return state.withLock { state in
            var warnings: [CaptureWarning] = []
            if let since = state.unhealthySince, instant - since > 5.0 {
                warnings.append(.microphoneUnrecovered(seconds: instant - since))
            }
            let recent = state.restartTimestamps.filter { instant - $0 <= 60 }
            if recent.count > 3 {
                warnings.append(.rebuildLoop(count: recent.count, windowSeconds: 60))
            }
            return warnings
        }
    }

    private func refreshHealth(at now: Double) {
        let implied = state.withLock { $0.policy.health(at: now) }
        guard implied != health else { return }
        setHealth(implied, detail: nil)
    }

    private func setHealth(_ new: CaptureHealthState, detail: String?) {
        let changed: Bool = state.withLock { state in
            guard state.health != new else { return false }
            state.health = new
            if new.isNominal {
                state.unhealthySince = nil
            } else if new != .idle, state.unhealthySince == nil {
                state.unhealthySince = clock.monotonicSeconds
            }
            return true
        }
        if changed { delegate.captureHealthChanged(track: .mic, state: new, detail: detail) }
    }

    private func rebuild(reason: RebuildReason, isInitial: Bool) {
        let now = clock.monotonicSeconds
        // While builds are failing, every path into a rebuild waits for the
        // backoff, including the watchdog. Otherwise a device that has gone away
        // is rebuilt on every poll and each attempt writes health transitions to
        // the manifest, which is an fsync each.
        let tooSoon: Bool = state.withLock { state in
            guard !isInitial, let allowedAt = state.nextRebuildAllowedAt else { return false }
            return now < allowedAt
        }
        if tooSoon { return }
        state.withLock { state in
            state.policy.noteRebuildStarted(at: now, isInitial: isInitial)
            if !isInitial { state.restartTimestamps.append(now) }
            state.restartTimestamps.removeAll { now - $0 > 300 }
        }
        setHealth(.recovering, detail: reason.label)
        if !isInitial {
            delegate.captureDidRestart(track: .mic, reason: reason, restartCount: restartCount)
        }

        controller.teardown()

        // Read the device fresh. A burst that has settled reports the real device;
        // an unusable reading here means the hardware is still in transition.
        let candidate = controller.currentInputFormat()
        let previous = state.withLock { $0.activeFormat }
        let chosen: AudioFormatDescriptor?
        if let candidate, candidate.isUsable {
            chosen = candidate
        } else if let previous, previous.isUsable {
            // Keep recording at the last good format rather than adopting 0ch/0Hz.
            chosen = previous
        } else {
            chosen = nil
        }

        guard let format = chosen else {
            state.withLock { $0.noteBuildFailure(at: now, thresholds: thresholds) }
            setHealth(.degraded, detail: "no usable input device")
            return
        }

        // A voice unit that builds and then records nothing looks exactly like a
        // healthy one until the buffers do not arrive, and rebuilding into it
        // emits another configuration change, so the rebuild is what sustains
        // the loop. Give it up and build plainly instead.
        let giveUp: Bool = state.withLock { state in
            guard !state.gaveUpOnVoiceProcessing, state.policy.voiceProcessingLooksFaulty
            else { return false }
            state.gaveUpOnVoiceProcessing = true
            return true
        }
        if giveUp { controller.setVoiceProcessingSuppressed(true) }

        do {
            let installed = try controller.buildAndStart(preferred: format)
            if installed != previous {
                delegate.captureWillChangeFormat(
                    track: .mic, from: previous, to: installed, reason: reason.label
                )
            }
            state.withLock { state in
                state.activeFormat = installed
                state.consecutiveBuildFailures = 0
                state.nextRebuildAllowedAt = nil
            }
        } catch {
            state.withLock { $0.noteBuildFailure(at: now, thresholds: thresholds) }
            setHealth(.failed, detail: "engine start failed")
            delegate.captureDidFail(
                track: .mic,
                error: (error as? CaptureError) ?? .microphoneEngineStartFailed(status: -1)
            )
        }
    }
}

/// Conditions that justify interrupting the user. Everything else stays silent:
/// silence, mute, an idle remote application, a single successful rebuild, and a
/// device switch that recovered are all normal.
public enum CaptureWarning: Sendable, Equatable {
    case microphoneUnrecovered(seconds: Double)
    case rebuildLoop(count: Int, windowSeconds: Double)
    case remoteProducingWithoutCallbacks(seconds: Double)
    case segmentWriteFailed(track: CaptureTrack)
    case permissionRevoked(track: CaptureTrack)
    case storageUnavailable(path: String)

    /// Identifies the condition, not the moment. Two reports of the same problem
    /// are one warning however long it has lasted.
    public var dedupKey: String {
        switch self {
        case .microphoneUnrecovered: "microphone_unrecovered"
        case .rebuildLoop: "rebuild_loop"
        case .remoteProducingWithoutCallbacks: "remote_without_callbacks"
        case .segmentWriteFailed(let track): "segment_write_failed_\(track.rawValue)"
        case .permissionRevoked(let track): "permission_revoked_\(track.rawValue)"
        case .storageUnavailable: "storage_unavailable"
        }
    }

    public var message: String {
        switch self {
        case .microphoneUnrecovered:
            "Pipit cannot capture the microphone at the moment. Meeting audio is still being recorded."
        case .rebuildLoop:
            "The microphone keeps disconnecting. Audio may be incomplete."
        case .remoteProducingWithoutCallbacks:
            "The meeting application is playing audio that Pipit is not receiving. Reconnecting."
        case .segmentWriteFailed:
            "Pipit could not write recorded audio to disk."
        case .permissionRevoked(let track):
            track == .mic
                ? "Microphone access was revoked while recording."
                : "System audio access was revoked while recording."
        case .storageUnavailable:
            "Pipit has no writable location for recordings."
        }
    }
}
