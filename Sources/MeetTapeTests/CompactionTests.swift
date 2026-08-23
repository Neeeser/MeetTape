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

        test("the archive is recorded before anything is deleted") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let meeting = try makeCompleteMeeting(root: root)
            let store = meeting.store

            // One segment file refuses deletion. The transcode and the metadata
            // write must both have happened by the time the delete throws, or
            // the ordering the whole design rests on is broken.
            let fileManager = FileManager.default
            let locked = try fileManager.contentsOfDirectory(
                at: store.layout.segments, includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix("mic.") }
            guard let locked else { throw TestSkip("fixture wrote no mic segment") }
            try fileManager.setAttributes([.immutable: true], ofItemAtPath: locked.path)

            var thrown: (any Error)?
            do { _ = try AudioCompactor().compact(store: store) } catch { thrown = error }
            try fileManager.setAttributes([.immutable: false], ofItemAtPath: locked.path)

            expect.isTrue(thrown != nil, "the refused delete surfaces")
            let metadata = try store.readMetadata()
            expect.isTrue(
                metadata.audioArchive != nil,
                "the archive was recorded before deletion was attempted"
            )
            expect.isTrue(
                fileManager.fileExists(atPath: locked.path),
                "the undeletable segment is still there"
            )

            // With the lock lifted the next sweep finishes the job.
            let outcome = try AudioCompactor().compact(store: store)
            expect.equal(outcome, AudioCompactor.Outcome.compacted)
            expect.isFalse(fileManager.fileExists(atPath: store.layout.segments.path))
        },

        test("a failure on the second track records no archive and keeps every segment") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let meeting = try makeCompleteMeeting(root: root)
            let store = meeting.store

            // The mic track (first in CaptureTrack.allCases) exports and is
            // promoted; the system track then comes up empty. Nothing may be
            // recorded and nothing deleted, or the mic segments would be
            // removed on the next sweep while the system audio has no archive.
            for file in try FileManager.default.contentsOfDirectory(
                at: store.layout.segments, includingPropertiesForKeys: nil
            ) where file.lastPathComponent.hasPrefix("system.") {
                try FileManager.default.removeItem(at: file)
            }

            var thrown: (any Error)?
            do { _ = try AudioCompactor().compact(store: store) } catch { thrown = error }
            expect.isTrue(thrown != nil)
            expect.isTrue(try store.readMetadata().audioArchive == nil)
            let micSegments = try FileManager.default.contentsOfDirectory(
                at: store.layout.segments, includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("mic.") }
            expect.isTrue(!micSegments.isEmpty, "the mic segments survive the failed run")
        },

        test("a file the manifest does not account for survives compaction") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let meeting = try makeCompleteMeeting(root: root)
            let store = meeting.store
            _ = try AudioCompactor().compact(store: store)

            // A leftover state holding one file the archive covered and one it
            // never saw: only the covered one goes.
            try FileManager.default.createDirectory(
                at: store.layout.segments, withIntermediateDirectories: true
            )
            let covered = store.layout.segments.appendingPathComponent("mic.0001.caf")
            let unknown = store.layout.segments.appendingPathComponent("mic.9999.caf")
            try Data("covered".utf8).write(to: covered)
            try Data("unknown".utf8).write(to: unknown)

            _ = try AudioCompactor().compact(store: store)
            expect.isFalse(
                FileManager.default.fileExists(atPath: covered.path),
                "the manifest-known file the archive replaced is removed"
            )
            expect.isTrue(
                FileManager.default.fileExists(atPath: unknown.path),
                "audio the manifest does not account for is never deleted"
            )
        },

        test("a missing archive file stops deletion cold") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let meeting = try makeCompleteMeeting(root: root)
            let store = meeting.store
            _ = try AudioCompactor().compact(store: store)

            // The archive record survives a restore; the archive file did not.
            // The recreated segments are now the only audio, and the resume
            // path must refuse to touch them.
            try FileManager.default.removeItem(at: store.layout.trackArchiveFile(track: .mic))
            try FileManager.default.createDirectory(
                at: store.layout.segments, withIntermediateDirectories: true
            )
            let survivor = store.layout.segments.appendingPathComponent("mic.0001.caf")
            try Data("the only copy".utf8).write(to: survivor)

            var thrown: (any Error)?
            do { _ = try AudioCompactor().compact(store: store) } catch { thrown = error }
            expect.isTrue(thrown != nil, "verification refuses the missing archive")
            expect.isTrue(
                FileManager.default.fileExists(atPath: survivor.path),
                "nothing was deleted"
            )
        },

        test("the archive starts where the PCM started") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let repository = MeetingRepository(root: root)
            let started = Date(timeIntervalSince1970: 1_787_070_000)
            let created = try repository.createMeeting(
                source: .manual, provider: .unknown, startedAt: started,
                titles: TitleCandidates(timestampFallback: "offset"), now: started
            )
            let manifest = try ManifestWriter(url: created.store.layout.manifest)
            manifest.append(.sessionStart(.init(
                meetingID: created.metadata.id, source: .manual, segmentSeconds: 30,
                appVersion: "test", processID: 1
            )))
            let writer = SegmentWriter(
                track: .mic, layout: created.store.layout, manifest: manifest,
                format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!,
                segmentSeconds: 30
            )
            // One second of silence, then two of tone. AAC encoder priming that
            // leaked into the timeline would shift the onset by ~0.13 s, which
            // every word timing and diarization boundary would inherit.
            writer.enqueueSynchronously(AudioBufferPacket(
                buffer: AudioTests.makeTone(seconds: 1, sampleRate: 48_000, amplitude: 0), hostTime: 100
            ))
            writer.enqueueSynchronously(AudioBufferPacket(
                buffer: AudioTests.makeTone(seconds: 2, sampleRate: 48_000), hostTime: 101
            ))
            writer.finish(reason: "test")
            manifest.append(.sessionEnd(.init(reason: "test", micSeconds: 3, remoteSeconds: 0)))
            manifest.close()
            _ = try created.store.updateMetadata {
                $0.processing = ProcessingStatus(state: .complete, updatedAt: started)
            }

            _ = try AudioCompactor().compact(store: created.store)

            let metadata = try created.store.readMetadata()
            let timeline = try created.store.readTimeline()
            let location = created.store.trackAudioLocation(
                track: .mic, metadata: metadata, timeline: timeline
            )
            let stream = TrackAudioStream(
                segments: location.segments,
                segmentsDirectory: location.directory,
                format: AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1)
            )
            var firstLoudFrame: Int64 = -1
            var position: Int64 = 0
            try stream.forEachBuffer(from: 0, to: 3) { buffer, _ in
                if firstLoudFrame < 0, let data = buffer.floatChannelData {
                    for frame in 0..<Int(buffer.frameLength) where abs(data[0][frame]) > 0.05 {
                        firstLoudFrame = position + Int64(frame)
                        break
                    }
                }
                position += Int64(buffer.frameLength)
                return firstLoudFrame < 0
            }
            expect.isTrue(firstLoudFrame >= 0, "the tone is in the archive")
            expect.close(Double(firstLoudFrame) / 16_000, 1.0, tolerance: 0.1)
        },

        test("the startup sweep compacts a folded continuation") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let primary = try makeCompleteMeeting(root: root)
            let folded = try makeCompleteMeeting(root: root)
            _ = try folded.store.updateMetadata { $0.mergedIntoMeetingID = primary.metadata.id }
            _ = try primary.store.updateMetadata { $0.absorbedMeetingIDs = [folded.metadata.id] }

            let pipeline = PipelineTests.makePipeline(
                repository: MeetingRepository(root: root), backend: FakeAIBackend()
            )
            await pipeline.compactPending()

            for store in [primary.store, folded.store] {
                expect.isTrue(
                    try store.readMetadata().audioArchive != nil,
                    "the hidden continuation compacts like the meeting it folded into"
                )
                expect.isFalse(FileManager.default.fileExists(atPath: store.layout.segments.path))
            }
        },

        test("compaction after complete waits for the recording gate") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let meeting = try makeCompleteMeeting(root: root)
            let store = meeting.store

            let capture = LockedBox(RecordingAwareGate.CaptureState.recording)
            let gate = RecordingAwareGate(pollSeconds: 0.05) { capture.withLock { $0 } }
            let pipeline = ProcessingPipeline(
                repository: MeetingRepository(root: root),
                backend: FakeAIBackend(),
                gate: gate,
                clock: ManualClock(),
                settingsProvider: { AppSettings() },
                wait: { _ in }
            )

            let job = Task { await pipeline.process(meetingID: meeting.metadata.id) }
            try await Task.sleep(nanoseconds: 300_000_000)
            expect.isTrue(
                FileManager.default.fileExists(atPath: store.layout.segments.path),
                "nothing is transcoded or deleted while a recording is live"
            )
            expect.isTrue(try store.readMetadata().audioArchive == nil)

            capture.withLock { $0 = .idle }
            await job.value
            expect.isTrue(try store.readMetadata().audioArchive != nil)
            expect.isFalse(FileManager.default.fileExists(atPath: store.layout.segments.path))
        },

        test("recovery waits for a folder whose migration has not run") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let made = try PipelineTests.makeRecordedMeeting(root: root)
            let store = made.store
            let layout = store.layout
            _ = try store.updateMetadata {
                $0.processing = ProcessingStatus(state: .recording, updatedAt: $0.startedAt)
            }

            // The folder as an old build left it after a crash: everything at
            // the root, and this launch's migration failed to move it.
            let fileManager = FileManager.default
            try fileManager.moveItem(at: layout.metadata, to: layout.legacyMetadata)
            try fileManager.moveItem(at: layout.segments, to: layout.legacySegments)
            try fileManager.moveItem(at: layout.manifest, to: layout.legacyManifest)
            try fileManager.removeItem(at: layout.raw)

            let scanner = RecoveryScanner(
                repository: MeetingRepository(root: root), inspector: AudioFileInspector()
            )
            let report = scanner.scan()
            expect.equal(report.recovered.count, 0)

            // The failure mode this pins: recovery must not open a fresh empty
            // manifest at the new path, which would shadow the real one and
            // block the manifest's migration forever.
            expect.isFalse(
                fileManager.fileExists(atPath: layout.manifest.path),
                "no empty manifest was created at the new path"
            )
            let metadata = try store.readMetadata()
            expect.equal(metadata.processing.state, ProcessingState.recording)

            // Once the migration succeeds, recovery proceeds normally.
            try MeetingLayoutMigration.migrate(layout: layout)
            let second = scanner.scan()
            expect.equal(second.recovered.count, 1)
            expect.equal(try store.readMetadata().processing.state, ProcessingState.audioSafe)
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

            // Compaction refuses the folder while it is unmigrated: a metadata
            // write here would create raw/metadata.json and permanently block
            // that file's move.
            expect.equal(try AudioCompactor().compact(store: store), AudioCompactor.Outcome.nothingToDo)
            expect.isFalse(
                fileManager.fileExists(atPath: layout.metadata.path),
                "no raw/metadata.json shadow was created"
            )

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
