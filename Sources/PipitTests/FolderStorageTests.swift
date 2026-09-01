import Foundation
import PipitCore
import TestKit

/// Filing a meeting moves its directory. These pin what has to survive that:
/// the identifier, the listing, and the agreement between where a meeting sits
/// and what its metadata says about where it sits.
enum FolderStorageTests {
    static func archive() throws -> (root: URL, repository: MeetingRepository, folders: MeetingFolderStore) {
        let root = try ManifestTests.makeTemporaryDirectory()
        return (root, MeetingRepository(root: root), MeetingFolderStore(root: root))
    }

    static func meeting(
        _ repository: MeetingRepository, title: String, hour: Int = 11, minute: Int = 31,
        day: Int = 18
    ) throws -> MeetingMetadata {
        let started = MeetingFolderNameTests.date(
            year: 2026, month: 8, day: day, hour: hour, minute: minute
        )
        let created = try repository.createMeeting(
            source: .slackHuddle, provider: .slack, startedAt: started,
            titles: TitleCandidates(provider: title, timestampFallback: "f"), now: started
        )
        return try created.store.updateMetadata { $0.processing = ProcessingStatus(state: .complete) }
    }

    static var suite: Suite {
        Suite("Folder storage", [
            test("a new folder is a directory with a manifest beside its meetings") { expect in
                let (root, _, store) = try archive()
                defer { try? FileManager.default.removeItem(at: root) }
                let folder = try store.create(name: "Hindsight Daily", about: "The weekday standup")
                expect.equal(folder.name, "Hindsight Daily")
                expect.isTrue(store.exists("Hindsight Daily"))
                let manifest = root
                    .appendingPathComponent("Folders/Hindsight Daily/folder.json")
                expect.isTrue(FileManager.default.fileExists(atPath: manifest.path))
                expect.equal(store.folder(named: "Hindsight Daily")?.about, "The weekday standup")
            },

            test("a folder somebody made in Finder is still a folder") { expect in
                let (root, _, store) = try archive()
                defer { try? FileManager.default.removeItem(at: root) }
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent("Folders/Made By Hand"),
                    withIntermediateDirectories: true
                )
                expect.equal(store.folders().map(\.name), ["Made By Hand"])
                expect.equal(store.folder(named: "Made By Hand")?.filesAutomatically, false)
            },

            test("a name already taken, and a name that is not a name, are refused") { expect in
                let (root, _, store) = try archive()
                defer { try? FileManager.default.removeItem(at: root) }
                try store.create(name: "Tudor")
                expect.throwsError(MeetingFolderError.folderExists("Tudor")) {
                    try store.create(name: "Tudor")
                }
                expect.throwsError(MeetingFolderError.invalidFolderName("   ")) {
                    try store.create(name: "   ")
                }
                expect.throwsError(MeetingFolderError.invalidFolderName("Folders")) {
                    try store.create(name: "Folders")
                }
            },

            test("renaming a folder moves the directory and keeps what it holds") { expect in
                let (root, repository, store) = try archive()
                defer { try? FileManager.default.removeItem(at: root) }
                try store.create(name: "Cap One", about: "Client work")
                let created = try meeting(repository, title: "Kickoff")
                try repository.move(meetingID: created.id, toFolder: "Cap One")
                try store.rename("Cap One", to: "Capital One")

                expect.isFalse(store.exists("Cap One"))
                expect.equal(store.folder(named: "Capital One")?.about, "Client work")
                expect.equal(repository.meetings(inFolder: "Capital One").count, 1)
                // The directory moved with the folder, and the identifier still
                // reaches it.
                expect.equal(repository.findMeeting(id: created.id)?.metadata.id, created.id)
            },

            test("filing a meeting moves its directory and records where it went") { expect in
                let (root, repository, store) = try archive()
                defer { try? FileManager.default.removeItem(at: root) }
                try store.create(name: "Hindsight Daily")
                let created = try meeting(repository, title: "Hindsight Daily")
                let before = repository.findMeeting(id: created.id)?.store.layout.root
                expect.isTrue(before?.path.contains("/2026/08/") == true, "starts under the month")

                let moved = try repository.move(meetingID: created.id, toFolder: "Hindsight Daily")
                expect.equal(
                    moved.deletingLastPathComponent().lastPathComponent, "Hindsight Daily"
                )
                expect.equal(moved.lastPathComponent, "Hindsight Daily (Aug 18, 11:31 AM)")
                let found = repository.findMeeting(id: created.id)
                expect.equal(found?.store.layout.root, moved)
                expect.equal(found?.metadata.folderName, "Hindsight Daily")
                expect.equal(found?.metadata.id, created.id, "the identifier did not change")
                expect.equal(repository.listMeetings().count, 1, "still one meeting, once")
            },

            test("taking a meeting out puts it back under the month it was recorded") { expect in
                let (root, repository, store) = try archive()
                defer { try? FileManager.default.removeItem(at: root) }
                try store.create(name: "Tudor")
                let created = try meeting(repository, title: "Tudor Meeting 2")
                try repository.move(meetingID: created.id, toFolder: "Tudor")
                let out = try repository.move(meetingID: created.id, toFolder: nil)

                expect.isTrue(out.path.contains("/2026/08/"), "got \(out.path)")
                let found = repository.findMeeting(id: created.id)
                expect.isNil(found?.metadata.folderName)
                expect.equal(found?.metadata.removedFromFolders, ["Tudor"])
                expect.equal(repository.meetings(inFolder: "Tudor").count, 0)
            },

            test("a meeting still being processed is not moved") { expect in
                let (root, repository, store) = try archive()
                defer { try? FileManager.default.removeItem(at: root) }
                try store.create(name: "Tudor")
                let started = MeetingFolderNameTests.date(
                    year: 2026, month: 8, day: 18, hour: 9, minute: 0
                )
                let created = try repository.createMeeting(
                    source: .slackHuddle, provider: .slack, startedAt: started, now: started
                )
                expect.throwsError(MeetingFolderError.meetingIsBusy(created.metadata.id)) {
                    try repository.move(meetingID: created.metadata.id, toFolder: "Tudor")
                }

                let done = try meeting(repository, title: "Finished", hour: 15)
                expect.throwsError(MeetingFolderError.folderNotFound("Nowhere")) {
                    try repository.move(meetingID: done.id, toFolder: "Nowhere")
                }
                expect.throwsError(MeetingFolderError.meetingNotFound("nobody")) {
                    try repository.move(meetingID: "nobody", toFolder: "Tudor")
                }
            },

            test("a filed meeting renamed by enrichment stays in its folder") { expect in
                let (root, repository, store) = try archive()
                defer { try? FileManager.default.removeItem(at: root) }
                try store.create(name: "Hindsight Daily")
                let created = try meeting(repository, title: "Huddle in #eng")
                try repository.move(meetingID: created.id, toFolder: "Hindsight Daily")

                guard let found = repository.findMeeting(id: created.id) else {
                    return expect.fail("the meeting went missing")
                }
                _ = try found.store.updateMetadata { $0.titles.human = "Hindsight Daily" }
                guard let settled = repository.settleFolderName(
                    for: repository.findMeeting(id: created.id)!.metadata
                ) else { return expect.fail("nothing settled") }

                expect.equal(settled.lastPathComponent, "Hindsight Daily (Aug 18, 11:31 AM)")
                expect.equal(
                    settled.deletingLastPathComponent().lastPathComponent, "Hindsight Daily",
                    "renaming must not drag it back to the month"
                )
                expect.equal(
                    repository.findMeeting(id: created.id)?.metadata.folderName, "Hindsight Daily"
                )
            },
        ])
    }
}
