import Foundation
import PipitCore
import Synchronization

/// Stands in for AVAudioEngine. Records every teardown and build so a rebuild
/// storm is countable, and lets a test script the exact device readings macOS
/// produced during Bluetooth negotiation, including the transient 0ch/0Hz one.
final class FakeMicrophoneEngine: MicrophoneEngineController, Sendable {
    struct Build: Sendable, Equatable {
        let format: AudioFormatDescriptor
    }

    private struct State {
        var formatQueue: [AudioFormatDescriptor?] = []
        var steadyFormat: AudioFormatDescriptor? = AudioFormatDescriptor(sampleRate: 48_000, channelCount: 1)
        var builds: [Build] = []
        var teardowns = 0
        var running = false
        var failNextBuild: CaptureError?
        var formatReads = 0
        var installedFormat: AudioFormatDescriptor?
        var failEveryBuild: CaptureError?
        var deviceUID: String? = "fake-input"
        /// The OSStatus a build reports for a device it could not open. A
        /// build that reports one still succeeds, which is the real shape:
        /// `MicrophoneSource` keeps the engine it built on whatever device the
        /// input unit already held.
        var deviceSelectionStatus: Int32?
        /// Runs inside `buildAndStart`, before the build is decided. A driver
        /// that flushes a buffer while the device is being opened delivers it
        /// here, on the coordinator's own call stack, which is the only place
        /// a test can put a buffer into the window between teardown and the
        /// build's outcome.
        var duringBuild: (@Sendable () -> Void)?
        /// Runs inside `teardown`. A driver that flushes a buffer as the tap is
        /// removed delivers it here, on the coordinator's own call stack, after
        /// the rebuild has been decided and before the new build begins.
        var duringTeardown: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    var builds: [Build] { state.withLock { $0.builds } }
    var buildCount: Int { state.withLock { $0.builds.count } }
    var teardownCount: Int { state.withLock { $0.teardowns } }
    var isRunning: Bool { state.withLock { $0.running } }
    var formatReads: Int { state.withLock { $0.formatReads } }

    /// Sets the device reading returned once capture settles.
    func setSteadyFormat(_ format: AudioFormatDescriptor?) {
        state.withLock { $0.steadyFormat = format }
    }

    /// The identity of the device behind the readings. Changing it is a
    /// different device; changing only the format is the same device
    /// renegotiating.
    func setDeviceUID(_ uid: String?) {
        state.withLock { $0.deviceUID = uid }
    }

    /// Makes every build report that it could not open the device it asked for.
    func setDeviceSelectionStatus(_ status: Int32?) {
        state.withLock { $0.deviceSelectionStatus = status }
    }

    func setDuringBuild(_ hook: (@Sendable () -> Void)?) {
        state.withLock { $0.duringBuild = hook }
    }

    func setDuringTeardown(_ hook: (@Sendable () -> Void)?) {
        state.withLock { $0.duringTeardown = hook }
    }

    func currentInputDeviceUID() -> String? {
        state.withLock { $0.deviceUID }
    }

    func currentInputDevice() -> MicrophoneDeviceDescription? {
        state.withLock { state in
            guard let uid = state.deviceUID else { return nil }
            let format = state.installedFormat ?? state.steadyFormat
            return MicrophoneDeviceDescription(
                uid: uid, name: "Fake input",
                sampleRate: format?.sampleRate ?? 0, channelCount: format?.channelCount ?? 0
            )
        }
    }

    /// Queues one-shot device readings, consumed in order before the steady value.
    func queueFormatReadings(_ formats: [AudioFormatDescriptor?]) {
        state.withLock { $0.formatQueue.append(contentsOf: formats) }
    }

    func failNextBuild(with error: CaptureError) {
        state.withLock { $0.failNextBuild = error }
    }

    /// Every build fails until `stopFailing`, which is a device that is gone
    /// rather than one that is momentarily busy.
    func failEveryBuild(with error: CaptureError) {
        state.withLock { $0.failEveryBuild = error }
    }

    func stopFailing() {
        state.withLock { state in
            state.failEveryBuild = nil
            state.failNextBuild = nil
        }
    }

    func currentInputFormat() -> AudioFormatDescriptor? {
        state.withLock { state in
            state.formatReads += 1
            if !state.formatQueue.isEmpty { return state.formatQueue.removeFirst() }
            return state.steadyFormat
        }
    }

    func teardown() {
        let hook: (@Sendable () -> Void)? = state.withLock { state in
            state.teardowns += 1
            let wasRunning = state.running
            state.running = false
            return wasRunning ? state.duringTeardown : nil
        }
        hook?()
    }

    /// The format the hardware settles on, which may differ from what the
    /// coordinator asked for.
    func setInstalledFormat(_ format: AudioFormatDescriptor?) {
        state.withLock { $0.installedFormat = format }
    }

    @discardableResult
    func buildAndStart(preferred: AudioFormatDescriptor) throws -> MicrophoneBuild {
        state.withLock { $0.duringBuild }?()
        let failure: CaptureError? = state.withLock { state in
            if let always = state.failEveryBuild {
                state.builds.append(Build(format: preferred))
                return always
            }
            defer { state.failNextBuild = nil }
            return state.failNextBuild
        }
        if let failure { throw failure }
        return state.withLock { state in
            let installed = state.installedFormat ?? preferred
            state.builds.append(Build(format: installed))
            state.running = true
            return MicrophoneBuild(
                format: installed, deviceSelectionStatus: state.deviceSelectionStatus
            )
        }
    }
}

/// Stands in for the CoreAudio process tap.
final class FakeProcessTap: ProcessTapController, Sendable {
    private struct State {
        var targets: [RemoteAudioTarget] = []
        var binds: [[Int32]] = []
        var teardowns = 0
        var format = AudioFormatDescriptor(sampleRate: 48_000, channelCount: 2)
        var failNextBind: CaptureError?
    }

