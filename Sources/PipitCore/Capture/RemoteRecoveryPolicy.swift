import Foundation

/// One CoreAudio process object that matches a provider's bundle prefixes.
///
/// Slack Huddle audio lives in `com.tinyspeck.slackmacgap.helper`, not in the main
/// Slack bundle, so targets are always resolved by prefix over the live process
/// list rather than pinned to a bundle identifier or a PID.
public struct RemoteAudioTarget: Sendable, Equatable, Hashable {
    public let audioObjectID: UInt32
    public let processID: Int32
    public let bundleIdentifier: String
    public let isRunningOutput: Bool

    public init(audioObjectID: UInt32, processID: Int32, bundleIdentifier: String, isRunningOutput: Bool) {
        self.audioObjectID = audioObjectID
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.isRunningOutput = isRunningOutput
    }
}

/// Remote (process tap) health, which is a different problem from the microphone.
///
/// A tap on an idle application delivers zero callbacks indefinitely, and that is
/// correct behaviour. The decidable signal is the tapped process's own output
/// state, so a callback gap is only a fault while a target is producing output.
public struct RemoteRecoveryPolicy: Sendable {
    public enum Decision: Sendable, Equatable {
        case none
        case bind(RebuildReason)
    }

    public private(set) var thresholds: CaptureThresholds
    public private(set) var health: CaptureHealthState = .idle
    public private(set) var boundProcessIDs: [Int32] = []
    public private(set) var bindCount = 0
    public private(set) var isRunning = false

    private var lastBufferAt: Double?
    private var producingSince: Double?
    /// When the run of exactly-zero buffers began. A rebind that changes
    /// nothing leaves it running, so the episode is measured end to end. It
    /// only means anything while a target reports output, and `clearSilenceRun`
    /// says what ends it.
    private var silentSince: Double?
    /// When the tap was rebound because of that run.
    private var silentRebindAt: Double?
    /// Set by `evaluate` when it calls the tap degraded for that run. The
    /// health state and the warning read this one flag, so a poll can never
    /// warn the user about a run it has not yet called degraded.
    private var silenceDeclared = false

    public init(thresholds: CaptureThresholds = .validated) {
        self.thresholds = thresholds
    }

    public mutating func start() {
        isRunning = true
        health = .recovering
    }

    public mutating func stop() {
        isRunning = false
        health = .idle
        boundProcessIDs = []
        lastBufferAt = nil
        producingSince = nil
        clearSilenceRun()
    }

    /// Ends the run of zero buffers and everything decided from it.
    ///
    /// The run is evidence only against a target that says it is playing. The
    /// aggregate device is clocked by its output sub-device, so it hands over
    /// digital zero at full rate through every quiet stretch, and a run carried
    /// out of one of those into the moment output starts rebinds on the first
    /// poll of the call. A run carried past the process it was measured against
    /// does the same to that process's replacement.
    private mutating func clearSilenceRun() {
        silentSince = nil
        silentRebindAt = nil
        silenceDeclared = false
    }

    /// Called once a tap has been created for `targets`.
    public mutating func noteBound(to targets: [RemoteAudioTarget], at now: Double) {
        isRunning = true
        bindCount += 1
        let processIDs = targets.map(\.processID).sorted()
        // Rebinding the same processes is the attempt to fix the silence run
        // that is already under way, so it must not re-arm the wait for a
        // second one. A different set of processes is a different source, and
        // its silence is judged from its own bind.
        if processIDs != boundProcessIDs { clearSilenceRun() }
        boundProcessIDs = processIDs
        lastBufferAt = nil
        // Restart the producing clock so the fault threshold is measured from this
        // bind, not from before it. Without this a target that keeps producing
        // while the tap stays silent rebinds on every poll.
        producingSince = nil
        health = targets.isEmpty ? .degraded : .recovering
    }

    public mutating func noteBindFailed() {
        health = .failed
    }

    /// `peak` is the largest sample magnitude in the buffer, or nil when the
    /// caller could not measure it. A buffer nobody read says nothing about
    /// whether the tap carries audio, so it leaves the silence run alone.
    public mutating func noteBufferArrived(at now: Double, peak: Float?) {
        lastBufferAt = now
        health = .healthy
        guard let peak else { return }
        if peak > 0 {
            clearSilenceRun()
        } else if silentSince == nil {
            silentSince = now
        }
    }

    /// Seconds of unbroken silence, once `evaluate` has called the tap
    /// degraded for it. Nil until then, which is the state the warning reports.
    public func unrecoveredSilence(at now: Double) -> Double? {
        guard silenceDeclared, let silentSince else { return nil }
        return now - silentSince
    }

    public func gap(at now: Double) -> Double? {
        guard let lastBufferAt else { return nil }
        return now - lastBufferAt
    }

    public mutating func evaluate(targets: [RemoteAudioTarget], at now: Double) -> Decision {
        guard isRunning else { return .none }
        let liveProcessIDs = targets.map(\.processID).sorted()
        let anyProducing = targets.contains { $0.isRunningOutput }

        if boundProcessIDs.isEmpty {
            guard !targets.isEmpty else {
                health = .degraded
                return .none
            }
            return .bind(.targetAppeared)
        }

        if liveProcessIDs.isEmpty {
            // The tapped application exited. This is source absence, not tap
            // failure, and polling continues so a relaunch rebinds immediately.
            health = .degraded
            producingSince = nil
            clearSilenceRun()
            return .none
        }

        if liveProcessIDs != boundProcessIDs {
            return .bind(.targetChanged)
        }

        guard anyProducing else {
            health = .idleButBound
            producingSince = nil
            clearSilenceRun()
            return .none
        }

        if producingSince == nil { producingSince = now }
        let producingFor = now - (producingSince ?? now)

        guard let gap = gap(at: now) else {
            if producingFor > thresholds.remoteCallbackTimeout {
                return .bind(.producingWithoutCallbacks(gapSeconds: nil))
            }
            health = .recovering
            return .none
        }

        if gap > thresholds.remoteCallbackTimeout, producingFor > thresholds.remoteCallbackTimeout {
            health = .failed
            return .bind(.producingWithoutCallbacks(gapSeconds: gap))
        }
        if gap > thresholds.remoteCallbackTimeout {
            // Producing only recently; not yet a fault.
            health = .recovering
            return .none
        }

        // Buffers are arriving and every one of them is digital zero while the
        // target says it is playing. Rebinding is worth one try, because the
        // tap may be reading the wrong stream of the aggregate. Silence that
        // outlives the rebind is a recording losing its far side, and the user
        // is the only one who can do anything about it.
        if let silentSince, now - silentSince >= thresholds.remoteSilenceTimeout {
            guard let silentRebindAt else {
                self.silentRebindAt = now
                return .bind(.silentWhileProducing)
            }
            if now - silentRebindAt >= thresholds.remoteSilenceTimeout {
                silenceDeclared = true
                health = .degraded
                return .none
            }
        }
        health = .healthy
        return .none
    }
}
