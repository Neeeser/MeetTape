import Foundation

/// One append-only manifest record.
///
/// The manifest, not the audio container header, is the timeline authority. Every
/// line is flushed with `fsync`, so a hard kill leaves a truncated last line at
/// worst and the reader tolerates that.
public struct ManifestLine: Sendable, Equatable {
    public let hostTime: Double
    public let wallClock: Date
    public let event: ManifestEvent

    public init(hostTime: Double, wallClock: Date, event: ManifestEvent) {
        self.hostTime = hostTime
        self.wallClock = wallClock
        self.event = event
    }
}

public enum ManifestEvent: Sendable, Equatable {
    case sessionStart(SessionStart)
    case segmentOpen(SegmentOpen)
    case segmentClose(SegmentClose)
    case formatChange(FormatChange)
    case captureRestart(CaptureRestart)
    case sourceHealth(SourceHealth)
    case preRollFlushed(PreRollFlushed)
    case marker(Marker)
    case sessionEnd(SessionEnd)
    case crashTailAdopted(CrashTailAdopted)
    case remoteBind(RemoteBind)
    case micBind(MicBind)

    public struct SessionStart: Codable, Sendable, Equatable {
        public let meetingID: String
        public let source: MeetingSource
        public let segmentSeconds: Double
        public let appVersion: String
        public let processID: Int32

        public init(meetingID: String, source: MeetingSource, segmentSeconds: Double, appVersion: String, processID: Int32) {
            self.meetingID = meetingID
            self.source = source
            self.segmentSeconds = segmentSeconds
            self.appVersion = appVersion
            self.processID = processID
        }
    }

    public struct SegmentOpen: Codable, Sendable, Equatable {
        public let track: CaptureTrack
        public let index: Int
        public let file: String
        /// Host time of the first frame written to this segment, filled in when the
        /// first buffer arrives. Nil until then.
        public let firstFrameHostTime: Double?
        public let startFrame: Int64
        public let sampleRate: Double
        public let channelCount: Int
        public let reason: String

        public init(
            track: CaptureTrack, index: Int, file: String, firstFrameHostTime: Double?,
            startFrame: Int64, sampleRate: Double, channelCount: Int, reason: String
        ) {
            self.track = track
            self.index = index
            self.file = file
            self.firstFrameHostTime = firstFrameHostTime
            self.startFrame = startFrame
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.reason = reason
        }

        public var format: AudioFormatDescriptor {
            AudioFormatDescriptor(sampleRate: sampleRate, channelCount: channelCount)
        }
    }

    public struct SegmentClose: Codable, Sendable, Equatable {
        public let track: CaptureTrack
        public let index: Int
        public let frameCount: Int64
        public let byteCount: Int64
        public let seconds: Double
        public let firstFrameHostTime: Double?
        public let reason: String

        public init(
            track: CaptureTrack, index: Int, frameCount: Int64, byteCount: Int64,
            seconds: Double, firstFrameHostTime: Double?, reason: String
        ) {
            self.track = track
            self.index = index
            self.frameCount = frameCount
            self.byteCount = byteCount
            self.seconds = seconds
            self.firstFrameHostTime = firstFrameHostTime
            self.reason = reason
        }
    }

    public struct FormatChange: Codable, Sendable, Equatable {
        public let track: CaptureTrack
        public let fromSampleRate: Double
        public let fromChannelCount: Int
        public let toSampleRate: Double
        public let toChannelCount: Int
        public let reason: String

        public init(track: CaptureTrack, from: AudioFormatDescriptor, to: AudioFormatDescriptor, reason: String) {
            self.track = track
            self.fromSampleRate = from.sampleRate
            self.fromChannelCount = from.channelCount
            self.toSampleRate = to.sampleRate
            self.toChannelCount = to.channelCount
            self.reason = reason
        }
    }

    public struct CaptureRestart: Codable, Sendable, Equatable {
        public let track: CaptureTrack
        public let reason: String
        public let restartCount: Int

        public init(track: CaptureTrack, reason: String, restartCount: Int) {
            self.track = track
            self.reason = reason
            self.restartCount = restartCount
        }
    }

    /// What the process tap was pointed at, recorded on every bind.
    ///
    /// A tap that produces nothing and a tap on an application that is playing
    /// nothing write the same track, and until this existed the manifest could
    /// not tell them apart after the fact: it carried health transitions but
    /// never which processes were bound or whether CoreAudio believed any of
    /// them was producing output. One meeting on disk needed exactly this and
    /// the question is not answerable from what was kept.
    public struct RemoteBind: Codable, Sendable, Equatable {
        public struct Target: Codable, Sendable, Equatable {
            public let processID: Int32
            public let bundleIdentifier: String
            /// CoreAudio's own `kAudioProcessPropertyIsRunningOutput` for this
            /// process at the moment of the bind. The one signal that separates
            /// a correctly silent tap from a broken one.
            public let isRunningOutput: Bool

