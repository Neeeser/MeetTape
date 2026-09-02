import Foundation

/// One recorded audio segment as the manifest describes it.
public struct RecordedSegment: Sendable, Equatable {
    public let track: CaptureTrack
    public let index: Int
    public let file: String
    public let format: AudioFormatDescriptor
    public let startFrame: Int64
    public let firstFrameHostTime: Double?
    public let openedAt: Date
    public let openReason: String
    /// Nil while the segment is open. A segment still open when the manifest ends
    /// is a crash tail: the file is readable, its length is only known from disk.
    public private(set) var frameCount: Int64?
    public private(set) var byteCount: Int64?
    public private(set) var closeReason: String?
    public private(set) var wasAdoptedFromCrashTail = false
    /// Host time of this segment's first frame. Only known once a buffer has
    /// arrived, so the close record carries it and the open record cannot.
    public private(set) var resolvedFirstFrameHostTime: Double?

    public init(
        track: CaptureTrack, index: Int, file: String, format: AudioFormatDescriptor,
        startFrame: Int64, firstFrameHostTime: Double?, openedAt: Date, openReason: String
    ) {
        self.track = track
        self.index = index
        self.file = file
        self.format = format
        self.startFrame = startFrame
        self.firstFrameHostTime = firstFrameHostTime
        self.resolvedFirstFrameHostTime = firstFrameHostTime
        self.openedAt = openedAt
        self.openReason = openReason
    }

    public var isClosed: Bool { frameCount != nil }

    /// Duration of this segment alone, at the rate this segment was recorded at.
    public var seconds: Double {
        guard let frameCount, format.sampleRate > 0 else { return 0 }
        return Double(frameCount) / format.sampleRate
    }

    mutating func close(
        frameCount: Int64, byteCount: Int64, reason: String, adopted: Bool,
        firstFrameHostTime: Double? = nil
    ) {
        self.frameCount = frameCount
        self.byteCount = byteCount
        self.closeReason = reason
        self.wasAdoptedFromCrashTail = adopted
        if let firstFrameHostTime { resolvedFirstFrameHostTime = firstFrameHostTime }
    }
}

/// The reconstructed timeline of one recording.
///
/// Total duration is the sum of per-segment durations. Dividing an accumulated
/// frame count by the current sample rate is wrong the moment a Bluetooth profile
/// switch changes the rate mid-recording, and it under-reported a real session by
/// two thirds during the stress test.
public struct RecordingTimeline: Sendable, Equatable {
    public let meetingID: String?
    public let source: MeetingSource?
    public let startedAt: Date?
    public let endedAt: Date?
    public let endReason: String?
    public let segments: [RecordedSegment]
    public let restarts: [ManifestEvent.CaptureRestart]
    /// When each restart happened, on the capture clock.
    ///
    /// The restart payload carries no time of its own, and the only question
    /// worth asking about a restart is where it falls: one before a track's
    /// audio began cost that track nothing, and one inside the last segment is
    /// the single gap no segment boundary can reveal.
    public let restartMoments: [(track: CaptureTrack, hostTime: Double)]
    public let formatChanges: [ManifestEvent.FormatChange]
    public let markers: [(date: Date, label: String)]
    public let preRollFlushes: [ManifestEvent.PreRollFlushed]
    /// True when the final line of the manifest was cut off mid-write.
    public let hasTruncatedTail: Bool

    public var isComplete: Bool { endedAt != nil }

    public func segments(track: CaptureTrack) -> [RecordedSegment] {
        segments.filter { $0.track == track }.sorted { $0.index < $1.index }
    }

    /// Duration of one track: the sum of each segment's own frames over its own
    /// sample rate.
    public func duration(track: CaptureTrack) -> Double {
        segments(track: track).reduce(0) { $0 + $1.seconds }
    }

    /// Duration of the meeting, which is the longer of the two tracks.
    public var duration: Double {
        max(duration(track: .mic), duration(track: .remote))
    }

    /// Host time of a track's first recorded frame.
    public func firstFrameHostTime(track: CaptureTrack) -> Double? {
        segments(track: track).compactMap(\.resolvedFirstFrameHostTime).first
    }