    private let state = Mutex(State())

    var bindCount: Int { state.withLock { $0.binds.count } }
    var bindHistory: [[Int32]] { state.withLock { $0.binds } }
    var teardownCount: Int { state.withLock { $0.teardowns } }

    func setTargets(_ targets: [RemoteAudioTarget]) {
        state.withLock { $0.targets = targets }
    }

    func setFormat(_ format: AudioFormatDescriptor) {
        state.withLock { $0.format = format }
    }

    func failNextBind(with error: CaptureError) {
        state.withLock { $0.failNextBind = error }
    }

    func resolveTargets(bundlePrefixes: [String]) -> [RemoteAudioTarget] {
        state.withLock { state in
            state.targets.filter { target in
                bundlePrefixes.contains { target.bundleIdentifier.hasPrefix($0) }
            }
        }
    }

    func teardown() {
        state.withLock { $0.teardowns += 1 }
    }

    func bind(to targets: [RemoteAudioTarget]) throws -> RemoteTapBinding {
        let failure: CaptureError? = state.withLock { state in
            defer { state.failNextBind = nil }
            return state.failNextBind
        }
        if let failure { throw failure }
        return state.withLock { state in
            state.binds.append(targets.map(\.processID).sorted())
            return RemoteTapBinding(format: state.format, streamCount: 2, tapStreamIndex: 1)
        }
    }
}

/// Captures coordinator callbacks so a test can assert on the manifest-visible
/// consequences of recovery.
final class RecordingCaptureDelegate: CaptureCoordinatorDelegate, Sendable {
    struct FormatChange: Sendable, Equatable {
        let track: CaptureTrack
        let from: AudioFormatDescriptor?
        let to: AudioFormatDescriptor
        let reason: String
    }

    struct Restart: Sendable, Equatable {
        let track: CaptureTrack
        let reason: String
        let count: Int
    }

    struct HealthChange: Sendable, Equatable {
        let track: CaptureTrack
        let state: CaptureHealthState
        /// The reason written beside the state in the manifest.
        let detail: String?
    }

    struct RemoteBind: Sendable, Equatable {
        let reason: String
        let processIDs: [Int32]
        let producing: [Bool]
        let count: Int
        let binding: RemoteTapBinding
    }

    struct MicBind: Sendable, Equatable {
        let device: MicrophoneDeviceDescription
        let build: MicrophoneBuild
        let reason: String
    }

    private struct State {
        var formatChanges: [FormatChange] = []
        var restarts: [Restart] = []
        var healthChanges: [HealthChange] = []
        var remoteBinds: [RemoteBind] = []
        var micBinds: [MicBind] = []
        var failures: [CaptureError] = []
    }

    private let state = Mutex(State())

    var formatChanges: [FormatChange] { state.withLock { $0.formatChanges } }
    var restarts: [Restart] { state.withLock { $0.restarts } }
    var healthChanges: [HealthChange] { state.withLock { $0.healthChanges } }
    var remoteBinds: [RemoteBind] { state.withLock { $0.remoteBinds } }
    var micBinds: [MicBind] { state.withLock { $0.micBinds } }
    var failures: [CaptureError] { state.withLock { $0.failures } }

    func captureWillChangeFormat(
        track: CaptureTrack, from: AudioFormatDescriptor?, to: AudioFormatDescriptor, reason: String
    ) {
        state.withLock { $0.formatChanges.append(FormatChange(track: track, from: from, to: to, reason: reason)) }
    }

    func captureDidRestart(track: CaptureTrack, reason: RebuildReason, restartCount: Int) {
        state.withLock { $0.restarts.append(Restart(track: track, reason: reason.label, count: restartCount)) }
    }

    func captureHealthChanged(track: CaptureTrack, state newState: CaptureHealthState, detail: String?) {
        state.withLock {
            $0.healthChanges.append(HealthChange(track: track, state: newState, detail: detail))
        }
    }

    func captureDidBindRemote(
        targets: [RemoteAudioTarget], reason: RebuildReason, bindCount: Int, binding: RemoteTapBinding
    ) {
        state.withLock {
            $0.remoteBinds.append(RemoteBind(
                reason: reason.label,
                processIDs: targets.map(\.processID),
                producing: targets.map(\.isRunningOutput),
                count: bindCount,
                binding: binding
            ))
        }
    }

    func captureDidBindMicrophone(
        device: MicrophoneDeviceDescription, build: MicrophoneBuild, reason: RebuildReason
    ) {
        state.withLock {
            $0.micBinds.append(MicBind(device: device, build: build, reason: reason.label))
        }
    }

    func captureDidFail(track: CaptureTrack, error: CaptureError) {
        state.withLock { $0.failures.append(error) }
    }
}

func makeTarget(
    pid: Int32, bundle: String = "org.mozilla.firefox", producing: Bool = false, objectID: UInt32? = nil
) -> RemoteAudioTarget {
    RemoteAudioTarget(
        audioObjectID: objectID ?? UInt32(pid),
        processID: pid,
        bundleIdentifier: bundle,
        isRunningOutput: producing
    )
}
