import AudioToolbox
import CoreAudio
import Foundation
import PipitCore

/// One process as CoreAudio sees it.
public struct AudioProcessInfo: Sendable, Equatable {
    public let objectID: AudioObjectID
    public let processID: pid_t
    public let bundleIdentifier: String
    public let isRunning: Bool
    public let isRunningInput: Bool
    public let isRunningOutput: Bool

    public init(
        objectID: AudioObjectID, processID: pid_t, bundleIdentifier: String,
        isRunning: Bool, isRunningInput: Bool, isRunningOutput: Bool
    ) {
        self.objectID = objectID
        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
        self.isRunning = isRunning
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }

    public var remoteTarget: RemoteAudioTarget {
        RemoteAudioTarget(
            audioObjectID: objectID, processID: processID,
            bundleIdentifier: bundleIdentifier, isRunningOutput: isRunningOutput
        )
    }
}

/// Thin, allocation-light wrappers over the CoreAudio property API.
public enum CoreAudioSystem {
    public static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    public static func objectIDs(
        _ object: AudioObjectID, _ propertyAddress: AudioObjectPropertyAddress
    ) -> [AudioObjectID] {
        var address = propertyAddress
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    public static func string(_ object: AudioObjectID, _ propertyAddress: AudioObjectPropertyAddress) -> String? {
        var address = propertyAddress
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    public static func uint32(_ object: AudioObjectID, _ propertyAddress: AudioObjectPropertyAddress) -> UInt32? {
        var address = propertyAddress
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    public static func double(_ object: AudioObjectID, _ propertyAddress: AudioObjectPropertyAddress) -> Double? {
        var address = propertyAddress
        var size = UInt32(MemoryLayout<Double>.size)
        var value: Double = 0
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    public static func processID(_ object: AudioObjectID) -> pid_t? {
        var address = self.address(kAudioProcessPropertyPID)
        var size = UInt32(MemoryLayout<pid_t>.size)
        var value: pid_t = -1
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// Every process CoreAudio knows about, with its live input/output state.
    public static func processes() -> [AudioProcessInfo] {
        objectIDs(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyProcessObjectList))
            .map { objectID in
                AudioProcessInfo(
                    objectID: objectID,
                    processID: processID(objectID) ?? -1,
                    bundleIdentifier: string(objectID, address(kAudioProcessPropertyBundleID)) ?? "",
                    isRunning: (uint32(objectID, address(kAudioProcessPropertyIsRunning)) ?? 0) != 0,
                    isRunningInput: (uint32(objectID, address(kAudioProcessPropertyIsRunningInput)) ?? 0) != 0,
                    isRunningOutput: (uint32(objectID, address(kAudioProcessPropertyIsRunningOutput)) ?? 0) != 0
                )
            }
    }

    public static func defaultOutputDeviceUID() -> String? {
        guard let device = uint32(
            AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice)
        ) else { return nil }
        return string(device, address(kAudioDevicePropertyDeviceUID))
    }

    public static func defaultInputDevice() -> AudioDeviceID? {
        uint32(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultInputDevice))
    }

    public static func deviceName(_ device: AudioDeviceID) -> String {
        string(device, address(kAudioObjectPropertyName)) ?? "Unknown device"
    }

    public static func deviceSampleRate(_ device: AudioDeviceID) -> Double {
        double(device, address(kAudioDevicePropertyNominalSampleRate)) ?? 0
    }

    public static func deviceChannelCount(
        _ device: AudioDeviceID, scope: AudioObjectPropertyScope
    ) -> Int {
        var address = self.address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func fourCharCode(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return "'\(String(bytes: bytes, encoding: .ascii) ?? "?")'"
        }
        return "\(status)"
    }
}
