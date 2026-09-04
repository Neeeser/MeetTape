import Foundation
import PipitCore
import PipitServices
import TestKit

enum ReprocessingTests {
    static let suite = Suite("Reprocessing", [
        test("a reset removes what was derived and keeps the recording and the names") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let made = try PipelineTests.makeRecordedMeeting(root: root, seconds: 4)
            let store = made.store
            let layout = store.layout
            try Data("{}".utf8).write(to: layout.rawTranscript)
            try Data("{}".utf8).write(to: layout.canonicalTranscript)
            try Data("{}".utf8).write(to: layout.speechEvidence)
            try Data("# notes".utf8).write(to: layout.transcriptMarkdown)
            var speakers = SpeakerMap()
            speakers.assign("Ada", to: "remote-001_speaker_00")
            try store.writeSpeakerMap(speakers)
            _ = try store.updateMetadata {
                $0.processing = ProcessingStatus(state: .complete, updatedAt: $0.startedAt)
                $0.cleaningOutcome = .bypassedNoEchoPath
            }
            let manifestBefore = try Data(contentsOf: layout.manifest)
            let segmentsBefore = try FileManager.default.contentsOfDirectory(atPath: layout.segments.path)

            let backup = root.appendingPathComponent("backup", isDirectory: true)
            try Reprocessing.backUp(store: store, to: backup)
            let metadata = try Reprocessing.reset(store: store)

            expect.equal(metadata.processing.state, ProcessingState.audioSafe)
            expect.isTrue(metadata.cleaningOutcome == nil, "the cleaner runs again")
            expect.isFalse(FileManager.default.fileExists(atPath: layout.rawTranscript.path))
            expect.isFalse(FileManager.default.fileExists(atPath: layout.canonicalTranscript.path))
            expect.isFalse(FileManager.default.fileExists(atPath: layout.speechEvidence.path))
            expect.isFalse(FileManager.default.fileExists(atPath: layout.transcriptMarkdown.path))
            expect.isTrue(FileManager.default.fileExists(atPath: layout.speakerMap.path), "typed names stay")
            expect.equal(try store.readSpeakerMap().entries["remote-001_speaker_00"]?.displayName, "Ada")
            expect.equal(try Data(contentsOf: layout.manifest), manifestBefore, "the manifest is untouched")
            expect.equal(
                try FileManager.default.contentsOfDirectory(atPath: layout.segments.path).sorted(),
                segmentsBefore.sorted(), "the recording is untouched"
            )
            let backedUp = backup.appendingPathComponent("raw/transcript.raw.json")
            expect.isTrue(FileManager.default.fileExists(atPath: backedUp.path), "the backup holds the transcript")
            expect.isTrue(
                FileManager.default.fileExists(atPath: backup.appendingPathComponent("raw/metadata.json").path),
                "the backup holds the metadata"
            )
        },
    ])
}
