import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import MeetTapeCore
import Synchronization

/// The CoreAudio process-tap half of remote meeting capture.
///
/// One tap per meeting, covering every audio process whose bundle identifier
/// starts with one of the provider's prefixes. Prefix matching is required, not a
/// convenience: Slack Huddle audio lives in `com.tinyspeck.slackmacgap.helper`
/// and tapping the main Slack bundle yields zero frames.
///
/// No virtual audio driver is involved, and no global tap: the global forms return
/// silence with an exclusion list and deadlock without one.
public final class RemoteAudioSource: ProcessTapController, Sendable {
    private struct State {
        var tapID: AudioObjectID = 0
        var aggregateID: AudioObjectID = 0
        var ioProcID: AudioDeviceIOProcID?
        var format: AVAudioFormat?
        var tapUUID = UUID()
        var formatListener: AudioObjectPropertyListenerBlock?
    }

    private let state = LockedBox(State())
    private let sink: AudioBufferSink
    /// Called when the tap's own format changes underneath us, which callback
    /// arrival cannot detect: buffers keep coming, labelled with the old format.
    private let onFormatChanged: @Sendable () -> Void
    /// On macOS 26 the tap description can carry bundle identifiers so CoreAudio
    /// restores the tap when a provider process restarts. The poll-driven rebind
    /// stays active either way; it recovered a Firefox restart in 16 ms.
    private let usesBundleRestore: Bool

    public init(
        sink: @escaping AudioBufferSink,
        onFormatChanged: @escaping @Sendable () -> Void = {},
        usesBundleRestore: Bool = true
    ) {
        self.sink = sink
        self.onFormatChanged = onFormatChanged
        self.usesBundleRestore = usesBundleRestore
    }

    deinit { teardown() }

    public func resolveTargets(bundlePrefixes: [String]) -> [RemoteAudioTarget] {
        CoreAudioSystem.processes()
            .filter { process in bundlePrefixes.contains { process.bundleIdentifier.hasPrefix($0) } }
            .map(\.remoteTarget)
    }

    public func teardown() {
        let removed = state.withLock {
            state -> (AudioObjectID, AudioObjectID, AudioDeviceIOProcID?, AudioObjectPropertyListenerBlock?) in
            let values = (state.aggregateID, state.tapID, state.ioProcID, state.formatListener)
            state.aggregateID = 0
            state.tapID = 0
            state.ioProcID = nil
            state.format = nil
            state.formatListener = nil
            return values
        }
        let (aggregateID, tapID, ioProcID, formatListener) = removed
        if let formatListener, tapID != 0 {
            var address = CoreAudioSystem.address(kAudioTapPropertyFormat)
            AudioObjectRemovePropertyListenerBlock(tapID, &address, nil, formatListener)
        }
        if let ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
    }

    public func bind(to targets: [RemoteAudioTarget]) throws -> AudioFormatDescriptor {
        teardown()
        guard !targets.isEmpty else {
            throw CaptureError.noMatchingAudioProcess(prefixes: [])
        }

        let uuid = UUID()
        let description = CATapDescription(
            stereoMixdownOfProcesses: targets.map(\.audioObjectID)
        )
        description.name = "MeetTape"
        description.uuid = uuid
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.isExclusive = false
        if usesBundleRestore { applyBundleRestore(to: description, targets: targets) }

        var tapID: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr, tapID != 0 else {
            throw CaptureError.processTapCreationFailed(status: tapStatus)
        }

        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = CoreAudioSystem.address(kAudioTapPropertyFormat)
        guard AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &streamDescription) == noErr
        else {
            AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.tapFormatUnavailable
        }
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: streamDescription.mSampleRate,
            channels: AVAudioChannelCount(streamDescription.mChannelsPerFrame)
        ) else {
            AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.tapFormatUnavailable
        }

        var aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MeetTape Capture",
            kAudioAggregateDeviceUIDKey: "com.meettape.aggregate.\(uuid.uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        if let outputUID = CoreAudioSystem.defaultOutputDeviceUID() {
            aggregateDescription[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregateDescription[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }

        var aggregateID: AudioObjectID = 0
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &aggregateID
        )
        guard aggregateStatus == noErr, aggregateID != 0 else {
            AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.aggregateDeviceCreationFailed(status: aggregateStatus)
        }

        let sink = self.sink
        var ioProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            _, inputData, inputTime, _, _ in
            guard let buffer = makeBuffer(from: inputData, format: format) else { return }
            sink(AudioBufferPacket(
                buffer: buffer, hostTime: HostTime.seconds(inputTime.pointee.mHostTime)
            ))
        }
        guard ioStatus == noErr, let ioProcID else {
            // The call can fail after writing an ID; destroying it first avoids
            // leaking the block and everything it captured.
            if let orphan = ioProcID { AudioDeviceDestroyIOProcID(aggregateID, orphan) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.ioProcCreationFailed(status: ioStatus)
        }

        let startStatus = AudioDeviceStart(aggregateID, ioProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.ioProcCreationFailed(status: startStatus)
        }

        // A tap whose format changes keeps delivering buffers that would be
        // written under the old label, at the wrong rate, with nothing in the
        // health model able to notice.
        let notifyFormatChanged = onFormatChanged
        let listener: AudioObjectPropertyListenerBlock = { _, _ in notifyFormatChanged() }
        var formatAddressForListener = CoreAudioSystem.address(kAudioTapPropertyFormat)
        AudioObjectAddPropertyListenerBlock(tapID, &formatAddressForListener, nil, listener)

        state.withLock { state in
            state.tapID = tapID
            state.aggregateID = aggregateID
            state.ioProcID = ioProcID
            state.format = format
            state.tapUUID = uuid
            state.formatListener = listener
        }

        return AudioFormatDescriptor(
            sampleRate: format.sampleRate, channelCount: Int(format.channelCount)
        )
    }

    public var activeFormat: AVAudioFormat? { state.withLock { $0.format } }

    /// `bundleIDs` and `processRestoreEnabled` exist only on macOS 26 and later.
    /// They are set through key-value coding so the code still compiles against an
    /// older SDK, and skipped entirely when the properties are absent.
    private func applyBundleRestore(to description: CATapDescription, targets: [RemoteAudioTarget]) {
        guard #available(macOS 26.0, *) else { return }
        let bundleIDs = Array(Set(targets.map(\.bundleIdentifier))).filter { !$0.isEmpty }
        guard !bundleIDs.isEmpty else { return }
        guard description.responds(to: Selector(("setBundleIDs:"))) else { return }
        description.setValue(bundleIDs, forKey: "bundleIDs")
        if description.responds(to: Selector(("setProcessRestoreEnabled:"))) {
            description.setValue(true, forKey: "processRestoreEnabled")
        }
    }
}
