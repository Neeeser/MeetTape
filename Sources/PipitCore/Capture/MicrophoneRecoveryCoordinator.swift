import Foundation
import Synchronization

/// The input device an engine was built on, as CoreAudio describes it.
///
/// The UID is the identity; the name, rate and channel count are what a person
/// reading the manifest afterwards needs to tell a one-channel built-in
/// microphone from a nine-channel aggregate.
public struct MicrophoneDeviceDescription: Sendable, Equatable {
    public let uid: String
    public let name: String
    public let sampleRate: Double
    public let channelCount: Int

    public init(uid: String, name: String, sampleRate: Double, channelCount: Int) {
        self.uid = uid
        self.name = name
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

/// What one microphone build produced.
public struct MicrophoneBuild: Sendable, Equatable {
    /// The format the installed tap runs at, which is what segments are written
    /// in. The hardware has the last word, so this is not always the format the
    /// coordinator asked for.
    public let format: AudioFormatDescriptor
    /// The OSStatus from pointing the input unit at the system default input
    /// device, present only when that set failed. The build then runs on
    /// whatever device the unit already held, which is a real track from a
    /// device nothing here named. Carried out so the manifest says so.
    public let deviceSelectionStatus: Int32?

    public init(format: AudioFormatDescriptor, deviceSelectionStatus: Int32?) {
        self.format = format
        self.deviceSelectionStatus = deviceSelectionStatus
    }
}

/// The AVAudioEngine operations the recovery coordinator needs. Implemented for
/// real in PipitAudio and by a fake in the regression tests, so the tests
/// exercise the shipping algorithm rather than a copy of it.
public protocol MicrophoneEngineController: AnyObject, Sendable {
    /// Reads the current input device format from the hardware. Must be read fresh
    /// on every rebuild: a device re-enumerated underneath a running engine keeps
    /// the old format cached.
    func currentInputFormat() -> AudioFormatDescriptor?
    /// The identity of the current input device, stable across the rate and
    /// channel changes one device makes while it renegotiates. Two devices
    /// with the same format are still two devices, and one device changing
    /// format is still one; a format is not an identity. Nil where the system
    /// cannot say, in which case nothing is inferred from it.
    func currentInputDeviceUID() -> String?
    /// The same device, described in full, for the manifest. Nil on the same
    /// condition as `currentInputDeviceUID`, which is the system not naming the
    /// default input device.
    func currentInputDevice() -> MicrophoneDeviceDescription?
    /// Removes the tap and stops the engine.
    func teardown()
    /// Builds a new engine, installs the tap and starts it, returning what the
    /// build produced.
    ///
    /// The hardware has the last word: `preferred` is what the coordinator chose
    /// after rejecting an unusable reading, but the device may have settled on
    /// something else by the time the engine is built, and the returned format
    /// is what segments must be written in.
    ///
    /// Throwing means no engine. A build that could not open the device it
    /// wanted still returns, because a track from another device beats no track
    /// at all, and says so through `deviceSelectionStatus`.
    @discardableResult
    func buildAndStart(preferred: AudioFormatDescriptor) throws -> MicrophoneBuild
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
        targets: [RemoteAudioTarget], reason: RebuildReason, bindCount: Int, binding: RemoteTapBinding
    )
    /// Which input device the microphone engine was opened on, and what the
    /// build made of it, reported after every build that installed an engine.
    /// The device and the build's format are separate readings and can
    /// disagree.
    func captureDidBindMicrophone(
        device: MicrophoneDeviceDescription, build: MicrophoneBuild, reason: RebuildReason
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
        /// The device the installed engine was built on, by identity.
        var activeDeviceUID: String?
        /// Whether `buildAndStart` has returned since the last rebuild was
        /// decided. The one fact a buffer and an implied health state are
        /// evidence about; inferred before from the wait's cause and from a
        /// timestamp, and both went stale across the build itself, where the
        /// wait is nil and the timestamp says a rebuild is in flight whether or
        /// not it threw. Cleared the moment a rebuild is committed to, before
        /// the old engine is torn down: cleared after the teardown returned, a
        /// buffer the old tap flushed while being torn down was recorded as the
        /// new build's, and reset the grace window and every count it relied on.
        /// Set after `buildAndStart` returns, which is a few milliseconds after
        /// the engine started; a first buffer landing inside that gap is
        /// dropped, and the next one, about 85 ms behind it, is recorded.
        var engineInstalled = false
        /// When the rebuild that produced the installed engine was committed
        /// to. `engineInstalled` says an engine exists now; this says which
        /// buffers are its. A buffer already in flight on the render thread
        /// while the old tap was removed can take the lock after the new build
        /// has been recorded, and it carries the old engine's timestamp.
        var buildCommittedAt: Double = 0
        var health: CaptureHealthState = .idle
        var wakeRequestedAt: Double?
        var restartTimestamps: [Double] = []
        var unhealthySince: Double?
        var consecutiveBuildFailures = 0
        var wait: Wait?
        /// Waits cleared by a configuration change or by a differing device
        /// identity since audio last arrived. Neither signal proves anything
        /// works, and trusting them without limit is what let a driver that
        /// emits a change on every failed open forgive its own failure every
        /// time, and a flapping default input read as a fresh swap on every
        /// poll. Only a buffer resets this, because only a buffer is the
        /// engine working.
        var waitClearsWithoutAudio = 0

        /// Clears the wait for a signal that says the hardware moved, while
        /// such signals are still worth trusting.
        mutating func clearWaitForHardwareSignal(thresholds: CaptureThresholds) -> Bool {
            guard waitClearsWithoutAudio < thresholds.waitClearsBeforeBackoff else { return false }
            waitClearsWithoutAudio += 1
            wait = nil
            return true
        }

        /// The first retry is immediate, on the next poll. Each further failure
        /// doubles the wait, up to the ceiling.
        ///
        /// Unless a configuration change is already pending. A change that
        /// arrives clears a failed build's wait, because the device may be
        /// back; a change that arrived before the failure had nothing to clear,
        /// and the wait installed after it was one no change would ever end.
        /// The retry then consumed it as `manual`, and the change, still
        /// pending, tore the new engine down on the poll after. The one ordering
        /// that reaches this is a wake whose rebuild throws while a change from
        /// the settle window is still in its debounce, and the change's own
        /// rebuild is the one that should run, under its own name.
        mutating func noteBuildFailure(at now: Double, thresholds: CaptureThresholds) {
            // Only a change that arrived before this build was committed to.
            // One that arrived during it was, on the device that motivated
            // this, emitted by the failing open itself, and honouring it made
            // every failure forgive itself: 601 builds in five minutes. That
            // change stays pending, is refused by the wait, and is taken when
            // the wait expires, so a real reconnect during a failing build
            // costs at most the current step.
            if policy.configurationChangePending, policy.lastConfigurationChangeAt < buildCommittedAt {
                wait = nil
                consecutiveBuildFailures = 0
                return
            }
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
            state.waitClearsWithoutAudio = 0
            state.wakeRequestedAt = nil
            state.activeFormat = nil
            state.activeDeviceUID = nil
            state.engineInstalled = false
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
            guard state.policy.isRunning else { return }
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
            // A failed build's wait is the one a change forgives: the device
            // that could not be built may exist now, so the backoff starts
            // again from nothing and the rebuild this change decides is the one
            // that tries it. Only that wait. With no failed build waiting there
            // is nothing to forgive, and a change that arrives during a build
            // must not zero the count the build's own failure is about to
            // increment: that let a device emitting a change on every failed
            // open forgive itself on every attempt.
            // The discriminator below catches a change delivered while the
            // build is still in flight. Delivery is asynchronous, though:
            // CoreAudio posts on its own thread, so the same driver's change
            // can land just after the throw instead, with the wait already
            // standing. Then it is this clause that forgives, and it forgave on
            // every attempt: 601 builds in five minutes.
            guard state.wait?.cause == .buildFailed else { return }
            guard state.clearWaitForHardwareSignal(thresholds: thresholds) else { return }
            state.consecutiveBuildFailures = 0
        }
    }

    /// Called from the audio thread for every delivered buffer.
    public func noteBufferArrived(hostTime: Double) {
        let becameHealthy: Bool = state.withLock { state in
            // A buffer with no engine installed is the torn-down tap's last
            // delivery, or a driver flushing one while the device is being
            // opened. Nothing exists to have produced it, so it is evidence of
            // nothing: not that the microphone is healthy, not that a failure
            // is forgiven, not that silence ended. Recording it did all three.
            // It zeroed the failure count, so the next failure started again at
            // a half-second step and a driver that flushed one buffer per
            // failed open was retried 600 times in five minutes; and it marked
            // a microphone that never built healthy, which cleared the
            // unrecovered warning the user should have seen. Asking the wait's
            // cause instead was not enough, because the retry clears the wait
            // before the build runs and the build is where that driver's buffer
            // arrives.
            guard state.engineInstalled, hostTime >= state.buildCommittedAt else { return false }
            state.policy.noteBufferArrived(at: hostTime)
            // Audio arriving means the engine works, so a rebuild the hardware
            // asks for next is not held behind a silent engine's wait, and the
            // failures before this engine are forgiven.
            if state.wait?.cause == .silentEngine { state.wait = nil }
            state.consecutiveBuildFailures = 0
            // The engine works, so the signals that say the hardware moved are
            // worth trusting again.
            state.waitClearsWithoutAudio = 0
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
                // The audio stack re-enumerated, so what it says next is worth
                // trusting again.
                state.waitClearsWithoutAudio = 0
                // The audio stack re-enumerated. Whatever the silent count said,
                // it said about an engine that no longer exists; carried across,
                // the wake's own rebuild re-derived the wait the wake had just
                // cleared and held the new engine for the ceiling.
                state.policy.noteEngineGone()
            }
            rebuild(reason: .wake, isInitial: false)
            refreshHealth(at: now)
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
                  now >= wait.until,
                  // A pending change decides the rebuild instead, under its own
                  // name; taken here it was filed as manual and the change,
                  // still pending, rebuilt again a poll later.
                  !state.policy.configurationChangePending
            else { return false }
            state.wait = nil
            return true
        }
        if retryFailedBuild {
            rebuild(reason: .manual, isInitial: false)
            refreshHealth(at: now)
            return
        }

        let decision = state.withLock { $0.policy.evaluate(at: now) }
        switch decision {
        case .none:
            refreshHealth(at: now)
        case .rebuild(let reason):
            rebuild(reason: reason, isInitial: false)
            // Whether or not the rebuild ran. While a wait refuses one on
            // every poll, the decision is `.rebuild` on every poll, and health
            // was never revisited: it stayed at the `.recovering` the last
            // rebuild wrote, for as long as the engine stayed silent, and
            // `.recovering` does not light the icon that says audio is being
            // lost.
            refreshHealth(at: now)
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
        // The policy's health describes an engine that exists: how long since
        // it delivered, whether a rebuild of it is in flight. With no engine
        // installed the coordinator's own verdict stands, `.failed` or
        // `.degraded` with the reason it set, rather than being overwritten a
        // poll later by a timestamp that still said a rebuild was under way.
        let implied: CaptureHealthState? = state.withLock { state in
            state.engineInstalled ? state.policy.health(at: now) : nil
        }
        guard let implied, implied != health else { return }
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
            // Only a silent engine's wait can be pending here. A configuration
            // change clears a failed build's wait when it arrives, and a build
            // that fails under a pending change installs none, so no failed
            // build's wait survives to meet a change; the cause check below is
            // belt and braces. The silent engine's wait refuses the change
            // because, on the device this was
            // measured against, the rebuild is what emitted it. That footprint
            // is the same device, whatever format it reports this time; a
            // device the user plugged in is a different one. Identity, not
            // format: most microphones on most Macs read 48 kHz at one or two
            // channels, so a format match told a swap from the footprint on
            // none of them, and a device renegotiating its rate read as a new
            // device on every rebuild and cleared the wait each time. Where the
            // system cannot name the device, nothing is inferred and the wait
            // holds, which costs at most the ceiling.
            let differentDevice: Bool = {
                guard pending.cause == .silentEngine,
                      let current = controller.currentInputDeviceUID()
                else { return false }
                return state.withLock { state in
                    guard let active = state.activeDeviceUID, current != active else { return false }
                    // A dock or a headset whose profiles present distinct
                    // identities can alternate on every poll, and each
                    // alternation reads as a fresh swap. Admitted without limit
                    // it cleared the wait every poll and restarted the silent
                    // count each time, so the bound was absent for that shape.
                    guard state.clearWaitForHardwareSignal(thresholds: thresholds) else { return false }
                    // Whatever was silent was the other device. Carried across,
                    // the new device's first build re-latched at the ceiling.
                    state.policy.noteEngineGone()
                    return true
                }
            }()
            if !differentDevice {
                // `evaluate` consumed the pending flag and the coalesced count to
                // return this. Both go back, so the rebuild at expiry is taken
                // and recorded as the burst it was.
                state.withLock { $0.policy.noteConfigurationChangeRefused(coalesced: coalesced) }
                return
            }
        }
        state.withLock { state in
            state.policy.noteRebuildStarted(at: now, isInitial: isInitial)
            if !isInitial { state.restartTimestamps.append(now) }
            state.restartTimestamps.removeAll { now - $0 > 300 }
            // From here the old engine is being replaced. Nothing it delivers
            // from now on is evidence about anything, including the buffer a
            // driver flushes as the tap is torn down, and including a buffer
            // stamped before this moment that reaches the lock after the new
            // engine has been recorded.
            state.engineInstalled = false
            state.activeDeviceUID = nil
            state.buildCommittedAt = now
            // Whatever wait this rebuild was allowed past is spent: expired, or
            // admitted. Left in place it was still there to be forgiven by a
            // change arriving during the build.
            state.wait = nil
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
            let build = try controller.buildAndStart(preferred: format)
            let installed = build.format
            // Read after the build, so it names the device the engine is on.
            let deviceUID = controller.currentInputDeviceUID()
            if let device = controller.currentInputDevice() {
                // Both readings, because they answer different questions. The
                // device is what this build asked for; the build's format is
                // what the node reported afterwards, which is what the segments
                // are written at. They can disagree, and so can the device and
                // the one the unit actually kept. The manifest is where all of
                // that shows.
                delegate.captureDidBindMicrophone(device: device, build: build, reason: reason)
            }
            if installed != previous {
                delegate.captureWillChangeFormat(
                    track: .mic, from: previous, to: installed, reason: reason.label
                )
            }
            state.withLock { state in
                state.activeFormat = installed
                state.activeDeviceUID = deviceUID
                state.engineInstalled = true
                if !isInitial { state.policy.noteRebuildSucceeded() }
                // This build read the device fresh, which is all a change that
                // arrived before it was asking for. Left pending, a change from
                // a wake's settle window rebuilt the engine the wake had just
                // built. One that arrived during the build stays: it may be the
                // footprint, and it may be a device that arrived just now.
                if state.policy.configurationChangePending,
                   state.policy.lastConfigurationChangeAt < state.buildCommittedAt {
                    state.policy.clearPendingConfigurationChange()
                }
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
    case remoteSilentWhileProducing(seconds: Double)
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
        case .remoteSilentWhileProducing: "remote_silent_while_producing"
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
        case .remoteSilentWhileProducing:
            """
            Pipit is receiving silence from the meeting app while it reports playing audio. \
            The other side of this call may not be recorded.
            """
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
