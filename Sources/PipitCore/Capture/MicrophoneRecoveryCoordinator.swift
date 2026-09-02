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
    /// Why the next rebuild is waiting. Two things earn a wait and they are
    /// released by different events, so the wait carries which one it is
    /// rather than leaving every reader to infer it from side-channels.
    ///
    /// That inference is where four rounds of review each found a bug: a
    /// timestamp that meant both "the last build threw" and "the retry has
    /// not run", cleared on one of the paths that end a failure; and a
    /// silent-rebuild count that no failure reset, still asserting an engine
    /// was silent after the engine was gone. Each fix corrected one reader and
    /// left the others reading the stale value.
    private enum WaitCause: Sendable, Equatable {
        /// The build threw or found no usable device. No engine exists, so no
        /// buffer can ever release this; a configuration change can, because
        /// the device may be back, and so can expiry.
        case buildFailed
        /// The build succeeded and delivered nothing, several times in a row.
        /// An engine exists, so its first buffer releases this; a configuration
        /// change does not, because on the device this was measured against
        /// the rebuild is what emitted the change.
        case silentEngine
    }

    private struct Wait: Sendable, Equatable {
        var until: Double
        var cause: WaitCause
    }

    private struct State {
        var policy: MicRecoveryPolicy
        var activeFormat: AudioFormatDescriptor?
        var health: CaptureHealthState = .idle
        var wakeRequestedAt: Double?
        var restartTimestamps: [Double] = []
        var unhealthySince: Double?
        var consecutiveBuildFailures = 0
        var wait: Wait?

        /// The first retry is immediate, on the next poll. Each further failure
        /// doubles the wait, up to the ceiling.
        mutating func noteBuildFailure(at now: Double, thresholds: CaptureThresholds) {
            consecutiveBuildFailures += 1
            wait = Wait(
                until: now + Self.backoff(step: consecutiveBuildFailures - 1, thresholds: thresholds),
                cause: .buildFailed
            )
        }

        /// A build that succeeded and then delivered nothing, for the Nth time in
        /// a row. The same doubling wait as a build that threw, from the point
        /// the count stopped looking like a recovery.
        mutating func noteSilentRebuild(count: Int, at now: Double, thresholds: CaptureThresholds) {
            // From one poll interval past the threshold. A wait of exactly one
            // interval expires on the very poll it was meant to hold, because
            // `tooSoon` is strict and polls land on the grid.
            let step = count - thresholds.silentRebuildsBeforeBackoff + 1
            wait = Wait(until: now + Self.backoff(step: step, thresholds: thresholds), cause: .silentEngine)
        }

        private static func backoff(step: Int, thresholds: CaptureThresholds) -> Double {
            let steps = Double(min(max(step, 0), 6))
            return min(thresholds.rebuildBackoffCeiling, thresholds.pollInterval * pow(2, steps))
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
        rebuild(reason: .sessionStart, isInitial: true)
    }

    public func stop() {
        state.withLock { state in
            state.policy.stop()
            // Fault bookkeeping is per meeting: carrying it over makes the next
            // recording warn about the previous one's problems.
            state.unhealthySince = nil
            state.restartTimestamps = []
            state.consecutiveBuildFailures = 0
            state.wait = nil
            state.wakeRequestedAt = nil
            state.activeFormat = nil
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
            // A silent engine's wait holds here. On the device this bound was
            // measured against, each rebuild was followed by a configuration
            // change, and clearing the wait on it reopened the loop at the
            // debounce cadence. That was observed with the voice-processing
            // unit installed; whether a plain rebuild still emits one there is
            // unverified, so this guards the shape rather than a measured
            // property of the current build. The decision this change produces
            // is where a real device switch is told from the footprint: a
            // change that reports a different device is admitted there, and
            // only a change reporting the same one waits out the ceiling.
            if state.wait?.cause == .silentEngine { return }
            // Otherwise the hardware changed, so a device that could not be
            // built a moment ago may exist now. The backoff starts again from
            // nothing, and the rebuild this change decides is the one that
            // tries it.
            state.wait = nil
            state.consecutiveBuildFailures = 0
        }
    }

    /// Called from the audio thread for every delivered buffer.
    public func noteBufferArrived(hostTime: Double) {
        let becameHealthy: Bool = state.withLock { state in
            // A buffer with a failed build's wait pending is the torn-down tap's
            // last delivery. No engine exists to have produced it, so it is
            // evidence of nothing: not that the microphone is healthy, not that
            // a failure is forgiven, not that silence ended. Recording it did
            // all three. It zeroed the failure count, so the next failure
            // started again at a half-second step and a driver that flushed one
            // buffer per failed open was retried 600 times in five minutes; and
            // it marked a microphone that never built healthy, which cleared
            // the unrecovered warning the user should have seen.
            guard state.wait?.cause != .buildFailed else { return false }
            state.policy.noteBufferArrived(at: hostTime)
            // Audio arriving means the engine works, so a rebuild the hardware
            // asks for next is not held behind a silent engine's wait, and the
            // failures before this engine are forgiven.
            if state.wait?.cause == .silentEngine { state.wait = nil }
            state.consecutiveBuildFailures = 0
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
                state.wait = nil
                state.consecutiveBuildFailures = 0
                // The audio stack re-enumerated. Whatever the silent count said,
                // it said about an engine that no longer exists; carried across,
                // the wake's own rebuild re-derived the wait the wake had just
                // cleared and held the new engine for the ceiling.
                state.policy.noteEngineGone()
            }
            rebuild(reason: .wake, isInitial: false)
            return
        }

        // A rebuild that could not find a usable device is retried, with a
        // backoff. Retrying every poll against an absent device produced eight
        // manifest fsyncs a second for as long as the device stayed away. Only a
        // failed build's wait is retried here: a silent engine's wait expires
        // into whatever the policy decides on the next poll, and a build that
        // succeeded leaves nothing here to retry, so a working engine is never
        // torn down on the poll after a wake or a reconnect.
        let retryFailedBuild: Bool = state.withLock { state in
            guard let wait = state.wait, wait.cause == .buildFailed, state.policy.isRunning,
                  now >= wait.until
            else { return false }
            state.wait = nil
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
        let pending: Wait? = state.withLock { state in
            guard !isInitial, let wait = state.wait, now < wait.until else { return nil }
            return wait
        }
        if let pending {
            guard case .configurationChange(let coalesced) = reason else {
                // A watchdog or first-buffer decision re-derives itself from
                // the gap on the next poll; nothing is lost by refusing it.
                return
            }
            // A silent engine's wait refuses the change because, on the device
            // this was measured against, the rebuild is what emitted it. That
            // footprint reports the same device. A change that reports a
            // different one is a device the user just plugged in, and it is not
            // the footprint of anything: it is admitted, whatever the wait.
            if pending.cause == .silentEngine,
               let candidate = controller.currentInputFormat(), candidate.isUsable,
               candidate != state.withLock({ $0.activeFormat }) {
                state.withLock { $0.wait = nil }
            } else {
                // `evaluate` consumed the pending flag and the coalesced count to
                // return this. Both go back, so the rebuild at expiry is taken
                // and recorded as the burst it was.
                state.withLock { $0.policy.noteConfigurationChangeRefused(coalesced: coalesced, at: now) }
                return
            }
        }
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
            state.withLock { state in
                state.policy.noteEngineGone()
                state.noteBuildFailure(at: now, thresholds: thresholds)
            }
            setHealth(.degraded, detail: "no usable input device")
            return
        }

        do {
            let installed = try controller.buildAndStart(preferred: format)
            if installed != previous {
                delegate.captureWillChangeFormat(
                    track: .mic, from: previous, to: installed, reason: reason.label
                )
            }
            state.withLock { state in
                state.activeFormat = installed
                if !isInitial { state.policy.noteRebuildSucceeded() }
                // Success is not recovery until a buffer arrives, for the wait
                // and for the failure count alike. An engine that builds cleanly
                // and delivers nothing was rebuilt on every poll after the grace
                // window, because each success cleared the wait the failing
                // case had earned: 119 rebuilds in four minutes, each a
                // teardown, a manifest fsync and another configuration change.
                // After a few of those the next attempt waits, and a device
                // that alternates throwing with silent success is not forgiven
                // its failures by the successes.
                if state.policy.isRebuildingWithoutAudio {
                    state.noteSilentRebuild(
                        count: state.policy.rebuildsWithoutAudio, at: now, thresholds: thresholds
                    )
                } else {
                    // The build worked, so whatever a failed build was waiting
                    // on is over; the failure count itself is forgiven by the
                    // first buffer, not by this.
                    state.wait = nil
                }
            }
        } catch {
            state.withLock { state in
                state.policy.noteEngineGone()
                state.noteBuildFailure(at: now, thresholds: thresholds)
            }
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
