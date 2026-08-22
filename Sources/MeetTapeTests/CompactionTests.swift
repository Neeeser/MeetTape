import AVFoundation
import Foundation
import MeetTapeAudio
import MeetTapeCore
import MeetTapeServices
import TestKit

/// Storage compaction: PCM segments become verified archive files, and the
/// layout migration that moves old folders under `raw/`.
enum CompactionTests {
    /// A finished two-track meeting marked `complete`, ready to compact.
    private static func makeCompleteMeeting(
        root: URL, seconds: Double = 6, remoteStartOffset: Double = 0
    ) throws -> (metadata: MeetingMetadata, store: MeetingStore) {
        let made = try PipelineTests.makeRecordedMeeting(
            root: root, seconds: seconds, remoteStartOffset: remoteStartOffset
        )
        let metadata = try made.store.updateMetadata {
            $0.processing = ProcessingStatus(state: .complete, updatedAt: $0.startedAt)
        }
        return (metadata, made.store)
    }

    static let suite = Suite("Compaction", [
        test("compaction archives both tracks, records them and deletes the segments") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let meeting = try makeCompleteMeeting(root: root)
            let store = meeting.store

            let outcome = try AudioCompactor().compact(store: store)
            expect.equal(outcome, AudioCompactor.Outcome.compacted)

            let metadata = try store.readMetadata()
            let archive = metadata.audioArchive
            expect.isTrue(archive != nil, "the archive is recorded in the metadata")
            for track in CaptureTrack.allCases {
                let record = archive?.track(track)
                expect.isTrue(record != nil, "\(track.rawValue) has an archive record")
                expect.close(record?.seconds ?? 0, 6, tolerance: 0.5)
                let file = store.layout.trackArchiveFile(track: track)
                expect.isTrue(
                    FileManager.default.fileExists(atPath: file.path),
                    "\(track.rawValue) archive file exists"
                )
                let info = try AudioFileInspector().inspect(url: file)
                expect.close(info.seconds, 6, tolerance: 0.5)
            }
            expect.isFalse(
                FileManager.default.fileExists(atPath: store.layout.segments.path),
                "the segments directory is gone"
            )
            expect.isTrue(
                FileManager.default.fileExists(atPath: store.layout.recordingAudio.path),
                "the mixdown exists before the segments are deleted"
            )
        },

        test("a compacted track reads back through its location at the recorded duration") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let meeting = try makeCompleteMeeting(root: root)
            let store = meeting.store
            _ = try AudioCompactor().compact(store: store)

            let metadata = try store.readMetadata()
            let timeline = try store.readTimeline()
            let location = store.trackAudioLocation(
                track: .mic, metadata: metadata, timeline: timeline
            )
            expect.equal(location.directory.lastPathComponent, "audio")
            expect.close(location.seconds, 6, tolerance: 0.5)

            // The archive decodes as a continuous signal, not just a header.
            let stream = TrackAudioStream(
                segments: location.segments,
                segmentsDirectory: location.directory,
                format: AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1)
            )
            var frames: Int64 = 0
            var peak: Float = 0
            try stream.forEachBuffer(from: 0, to: 10) { buffer, _ in
                frames += Int64(buffer.frameLength)
                if let data = buffer.floatChannelData {
                    for frame in 0..<Int(buffer.frameLength) {
                        peak = max(peak, abs(data[0][frame]))
                    }
                }
                return true
            }
            expect.close(Double(frames) / 16_000, 6, tolerance: 0.5)
            expect.isTrue(peak > 0.1, "the decoded audio holds the tone, not silence")
        },

        test("a failed export keeps the segments and records no archive") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let meeting = try makeCompleteMeeting(root: root)
            let store = meeting.store

            // The manifest still names the mic segment; the file is gone, which
            // is what a damaged archive folder looks like. The transcode comes
            // up short and verification must refuse it.
            for file in try FileManager.default.contentsOfDirectory(
                at: store.layout.segments, includingPropertiesForKeys: nil
            ) where file.lastPathComponent.hasPrefix("mic.") {
                try FileManager.default.removeItem(at: file)
            }

            var thrown: (any Error)?
            do { _ = try AudioCompactor().compact(store: store) } catch { thrown = error }
            expect.isTrue(thrown != nil, "verification refuses the short archive")

            let metadata = try store.readMetadata()
            expect.isTrue(metadata.audioArchive == nil, "no archive is recorded")
            expect.isTrue(
                FileManager.default.fileExists(atPath: store.layout.segments.path),
                "the segments stay the source"
            )
            let leftovers = (try? FileManager.default.contentsOfDirectory(
                at: store.layout.trackArchiveDirectory, includingPropertiesForKeys: nil
            )) ?? []
            expect.equal(
                leftovers.filter { $0.lastPathComponent.contains("partial") }, [],
                "no partial file is left behind"
            )
        },

        test("an interrupted deletion resumes once the archive is recorded") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let meeting = try makeCompleteMeeting(root: root)
            let store = meeting.store
            _ = try AudioCompactor().compact(store: store)

            // A crash between the metadata write and the deletion leaves both
            // representations on disk. Recreate that state.
            try FileManager.default.createDirectory(
                at: store.layout.segments, withIntermediateDirectories: true
            )
            try Data("stale".utf8).write(to: store.layout.segments.appendingPathComponent("mic.0001.caf"))
            try Data("stale".utf8).write(to: store.layout.legacyMixedAudio)

            let metadata = try store.readMetadata()
            expect.isTrue(AudioCompactor.hasWork(store: store, metadata: metadata))
            let outcome = try AudioCompactor().compact(store: store)
            expect.equal(outcome, AudioCompactor.Outcome.compacted)
            expect.isFalse(FileManager.default.fileExists(atPath: store.layout.segments.path))
            expect.isFalse(FileManager.default.fileExists(atPath: store.layout.legacyMixedAudio.path))
            let after = try store.readMetadata()
            expect.isFalse(AudioCompactor.hasWork(store: store, metadata: after))
        },

        test("the mixdown regenerates from the archives after the segments are gone") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            // The remote source starts a second late, as it does when the tap
            // comes up before the microphone. Alignment must survive the
            // segments' deletion because the host times move into the archive.
            let meeting = try makeCompleteMeeting(root: root, remoteStartOffset: 1)
            let store = meeting.store
            _ = try AudioCompactor().compact(store: store)
            try FileManager.default.removeItem(at: store.layout.recordingAudio)

            let metadata = try store.readMetadata()
            let timeline = try store.readTimeline()
            try AudioMixer().mix(
                mic: store.trackAudioLocation(track: .mic, metadata: metadata, timeline: timeline),
                remote: store.trackAudioLocation(track: .remote, metadata: metadata, timeline: timeline),
                to: store.layout.recordingAudio
            )
            let info = try AudioFileInspector().inspect(url: store.layout.recordingAudio)
            // Mic runs 0-6, remote 1-7: the aligned mix is 7 seconds.
            expect.close(info.seconds, 7, tolerance: 0.5)
        },

        test("a complete meeting with no audio compacts to nothing and leaves the sweep") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let repository = MeetingRepository(root: root)
            let started = Date(timeIntervalSince1970: 1_787_070_000)
            let created = try repository.createMeeting(
                source: .manual, provider: .unknown, startedAt: started,
                titles: TitleCandidates(timestampFallback: "empty"), now: started
            )
            let metadata = try created.store.updateMetadata {
                $0.processing = ProcessingStatus(state: .complete, updatedAt: started)
            }
            expect.isTrue(AudioCompactor.hasWork(store: created.store, metadata: metadata))

            let outcome = try AudioCompactor().compact(store: created.store)
            expect.equal(outcome, AudioCompactor.Outcome.nothingToDo)
            let after = try created.store.readMetadata()
            expect.isFalse(
                AudioCompactor.hasWork(store: created.store, metadata: after),
                "the empty segments directory is cleaned up so the sweep does not retry forever"
            )
        },

        test("an old-layout folder migrates to raw/ and reads the same") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let made = try PipelineTests.makeRecordedMeeting(root: root)
            let store = made.store
            let layout = store.layout
            let originalID = made.metadata.id
            let originalTimeline = try store.readTimeline()

            // Rebuild the folder exactly as the previous build laid it out:
            // everything at the root, the manifest inside segments/.
            let fileManager = FileManager.default
            try fileManager.moveItem(at: layout.metadata, to: layout.legacyMetadata)
            try fileManager.moveItem(at: layout.segments, to: layout.legacySegments)
            try fileManager.moveItem(at: layout.manifest, to: layout.legacyManifest)
            try fileManager.removeItem(at: layout.raw)

            // Before migration the metadata still reads, through the fallback.
            expect.equal(try store.readMetadata().id, originalID)
            expect.isTrue(MeetingLayoutMigration.needsMigration(layout: layout))

            let repository = MeetingRepository(root: root)
            let result = repository.migrateLayouts()
            expect.equal(result.migrated, 1)
            expect.equal(result.failed, 0)

            expect.isFalse(MeetingLayoutMigration.needsMigration(layout: layout))
            expect.equal(try store.readMetadata().id, originalID)
            expect.equal(try store.readTimeline(), originalTimeline)
            expect.isTrue(fileManager.fileExists(atPath: layout.manifest.path))
            expect.isFalse(fileManager.fileExists(atPath: layout.legacyMetadata.path))
            expect.isFalse(fileManager.fileExists(atPath: layout.legacySegments.path))

            // Running it again moves nothing.
            let second = repository.migrateLayouts()
            expect.equal(second.migrated, 0)
        },
    ])
}
