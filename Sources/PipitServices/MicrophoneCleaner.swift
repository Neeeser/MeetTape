import AVFoundation
import Foundation
import PipitAudio
import PipitCore

/// Subtracts the recorded far end out of the recorded microphone, and writes
/// the result beside the recording.
///
/// A call taken on speakers puts the far end into the microphone. It leaves the
/// speakers, crosses the room and arrives back at the capsule. On a Slack
/// huddle of 3 September 2026, 81% of the words the microphone carried were the
/// far end's. Pipit records that far end separately through a process tap, and
/// that recording is the reference an echo canceller needs.
///
/// The cleaned track is written to `raw/audio/mic.cleaned.m4a` and recorded in
/// `metadata.cleanedMic`, which is what makes every reader take it. The
/// recording itself is never written to, and the cleaned file only ever appears
/// after the canceller has affirmatively said its output is worth using.
public struct MicrophoneCleaner: Sendable {
    /// The decision is `EchoCancellationPass.judge`, which measures what the
    /// pass did to the user's own windows rather than what the canceller
    /// reported. See the constants there.
    static let farEndActiveDBFS = EchoCancellationPass.farEndActiveDBFS
    static let minimumActiveWindows = EchoCancellationPass.minimumActiveWindows

    /// Cleaned samples held back before a write, so the encoder is handed
    /// seconds at a time rather than 10 ms blocks.
    static let writeFrames = 16_000

    private let clock: any Clock

    public init(clock: any Clock = SystemClock()) {
        self.clock = clock
    }

    /// Cleans this meeting's microphone, or says why it did not.
    ///
    /// `metadata` comes back holding what was written, so a caller that keeps
    /// reading its own copy afterwards reads the cleaned microphone rather than
    /// the recording. Only `.cleaned` leaves a file and a `cleanedMic` record.
    /// Every other outcome clears both, including a stale one an earlier run
    /// left behind. The caller owns `metadata.cleaningOutcome`.
    public func clean(
        store: MeetingStore, metadata: inout MeetingMetadata, timeline: RecordingTimeline
    ) throws -> CleaningOutcome {
        do {
            return try attempt(store: store, metadata: &metadata, timeline: timeline)
        } catch {
            // A throw is one more answer that is not `.cleaned`, and it leaves
            // this meeting where every other one of them does. The caller
            // records `.failed` and never runs the cleaner on this meeting
            // again, so a record an earlier run left would otherwise keep every
            // reader on that run's file permanently.
            try? discardCleanedTrack(store: store, metadata: &metadata)
            throw error
        }
    }

