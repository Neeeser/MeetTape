import Foundation
import MeetTapeCore
import MeetTapeServices
import MeetTapeUI
import TestKit

/// A call that dropped and was rejoined is two recordings and one meeting.
///
/// The rule these pin: linking them moves no audio and hides nothing. Both
/// recordings keep every file they had, the conversation reads as one in time
/// order, and being wrong about the link is undoable.
enum ReconnectTests {
    /// Two recordings fifteen minutes apart, the second linked to the first.
    private static func makeSplitMeeting(
        root: URL, link: Bool = true
    ) throws -> (repository: MeetingRepository, first: String, second: String) {
        let repository = MeetingRepository(root: root)
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let first = try repository.createMeeting(
            source: .googleMeet, provider: .googleMeet, startedAt: started,
            titles: TitleCandidates(provider: "Weekly sync", timestampFallback: "f"),
            now: started
        )
        let second = try repository.createMeeting(
            source: .googleMeet, provider: .googleMeet,
            startedAt: started.addingTimeInterval(900),
            titles: TitleCandidates(provider: "Weekly sync", timestampFallback: "f"),
            now: started.addingTimeInterval(900)
        )

        _ = try first.store.updateMetadata { $0.durationSeconds = 600 }
        _ = try second.store.updateMetadata {
            $0.durationSeconds = 1_500
            $0.possibleContinuationOf = first.metadata.id
            $0.possibleContinuationReason = "same meeting, 15 minutes later"
        }
        try first.store.writeCanonicalTranscript(CanonicalTranscript(
            generatedAt: started,
            utterances: [
                Utterance(
                    id: "a1", start: 0, end: 5, track: .remote, rawSpeakerLabel: nil,
                    speakerKey: "remote-001_speaker_00", text: "before the drop",
                    chunkID: "c", model: "m"
                ),
            ]
        ))
        try second.store.writeCanonicalTranscript(CanonicalTranscript(
            generatedAt: started.addingTimeInterval(900),
            utterances: [
                Utterance(
                    id: "b1", start: 0, end: 5, track: .remote, rawSpeakerLabel: nil,
                    speakerKey: "remote-001_speaker_00", text: "after the rejoin",
                    chunkID: "c", model: "m"
                ),
            ]
        ))
        var secondMap = SpeakerMap()
        secondMap.assign("Priya", to: "remote-001_speaker_00")
        try second.store.writeSpeakerMap(secondMap)

        if link {
            _ = try second.store.updateMetadata {
                $0.mergedIntoMeetingID = first.metadata.id
                $0.possibleContinuationOf = nil
            }
            _ = try first.store.updateMetadata {
                $0.absorbedMeetingIDs = [second.metadata.id]
            }
        }
        return (repository, first.metadata.id, second.metadata.id)
    }

    static var suite: Suite {
        Suite("Reconnect", [
            test("both halves are one meeting, in the order they happened") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let (repository, first, second) = try makeSplitMeeting(root: root)

                let logical = try expect.unwrap(repository.logicalMeeting(id: first))
                expect.equal(logical.recordings.map(\.metadata.id), [first, second])
                expect.close(
                    logical.durationSeconds, 2_100, tolerance: 0.001,
                    "the conversation holds both recordings' audio"
                )

                let lines = logical.combinedTranscript()
                expect.equal(
                    lines.map(\.utterance.text), ["before the drop", "after the rejoin"]
                )
                expect.close(
                    lines[1].timelineStart, 900, tolerance: 0.001,
                    "the second half is placed by when its recording started"
                )
                expect.equal(
                    lines[1].speakerName, "Priya",
                    "and resolved through its own speaker map, not the first half's"
                )
                expect.equal(
                    lines[0].speakerName, "Speaker 1",
                    "the same key in the other recording is a different person"
                )
            },

            test("the folded half is reachable by its own identifier") { expect in
                // A notification posted before the two were linked still carries
                // it, and Reveal in Finder is built from it. Resolving to nothing
                // was how the second half of a dropped call became unreachable.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let (repository, first, second) = try makeSplitMeeting(root: root)

                let logical = try expect.unwrap(repository.logicalMeeting(id: second))
                expect.equal(
                    logical.id, first,
                    "asking about the continuation answers with the whole conversation"
                )
                expect.isTrue(
                    logical.combinedTranscript().contains { $0.utterance.text == "after the rejoin" }
                )
            },

            test("recent meetings shows one row for the whole conversation") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let (repository, first, _) = try makeSplitMeeting(root: root)

                let listed = repository.listMeetings()
                expect.equal(listed.map(\.id), [first])
                let summary = try expect.unwrap(listed.first)
                expect.equal(summary.recordingCount, 2)
                expect.close(
                    summary.durationSeconds, 2_100, tolerance: 0.001,
                    "and reports the audio both halves hold, not just the first"
                )
            },

            test("separating a continuation gives back two meetings and loses nothing") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let (repository, first, second) = try makeSplitMeeting(root: root)
                let secondDirectory = try expect.unwrap(
                    repository.findMeeting(id: second, includingMerged: true)?.store.layout.root
                )

                await MainActor.run {
                    let runtime = MeetTapeRuntime(settingsDirectory: root)
                    var settings = runtime.settings
                    settings.storageRootPath = root.path
                    runtime.update(settings: settings)
                    runtime.detachContinuation(meetingID: second)
                }

                let listed = repository.listMeetings()
                expect.equal(
                    Set(listed.map(\.id)), Set([first, second]),
                    "both are their own meeting again"
                )
                expect.equal(
                    listed.first { $0.id == first }?.recordingCount, 1
                )
                expect.close(
                    listed.first { $0.id == first }?.durationSeconds ?? 0, 600, tolerance: 0.001,
                    "and the first reports only its own audio again"
                )
                expect.isTrue(
                    FileManager.default.fileExists(atPath: secondDirectory.path),
                    "nothing was moved, so the second recording is where it always was"
                )
                let reopened = try expect.unwrap(repository.findMeeting(id: second))
                expect.isTrue(
                    ((try? reopened.store.readCanonicalTranscript()) ?? nil)?.utterances
                        .contains { $0.text == "after the rejoin" } ?? false
                )
            },

            test("linking does not rewrite either recording's own duration") { expect in
                // Adding the second half into the first recording's stored total
                // made undoing the link a subtraction, and a subtraction that goes
                // wrong reports a duration no file supports.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let (repository, first, second) = try makeSplitMeeting(root: root, link: false)

                await MainActor.run {
                    let runtime = MeetTapeRuntime(settingsDirectory: root)
                    var settings = runtime.settings
                    settings.storageRootPath = root.path
                    runtime.update(settings: settings)
                    runtime.combine(meetingID: second, into: first, reason: "test")
                }

                let stored = try expect.unwrap(repository.findMeeting(id: first))
                expect.close(
                    stored.metadata.durationSeconds, 600, tolerance: 0.001,
                    "the recording still reports the audio it holds"
                )
                expect.equal(stored.metadata.absorbedMeetingIDs, [second])
                expect.close(
                    repository.logicalMeeting(id: first)?.durationSeconds ?? 0, 2_100,
                    tolerance: 0.001,
                    "and the conversation reports both, derived rather than stored"
                )
            },
        ])
    }
}
