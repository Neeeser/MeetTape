import Foundation

/// Health of one capture source.
///
/// `idleButBound` exists because a process tap delivers no callbacks at all while
/// the tapped application is silent. That is the normal state for a remote source
/// and must never be reported as a fault.
public enum CaptureHealthState: String, Codable, Sendable, CaseIterable {
    case idle
    case healthy
    case recovering
    case idleButBound = "idle_but_bound"
    case degraded
    case failed

    /// True when audio that should be arriving is not arriving.
    public var isLosingAudio: Bool {
        switch self {
        case .degraded, .failed: true
        case .idle, .healthy, .recovering, .idleButBound: false
        }
    }

    /// True when the source is doing what it is supposed to be doing.
    public var isNominal: Bool {
        switch self {
        case .healthy, .idleButBound: true
        case .idle, .recovering, .degraded, .failed: false
        }
    }
}

/// Why capture was rebuilt. Carried into the manifest so a recording's recovery
/// history is reconstructable after the fact.
public enum RebuildReason: Sendable, Equatable {
    case sessionStart
    case configurationChange(coalesced: Int)
    case watchdog(gapSeconds: Double)
    case noFirstBuffer(elapsedSeconds: Double)
    case wake
    case manual
    case targetChanged
    case targetAppeared
    case producingWithoutCallbacks(gapSeconds: Double?)
    case silentWhileProducing

    public var label: String {
        switch self {
        case .sessionStart: "session_start"
        case .configurationChange(let coalesced): "config_change(coalesced:\(coalesced))"
        case .watchdog(let gap): String(format: "watchdog(gap:%.2fs)", gap)
        case .noFirstBuffer(let elapsed): String(format: "no_first_buffer(%.2fs)", elapsed)
        case .wake: "wake"
        case .manual: "manual"
        case .targetChanged: "target_changed"
        case .targetAppeared: "target_appeared"
        case .producingWithoutCallbacks(let gap):
            gap.map { String(format: "producing_without_callbacks(gap:%.2fs)", $0) }
                ?? "producing_without_callbacks(no_callbacks_yet)"
        case .silentWhileProducing: "silent_while_producing"
        }
    }
}

/// Thresholds validated by the capture stress test. Changing any of them changes
/// measured behaviour, so they are one struct with the measurements recorded here.
public struct CaptureThresholds: Sendable, Equatable {
    /// Quiet period a burst of `AVAudioEngineConfigurationChange` notifications must
    /// settle for before the device is re-read. Bluetooth negotiation emitted six
    /// topology events in under two seconds, one of them reporting 0ch/0Hz.
    public var configurationDebounce: Double
    /// Watchdog suppression after a rebuild starts. A rebuild takes 200–900 ms and
    /// produces no frames by definition; without this the watchdog and the config
    /// observer drive each other into a rebuild storm (8 rebuilds in 5.8 s measured).
    public var rebuildGrace: Double
    /// Microphone frame-arrival watchdog. Catches `isRunning == true` with dead
    /// callbacks, which is otherwise undetectable.
    public var micCallbackTimeout: Double
    /// Remote tap fault threshold, applied only while a target is producing output.
    public var remoteCallbackTimeout: Double
    /// How long every buffer may be exactly zero while a target reports output
    /// before the tap is rebound, and again before the tap is called degraded.
    /// Three recordings on this machine hold 2 to 41 minutes of digital zero
    /// from a bound Slack helper that reported `isRunningOutput: true` the whole
    /// time. Twenty seconds is longer than any pause a person leaves in a call
    /// and short enough that a rebind still saves most of the meeting.
    public var remoteSilenceTimeout: Double
    /// Health poll interval.
    public var pollInterval: Double
    /// Settle delay after system wake before proactively rebuilding.
    public var wakeSettleDelay: Double
    /// Longest wait between attempts to rebuild a source that keeps failing. The
    /// wait doubles from one poll interval, so a device that is simply gone is
    /// retried a few times a minute instead of twice a second.
    public var rebuildBackoffCeiling: Double
    /// Rebuilds in a row with no buffer arriving before the next one waits for
    /// the backoff. A build that throws already waits; a build that succeeds
    /// and delivers nothing did not, and rebuilt on every poll after the grace
    /// window for as long as the device stayed silent. A real device switch
    /// recovers in one rebuild, and the case this was measured on took 119 in
    /// four minutes.
    public var silentRebuildsBeforeBackoff: Int
    /// Times a backoff may be cleared by something other than audio before it
    /// stops being cleared at all, until audio arrives.
    ///
    /// Two signals clear a wait without proving anything works: a
    /// configuration change, which says the hardware moved and the device may
    /// be back, and a device identity that differs from the one the wait
    /// belongs to. Both are worth trusting a few times and neither is worth
    /// trusting forever. A driver that emits a change on every failed open
    /// forgave its own failure on every attempt, and a system whose default
    /// input flaps between two devices read as a fresh swap on every poll;
    /// each rebuilt twice a second for as long as it lasted.
    ///
    /// Unmeasured, unlike the constants above. The shape it bounds is hardware
    /// misbehaving rather than anything a recording captured, and it is the
    /// same number as the silent bound for the same reason: a few attempts
    /// before the backoff takes over.
    public var waitClearsBeforeBackoff: Int

    public init(
        configurationDebounce: Double = 0.4,
        rebuildGrace: Double = 1.5,
        micCallbackTimeout: Double = 2.0,
        remoteCallbackTimeout: Double = 5.0,
        remoteSilenceTimeout: Double = 20,
        pollInterval: Double = 0.5,
        wakeSettleDelay: Double = 1.5,
        rebuildBackoffCeiling: Double = 30,
        silentRebuildsBeforeBackoff: Int = 3,
        waitClearsBeforeBackoff: Int = 3
    ) {
        self.configurationDebounce = configurationDebounce
        self.rebuildGrace = rebuildGrace
        self.micCallbackTimeout = micCallbackTimeout
        self.remoteCallbackTimeout = remoteCallbackTimeout
        self.remoteSilenceTimeout = remoteSilenceTimeout
        self.pollInterval = pollInterval
        self.wakeSettleDelay = wakeSettleDelay
        self.rebuildBackoffCeiling = rebuildBackoffCeiling
        self.silentRebuildsBeforeBackoff = silentRebuildsBeforeBackoff
        self.waitClearsBeforeBackoff = waitClearsBeforeBackoff
    }

    public static let validated = CaptureThresholds()
}
