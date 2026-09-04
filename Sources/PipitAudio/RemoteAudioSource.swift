import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import PipitCore
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
    /// What the current bind's first IOProc callback delivered. Written once by
    /// the callback and cleared by `teardown`, so it always describes the bind
    /// that is running now.
    private let firstCallbackBox = LockedBox<TapCallbackReading?>(nil)
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
        // After the IOProc is gone, so a callback already running cannot write
        // this bind's reading back over the cleared box.
        firstCallbackBox.withLock { $0 = nil }
    }

    public func firstCallback() -> TapCallbackReading? {
        firstCallbackBox.withLock { $0 }
    }

    public func bind(to targets: [RemoteAudioTarget]) throws -> RemoteTapBinding {
        teardown()
        guard !targets.isEmpty else {
            throw CaptureError.noMatchingAudioProcess(prefixes: [])
        }

        let uuid = UUID()
        let description = CATapDescription(
            stereoMixdownOfProcesses: targets.map(\.audioObjectID)
        )
        description.name = "Pipit"
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
            kAudioAggregateDeviceNameKey: "Pipit Capture",
            kAudioAggregateDeviceUIDKey: "com.pipit.aggregate.\(uuid.uuidString)",
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

        // The tap's buffer is read from the final index, inferred from one Mac
        // delivering [8ch, 2ch] for a stereo tap and not from anything Apple
        // documents. `makeBuffer` matches on channel count when the index does
        // not hold, and logs that it did.
        let streamCount = CoreAudioSystem.inputStreamCount(of: aggregateID)
        let tapStreamIndex: Int? = if let streamCount, streamCount >= 1 { streamCount - 1 } else { nil }
        Log.capture.info(
            "aggregate input streams: count=\(streamCount ?? -1, privacy: .public) tapIndex=\(tapStreamIndex ?? -1, privacy: .public)"
        )

        let sink = self.sink
        var ioProcID: AudioDeviceIOProcID?
        let readingBox = firstCallbackBox
        let fellBack = LockedBox(false)
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) {
            _, inputData, inputTime, _, _ in
            let selection = makeBuffer(
                from: inputData, format: format, tapStreamIndex: tapStreamIndex
            )
            // The shape of the first buffer list and whether the index held,
            // once per bind. An aggregate device does not have to match the
            // tap's format, and the difference decides how many frames each
            // callback really carries. The poll reads this back and writes it
            // into the manifest, because a log line is gone by the time anyone
            // opens the meeting folder to ask why a track is silent.
            let reading = readingBox.withLock { stored -> TapCallbackReading? in
                guard stored == nil else { return nil }
                let list = UnsafeMutableAudioBufferListPointer(
                    UnsafeMutablePointer(mutating: inputData)
                )
                let fresh = TapCallbackReading(
                    streams: list.map {
                        .init(
                            channelCount: Int($0.mNumberChannels), byteCount: Int($0.mDataByteSize)
                        )
                    },
                    usedFallback: selection.usedFallback
                )
                stored = fresh
                return fresh
            }
            if let reading {
                let shape = reading.streams.map { "\($0.channelCount)ch/\($0.byteCount)B" }
                    .joined(separator: " ")
                Log.capture.info(
                    "tap buffers: count=\(reading.streams.count, privacy: .public) [\(shape, privacy: .public)] format=\(format.sampleRate, privacy: .public)Hz x\(format.channelCount, privacy: .public)"
                )
            }
            if selection.usedFallback {
                let shouldWarn = fellBack.withLock { warned -> Bool in
                    if warned { return false }
                    warned = true
                    return true
                }
                if shouldWarn {
                    Log.capture.info(
                        "tap stream index \(tapStreamIndex ?? -1, privacy: .public) unusable, matching on channel count instead"
                    )
                }
            }
            guard let buffer = selection.buffer else { return }
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

        return RemoteTapBinding(
            format: AudioFormatDescriptor(
                sampleRate: format.sampleRate, channelCount: Int(format.channelCount)
            ),
            streamCount: streamCount,
            tapStreamIndex: tapStreamIndex
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
