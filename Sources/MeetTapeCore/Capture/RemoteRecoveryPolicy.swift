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
    }

    /// Called once a tap has been created for `targets`.
    public mutating func noteBound(to targets: [RemoteAudioTarget], at now: Double) {
        isRunning = true
        bindCount += 1
        boundProcessIDs = targets.map(\.processID).sorted()
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

    public mutating func noteBufferArrived(at now: Double) {
        lastBufferAt = now
        health = .healthy
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
            return .none
        }

        if liveProcessIDs != boundProcessIDs {
            return .bind(.targetChanged)
        }

        guard anyProducing else {
            health = .idleButBound
            producingSince = nil
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
        health = .healthy
        return .none
    }
}