    /// Host time of the meeting timeline's own zero.
    ///
    /// Every interval on the meeting timeline is measured from the earliest
    /// frame any track recorded, which is what `leadIn` is relative to. This is
    /// that moment on the capture clock, so anything else stamped with host time
    /// can be placed on the same timeline.
    ///
    /// Not `startedAt`. That is the wall clock when the session was committed,
    /// and capture keeps a pre-roll it had already buffered, so the recording is
    /// older than the commit by as much as the pre-roll window.
    public var timelineOriginHostTime: Double? {
        CaptureTrack.allCases.compactMap { firstFrameHostTime(track: $0) }.min()
    }

    /// Whether one track's audio runs without a gap in it.
    ///
    /// The meeting timeline is concatenated-audio time: segments are joined
    /// with nothing between them, so a stretch of missing audio makes
    /// everything after it sit earlier on the timeline than in host time by the
    /// length of the gap. Anything placed by a single host-time shift, which is
    /// how sensor readings land, is only valid while this holds.
    ///
    /// Segment count says nothing about this. The writer rotates every thirty
    /// seconds, so a five minute call is ten segments recorded back to back.
    /// What matters is whether each segment begins where the one before it
    /// ended, measured on the capture clock and allowed a rotation's worth of
    /// slack, well above the buffer boundary a rotation actually costs.
    public func isContiguous(track: CaptureTrack, tolerance: Double = 0.5) -> Bool {
        let ordered = segments(track: track)
        // A restart inside the last segment is the one gap no boundary can
        // show: a restart does not force a rotation, so the frames stop and
        // resume inside the same file with nothing after it to measure.
        //
        // Only that restart. Rebinding the tap is ordinary and mostly costs no
        // audio at all: it happens once before a track's first frame on the
        // path where a generic call becomes a recognised one, and again
        // whenever a browser's helper processes come and go. Those are caught
        // by the boundary check below if they cost anything, and treating every
        // restart as a gap threw the record away for most real meetings.
        if let last = ordered.last, let start = last.resolvedFirstFrameHostTime,
           restartMoments.contains(where: { $0.track == track && $0.hostTime > start }) {
            return false
        }
        for (previous, next) in zip(ordered, ordered.dropFirst()) {
            // A segment whose start was never resolved cannot be compared. It
            // is also not evidence of a gap, and refusing on it would drop the
            // record for a recording that is very likely fine.
            guard let start = previous.resolvedFirstFrameHostTime,
                  let following = next.resolvedFirstFrameHostTime
            else { continue }
            let recorded = previous.seconds
            guard recorded > 0 else { continue }
            if following - (start + recorded) > tolerance { return false }
        }
        return true
    }

    /// How long after the meeting started this track's first frame arrived.
    ///
    /// The two sources start at different moments. The remote writer opens on the
    /// first packet from the meeting application, which can be many seconds after
    /// the microphone begins, so a position within one track's audio is not a
    /// position on the meeting timeline until this offset is added.
    public func leadIn(track: CaptureTrack) -> Double {
        let starts = CaptureTrack.allCases.compactMap { firstFrameHostTime(track: $0) }
        guard let earliest = starts.min(), let own = firstFrameHostTime(track: track) else { return 0 }
        return max(0, own - earliest)
    }

    /// Segments with no close record. Their audio is intact; only the manifest is.
    public var openSegments: [RecordedSegment] {
        segments.filter { !$0.isClosed }
    }

    public var wasInterrupted: Bool { !openSegments.isEmpty || !isComplete }

    public static func == (lhs: RecordingTimeline, rhs: RecordingTimeline) -> Bool {
        lhs.meetingID == rhs.meetingID
            && lhs.source == rhs.source
            && lhs.startedAt == rhs.startedAt
            && lhs.endedAt == rhs.endedAt
            && lhs.segments == rhs.segments
            && lhs.restarts == rhs.restarts
            && lhs.formatChanges == rhs.formatChanges
            && lhs.markers.map(\.label) == rhs.markers.map(\.label)
            && lhs.hasTruncatedTail == rhs.hasTruncatedTail
    }
}

public struct ManifestReadResult: Sendable {
    public let lines: [ManifestLine]
    /// The last line was incomplete, which is the expected shape after a crash.
    public let hasTruncatedTail: Bool
    /// Lines that parsed as JSON but described something this build does not know.
    public let unrecognisedLines: Int

    public init(lines: [ManifestLine], hasTruncatedTail: Bool, unrecognisedLines: Int) {
        self.lines = lines
        self.hasTruncatedTail = hasTruncatedTail
        self.unrecognisedLines = unrecognisedLines
    }
}

