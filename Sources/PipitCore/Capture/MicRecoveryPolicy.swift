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
    /// Rebuilds in a row after which not one buffer arrived.
    public private(set) var silentRebuilds = 0

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
            silentRebuilds = 0
        } else {
            restartCount += 1
            silentRebuilds += 1
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
        silentRebuilds = 0
    }

    /// Whether the engine has been rebuilt enough times without recording
    /// anything that echo cancellation is the likeliest cause.
    public var voiceProcessingLooksFaulty: Bool {
        silentRebuilds >= thresholds.voiceProcessingFailureRebuilds
    }

    public mutating func stop() {
        isRunning = false
        configurationChangePending = false
        rebuildStartedAt = nil
        lastBufferAt = nil
        silentRebuilds = 0
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
