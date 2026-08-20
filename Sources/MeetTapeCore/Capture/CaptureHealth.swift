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
    /// Health poll interval.
    public var pollInterval: Double
    /// Settle delay after system wake before proactively rebuilding.
    public var wakeSettleDelay: Double
    /// Longest wait between attempts to rebuild a source that keeps failing. The
    /// wait doubles from one poll interval, so a device that is simply gone is
    /// retried a few times a minute instead of twice a second.
    public var rebuildBackoffCeiling: Double
    /// Rebuilds in a row that deliver no audio at all before echo cancellation
    /// is given up on. The voice unit can build without error and then record
    /// nothing, and rebuilding into it produces another configuration change, so
    /// nothing else breaks the loop. A real device switch recovers in one.
    public var voiceProcessingFailureRebuilds: Int

    public init(
        configurationDebounce: Double = 0.4,
        rebuildGrace: Double = 1.5,
        micCallbackTimeout: Double = 2.0,
        remoteCallbackTimeout: Double = 5.0,
        pollInterval: Double = 0.5,
        wakeSettleDelay: Double = 1.5,
        rebuildBackoffCeiling: Double = 30,
        voiceProcessingFailureRebuilds: Int = 3
    ) {
        self.configurationDebounce = configurationDebounce
        self.rebuildGrace = rebuildGrace
        self.micCallbackTimeout = micCallbackTimeout
        self.remoteCallbackTimeout = remoteCallbackTimeout
        self.pollInterval = pollInterval
        self.wakeSettleDelay = wakeSettleDelay
        self.rebuildBackoffCeiling = rebuildBackoffCeiling
        self.voiceProcessingFailureRebuilds = voiceProcessingFailureRebuilds
    }

    public static let validated = CaptureThresholds()
}
