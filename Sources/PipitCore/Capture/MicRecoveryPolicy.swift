import Foundation

/// The microphone recovery decision, validated against the capture stress test.
///
/// The policy holds no I/O. It is fed configuration-change notifications and
/// buffer arrivals, and asked on every poll whether to rebuild. Keeping it pure is
/// what makes the rebuild-storm regression reproducible in a test.
///
/// Order matters and is the fix for the storm:
///  1. a settled configuration burst rebuilds once, against the settled device;
///  2. an unsettled burst does nothing at all;
///  3. a rebuild in flight suppresses the watchdog for the grace window;
///  4. only then does frame-arrival absence count as a fault.
public struct MicRecoveryPolicy: Sendable {
    public enum Decision: Sendable, Equatable {
        case none
        case rebuild(RebuildReason)
    }

    public private(set) var thresholds: CaptureThresholds
    public private(set) var isRunning = false
    public private(set) var configurationChangePending = false
    public private(set) var coalescedConfigurationChanges = 0
    public private(set) var suppressedWatchdogTrips = 0
    public private(set) var restartCount = 0
    /// Successful rebuilds in a row with no buffer arriving after any of them.
    /// An engine that builds without error and then delivers nothing looks
    /// healthy to every check but this one. A build that throws is not counted
    /// and resets it: no engine exists then, so nothing about silence can be
    /// said of it.
    public private(set) var rebuildsWithoutAudio = 0

    private var lastConfigurationChangeAt: Double = 0
    private var rebuildStartedAt: Double?
    private var lastBufferAt: Double?
    private var startedAt: Double = 0

    public init(thresholds: CaptureThresholds = .validated) {
        self.thresholds = thresholds
    }

    /// Called when the engine build begins, including the first one. Setting the
    /// grace window on the first build too means a source that never delivers a
    /// first buffer is still caught, instead of waiting forever for a gap that
    /// cannot be measured.
    public mutating func noteRebuildStarted(at now: Double, isInitial: Bool) {
        isRunning = true
        rebuildStartedAt = now
        if isInitial {
            startedAt = now
            lastBufferAt = nil
            rebuildsWithoutAudio = 0
        } else {
            restartCount += 1
        }
    }

    public mutating func noteConfigurationChange(at now: Double) {
        guard isRunning else { return }
        if configurationChangePending { coalescedConfigurationChanges += 1 }
        configurationChangePending = true
        lastConfigurationChangeAt = now
    }

    /// Called from the audio thread on every buffer. Arrival is the signal, never
    /// amplitude: a silent room produces valid buffers of zeroes.
    public mutating func noteBufferArrived(at now: Double) {
        lastBufferAt = now
        rebuildStartedAt = nil
        rebuildsWithoutAudio = 0
    }

    /// A rebuild whose engine built and started. Counted here rather than when
    /// the rebuild began, because a build that threw is not a silent engine:
    /// no engine exists, no buffer could ever release the count, and treating
    /// it as one held a reconnected device behind the silent-rebuild wait.
    public mutating func noteRebuildSucceeded() {
        rebuildsWithoutAudio += 1
    }

    /// A rebuild whose engine did not build. Whatever the count said about the
    /// engine before it, that engine is gone, and the one that comes after has
    /// not yet been silent at all. Left standing, the count went on asserting
    /// a silent engine through a run of failures, and a device that came back
    /// during them was held behind the silent engine's wait.
    public mutating func noteRebuildFailed() {
        rebuildsWithoutAudio = 0
    }

    /// Whether rebuilding has stopped being a recovery and become a loop.
    ///
    /// One shape, exactly: an engine that builds cleanly and delivers no
    /// buffer at all afterwards, rebuild after rebuild. That is the shape
    /// measured, 119 rebuilds in four minutes at the grace-window cadence, and
    /// each one is another teardown, another manifest fsync and another
    /// configuration change for nothing.
    ///
    /// Not covered: an engine that delivers a burst after each rebuild and then
    /// stops, because any buffer resets this, and a driver that delivers
    /// buffers of zeroes, because arrival is the signal and not amplitude. Both
    /// still rebuild at the watchdog cadence.
    public var isRebuildingWithoutAudio: Bool {
        rebuildsWithoutAudio >= thresholds.silentRebuildsBeforeBackoff
    }

    public mutating func stop() {
        isRunning = false
        configurationChangePending = false
        rebuildStartedAt = nil
        lastBufferAt = nil
        rebuildsWithoutAudio = 0
    }

    /// Seconds since the last buffer, or nil when none has arrived yet.
    public func gap(at now: Double) -> Double? {
        guard let lastBufferAt else { return nil }
        return now - lastBufferAt
    }

    public mutating func evaluate(at now: Double) -> Decision {
        guard isRunning else { return .none }

        if configurationChangePending, now - lastConfigurationChangeAt >= thresholds.configurationDebounce {
            let coalesced = coalescedConfigurationChanges
            configurationChangePending = false
            coalescedConfigurationChanges = 0
            return .rebuild(.configurationChange(coalesced: coalesced))
        }
        // The burst is still settling. Reading the device now can catch it
        // mid-teardown reporting zero channels at zero hertz.
        if configurationChangePending { return .none }

        if let rebuildStartedAt, now - rebuildStartedAt < thresholds.rebuildGrace {
            // No frames are expected yet. Count the suppression so a looping
            // recovery is visible without turning it into a warning.
            if let gap = gap(at: now), gap > thresholds.micCallbackTimeout {
                suppressedWatchdogTrips += 1
            }
            return .none
        }

        guard let gap = gap(at: now) else {
            let elapsed = now - startedAt
            if elapsed > thresholds.micCallbackTimeout + thresholds.rebuildGrace {
                return .rebuild(.noFirstBuffer(elapsedSeconds: elapsed))
            }
            return .none
        }

        if gap > thresholds.micCallbackTimeout {
            return .rebuild(.watchdog(gapSeconds: gap))
        }
        return .none
    }

    /// Health implied by the policy alone. The coordinator refines this once it
    /// knows whether the engine actually came back.
    public func health(at now: Double) -> CaptureHealthState {
        guard isRunning else { return .idle }
        if rebuildStartedAt != nil { return .recovering }
        guard let gap = gap(at: now) else { return .recovering }
        return gap > thresholds.micCallbackTimeout ? .degraded : .healthy
    }
}