    /// The pass itself. Every exit but a throw is already an outcome that has
    /// dealt with the record. `clean` deals with the throw.
    private func attempt(
        store: MeetingStore, metadata: inout MeetingMetadata, timeline: RecordingTimeline
    ) throws -> CleaningOutcome {
        // One track holding everyone, which is every import and every in-person
        // session. There is no separate far end, and the only thing there is to
        // subtract from this microphone is the microphone.
        guard metadata.source.micTrackIsLocalUser else {
            try discardCleanedTrack(store: store, metadata: &metadata)
            log(outcome: .skippedOneTrack)
            return .skippedOneTrack
        }

        // Both read as recorded, never through `trackAudioLocation`. A second
        // run has to subtract the far end from the microphone rather than from
        // what the first run left, and cleaning an already cleaned track finds
        // no echo path and throws the result away.
        let microphone = store.rawTrackAudioLocation(
            track: .mic, metadata: metadata, timeline: timeline
        )
        let reference = store.rawTrackAudioLocation(
            track: .remote, metadata: metadata, timeline: timeline
        )
        guard !microphone.isEmpty, !reference.isEmpty,
              try EchoCancellationPass.referenceHoldsAudio(reference) else {
            try discardCleanedTrack(store: store, metadata: &metadata)
            log(outcome: .skippedNoReference)
            return .skippedNoReference
        }

        let partial = store.layout.cleanedMicFile
            .deletingPathExtension()
            .appendingPathExtension("partial")
            .appendingPathExtension("m4a")
        let pass = try subtract(
            microphone: microphone, reference: reference, timeline: timeline, to: partial
        )
        let judgement = EchoCancellationPass.judge(windows: pass.windows)
        let median = judgement.reportedMedianDB
        let active = judgement.activeWindows
        guard judgement.outcome == .cleaned else {
            // Too little far end played to be judged on, or the pass took the
            // user's own speech down with the echo. Either way this microphone
            // is read as it was recorded.
            try? FileManager.default.removeItem(at: partial)
            try discardCleanedTrack(store: store, metadata: &metadata)
            log(outcome: judgement.outcome, median: median, active: active, frames: pass.frames)
            Log.processing.info("microphone cleaning reason: \(judgement.reason, privacy: .public)")
            return judgement.outcome
        }

        // Cleared before anything on disk moves. A crash between here and the
        // write below leaves every reader on the recording, which is the safe
        // end of this. Clearing later would leave the metadata naming a file
        // that had already been deleted, and would leave a refused verification
        // pointing readers at an older track this run never blessed.
        try discardCleanedTrack(store: store, metadata: &metadata)

        // The file itself is the authority, exactly as it is for a compaction
        // archive. Every reader above is about to be pointed at this file with
        // no fallback, so the sample count handed to the encoder is not good
        // enough. An encode that stopped short or a container that will not
        // open throws here, and the meeting keeps the microphone it recorded.
        let written = try verify(
            partial, cleaned: pass.frames, against: microphone.seconds
        )

        // An interrupted run leaves a file with no record behind it.
        // `discardCleanedTrack` above removed one the metadata named.
        try? FileManager.default.removeItem(at: store.layout.cleanedMicFile)
        do {
            try FileManager.default.moveItem(at: partial, to: store.layout.cleanedMicFile)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw StorageError.fileWriteFailed(
                path: store.layout.cleanedMicFile.path, underlying: "\(error)"
            )
        }
        // Written last. Until this lands the file is one nothing reads, and
        // after it every reader takes the cleaned track.
        metadata = try store.updateMetadata {
            $0.cleanedMic = CleanedMicrophone(
                track: AudioArchive.Track(
                    file: store.layout.cleanedMicFileName,
                    sampleRate: written.sampleRate,
                    channelCount: written.channelCount,
                    frameCount: written.frameCount,
                    seconds: written.seconds,
                    // The cleaned track starts on the microphone's own first
                    // frame, so it carries the microphone's host time and the
                    // mixdown aligns it exactly as it aligned the recording.
                    firstFrameHostTime: timeline.firstFrameHostTime(track: .mic)
                ),
                echoRemovedMedianDB: median,
                farEndActiveWindows: active,
                producedAt: clock.now
            )
        }
        log(outcome: .cleaned, median: median, active: active, frames: written.frameCount)
        return .cleaned
    }