public enum ManifestReader {
    /// Reads a manifest, tolerating both a truncated final line and event types a
    /// future build may add. Neither should discard a recording.
    public static func read(contentsOf url: URL) throws -> ManifestReadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StorageError.fileReadFailed(path: url.path, underlying: "\(error)")
        }
        return parse(data)
    }

    public static func parse(_ data: Data) -> ManifestReadResult {
        let decoder = ManifestCoding.makeDecoder()
        var lines: [ManifestLine] = []
        var unrecognised = 0
        var truncated = false

        let rawLines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        for (offset, raw) in rawLines.enumerated() {
            if raw.isEmpty { continue }
            let isLast = offset == rawLines.count - 1
            guard let line = try? decoder.decode(ManifestLine.self, from: Data(raw)) else {
                if isLast, !data.hasSuffix(newline: true) {
                    truncated = true
                } else {
                    unrecognised += 1
                }
                continue
            }
            lines.append(line)
        }
        return ManifestReadResult(lines: lines, hasTruncatedTail: truncated, unrecognisedLines: unrecognised)
    }

    /// Folds manifest lines into a timeline.
    public static func timeline(from result: ManifestReadResult) -> RecordingTimeline {
        var meetingID: String?
        var source: MeetingSource?
        var startedAt: Date?
        var endedAt: Date?
        var endReason: String?
        var segmentsByKey: [SegmentKey: RecordedSegment] = [:]
        var order: [SegmentKey] = []
        var restarts: [ManifestEvent.CaptureRestart] = []
        var restartMoments: [(track: CaptureTrack, hostTime: Double)] = []
        var formatChanges: [ManifestEvent.FormatChange] = []
        var markers: [(date: Date, label: String)] = []
        var preRolls: [ManifestEvent.PreRollFlushed] = []

        for line in result.lines {
            switch line.event {
            case .sessionStart(let payload):
                meetingID = payload.meetingID
                source = payload.source
                startedAt = line.wallClock
            case .segmentOpen(let payload):
                let key = SegmentKey(track: payload.track, index: payload.index)
                if segmentsByKey[key] == nil { order.append(key) }
                segmentsByKey[key] = RecordedSegment(
                    track: payload.track, index: payload.index, file: payload.file,
                    format: payload.format, startFrame: payload.startFrame,
                    firstFrameHostTime: payload.firstFrameHostTime,
                    openedAt: line.wallClock, openReason: payload.reason
                )
            case .segmentClose(let payload):
                let key = SegmentKey(track: payload.track, index: payload.index)
                segmentsByKey[key]?.close(
                    frameCount: payload.frameCount, byteCount: payload.byteCount,
                    reason: payload.reason, adopted: false,
                    firstFrameHostTime: payload.firstFrameHostTime
                )
            case .crashTailAdopted(let payload):
                let key = SegmentKey(track: payload.track, index: payload.index)
                segmentsByKey[key]?.close(
                    frameCount: payload.frameCount, byteCount: payload.byteCount,
                    reason: "crash_tail", adopted: true
                )
            case .formatChange(let payload):
                formatChanges.append(payload)
            case .captureRestart(let payload):
                restarts.append(payload)
                restartMoments.append((track: payload.track, hostTime: line.hostTime))
            case .marker(let payload):
                markers.append((date: line.wallClock, label: payload.label))
            case .preRollFlushed(let payload):
                preRolls.append(payload)
            case .sessionEnd(let payload):
                endedAt = line.wallClock
                endReason = payload.reason
            case .sourceHealth, .remoteBind:
                // Provenance for reading the recording afterwards. Neither
                // places audio on the timeline.
                break
            }
        }

        let segments = order.compactMap { segmentsByKey[$0] }
        return RecordingTimeline(
            meetingID: meetingID, source: source, startedAt: startedAt, endedAt: endedAt,
            endReason: endReason, segments: segments, restarts: restarts,
            restartMoments: restartMoments,
            formatChanges: formatChanges, markers: markers, preRollFlushes: preRolls,
            hasTruncatedTail: result.hasTruncatedTail
        )
    }

    public static func timeline(contentsOf url: URL) throws -> RecordingTimeline {
        timeline(from: try read(contentsOf: url))
    }

    private struct SegmentKey: Hashable {
        let track: CaptureTrack
        let index: Int
    }
}

private extension Data {
    func hasSuffix(newline: Bool) -> Bool {
        guard newline, let last else { return false }
        return last == 0x0A
    }
}
