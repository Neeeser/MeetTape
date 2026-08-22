import Foundation
import MeetTapeAudio
import MeetTapeCore

/// Replaces a finished meeting's PCM segments with verified archive files.
///
/// Runs only after a meeting is `complete`, so every model has already read the
/// audio at full fidelity. Each track's segment chain is transcoded to one AAC
/// file, the file is decoded again and checked against the manifest duration,
/// and only then does the metadata record the archive. The segments are deleted
/// strictly after that record is durable: a crash at any point either leaves the
/// segments as the source or leaves both representations, and the next sweep
/// finishes the deletion. Nothing here ever deletes the only copy of a track.
public struct AudioCompactor: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// Archives written now, or leftovers from an interrupted run removed.
        case compacted
        /// Metadata already records the archive and no leftovers remain.
        case alreadyCompacted
        /// Nothing to archive: no audio, or the meeting is not complete.
        case nothingToDo
    }

    public let exporter: TrackArchiveExporter
    public let mixer: AudioMixer
    private let clock: any Clock

    public init(
        exporter: TrackArchiveExporter = TrackArchiveExporter(),
        mixer: AudioMixer = AudioMixer(),
        clock: any Clock = SystemClock()
    ) {
        self.exporter = exporter
        self.mixer = mixer
        self.clock = clock
    }

    /// Whether a meeting still has compaction work: segments to archive, or
    /// files an interrupted run left behind.
    public static func hasWork(store: MeetingStore, metadata: MeetingMetadata) -> Bool {
        guard metadata.processing.state == .complete else { return false }
        let fileManager = FileManager.default
        if metadata.audioArchive == nil {
            return fileManager.fileExists(atPath: store.layout.segments.path)
                || fileManager.fileExists(atPath: store.layout.legacySegments.path)
        }
        return fileManager.fileExists(atPath: store.layout.segments.path)
            || fileManager.fileExists(atPath: store.layout.legacyMixedAudio.path)
    }

    public func compact(store: MeetingStore) throws -> Outcome {
        var metadata = try store.readMetadata()
        guard metadata.processing.state == .complete else { return .nothingToDo }

        if metadata.audioArchive == nil {
            let timeline = try store.readTimeline()
            guard let archive = try writeArchives(store: store, timeline: timeline) else {
                removeEmptySegmentsDirectory(store: store)
                return .nothingToDo
            }
            ensureMixdown(store: store, timeline: timeline)
            metadata = try store.updateMetadata { $0.audioArchive = archive }
        } else if !Self.hasWork(store: store, metadata: metadata) {
            return .alreadyCompacted
        }

        try deleteReplacedAudio(store: store)
        return .compacted
    }

    /// Transcodes every track that has audio and verifies each file by decoding
    /// it again. Returns nil when no track had anything to archive.
    private func writeArchives(
        store: MeetingStore, timeline: RecordingTimeline
    ) throws -> AudioArchive? {
        var archive = AudioArchive(compactedAt: clock.now)
        var wroteAnything = false
        let inspector = AudioFileInspector()

        for track in CaptureTrack.allCases {
            let segments = timeline.segments(track: track)
            guard !segments.isEmpty else { continue }
            let location = TrackAudioLocation(segments: segments, directory: store.layout.segments)
            let expectedSeconds = location.seconds
            guard expectedSeconds > 0 else { continue }

            let partial = store.layout.trackArchiveDirectory
                .appendingPathComponent("\(track.segmentPrefix).partial.m4a")
            let frames: Int64
            do {
                frames = try exporter.export(location: location, to: partial)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                throw error
            }

            // The file itself is the authority: decode what was written and
            // compare against the manifest. An encoder that silently stopped
            // short must leave the segments as the source.
            let info = try inspector.inspect(url: partial)
            let tolerance = max(0.5, expectedSeconds * 0.01)
            guard frames > 0, abs(info.seconds - expectedSeconds) <= tolerance else {
                try? FileManager.default.removeItem(at: partial)
                throw ProcessingError.localProcessingFailed(
                    reason: "archive verification failed for \(track.segmentPrefix): "
                        + "\(String(format: "%.1f", info.seconds))s decoded, "
                        + "\(String(format: "%.1f", expectedSeconds))s recorded",
                    retryable: true
                )
            }

            let destination = store.layout.trackArchiveFile(track: track)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
            archive.setTrack(track, to: AudioArchive.Track(
                file: store.layout.trackArchiveFileName(track: track),
                sampleRate: exporter.settings.sampleRate,
                channelCount: exporter.settings.channelCount,
                frameCount: frames,
                seconds: info.seconds,
                firstFrameHostTime: segments.compactMap(\.resolvedFirstFrameHostTime).first
            ))
            wroteAnything = true
        }
        return wroteAnything ? archive : nil
    }

    /// Mixes `recording.m4a` from the segments while they still exist. Optional
    /// like every mixdown: the archives can regenerate it later, so a failure
    /// here never blocks compaction.
    private func ensureMixdown(store: MeetingStore, timeline: RecordingTimeline) {
        guard !FileManager.default.fileExists(atPath: store.layout.recordingAudio.path) else { return }
        do {
            try mixer.mix(
                mic: TrackAudioLocation(
                    segments: timeline.segments(track: .mic), directory: store.layout.segments
                ),
                remote: TrackAudioLocation(
                    segments: timeline.segments(track: .remote), directory: store.layout.segments
                ),
                to: store.layout.recordingAudio
            )
        } catch {
            Log.processing.notice("mixdown skipped: \(logSafeDescription(error), privacy: .public)")
        }
    }

    /// A complete meeting with no recorded audio keeps nothing to compact; its
    /// empty segments directory would otherwise re-enter the sweep every launch.
    /// Only an empty directory is removed: a file the manifest does not know is
    /// still audio, and audio is never deleted on an inference.
    private func removeEmptySegmentsDirectory(store: MeetingStore) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: store.layout.segments, includingPropertiesForKeys: nil
        ), contents.isEmpty else { return }
        try? fileManager.removeItem(at: store.layout.segments)
    }

    /// Removes what the archive replaced. Runs only once `metadata.audioArchive`
    /// is durable, and is idempotent so an interrupted deletion resumes.
    private func deleteReplacedAudio(store: MeetingStore) throws {
        let fileManager = FileManager.default
        for url in [store.layout.segments, store.layout.legacySegments,
                    store.layout.legacyMixedAudio] {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                throw StorageError.fileWriteFailed(path: url.path, underlying: "\(error)")
            }
        }
    }
}
