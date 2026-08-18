import AVFoundation
import CoreAudio
import Foundation
import MeetTapeCore
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
        if let observer = state.withLock({ $0.observer }) {
            NotificationCenter.default.removeObserver(observer)
        }
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

    public func buildAndStart(format: AudioFormatDescriptor) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Install against the node's own format. Passing a format the hardware is
        // not actually running at throws inside CoreAudio.
        let tapFormat = input.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else {
            throw CaptureError.microphoneEngineStartFailed(status: -1)
        }

        let sink = self.sink
        input.installTap(onBus: 0, bufferSize: 4_096, format: tapFormat) { buffer, when in
            guard let copy = buffer.deepCopy() else { return }
            sink(AudioBufferPacket(buffer: copy, hostTime: HostTime.seconds(when.hostTime)))
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
