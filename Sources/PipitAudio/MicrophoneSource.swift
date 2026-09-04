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

    /// The system default input device, which `build` tries to open the input
    /// unit on. The coordinator records this after each build as the identity
    /// of the engine it just built, and tells a device the user plugged in
    /// from the same device renegotiating by comparing against it. That
    /// comparison is about one device only if both readings name one device,
    /// which is why the build points the unit at what this same call resolves
    /// rather than letting the node keep the one it defaulted to.
    ///
    /// The set usually holds. It fails where AVAudioEngine has already
    /// initialised the input unit, and the build then keeps whatever device
    /// the unit already held, so this call can name a device the recording is
    /// not from. `mic_bind.deviceSelectionStatus` is where a manifest says
    /// that happened.
    public func currentInputDeviceUID() -> String? {
        CoreAudioSystem.defaultInputDeviceUID()
    }

    /// The same device with the rate and channel count CoreAudio reports for
    /// it, which is what the manifest records for each build.
    ///
    /// The UID comes from the device id this call resolved, not from a second
    /// default-device lookup, so this and `currentInputDeviceUID` fail on the
    /// same two property reads and a description never mixes one device's
    /// identity with another's format.
    public func currentInputDevice() -> MicrophoneDeviceDescription? {
        guard let device = CoreAudioSystem.defaultInputDevice(),
              let uid = CoreAudioSystem.deviceUID(device)
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
    public func buildAndStart(preferred: AudioFormatDescriptor) throws -> MicrophoneBuild {
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
        // nothing. Speaker bleed is subtracted after the fact instead, by
        // `MicrophoneCleaner` against the process tap's own recording of the far
        // end. What the unit did do, for as long as the engine ran, was
        // duck every other application's output. Its ducking API has no off
        // setting, `.min` is a constant attenuation, and a person on a Slack
        // huddle heard the other side drop the moment recording began. This
        // engine must not change what the user hears.
        return try build()
    }

    private func build() throws -> MicrophoneBuild {
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
        // engine is opened on the device that call names, which is what the set
        // below asks for. It usually holds. When the set returns an error the
        // engine runs on whatever device the unit already had, the two readings
        // can name different devices, and `deviceSelectionStatus` in `mic_bind`
        // is what tells them apart.
        //
        // The device is chosen here. The format is not. The unit is already
        // instantiated by the time `input.audioUnit` hands it back, and setting
        // the device moves only its hardware-side format. Two shapes follow,
        // both measured on this Mac on 2026-09-03.
        //
        // One shape is a client format wider than the device. With the client
        // format forced to 8 channels and the unit pointed at the 1-channel
        // built-in microphone, buffers arrived with the microphone on channel 0
        // and the other seven at exactly zero. The energy scan in
        // `TrackAudioReader` keeps the channel carrying the voice, so that
        // shape survives.
        //
        // The other is a client format narrower than the device. Pointing the
        // unit at an 8-channel device took its input scope to 8 channels while
        // its output scope stayed at the 1 channel the node was instantiated
        // with, and the output scope is what `outputFormat(forBus: 0)` reports.
        // The track is written at that 1 channel. The scan runs only above two
        // channels, so it does not run there, and which of the device's
        // channels AUHAL folds into the single one was not measured. This
        // branch does not improve on that shape.
        //
        // The set still belongs before the read, because that is the only order
        // in which the read could reflect the choice, and `mic_bind` records
        // both formats so a manifest shows when they diverged.
        guard let deviceID = CoreAudioSystem.defaultInputDevice(), let unit = input.audioUnit else {
            throw CaptureError.microphoneEngineStartFailed(status: -1)
        }
        var device = deviceID
        let deviceStatus = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if deviceStatus != noErr {
            // Not a reason to abandon the microphone. `kAudioUnitErr_Initialized`
            // is reachable wherever AVAudioEngine has already initialised the
            // input unit by the time it hands it over, and throwing here would
            // leave the meeting with no microphone track at all, retried on
            // backoff until it ended. Build on whatever device the unit holds,
            // which is what this did before the set existed, and write the
            // status into `mic_bind` so the record says the device was not
            // honoured.
            Log.capture.notice(
                "input unit kept its own device: \(CoreAudioSystem.fourCharCode(deviceStatus), privacy: .public)"
            )
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
        return MicrophoneBuild(
            format: AudioFormatDescriptor(
                sampleRate: tapFormat.sampleRate, channelCount: Int(tapFormat.channelCount)
            ),
            deviceSelectionStatus: deviceStatus == noErr ? nil : deviceStatus
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
