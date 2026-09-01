import Foundation
import PipitCore
import TestKit

/// Which folder a finished meeting is offered, and when it is offered nothing.
///
/// The silences are the point. A ladder that finds a home for every meeting is
/// a ladder that gets turned off, so the cases that must stay quiet are pinned
/// as hard as the ones that must fire.
enum FolderMatchTests {
    static func facts(
        _ title: String,
        provider: MeetingProvider = .slack,
        series: String? = nil,
        at minute: Int = 11 * 60 + 31,
        weekday: Int = 2,
        people: [String] = ["Andrew", "Chris Latimer", "Nate"],
        excluding: [String] = []
    ) -> MeetingFacts {
        MeetingFacts(
            title: title, provider: provider, calendarSeriesID: series,
            startMinute: minute, weekday: weekday, participantNames: people,
            excludedFolders: excluding
        )
    }

    /// A standup folder: thirteen Slack huddles called the same thing, all on
    /// weekday mornings.
    static func standup(
        filesAutomatically: Bool = true, series: String? = nil
    ) -> FolderProfile {
        let members = (0..<13).map { index in
            facts(
                "Hindsight Daily", series: series,
                at: 11 * 60 + 28 + (index % 5), weekday: 2 + (index % 5)
            )
        }
        return FolderProfile(
            name: "Hindsight Daily", about: "The weekday standup",
            filesAutomatically: filesAutomatically, members: members
        )
    }

    static func client() -> FolderProfile {
        FolderProfile(
            name: "Capital One", about: "Client work with Capital One",
            members: [
                facts("Hindsight <> Capital One", provider: .googleMeet, at: 14 * 60, weekday: 3,
                      people: ["Andrew", "Chris Latimer", "Brian McNamara"]),
                facts("Brian McNamara, Chris Latimer", provider: .googleMeet, at: 12 * 60 + 34,
                      weekday: 6, people: ["Chris Latimer", "Brian McNamara"]),
            ]
        )
    }

