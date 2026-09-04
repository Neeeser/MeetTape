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
    /// Median enhancement, over the windows where the far end was playing,
    /// below which the cleaned track is thrown away.
    ///
    /// Provisional. PR 4's measurement command settles it against real
    /// recordings. 6 dB is a starting point between the 2.84 dB a canceller
    /// with no echo path to lock onto reports and the 96.8 dB it reports with
    /// one, both measured on tones in `AudioTests`.
    public static let bypassBelowDB = 6.0

    /// A window whose far-end level clears this had the far end playing in it.
    static let farEndActiveDBFS = -60.0
    /// A track that never clears this in any window recorded nothing at all.
    static let referenceFloorDBFS = -80.0
    /// Seconds one measurement window covers, matching the grid the speech
    /// evidence is already sampled on.
    static let windowSeconds = 0.25
    /// Windows of far-end activity the decision needs before it is made at all.
    ///
    /// Ten seconds. The canceller reports nothing for its first 2.5 s of
    /// far-end activity, which is ten of these windows, and those windows read
    /// zero. Forty windows is what keeps that start-up from being a quarter of
    /// the sample, and counting in far-end-active windows rather than in
    /// seconds of file is what makes the bound hold for a meeting whose far end
    /// stayed quiet for the first minute.
    static let minimumActiveWindows = 40

    /// The rate both tracks are read at, which is the rate every model above
    /// reads them at too.
    static let readFormat = AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1)
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
        guard !microphone.isEmpty, !reference.isEmpty, try referenceHoldsAudio(reference) else {
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
        let active = pass.windows.filter { $0.farEndDBFS > Self.farEndActiveDBFS }
        let median = median(of: active.map(\.echoRemovedDB))

        // Too little far end played for the canceller to have been judged on
        // anything. The same answer as a meeting with no far-end track, which
        // is that this microphone is used as it was recorded.
        guard active.count >= Self.minimumActiveWindows else {
            try? FileManager.default.removeItem(at: partial)
            try discardCleanedTrack(store: store, metadata: &metadata)
            log(outcome: .skippedNoReference, median: median, active: active.count, frames: pass.frames)
            return .skippedNoReference
        }
        // The filter never locked on to an echo path, which is a call taken on
        // headphones. A low reading says nothing about how close the output is
        // to the recording. It comes from the linear filter, and the suppressor
        // that runs after it takes tens of decibels out of a microphone holding
        // only the user. A filter that did not lock on is a filter whose output
        // there is no reason to trust, so the output is thrown away.
        guard median >= Self.bypassBelowDB else {
            try? FileManager.default.removeItem(at: partial)
            try discardCleanedTrack(store: store, metadata: &metadata)
            log(outcome: .bypassedNoEchoPath, median: median, active: active.count, frames: pass.frames)
            return .bypassedNoEchoPath
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
        let written = try verify(partial, against: pass.frames)

        // A file with no record behind it, which is what an interrupted run
        // leaves. `discardCleanedTrack` above removed one the metadata named.
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
                farEndActiveWindows: active.count,
                producedAt: clock.now
            )
        }
        log(outcome: .cleaned, median: median, active: active.count, frames: written.frameCount)
        return .cleaned
    }

    /// Decodes what was just encoded and reports what is in it.
    ///
    /// The frame count and the duration recorded for a cleaned track come from
    /// here rather than from the samples handed to the encoder, so the
    /// synthetic segment a reader is given can never claim more audio than the
    /// file holds. A file that will not open, or one whose duration disagrees
    /// with the pass that wrote it, throws: the recording is intact, so a later
    /// attempt can build the track again.
    private func verify(_ url: URL, against frames: Int64) throws -> AudioFileInfo {
        let expected = Double(frames) / Self.readFormat.sampleRate
        let info: AudioFileInfo
        do {
            info = try AudioFileInspector().inspect(url: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw ProcessingError.localProcessingFailed(
                reason: "the cleaned microphone would not decode", retryable: true
            )
        }
        // Floored for codec padding on short files, capped so a long meeting
        // cannot lose most of a minute and still verify. The same bound
        // compaction holds its archives to.
        let tolerance = max(0.5, min(expected * 0.01, 2.0))
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

    /// One quarter-second of the pass: how loud the far end was, and what the
    /// canceller said it had removed by the end of it.
    ///
    /// The pair travels together because neither reads on its own. Both the
    /// 39.9 dB of damage measured on a pure tone with no echo path and the
    /// 2.1 dB measured on real recordings come out of the same code, differing
    /// only in how much of the time the far end was loud.
    private struct Window {
        let farEndDBFS: Double
        let echoRemovedDB: Double
    }

    private struct Pass {
        var frames: Int64
        var windows: [Window]
    }

    private func subtract(
        microphone: TrackAudioLocation, reference: TrackAudioLocation,
        timeline: RecordingTimeline, to destination: URL
    ) throws -> Pass {
        guard let canceller = EchoCanceller(sampleRate: Int(Self.readFormat.sampleRate)) else {
            throw ProcessingError.localProcessingFailed(
                reason: "the echo canceller refused \(Self.readFormat.sampleRate) Hz",
                retryable: false
            )
        }
        let block = canceller.blockFrames
        let windowFrames = Int((Self.windowSeconds * Self.readFormat.sampleRate).rounded())
        guard block > 0, windowFrames >= block else {
            throw ProcessingError.localProcessingFailed(
                reason: "the echo canceller reported a block of \(block) frames", retryable: false
            )
        }
        let blocksPerWindow = windowFrames / block

        // The microphone is read from its own first frame, so a position in the
        // cleaned file is the same position in the recording and every
        // timestamp downstream still lands where it did. The far end is moved
        // onto that clock. `leadIn` says how long after the earliest track each
        // one started, so their difference is how far the far end has to move
        // to line up: a far end that started later is padded with the silence
        // Pipit did not record, and one that started earlier has that much of
        // it read and thrown away.
        let referenceOffset = timeline.leadIn(track: .remote) - timeline.leadIn(track: .mic)
        guard let microphoneReader = TimelineTrackReader(
            location: microphone, format: Self.readFormat, offsetSeconds: 0
        ), let referenceReader = TimelineTrackReader(
            location: reference, format: Self.readFormat, offsetSeconds: referenceOffset
        ) else {
            throw ProcessingError.audioUnreadable(path: microphone.directory.lastPathComponent)
        }

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Self.readFormat.sampleRate, channels: 1
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

        var pass = Pass(frames: 0, windows: [])
        var pending: [Float] = []
        var blocksInWindow = 0
        var farEndSquares = 0.0
        var farEndCount = 0

        while true {
            var samples = try microphoneReader.next(count: block)
            if samples.isEmpty { break }
            // The canceller takes whole blocks. The tail of the recording is
            // padded to one and trimmed back off before it is written.
            let recorded = samples.count
            if recorded < block {
                samples += [Float](repeating: 0, count: block - recorded)
            }
            var played = try referenceReader.next(count: block)
            // The far end's tap can stop before the microphone does, and what
            // it did not record is silence.
            if played.count < block {
                played += [Float](repeating: 0, count: block - played.count)
            }
            guard canceller.process(microphone: &samples, reference: played) else {
                throw ProcessingError.localProcessingFailed(
                    reason: "the echo canceller refused a block of \(block) frames",
                    retryable: false
                )
            }

            // The only place the canceller's figure is read, and it is read on
            // the far side of a call that returned true. A block that was never
            // processed and a filter that has not locked on both reach Swift as
            // 0.0, and this is what keeps the first out of the median.
            farEndSquares += played.reduce(0.0) { $0 + Double($1) * Double($1) }
            farEndCount += played.count
            blocksInWindow += 1
            if blocksInWindow == blocksPerWindow {
                pass.windows.append(Window(
                    farEndDBFS: decibels(squares: farEndSquares, count: farEndCount),
                    echoRemovedDB: canceller.echoRemovedDB
                ))
                blocksInWindow = 0
                farEndSquares = 0
                farEndCount = 0
            }

            pending += samples.prefix(recorded)
            pass.frames += Int64(recorded)
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

    /// Whether the far end's track holds any audio at all.
    ///
    /// A track that never clears the floor in any window is one the tap opened
    /// on and recorded nothing through. An early exit rather than a rule of its
    /// own: a track this refuses has no window loud enough to count below
    /// either, so the answer is the same. What it saves is cancelling and
    /// encoding a two-hour meeting against silence before saying so.
    private func referenceHoldsAudio(_ location: TrackAudioLocation) throws -> Bool {
        guard let reader = TimelineTrackReader(
            location: location, format: Self.readFormat, offsetSeconds: 0
        ) else { return false }
        let window = Int((Self.windowSeconds * Self.readFormat.sampleRate).rounded())
        while true {
            let samples = try reader.next(count: window)
            if samples.isEmpty { return false }
            let squares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
            if decibels(squares: squares, count: samples.count) > Self.referenceFloorDBFS {
                return true
            }
            if samples.count < window { return false }
        }
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

    private func decibels(squares: Double, count: Int) -> Double {
        guard count > 0 else { return EmptyTranscriptPolicy.silenceFloorDBFS }
        let rms = (squares / Double(count)).squareRoot()
        guard rms > 0 else { return EmptyTranscriptPolicy.silenceFloorDBFS }
        return max(EmptyTranscriptPolicy.silenceFloorDBFS, 20 * log10(rms))
    }

    private func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
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
