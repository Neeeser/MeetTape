import Foundation
import MeetTapeCore
import TestKit

/// Which calendar entry may name a meeting.
enum CalendarMatchTests {
    private static let start = Date(timeIntervalSince1970: 1_787_000_000)

    private static func candidate(
        _ title: String, offsetMinutes: Double, durationMinutes: Double,
        isAllDay: Bool = false, haystack: String = ""
    ) -> CalendarCandidate {
        let began = start.addingTimeInterval(offsetMinutes * 60)
        return CalendarCandidate(
            identifier: title, title: title, startDate: began,
            endDate: began.addingTimeInterval(durationMinutes * 60),
            isAllDay: isAllDay, haystack: haystack
        )
    }

    static var suite: Suite {
        Suite("CalendarMatch", [
            test("a shift that contains the recording does not name it") { expect in
                // Measured: a 38-second recording was titled "5-10" and two
                // others "12-5", after the shifts they happened during. A
                // containing event covered the whole recording, which scored the
                // maximum overlap available, so the longest entry of the day won
                // every time.
                let shift = candidate("12-5", offsetMinutes: -120, durationMinutes: 300)
                let match = CalendarMatchPolicy.best(
                    among: [shift], startedAt: start,
                    endedAt: start.addingTimeInterval(38),
                    meetingURL: nil, providerMeetingID: nil
                )
                expect.isTrue(match == nil, "got \(match?.candidate.title ?? "nil")")
            },

            test("an all-day entry does not name a meeting") { expect in
                let holiday = candidate(
                    "Out of office", offsetMinutes: -600, durationMinutes: 1_440, isAllDay: true
                )
                expect.isTrue(
                    CalendarMatchPolicy.best(
                        among: [holiday], startedAt: start,
                        endedAt: start.addingTimeInterval(1_800),
                        meetingURL: nil, providerMeetingID: nil
                    ) == nil
                )
            },

            test("the real meeting still wins against the block it sits inside") { expect in
                let shift = candidate("12-5", offsetMinutes: -120, durationMinutes: 300)
                let standup = candidate("Platform standup", offsetMinutes: 0, durationMinutes: 30)
                let match = try expect.unwrap(CalendarMatchPolicy.best(
                    among: [shift, standup], startedAt: start,
                    endedAt: start.addingTimeInterval(1_500),
                    meetingURL: nil, providerMeetingID: nil
                ))
                expect.equal(match.candidate.title, "Platform standup")
            },

            test("recording the tail of a meeting still matches it") { expect in
                // Joining late is ordinary, and the recording then covers a
                // fraction of the event. Timing is still what identifies it.
                let review = candidate("Design review", offsetMinutes: -25, durationMinutes: 30)
                let match = try expect.unwrap(CalendarMatchPolicy.best(
                    among: [review], startedAt: start,
                    endedAt: start.addingTimeInterval(300),
                    meetingURL: nil, providerMeetingID: nil
                ))
                expect.equal(match.candidate.title, "Design review")
            },

            test("an invitation naming this meeting names it whatever its length") { expect in
                // A day-long workshop with the Meet link in the invitation is
                // the meeting, and the link says so where timing cannot.
                let workshop = candidate(
                    "Onboarding workshop", offsetMinutes: -60, durationMinutes: 480,
                    haystack: "https://meet.google.com/abc-defg-hij"
                )
                let match = try expect.unwrap(CalendarMatchPolicy.best(
                    among: [workshop], startedAt: start,
                    endedAt: start.addingTimeInterval(1_800),
                    meetingURL: nil, providerMeetingID: "abc-defg-hij"
                ))
                expect.equal(match.candidate.title, "Onboarding workshop")
                expect.isTrue(
                    match.score >= 0.7, "the invitation is decisive on its own"
                )
            },
        ])
    }
}