    static var suite: Suite {
        Suite("Folder matching", [
            test("the same title on the same provider is the folder's next meeting") { expect in
                let match = FolderMatcher.recurrence(
                    of: facts("Hindsight Daily"), in: [standup(), client()]
                )
                expect.equal(match?.folderName, "Hindsight Daily")
                expect.equal(match?.reason, .title)
                expect.equal(match?.confidence, 0.95)
                expect.isTrue(match?.reason.mayFileWithoutAsking == true)
            },

            test("a calendar series wins even when the title has changed") { expect in
                let folder = standup(series: "series-abc")
                let match = FolderMatcher.recurrence(
                    of: facts("Standup", provider: .googleMeet, series: "series-abc"),
                    in: [folder, client()]
                )
                expect.equal(match?.folderName, "Hindsight Daily")
                expect.equal(match?.reason, .calendarSeries)
                expect.equal(match?.confidence, 1.0)
            },

            test("the same slot and people carry a meeting with a different title") { expect in
                let match = FolderMatcher.recurrence(
                    of: facts("Morning sync", at: 11 * 60 + 34, weekday: 3),
                    in: [standup(), client()]
                )
                expect.equal(match?.folderName, "Hindsight Daily")
                expect.equal(match?.reason, .slot)
                expect.equal(match?.confidence, 0.8)
            },

            test("the slot clause is weaker on a weekday the folder never meets") { expect in
                let match = FolderMatcher.recurrence(
                    of: facts("Morning sync", at: 11 * 60 + 34, weekday: 7),
                    in: [standup()]
                )
                expect.equal(match?.reason, .slot)
                expect.equal(match?.confidence, 0.6)
                expect.isFalse(
                    FolderMatcher.mayFileWithoutAsking(match, in: [standup()]),
                    "0.6 is under the filing floor"
                )
            },

            test("a title match far outside the folder's slot is offered, not filed") { expect in
                let match = FolderMatcher.recurrence(
                    of: facts("Hindsight Daily", at: 16 * 60 + 12, weekday: 7, people: ["Andrew", "Chris Latimer"]),
                    in: [standup()]
                )
                expect.equal(match?.reason, .title)
                expect.equal(match?.confidence, 0.7)
                expect.isFalse(FolderMatcher.mayFileWithoutAsking(match, in: [standup()]))
            },

            test("a folder with two members is not yet a series") { expect in
                // Capital One holds two meetings with different titles. Nothing
                // about a third Google Meet makes it the next one.
                let match = FolderMatcher.recurrence(
                    of: facts("Quarterly planning", provider: .googleMeet, at: 9 * 60, weekday: 4,
                              people: ["Andrew"]),
                    in: [client()]
                )
                expect.isNil(match)
            },

            test("a folder the meeting was taken out of is never offered again") { expect in
                let match = FolderMatcher.recurrence(
                    of: facts("Hindsight Daily", excluding: ["Hindsight Daily"]),
                    in: [standup()]
                )
                expect.isNil(match)
            },

            test("a model answer becomes a suggestion that may not file") { expect in
                let match = FolderMatcher.fromModel(
                    [ModelFolderCandidate(
                        folderName: "Capital One", confidence: 0.82,
                        why: "twelve minutes on their security review",
                        quote: "their security review is still open", atSeconds: 51.4
                    )],
                    meeting: facts("Ray Mauge and Chris Latimer + Brian McNamara"),
                    profiles: [standup(), client()], reach: .clearTopics
                )
                expect.equal(match?.folderName, "Capital One")
                expect.equal(match?.reason, .model)
                expect.equal(match?.quote, "their security review is still open")
                expect.isFalse(match?.reason.mayFileWithoutAsking == true)
                expect.isFalse(
                    FolderMatcher.mayFileWithoutAsking(match, in: [standup(), client()]),
                    "a model guess never files, whatever the folder switch says"
                )
            },

            test("two folders within a tenth of each other produce nothing") { expect in
                let match = FolderMatcher.fromModel(
                    [
                        ModelFolderCandidate(
                            folderName: "Capital One", confidence: 0.84, why: "Chris is in it",
                            quote: "Chris said", atSeconds: 4
                        ),
                        ModelFolderCandidate(
                            folderName: "Hindsight Daily", confidence: 0.79, why: "Chris is in it too",
                            quote: "Chris said", atSeconds: 4
                        ),
                    ],
                    meeting: facts("Chris Latimer"),
                    profiles: [standup(), client()], reach: .clearTopics
                )
                expect.isNil(match)
            },

            test("an answer under the reach floor is not shown") { expect in
                let candidate = ModelFolderCandidate(
                    folderName: "Capital One", confidence: 0.62, why: "they came up once",
                    quote: "Capital One", atSeconds: 12
                )
                expect.isNil(FolderMatcher.fromModel(
                    [candidate], meeting: facts("Chris Latimer"),
                    profiles: [client()], reach: .clearTopics
                ))
                expect.equal(
                    FolderMatcher.fromModel(
                        [candidate], meeting: facts("Chris Latimer"),
                        profiles: [client()], reach: .anyLikely
                    )?.folderName,
                    "Capital One"
                )
            },

            test("an answer with no quote behind it is dropped") { expect in
                expect.isNil(FolderMatcher.fromModel(
                    [ModelFolderCandidate(
                        folderName: "Capital One", confidence: 0.9, why: "it felt like them"
                    )],
                    meeting: facts("Chris Latimer"),
                    profiles: [client()], reach: .clearTopics
                ))
            },

            test("no model answer is taken when the reach is recurring meetings only") { expect in
                expect.isNil(FolderMatcher.fromModel(
                    [ModelFolderCandidate(
                        folderName: "Capital One", confidence: 0.99, why: "named throughout",
                        quote: "Capital One", atSeconds: 3
                    )],
                    meeting: facts("Chris Latimer"),
                    profiles: [client()], reach: .recurringOnly
                ))
            },

            test("a folder the model invented is not offered") { expect in
                expect.isNil(FolderMatcher.fromModel(
                    [ModelFolderCandidate(
                        folderName: "Fico", confidence: 0.95, why: "a new client",
                        quote: "Fico", atSeconds: 8
                    )],
                    meeting: facts("First Fico Meeting"),
                    profiles: [standup(), client()], reach: .clearTopics
                ))
            },
        ])
    }
}
