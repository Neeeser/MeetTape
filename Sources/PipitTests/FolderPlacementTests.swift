import Foundation
import PipitCore
import PipitIntegrations
import PipitServices
import TestKit

/// Where a finished meeting ends up, run through the pipeline that decides it.
///
/// The matcher is tested on its own; these pin the seam around it. What is sent
/// to the model, what is written to disk, and the one rule that matters most:
/// a model's answer is recorded and never acted on.
enum FolderPlacementTests {
    static func processed(
        root: URL, backend: FakeAIBackend, settings: AppSettings
    ) async throws -> (metadata: MeetingMetadata, repository: MeetingRepository) {
        let meeting = try PipelineTests.makeRecordedMeeting(root: root, seconds: 6)
        backend.transcriptionSegments = [
            RawTranscriptSegment(start: 0, end: 5, text: "The security review is still open.", speaker: "speaker_0")
        ]
        backend.diarizationSegments = backend.transcriptionSegments
        let pipeline = PipelineTests.makePipeline(
            repository: meeting.repository, backend: backend, settings: settings
        )
        await pipeline.process(meetingID: meeting.metadata.id)
        return (meeting.metadata, meeting.repository)
    }

    static var suite: Suite {
        Suite("Folder placement", [
            test("a folder rule files a matching meeting on its own") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let folders = MeetingFolderStore(root: root)
                var folder = try folders.create(name: "Weekly")
                folder.rule = FolderRule(titleIs: "Weekly sync", provider: .googleMeet)
                folder.filesAutomatically = true
                try folders.write(folder)

                let backend = FakeAIBackend()
                backend.enrichment = MeetingEnrichment(summary: "Discussed the review.")
                let run = try await processed(root: root, backend: backend, settings: AppSettings())

                guard let found = run.repository.findMeeting(id: run.metadata.id) else {
                    return expect.fail("the meeting went missing")
                }
                expect.equal(found.metadata.folderName, "Weekly")
                expect.equal(
                    found.store.layout.root.deletingLastPathComponent().lastPathComponent, "Weekly"
                )
                expect.equal(found.store.readFolderSuggestion()?.reason, .rule)
                expect.equal(run.repository.meetings(inFolder: "Weekly").count, 1)
            },

            test("a folder with its switch off is offered, never taken") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let folders = MeetingFolderStore(root: root)
                var folder = try folders.create(name: "Weekly")
                folder.rule = FolderRule(titleIs: "Weekly sync", provider: .googleMeet)
                try folders.write(folder)

                let backend = FakeAIBackend()
                let run = try await processed(root: root, backend: backend, settings: AppSettings())

                guard let found = run.repository.findMeeting(id: run.metadata.id) else {
                    return expect.fail("the meeting went missing")
                }
                expect.isNil(found.metadata.folderName, "nothing moved")
                expect.equal(found.store.readFolderSuggestion()?.folderName, "Weekly")
            },

            test("what a model answers is written down and never acted on") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let folders = MeetingFolderStore(root: root)
                var folder = try folders.create(name: "Capital One", about: "Client work")
                // Switched on, to prove that a model's answer is refused even by
                // a folder that files everything it is allowed to.
                folder.filesAutomatically = true
                try folders.write(folder)

                let backend = FakeAIBackend()
                backend.enrichment = MeetingEnrichment(
                    summary: "Discussed the review.",
                    folderCandidates: [ModelFolderCandidate(
                        folderName: "Capital One", confidence: 0.9,
                        why: "their security review", quote: "The security review is still open.",
                        atSeconds: 1
                    )]
                )
                let run = try await processed(root: root, backend: backend, settings: AppSettings())

                guard let found = run.repository.findMeeting(id: run.metadata.id) else {
                    return expect.fail("the meeting went missing")
                }
                let suggestion = found.store.readFolderSuggestion()
                expect.equal(suggestion?.folderName, "Capital One")
                expect.equal(suggestion?.reason, .model)
                expect.equal(suggestion?.quote, "The security review is still open.")
                expect.isNil(found.metadata.folderName, "a model guess never files")
            },

            test("the folders are shown to the model, with what they are for") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let folders = MeetingFolderStore(root: root)
                try folders.create(name: "Capital One", about: "Client work with Capital One")

                let backend = FakeAIBackend()
                _ = try await processed(root: root, backend: backend, settings: AppSettings())

                expect.equal(backend.lastEnrichmentFolders?.count, 1)
                expect.equal(backend.lastEnrichmentFolders?.first?.name, "Capital One")
                expect.equal(
                    backend.lastEnrichmentFolders?.first?.about, "Client work with Capital One"
                )
            },

            test("recurring meetings only asks the model nothing about folders") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let folders = MeetingFolderStore(root: root)
                try folders.create(name: "Capital One", about: "Client work")

                var settings = AppSettings()
                settings.enrichment.folderReach = .recurringOnly
                let backend = FakeAIBackend()
                backend.enrichment = MeetingEnrichment(
                    summary: "Discussed the review.",
                    folderCandidates: [ModelFolderCandidate(
                        folderName: "Capital One", confidence: 0.99, why: "named throughout",
                        quote: "Capital One", atSeconds: 1
                    )]
                )
                let run = try await processed(root: root, backend: backend, settings: settings)

                expect.equal(backend.lastEnrichmentFolders?.isEmpty, true, "no catalogue was sent")
                guard let found = run.repository.findMeeting(id: run.metadata.id) else {
                    return expect.fail("the meeting went missing")
                }
                expect.isNil(
                    found.store.readFolderSuggestion(),
                    "an answer arriving anyway is still refused"
                )
            },
        ])
    }
}