    /// Decodes what was just encoded and reports what is in it.
    ///
    /// The frame count and the duration recorded for a cleaned track come from
    /// here rather than from the samples handed to the encoder, so the
    /// synthetic segment a reader is given can never claim more audio than the
    /// file holds. This throws on a pass that never read the whole microphone,
    /// on a file that will not open, and on one whose duration disagrees with
    /// the pass that wrote it. The recording is intact either way, so a later
    /// attempt can build the track again.
    ///
    /// `recorded` is the duration the manifest holds rather than anything this
    /// run measured, and both checks are made against it because the pass
    /// cannot bound itself. `TrackAudioReader` skips a segment it cannot open
    /// and only logs a notice, so a run that reads ten seconds of a
    /// sixty-minute microphone writes ten seconds, agrees with its own read
    /// exactly, and would be promoted as the track every reader takes.
    private func verify(
        _ url: URL, cleaned frames: Int64, against recorded: Double
    ) throws -> AudioFileInfo {
        let expected = Double(frames) / EchoCancellationPass.readFormat.sampleRate
        // Floored for codec padding on short files, capped so a long meeting
        // cannot lose most of a minute and still verify. The same formula
        // compaction uses, on the quantity compaction uses it on, which is the
        // duration the manifest recorded.
        let tolerance = max(0.5, min(recorded * 0.01, 2.0))
        guard abs(expected - recorded) <= tolerance else {
            try? FileManager.default.removeItem(at: url)
            throw ProcessingError.localProcessingFailed(
                reason: "the cleaned microphone covers "
                    + "\(String(format: "%.1f", expected))s of "
                    + "\(String(format: "%.1f", recorded))s recorded",
                retryable: true
            )
        }
        let info: AudioFileInfo
        do {
            info = try AudioFileInspector().inspect(url: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw ProcessingError.localProcessingFailed(
                reason: "the cleaned microphone would not decode", retryable: true
            )
        }
        guard info.frameCount > 0, abs(info.seconds - expected) <= tolerance else {
            try? FileManager.default.removeItem(at: url)
            throw ProcessingError.localProcessingFailed(
                reason: "the cleaned microphone decoded to "
                    + "\(String(format: "%.1f", info.seconds))s against "
                    + "\(String(format: "%.1f", expected))s cleaned",
                retryable: true
            )
        }
        return info
    }

    /// Removes the record of a cleaned track and then the track itself.
    ///
    /// Every outcome but `.cleaned` means this meeting has no cleaned
    /// microphone. A record an earlier run left would otherwise keep every
    /// reader on a file this run decided against. The record goes first, so an
    /// interruption between the two leaves a file nothing reads rather than a
    /// name with no file behind it.
    private func discardCleanedTrack(
        store: MeetingStore, metadata: inout MeetingMetadata
    ) throws {
        guard metadata.cleanedMic != nil else { return }
        metadata = try store.updateMetadata { $0.cleanedMic = nil }
        try? FileManager.default.removeItem(at: store.layout.cleanedMicFile)
    }

    // MARK: - the pass over both tracks

    /// Runs `EchoCancellationPass` over the pair and encodes what comes back.
    ///
    /// Everything about how the two tracks are lined up and measured is in the
    /// pass. What is here is the encoder: samples held back until there are
    /// seconds of them, and a file that is removed rather than left truncated
    /// if anything throws.
    private func subtract(
        microphone: TrackAudioLocation, reference: TrackAudioLocation,
        timeline: RecordingTimeline, to destination: URL
    ) throws -> EchoCancellationPass.Result {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: EchoCancellationPass.readFormat.sampleRate, channels: 1
        ) else {
            throw ProcessingError.audioUnreadable(path: destination.lastPathComponent)
        }
        let settings = TrackArchiveExporter.Settings.archive
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: destination)
        var file: AVAudioFile?
        do {
            file = try AVAudioFile(forWriting: destination, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: settings.sampleRate,
                AVNumberOfChannelsKey: settings.channelCount,
                AVEncoderBitRateKey: settings.bitRate,
            ])
        } catch {
            throw ProcessingError.audioUnreadable(path: destination.lastPathComponent)
        }
        // A throw anywhere below leaves nothing on disk rather than a truncated
        // file the next stage would read as the whole meeting.
        defer { if file != nil { try? FileManager.default.removeItem(at: destination) } }

        var pending: [Float] = []
        let pass = try EchoCancellationPass.run(
            microphone: microphone, reference: reference,
            referenceOffset: EchoCancellationPass.referenceOffset(timeline: timeline)
        ) { cleaned in
            pending += cleaned
            if pending.count >= Self.writeFrames {
                try write(&pending, to: file, format: format)
            }
        }
        try write(&pending, to: file, format: format)
        // Released before returning: `AVAudioFile` finalises the container on
        // deallocation, and the caller renames this file.
        file = nil
        return pass
    }

    private func write(_ samples: inout [Float], to file: AVAudioFile?, format: AVAudioFormat) throws {
        guard let file, !samples.isEmpty else {
            samples.removeAll(keepingCapacity: true)
            return
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
        ), let data = buffer.floatChannelData else {
            throw ProcessingError.audioUnreadable(path: file.url.lastPathComponent)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for index in samples.indices { data[0][index] = samples[index] }
        try file.write(from: buffer)
        samples.removeAll(keepingCapacity: true)
    }

    /// Counts and decibels only. Nothing here describes what was said.
    private func log(
        outcome: CleaningOutcome, median: Double = 0, active: Int = 0, frames: Int64 = 0
    ) {
        Log.processing.info(
            """
            microphone cleaning \(outcome.rawValue, privacy: .public): \
            \(median, format: .fixed(precision: 1), privacy: .public) dB median over \
            \(active, privacy: .public) far-end windows, \
            \(frames, privacy: .public) frames
            """
        )
    }
}