            public init(processID: Int32, bundleIdentifier: String, isRunningOutput: Bool) {
                self.processID = processID
                self.bundleIdentifier = bundleIdentifier
                self.isRunningOutput = isRunningOutput
            }
        }

        public let reason: String
        public let targets: [Target]
        public let bindCount: Int
        /// Input streams the aggregate device published, and the index the tap's
        /// audio was read from. Both are absent in manifests written before the
        /// tap was selected by index, so both decode as nil.
        public let streamCount: Int?
        public let tapStreamIndex: Int?

        public init(
            reason: String, targets: [Target], bindCount: Int,
            streamCount: Int?, tapStreamIndex: Int?
        ) {
            self.reason = reason
            self.targets = targets
            self.bindCount = bindCount
            self.streamCount = streamCount
            self.tapStreamIndex = tapStreamIndex
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            reason = try container.decode(String.self, forKey: .reason)
            targets = try container.decode([Target].self, forKey: .targets)
            bindCount = try container.decode(Int.self, forKey: .bindCount)
            streamCount = try container.decodeIfPresent(Int.self, forKey: .streamCount)
            tapStreamIndex = try container.decodeIfPresent(Int.self, forKey: .tapStreamIndex)
        }
    }

    /// Which input device the microphone engine was opened on, and what the tap
    /// it installed is running at, recorded on every build.
    ///
    /// Two formats, because they are two facts. `deviceSampleRate` and
    /// `deviceChannelCount` are CoreAudio's answer for the device the build
    /// chose. `trackSampleRate` and `trackChannelCount` are what the engine's
    /// node reported afterwards, which is what the segments are written at.
    ///
    /// The pair diverging is itself the signal. Setting the input unit's device
    /// changes its hardware-side format and leaves its client-side format at
    /// whatever the node was instantiated on, so a build that names a
    /// one-channel microphone and writes an eight-channel track says the client
    /// format did not follow the device. Recording only the device's numbers
    /// would put that contradiction in the manifest with nothing to explain it.
    public struct MicBind: Codable, Sendable, Equatable {
        public let deviceUID: String
        public let deviceName: String
        public let deviceSampleRate: Double
        public let deviceChannelCount: Int
        /// The format the tap installed at. Absent in manifests written before
        /// the track's own format was recorded, so both decode as nil.
        public let trackSampleRate: Double?
        public let trackChannelCount: Int?
        public let reason: String

        public init(
            deviceUID: String, deviceName: String, deviceSampleRate: Double,
            deviceChannelCount: Int, trackSampleRate: Double?, trackChannelCount: Int?,
            reason: String
        ) {
            self.deviceUID = deviceUID
            self.deviceName = deviceName
            self.deviceSampleRate = deviceSampleRate
            self.deviceChannelCount = deviceChannelCount
            self.trackSampleRate = trackSampleRate
            self.trackChannelCount = trackChannelCount
            self.reason = reason
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            deviceUID = try container.decode(String.self, forKey: .deviceUID)
            deviceName = try container.decode(String.self, forKey: .deviceName)
            deviceSampleRate = try container.decode(Double.self, forKey: .deviceSampleRate)
            deviceChannelCount = try container.decode(Int.self, forKey: .deviceChannelCount)
            trackSampleRate = try container.decodeIfPresent(Double.self, forKey: .trackSampleRate)
            trackChannelCount = try container.decodeIfPresent(Int.self, forKey: .trackChannelCount)
            reason = try container.decode(String.self, forKey: .reason)
        }
    }

    public struct SourceHealth: Codable, Sendable, Equatable {
        public let track: CaptureTrack
        public let state: CaptureHealthState
        public let detail: String?

        public init(track: CaptureTrack, state: CaptureHealthState, detail: String?) {
            self.track = track
            self.state = state
            self.detail = detail
        }
    }

    public struct PreRollFlushed: Codable, Sendable, Equatable {
        public let track: CaptureTrack
        public let frameCount: Int64
        public let seconds: Double
        public let earliestHostTime: Double?

        public init(track: CaptureTrack, frameCount: Int64, seconds: Double, earliestHostTime: Double?) {
            self.track = track
            self.frameCount = frameCount
            self.seconds = seconds
            self.earliestHostTime = earliestHostTime
        }
    }

    public struct Marker: Codable, Sendable, Equatable {
        public let label: String

        public init(label: String) { self.label = label }
    }

    public struct SessionEnd: Codable, Sendable, Equatable {
        public let reason: String
        public let micSeconds: Double
        public let remoteSeconds: Double

