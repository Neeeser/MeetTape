import AVFoundation
import Foundation
import MeetTapeCore
import Synchronization

/// Rotating CAF segment writer.
///
/// CAF is the production source format because it declares its data chunk size as
/// -1, so a reader falls back to end-of-file and a killed process still leaves a
/// fully readable file. WAV under-reports its tail and M4A becomes unopenable.
///
/// All file I/O runs on a private serial queue. Audio callbacks hand over a copied
/// buffer and return immediately.
public final class SegmentWriter: Sendable {
    public struct Stats: Sendable, Equatable {
        public var segmentCount: Int
        public var completedSeconds: Double
        public var currentSegmentSeconds: Double
        public var writeFailures: Int

        public var totalSeconds: Double { completedSeconds + currentSegmentSeconds }
    }

    private struct State {
        var file: AVAudioFile?
        var format: AVAudioFormat
        var index = 0
        var framesInSegment: Int64 = 0
        /// Sum of every closed segment's own frames over its own sample rate. Never
        /// a global frame count divided by the current rate.
        var completedSeconds: Double = 0
        var startFrameOfSegment: Int64 = 0
        var totalFrames: Int64 = 0
        var firstFrameHostTime: Double?
        var writeFailures = 0
        var isFinished = false
        /// A failed open is retried on the next buffer rather than ending the
        /// track: a transiently full disk should cost seconds, not the meeting.
        var openFailedAt: Double?
        var lastFailureLoggedAt: Double?
    }

    private let state: LockedBox<State>
    private let queue: DispatchQueue
    private let track: CaptureTrack
    private let layout: MeetingLayout
    private let manifest: ManifestWriter
    private let clock: any Clock
    private let segmentSeconds: Double
    private let onFailure: @Sendable (CaptureError) -> Void

    public init(
        track: CaptureTrack,
        layout: MeetingLayout,
        manifest: ManifestWriter,
        format: AVAudioFormat,
        segmentSeconds: Double = 30,
        clock: any Clock = SystemClock(),
        onFailure: @escaping @Sendable (CaptureError) -> Void = { _ in }
    ) {
        self.track = track
        self.layout = layout
        self.manifest = manifest
        self.clock = clock
        self.segmentSeconds = segmentSeconds
        self.onFailure = onFailure
        self.state = LockedBox(State(format: format))
        self.queue = DispatchQueue(label: "com.meettape.segment-writer.\(track.rawValue)", qos: .utility)
        // Asynchronous because the caller can be an audio render thread: creating
        // the file and appending an fsync'd manifest line there drops the audio
        // being recorded. The queue is serial, so the segment is still open before
        // the first buffer is written, and a failure reported from here runs with
        // no caller lock held.
        queue.async { [self] in openSegment(reason: "start") }
    }

    public var stats: Stats {
        state.withLock { state in
            let current = state.format.sampleRate > 0
                ? Double(state.framesInSegment) / state.format.sampleRate
                : 0
            return Stats(
                segmentCount: state.index,
                completedSeconds: state.completedSeconds,
                currentSegmentSeconds: current,
                writeFailures: state.writeFailures
            )
        }
    }

    public var currentFormat: AVAudioFormat { state.withLock { $0.format } }

    /// Hands a buffer to the writer queue. The packet already owns a copy; tap
    /// buffers are only valid inside their callback.
    public func enqueue(_ packet: AudioBufferPacket) {
        queue.async { [self] in
            write(packet.buffer, hostTime: packet.hostTime)
        }
    }

    /// Writes a packet and waits for it. Used when flushing the pre-roll, where
    /// ordering against the live stream matters.
    public func enqueueSynchronously(_ packet: AudioBufferPacket) {
        queue.sync { [self] in
            write(packet.buffer, hostTime: packet.hostTime)
        }
    }

    /// Closes the open segment and starts a new one at `format`. Used when the
    /// device changes underneath capture, so a format change never corrupts a file.
    public func changeFormat(_ format: AVAudioFormat, reason: String) {
        queue.sync { [self] in
            let previous = state.withLock { $0.format }
            closeSegment(reason: reason)
            recordFormatChange(from: previous, to: format, reason: reason)
            state.withLock { $0.format = format }
            openSegment(reason: reason)
        }
    }

    public func finish(reason: String) {
        queue.sync { [self] in
            closeSegment(reason: reason)
            state.withLock { $0.isFinished = true }
        }
    }

    // MARK: - queue-confined

    private func write(_ buffer: AVAudioPCMBuffer, hostTime: Double) {
        let (file, format, finished) = state.withLock { ($0.file, $0.format, $0.isFinished) }
        guard !finished else { return }
        guard let file else {
            retryOpenIfNeeded(at: hostTime)
            if state.withLock({ $0.file }) != nil { write(buffer, hostTime: hostTime) }
            return
        }
        guard buffer.format.sampleRate == format.sampleRate,
              buffer.format.channelCount == format.channelCount
        else {
            // A buffer that does not match the open segment means the format changed
            // without the coordinator noticing. Rotate rather than drop the audio.
            changeFormatOnQueue(buffer.format, reason: "buffer_format_mismatch")
            write(buffer, hostTime: hostTime)
            return
        }

        do {
            try file.write(from: buffer)
        } catch {
            let (failures, shouldLog) = state.withLock { state -> (Int, Bool) in
                state.writeFailures += 1
                let now = self.clock.monotonicSeconds
                // A failing volume produces a failure per buffer; an fsync'd
                // manifest line each time would make the problem worse.
                let shouldLog = state.lastFailureLoggedAt.map { now - $0 > 10 } ?? true
                if shouldLog { state.lastFailureLoggedAt = now }
                return (state.writeFailures, shouldLog)
            }
            if shouldLog {
                manifest.append(
                    .sourceHealth(.init(
                        track: track, state: .failed,
                        detail: "segment write failed (\(failures) so far)"
                    )),
                    hostTime: clock.monotonicSeconds, wallClock: clock.now
                )
            }
            if failures == 1 {
                onFailure(.segmentWriteFailed(path: file.url.lastPathComponent, underlying: "\(error)"))
            }
            return
        }

        let shouldRotate: Bool = state.withLock { state in
            if state.firstFrameHostTime == nil { state.firstFrameHostTime = hostTime }
            state.framesInSegment += Int64(buffer.frameLength)
            state.totalFrames += Int64(buffer.frameLength)
            guard state.format.sampleRate > 0 else { return false }
            return Double(state.framesInSegment) / state.format.sampleRate >= segmentSeconds
        }
        if shouldRotate {
            closeSegment(reason: "rotate")
            openSegment(reason: "rotate")
        }
    }

