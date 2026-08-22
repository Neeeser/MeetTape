import Foundation
import MeetTapeAudio
import MeetTapeCore

/// Replaces a finished meeting's PCM segments with verified archive files.
///
/// Runs only after a meeting is `complete`, so every model has already read the
/// audio at full fidelity. Each track's segment chain is transcoded to one AAC
/// file, the file is decoded again and checked against the manifest duration,
/// and only then does the metadata record the archive. Deletion is narrower
/// still: it runs strictly after the metadata record is durable, it re-verifies
/// every recorded archive file immediately beforehand, and it removes only the
/// segment files the manifest accounts for and the archive covered. A crash at
/// any point either leaves the segments as the source or leaves both
/// representations, and the next sweep finishes the deletion. Nothing here ever
/// deletes the only copy of a track, and a file the manifest does not know is
/// never deleted at all.
public struct AudioCompactor: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// Archives written now, or leftovers from an interrupted run removed.
        case compacted
        /// Metadata already records the archive and nothing needed removing.
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

    /// Whether a meeting still has compaction work: segments to archive,
    /// leftovers an interrupted run kept, or a mixdown to regenerate.
    public static func hasWork(store: MeetingStore, metadata: MeetingMetadata) -> Bool {
        guard metadata.processing.state == .complete else { return false }
        let fileManager = FileManager.default
        let hasSegments = fileManager.fileExists(atPath: store.layout.segments.path)
            || fileManager.fileExists(atPath: store.layout.legacySegments.path)
        if metadata.audioArchive == nil {
            return hasSegments
        }
        return hasSegments
            || fileManager.fileExists(atPath: store.layout.legacyMixedAudio.path)
            || !fileManager.fileExists(atPath: store.layout.recordingAudio.path)
    }

    public func compact(store: MeetingStore) throws -> Outcome {
        var metadata = try store.readMetadata()
        guard metadata.processing.state == .complete else { return .nothingToDo }
        let timeline = try store.readTimeline()

        if metadata.audioArchive == nil {
            guard let archive = try writeArchives(
                store: store, metadata: metadata, timeline: timeline
            ) else {
                removeEmptySegmentsDirectory(store: store)
                return .nothingToDo
            }
            metadata = try store.updateMetadata { $0.audioArchive = archive }
        }
        guard let archive = metadata.audioArchive else { return .nothingToDo }

        // Deletion trusts nothing but what it can decode right now. The record
        // in the metadata says an archive was verified once; a synced, restored
        // or hand-edited folder can have lost it since, and the segments about
        // to be removed would then be the only copy.
        try verifyArchivesIntact(store: store, archive: archive)
        ensureMixdown(store: store, metadata: metadata, timeline: timeline)
        let removedAnything = try deleteReplacedAudio(
            store: store, archive: archive, timeline: timeline
        )
        return removedAnything ? .compacted : .alreadyCompacted
    }

    /// Transcodes every track that has audio and verifies each file by decoding
    /// it again. Returns nil when no track had anything to archive.
    private func writeArchives(
        store: MeetingStore, metadata: MeetingMetadata, timeline: RecordingTimeline
    ) throws -> AudioArchive? {
        var archive = AudioArchive(compactedAt: clock.now)
        var wroteAnything = false
        let inspector = AudioFileInspector()

        for track in CaptureTrack.allCases {
            let location = store.trackAudioLocation(
                track: track, metadata: metadata, timeline: timeline
            )
            guard !location.isEmpty else { continue }
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
            let info: AudioFileInfo
            do {
                info = try inspector.inspect(url: partial)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                throw error
            }
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
            // Frame count and seconds both come from the decoded file, so the
            // synthetic segment a reader gets can never disagree with the
            // duration recorded here.
            archive.setTrack(track, to: AudioArchive.Track(
                file: store.layout.trackArchiveFileName(track: track),
                sampleRate: info.sampleRate,
                channelCount: info.channelCount,
                frameCount: info.frameCount,
                seconds: info.seconds,
                firstFrameHostTime: location.segments.compactMap(\.resolvedFirstFrameHostTime).first
            ))
            wroteAnything = true
        }
        return wroteAnything ? archive : nil
    }

    /// Every recorded archive file must decode to the duration its record
    /// claims, right now, or nothing is deleted. Throws retryable: with the
    /// segments still on disk, a later attempt can rebuild the archive.
    private func verifyArchivesIntact(store: MeetingStore, archive: AudioArchive) throws {
        let inspector = AudioFileInspector()
        for track in CaptureTrack.allCases {
            guard let record = archive.track(track) else { continue }
            let url = store.layout.trackArchiveDirectory.appendingPathComponent(record.file)
            guard let info = try? inspector.inspect(url: url),
                  abs(info.seconds - record.seconds) <= max(0.5, record.seconds * 0.01)
            else {
                throw ProcessingError.localProcessingFailed(
                    reason: "recorded archive for \(track.segmentPrefix) is missing or short; "
                        + "keeping the segments",
                    retryable: true
                )
            }
        }
    }

    /// Mixes `recording.m4a` when it is missing. Reads through the location
    /// resolution, so it works from segments before deletion and from the
    /// archives after; that is what makes the mixdown regenerable for good.
    /// Optional like every mixdown: a failure never blocks compaction.
    private func ensureMixdown(
        store: MeetingStore, metadata: MeetingMetadata, timeline: RecordingTimeline
    ) {
        guard !FileManager.default.fileExists(atPath: store.layout.recordingAudio.path) else { return }
        do {
            try mixer.mix(
                mic: store.trackAudioLocation(track: .mic, metadata: metadata, timeline: timeline),
                remote: store.trackAudioLocation(track: .remote, metadata: metadata, timeline: timeline),
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
        for directory in [store.layout.segments, store.layout.legacySegments] {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ), contents.isEmpty else { continue }
            try? fileManager.removeItem(at: directory)
        }
    }

    /// Removes exactly what the archive replaced: the closed segment files the
    /// manifest names for each archived track, and the legacy mixdown once its
    /// replacement exists. An open segment (a crash tail that was never
    /// adopted) and any file the manifest does not name are kept, because their
    /// audio never reached the archive. Idempotent, so an interrupted deletion
    /// resumes. Returns whether anything was removed.
    private func deleteReplacedAudio(
        store: MeetingStore, archive: AudioArchive, timeline: RecordingTimeline
    ) throws -> Bool {
        let fileManager = FileManager.default
        var removedAnything = false

        var covered: Set<String> = []
        for track in CaptureTrack.allCases where archive.track(track) != nil {
            for segment in timeline.segments(track: track) where segment.isClosed {
                covered.insert(segment.file)
            }
        }

        for directory in [store.layout.segments, store.layout.legacySegments] {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ) else { continue }
            for file in contents where covered.contains(file.lastPathComponent) {
                do {
                    try fileManager.removeItem(at: file)
                } catch {
                    throw StorageError.fileWriteFailed(path: file.path, underlying: "\(error)")
                }
                removedAnything = true
            }
            let remaining = (try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )) ?? []
            if remaining.isEmpty {
                try? fileManager.removeItem(at: directory)
            } else {
                Log.processing.notice(
                    "compaction kept \(remaining.count, privacy: .public) files the manifest does not account for"
                )
            }
        }

        // The old mixdown goes only once its replacement is listenable.
        if fileManager.fileExists(atPath: store.layout.legacyMixedAudio.path),
           fileManager.fileExists(atPath: store.layout.recordingAudio.path) {
            do {
                try fileManager.removeItem(at: store.layout.legacyMixedAudio)
            } catch {
                throw StorageError.fileWriteFailed(
                    path: store.layout.legacyMixedAudio.path, underlying: "\(error)"
                )
            }
            removedAnything = true
        }
        return removedAnything
    }
}
