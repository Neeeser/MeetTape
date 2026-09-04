import Foundation
import PipitAudio
import PipitCore

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
        // A folder still in the old layout waits for its migration, exactly as
        // recovery does: the metadata write below would create raw/metadata.json
        // and permanently block that file's move.
        guard !MeetingLayoutMigration.needsMigration(layout: store.layout) else {
            return .nothingToDo
        }
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
            // Mixed while the metadata still points at the segments, so the
            // listening copy is built from the 48 kHz PCM rather than from the
            // 16 kHz archives about to replace it. The microphone side comes
            // from the cleaned track where there is one, which is what keeps
            // the far end out of the mix twice over.
            ensureMixdown(store: store, metadata: metadata, timeline: timeline)
            metadata = try store.updateMetadata { $0.audioArchive = archive }
        }
        guard let archive = metadata.audioArchive else { return .nothingToDo }

        // A meeting the sweep revisits only because it keeps files the
        // manifest does not account for has nothing to do; answering that from
        // a directory listing keeps the per-launch cost at a stat instead of
        // decoding both archives.
        let needsMixdown = !FileManager.default.fileExists(atPath: store.layout.recordingAudio.path)
        let needsDeletion = hasDeletionWork(store: store, archive: archive, timeline: timeline)
        guard needsMixdown || needsDeletion else { return .alreadyCompacted }

        // Verified first on both paths. For deletion this is the guard that
        // matters: the record in the metadata says an archive was verified
        // once, and a synced, restored or hand-edited folder can have lost it
        // since, so the segments about to be removed would be the only copy.
        // For the mixdown it turns "re-mix the whole meeting from a broken
        // archive every launch, silently" into a cheap decode check that
        // throws where someone can see it.
        try verifyArchivesIntact(store: store, archive: archive)

        // Resume-path regeneration: reads through the location resolution, so
        // a compacted meeting whose mixdown was lost gets one back from the
        // archives. A no-op whenever the file exists.
        if needsMixdown {
            ensureMixdown(store: store, metadata: metadata, timeline: timeline)
        }
        guard needsDeletion else { return .alreadyCompacted }
        let removedAnything = try deleteReplacedAudio(
            store: store, archive: archive, timeline: timeline
        )
        return removedAnything ? .compacted : .alreadyCompacted
    }

    /// Filenames of the segments each archived track replaced: the closed
    /// segments the manifest names. Open segments never reached the archive
    /// and are not covered.
    private func coveredSegmentFiles(
        archive: AudioArchive, timeline: RecordingTimeline
    ) -> Set<String> {
        var covered: Set<String> = []
        for track in CaptureTrack.allCases where archive.track(track) != nil {
            for segment in timeline.segments(track: track) where segment.isClosed {
                covered.insert(segment.file)
            }
        }
        return covered
    }

    /// Whether `deleteReplacedAudio` would remove anything right now.
    private func hasDeletionWork(
        store: MeetingStore, archive: AudioArchive, timeline: RecordingTimeline
    ) -> Bool {
        let fileManager = FileManager.default
        let covered = coveredSegmentFiles(archive: archive, timeline: timeline)
        for directory in [store.layout.segments, store.layout.legacySegments] {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ) else { continue }
            if contents.isEmpty { return true }
            if contents.contains(where: { covered.contains($0.lastPathComponent) }) { return true }
        }
        return fileManager.fileExists(atPath: store.layout.legacyMixedAudio.path)
            && fileManager.fileExists(atPath: store.layout.recordingAudio.path)
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
            // The recording, not the cleaned microphone. What this archives is
            // the source the manifest describes and the duration it verifies
            // against, and the cleaned file is derived from it.
            let location = store.rawTrackAudioLocation(
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
            // Floored for codec padding on short files, capped so a long
            // meeting cannot lose most of a minute and still verify.
            let tolerance = max(0.5, min(expectedSeconds * 0.01, 2.0))
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
                  abs(info.seconds - record.seconds) <= max(0.5, min(record.seconds * 0.01, 2.0))
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
        let covered = coveredSegmentFiles(archive: archive, timeline: timeline)

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