    private func retryOpenIfNeeded(at hostTime: Double) {
        let shouldRetry = state.withLock { state -> Bool in
            guard state.file == nil, !state.isFinished else { return false }
            let now = self.clock.monotonicSeconds
            guard let failedAt = state.openFailedAt else { return true }
            guard now - failedAt >= 1.0 else { return false }
            state.openFailedAt = nil
            return true
        }
        guard shouldRetry else { return }
        openSegment(reason: "retry_after_open_failure")
    }

    private func changeFormatOnQueue(_ format: AVAudioFormat, reason: String) {
        let previous = state.withLock { $0.format }
        closeSegment(reason: reason)
        recordFormatChange(from: previous, to: format, reason: reason)
        state.withLock { $0.format = format }
        openSegment(reason: reason)
    }

    /// Every format change reaches the manifest, whichever path noticed it.
    private func recordFormatChange(from previous: AVAudioFormat, to format: AVAudioFormat, reason: String) {
        guard previous.sampleRate != format.sampleRate
            || previous.channelCount != format.channelCount
        else { return }
        manifest.append(
            .formatChange(.init(
                track: track,
                from: AudioFormatDescriptor(
                    sampleRate: previous.sampleRate, channelCount: Int(previous.channelCount)
                ),
                to: AudioFormatDescriptor(
                    sampleRate: format.sampleRate, channelCount: Int(format.channelCount)
                ),
                reason: reason
            )),
            hostTime: clock.monotonicSeconds,
            wallClock: clock.now
        )
    }

    private func openSegment(reason: String) {
        let (format, index, startFrame) = state.withLock { state -> (AVAudioFormat, Int, Int64) in
            state.index += 1
            state.framesInSegment = 0
            state.firstFrameHostTime = nil
            state.startFrameOfSegment = state.totalFrames
            return (state.format, state.index, state.totalFrames)
        }

        let url = layout.segmentFile(track: track, index: index)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let file = try AVAudioFile(
                forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false
            )
            state.withLock { $0.file = file }
        } catch {
            let isFirst = state.withLock { state -> Bool in
                state.file = nil
                state.writeFailures += 1
                let first = state.openFailedAt == nil
                state.openFailedAt = self.clock.monotonicSeconds
                return first
            }
            if isFirst {
                onFailure(.segmentWriteFailed(path: url.lastPathComponent, underlying: "\(error)"))
            }
            return
        }

        manifest.append(
            .segmentOpen(.init(
                track: track, index: index, file: url.lastPathComponent, firstFrameHostTime: nil,
                startFrame: startFrame, sampleRate: format.sampleRate,
                channelCount: Int(format.channelCount), reason: reason
            )),
            hostTime: clock.monotonicSeconds,
            wallClock: clock.now
        )
    }

    private func closeSegment(reason: String) {
        // Releasing the AVAudioFile finalises the container, so the URL is read
        // out first and the reference dropped inside the lock.
        let closing = state.withLock { state -> (index: Int, frames: Int64, seconds: Double, firstFrame: Double, url: URL)? in
            guard let file = state.file else { return nil }
            let url = file.url
            let seconds = state.format.sampleRate > 0
                ? Double(state.framesInSegment) / state.format.sampleRate
                : 0
            state.completedSeconds += seconds
            state.file = nil
            let frames = state.framesInSegment
            // Reset so `stats` never counts a closed segment twice: after finish()
            // the total is completedSeconds alone.
            state.framesInSegment = 0
            return (state.index, frames, seconds, state.firstFrameHostTime ?? -1, url)
        }
        guard let closing else { return }

        let attributes = try? FileManager.default.attributesOfItem(atPath: closing.url.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        manifest.append(
            .segmentClose(.init(
                track: track, index: closing.index, frameCount: closing.frames, byteCount: byteCount,
                seconds: closing.seconds,
                firstFrameHostTime: closing.firstFrame >= 0 ? closing.firstFrame : nil,
                reason: reason
            )),
            hostTime: clock.monotonicSeconds,
            wallClock: clock.now
        )
    }
}

public extension AVAudioPCMBuffer {
    /// A deep copy. Tap and IOProc buffers are only valid for the duration of the
    /// callback, so anything handed to another queue has to be copied first.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }
        copy.frameLength = frameLength
        let channels = Int(format.channelCount)
        if let source = floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: Int(frameLength))
            }
            return copy
        }
        if let source = int16ChannelData, let destination = copy.int16ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: Int(frameLength))
            }
            return copy
        }
        if let source = int32ChannelData, let destination = copy.int32ChannelData {
            for channel in 0..<channels {
                destination[channel].update(from: source[channel], count: Int(frameLength))
            }
            return copy
        }
        return nil
    }
}
