import Foundation
import PipitCore
import TestKit

enum MeetingFolderNameTests {
    /// Built through `Calendar.current` so the expected stamp holds in any
    /// timezone the tests run in.
    static func date(
        year: Int, month: Int, day: Int, hour: Int, minute: Int
    ) -> Date {
        Calendar.current.date(
            from: DateComponents(
                year: year, month: month, day: day, hour: hour, minute: minute
            )
        ) ?? Date(timeIntervalSince1970: 0)
    }

    static var suite: Suite {
        Suite("Meeting folder names", [
            test("a title leads and the date follows") { expect in
                let name = MeetingFolderName.base(
                    title: "Pricing model rework",
                    source: .googleMeet,
                    startedAt: date(year: 2026, month: 8, day: 18, hour: 14, minute: 18)
                )
                expect.equal(name, "Pricing model rework (Aug 18, 2:18 PM)")
            },

            test("the day is padded so a series sorts by date") { expect in
                let third = MeetingFolderName.base(
                    title: "Hindsight Daily",
                    source: .slackHuddle,
                    startedAt: date(year: 2026, month: 8, day: 3, hour: 9, minute: 2)
                )
                let eighteenth = MeetingFolderName.base(
                    title: "Hindsight Daily",
                    source: .slackHuddle,
                    startedAt: date(year: 2026, month: 8, day: 18, hour: 9, minute: 0)
                )
                expect.equal(third, "Hindsight Daily (Aug 03, 9:02 AM)")
                expect.isTrue(third < eighteenth, "\(third) should sort before \(eighteenth)")
            },

            test("midnight and noon read as 12") { expect in
                expect.equal(
                    MeetingFolderName.stamp(
                        date(year: 2026, month: 1, day: 1, hour: 0, minute: 5)
                    ),
                    "Jan 01, 12:05 AM"
                )
                expect.equal(
                    MeetingFolderName.stamp(
                        date(year: 2026, month: 12, day: 31, hour: 12, minute: 0)
                    ),
                    "Dec 31, 12:00 PM"
                )
            },

            test("path-breaking characters are replaced and the rest survives") { expect in
                let name = MeetingFolderName.base(
                    title: "Q3/Q4 planning: Café \u{1F389}\nreview",
                    source: .zoom,
                    startedAt: date(year: 2026, month: 8, day: 18, hour: 14, minute: 18)
                )
                expect.isFalse(name.contains("/"), "got \(name)")
                expect.isFalse(name.contains(":") && !name.contains(", 2:18"), "got \(name)")
                expect.isFalse(name.contains("\n"), "got \(name)")
                expect.isTrue(name.contains("Café"), "accents should survive, got \(name)")
                expect.isTrue(name.contains("\u{1F389}"), "emoji should survive, got \(name)")
                expect.isTrue(name.hasSuffix("(Aug 18, 2:18 PM)"), "got \(name)")
            },

            test("a long title is cut at a word boundary") { expect in
                let title = String(repeating: "alpha bravo ", count: 12)
                let name = MeetingFolderName.base(
                    title: title,
                    source: .manual,
                    startedAt: date(year: 2026, month: 8, day: 18, hour: 14, minute: 18)
                )
                let head = String(name.prefix(while: { $0 != "(" }))
                    .trimmingCharacters(in: .whitespaces)
                expect.isTrue(head.count <= 60, "got \(head.count): \(head)")
                expect.isFalse(head.hasSuffix(" "), "got \(head)")
                expect.isTrue(
                    head.hasSuffix("alpha") || head.hasSuffix("bravo"),
                    "should end on a whole word, got \(head)"
                )
            },

            test("a name of multi-byte characters still fits a path component") { expect in
                // 60 characters of emoji is 240 bytes before the date is added,
                // and NAME_MAX is 255, so capping on characters alone made
                // createMeeting throw and the recording never start.
                let name = MeetingFolderName.base(
                    title: String(repeating: "\u{1F389}", count: 200),
                    source: .zoom,
                    startedAt: date(year: 2026, month: 8, day: 18, hour: 14, minute: 18)
                )
                expect.isTrue(name.utf8.count <= 255, "got \(name.utf8.count) bytes")
                expect.isTrue(name.hasSuffix("(Aug 18, 2:18 PM)"), "got \(name)")

                let cjk = MeetingFolderName.base(
                    title: String(repeating: "\u{4F1A}\u{8B70}", count: 60),
                    source: .zoom,
                    startedAt: date(year: 2026, month: 8, day: 18, hour: 14, minute: 18)
                )
                expect.isTrue(cjk.utf8.count <= 255, "got \(cjk.utf8.count) bytes")
            },

            test("a title that sanitizes away falls back to the source") { expect in
                let name = MeetingFolderName.base(
                    title: "  ...  ",
                    source: .manual,
                    startedAt: date(year: 2026, month: 8, day: 20, hour: 15, minute: 14)
                )
                expect.equal(name, "Manual recording (Aug 20, 3:14 PM)")
            },

            test("an unnamed meeting does not write the date twice") { expect in
                let started = date(year: 2026, month: 8, day: 20, hour: 15, minute: 14)
                var metadata = MeetingMetadata(
                    id: "x",
                    source: .manual,
                    provider: .unknown,
                    createdAt: started,
                    startedAt: started,
                    titles: TitleCandidates(
                        timestampFallback: MeetingRepository.timestampTitle(
                            startedAt: started, source: .manual
                        )
                    )
                )
                expect.equal(metadata.titles.resolvedOrigin, "timestamp")
                expect.equal(
                    MeetingFolderName.base(for: metadata),
                    "Manual recording (Aug 20, 3:14 PM)"
                )

                metadata.titles.ai = "Weekly retro"
                expect.equal(
                    MeetingFolderName.base(for: metadata),
                    "Weekly retro (Aug 20, 3:14 PM)"
                )
            },
        ])
    }
}
