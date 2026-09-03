import AVFoundation
import CoreAudio
import Foundation
import PipitCore
import Synchronization

/// The AVAudioEngine half of microphone capture.
///
/// It owns nothing about recovery policy: it builds, tears down and reports the
/// device format, and `MicrophoneRecoveryCoordinator` decides when. That split is
/// what lets the storm regression be tested without an audio device.
public final class MicrophoneSource: MicrophoneEngineController, Sendable {
    private struct State {
        var engine: AVAudioEngine?
        var observer: NSObjectProtocol?
    }

    private let state = LockedBox(State())
    private let sink: AudioBufferSink
    private let onConfigurationChange: @Sendable () -> Void

    public init(
        sink: @escaping AudioBufferSink,
        onConfigurationChange: @escaping @Sendable () -> Void
    ) {
        self.sink = sink
        self.onConfigurationChange = onConfigurationChange
        observeConfigurationChanges()
    }

    deinit {
        let (engine, observer) = state.withLock { ($0.engine, $0.observer) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        // The tap is removed explicitly: releasing the engine alone leaves the
        // microphone indicator lit until the tap is torn down.
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
    }

    public var isRunning: Bool {
        state.withLock { $0.engine?.isRunning ?? false }
    }

    /// Reads the input format from a freshly created engine.
    ///
    /// A device re-enumerated underneath a running engine keeps reporting the old
    /// format, which is exactly how a Meet join used to end capture silently, so
    /// this must never reuse the existing engine's cached value.
    public func currentInputFormat() -> AudioFormatDescriptor? {
        let probe = AVAudioEngine()
        let format = probe.inputNode.outputFormat(forBus: 0)
        return AudioFormatDescriptor(
            sampleRate: format.sampleRate, channelCount: Int(format.channelCount)
        )
    }

    /// The system default input device, which `build` opens the input unit on
    /// explicitly. The coordinator records this after each build as the
    /// identity of the engine it just built, and tells a device the user
    /// plugged in from the same device renegotiating by comparing against it.
    /// The two readings have to name one device, which is why the build sets
    /// the unit's device from the same call rather than letting the node keep
    /// the one it defaulted to.
    public func currentInputDeviceUID() -> String? {
        CoreAudioSystem.defaultInputDeviceUID()
    }

    /// The same device with the rate and channel count CoreAudio reports for
    /// it, which is what the manifest records for each build.
    public func currentInputDevice() -> MicrophoneDeviceDescription? {
        guard let device = CoreAudioSystem.defaultInputDevice(),
              let uid = CoreAudioSystem.defaultInputDeviceUID()
        else { return nil }
        return MicrophoneDeviceDescription(
            uid: uid,
            name: CoreAudioSystem.deviceName(device),
            sampleRate: CoreAudioSystem.deviceSampleRate(device),
            channelCount: CoreAudioSystem.deviceChannelCount(
                device, scope: kAudioObjectPropertyScopeInput
            )
        )
    }

    public func teardown() {
        let engine = state.withLock { state -> AVAudioEngine? in
            let engine = state.engine
            state.engine = nil
            return engine
        }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    @discardableResult
    public func buildAndStart(preferred: AudioFormatDescriptor) throws -> AudioFormatDescriptor {
        // Microphone access is checked here rather than assumed: a denied input
        // node starts cleanly and delivers buffers of zeroes, which would be
        // recorded and uploaded as a meeting of silence.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .denied, .restricted, .notDetermined:
            throw CaptureError.microphonePermissionDenied
        @unknown default:
            throw CaptureError.microphonePermissionDenied
        }

        // Plain capture, never the system voice-processing unit.
        //
        // The unit was here to subtract the speakers from the microphone. It
        // does not: measured 2026-08-25 with two standalone AVAudioEngine
        // binaries, one playing and one capturing with the unit on, AUVoiceIO
        // cancels only audio its own host renders, and this engine renders
        // nothing. Speaker bleed is handled after the fact instead, by
        // `EchoReturnLossProfile` and the clause in `LocalSpeechPolicy` that
        // reads it. What the unit did do, for as long as the engine ran, was
        // duck every other application's output. Its ducking API has no off
        // setting, `.min` is a constant attenuation, and a person on a Slack
        // huddle heard the other side drop the moment recording began. This
        // engine must not change what the user hears.
        return try build()
    }

    private func build() throws -> AudioFormatDescriptor {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Open the system default input device, resolved on every build.
        //
        // An input node left alone does not run on a microphone. It runs on
        // macOS's per-process `CADefaultDeviceAggregate`, which wraps the
        // default input together with whatever virtual drivers are installed.
        // Measured on this Mac on 2026-09-03: the node was instantiated on
        // `CADefaultDeviceAggregate-6807-0` while the default input device was
        // `BuiltInMicrophoneDevice`, and setting the property below moved it.
        //
        // The coordinator compares `currentInputDeviceUID` against the device
        // the engine is on to tell a device the user plugged in from the same
        // device renegotiating. That comparison is about one device only if the
        // engine is opened on the device that call names, which is what this
        // does. The property is set before the format is read, so the read
        // cannot instantiate the unit on a device nothing chose.
        guard let deviceID = CoreAudioSystem.defaultInputDevice(), let unit = input.audioUnit else {
            throw CaptureError.microphoneEngineStartFailed(status: -1)
        }
        var device = deviceID
        let deviceStatus = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard deviceStatus == noErr else {
            throw CaptureError.microphoneEngineStartFailed(status: deviceStatus)
        }

        // Install against the node's own format. Passing a format the hardware is
        // not actually running at throws inside CoreAudio, so `preferred` informs
        // the choice but the node decides.
        let tapFormat = input.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            throw CaptureError.microphoneEngineStartFailed(status: -1)
        }

        let sink = self.sink
        input.installTap(onBus: 0, bufferSize: 4_096, format: tapFormat) { buffer, when in
            guard let copy = buffer.deepCopy() else { return }
            // An invalid or zero host time would make every gap look like the
            // machine's uptime and rebuild the engine on every poll. Arrival is
            // what the watchdog measures, so substituting now is correct.
            let hostTime = when.isHostTimeValid && when.hostTime != 0
                ? HostTime.seconds(when.hostTime)
                : HostTime.now
            sink(AudioBufferPacket(buffer: copy, hostTime: hostTime))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            let status = (error as NSError).code
            throw CaptureError.microphoneEngineStartFailed(status: Int32(truncatingIfNeeded: status))
        }
        state.withLock { $0.engine = engine }
        return AudioFormatDescriptor(
            sampleRate: tapFormat.sampleRate, channelCount: Int(tapFormat.channelCount)
        )
    }

    /// The format the engine is actually running at, which is what segments are
    /// written in.
    public func activeFormat() -> AVAudioFormat? {
        state.withLock { $0.engine?.inputNode.outputFormat(forBus: 0) }
    }

    private func observeConfigurationChanges() {
        let handler = onConfigurationChange
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { _ in
            handler()
        }
        state.withLock { $0.observer = observer }
    }
}