        public init(reason: String, micSeconds: Double, remoteSeconds: Double) {
            self.reason = reason
            self.micSeconds = micSeconds
            self.remoteSeconds = remoteSeconds
        }
    }

    /// Written by startup recovery when a segment that had no close record is
    /// adopted from its file contents.
    public struct CrashTailAdopted: Codable, Sendable, Equatable {
        public let track: CaptureTrack
        public let index: Int
        public let frameCount: Int64
        public let byteCount: Int64
        public let seconds: Double

        public init(track: CaptureTrack, index: Int, frameCount: Int64, byteCount: Int64, seconds: Double) {
            self.track = track
            self.index = index
            self.frameCount = frameCount
            self.byteCount = byteCount
            self.seconds = seconds
        }
    }

    public var name: String {
        switch self {
        case .sessionStart: "session_start"
        case .segmentOpen: "segment_open"
        case .segmentClose: "segment_close"
        case .formatChange: "format_change"
        case .captureRestart: "capture_restart"
        case .sourceHealth: "source_health"
        case .preRollFlushed: "preroll_flushed"
        case .marker: "marker"
        case .sessionEnd: "session_end"
        case .crashTailAdopted: "crash_tail_adopted"
        case .remoteBind: "remote_bind"
        case .micBind: "mic_bind"
        }
    }
}

// MARK: - Flat JSON encoding

extension ManifestLine: Codable {
    private enum StampKeys: String, CodingKey {
        case event = "ev"
        case hostTime = "host"
        case wallClock = "t"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StampKeys.self)
        try container.encode(event.name, forKey: .event)
        try container.encode(hostTime, forKey: .hostTime)
        try container.encode(wallClock, forKey: .wallClock)
        switch event {
        case .sessionStart(let payload): try payload.encode(to: encoder)
        case .segmentOpen(let payload): try payload.encode(to: encoder)
        case .segmentClose(let payload): try payload.encode(to: encoder)
        case .formatChange(let payload): try payload.encode(to: encoder)
        case .captureRestart(let payload): try payload.encode(to: encoder)
        case .sourceHealth(let payload): try payload.encode(to: encoder)
        case .preRollFlushed(let payload): try payload.encode(to: encoder)
        case .marker(let payload): try payload.encode(to: encoder)
        case .sessionEnd(let payload): try payload.encode(to: encoder)
        case .crashTailAdopted(let payload): try payload.encode(to: encoder)
        case .remoteBind(let payload): try payload.encode(to: encoder)
        case .micBind(let payload): try payload.encode(to: encoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StampKeys.self)
        hostTime = try container.decode(Double.self, forKey: .hostTime)
        wallClock = try container.decode(Date.self, forKey: .wallClock)
        let name = try container.decode(String.self, forKey: .event)
        switch name {
        case "session_start": event = .sessionStart(try .init(from: decoder))
        case "segment_open": event = .segmentOpen(try .init(from: decoder))
        case "segment_close": event = .segmentClose(try .init(from: decoder))
        case "format_change": event = .formatChange(try .init(from: decoder))
        case "capture_restart": event = .captureRestart(try .init(from: decoder))
        case "source_health": event = .sourceHealth(try .init(from: decoder))
        case "preroll_flushed": event = .preRollFlushed(try .init(from: decoder))
        case "marker": event = .marker(try .init(from: decoder))
        case "session_end": event = .sessionEnd(try .init(from: decoder))
        case "crash_tail_adopted": event = .crashTailAdopted(try .init(from: decoder))
        case "remote_bind": event = .remoteBind(try .init(from: decoder))
        case "mic_bind": event = .micBind(try .init(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .event, in: container, debugDescription: "unknown manifest event \(name)"
            )
        }
    }
}

extension ManifestEvent.FormatChange {
    public var from: AudioFormatDescriptor {
        AudioFormatDescriptor(sampleRate: fromSampleRate, channelCount: fromChannelCount)
    }

    public var to: AudioFormatDescriptor {
        AudioFormatDescriptor(sampleRate: toSampleRate, channelCount: toChannelCount)
    }
}

/// JSON coders configured once so manifest lines round-trip identically.
public enum ManifestCoding {
    /// UTC, fractional seconds. `ISO8601FormatStyle` is used rather than
    /// `ISO8601DateFormatter` because it is `Sendable` and can be shared.
    public static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    public static func string(from date: Date) -> String { dateStyle.format(date) }

    public static func date(from text: String) -> Date? {
        if let parsed = try? dateStyle.parse(text) { return parsed }
        // Tolerate a producer that omitted fractional seconds.
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(text)
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let parsed = date(from: text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "bad timestamp \(text)")
                )
            }
            return parsed
        }
        return decoder
    }
}
