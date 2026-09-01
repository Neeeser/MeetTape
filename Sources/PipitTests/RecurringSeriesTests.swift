import Foundation
import PipitCore
import TestKit

/// The offer made after a meeting is filed by hand: what looks like this one,
/// and what rule would catch the rest.
enum RecurringSeriesTests {
    static func facts(
        _ title: String, provider: MeetingProvider = .slack, at minute: Int = 11 * 60 + 30,
        weekday: Int = 2, people: [String] = ["Andrew", "Chris Latimer", "Nate"],
        series: String? = nil
    ) -> MeetingFacts {
        MeetingFacts(
            title: title, provider: provider, calendarSeriesID: series,
            startMinute: minute, weekday: weekday, participantNames: people
        )
    }

    static var standups: [MeetingFacts] {
        (0..<13).map { index in
            facts("Hindsight Daily", at: 11 * 60 + 28 + (index % 5), weekday: 2 + (index % 5))
        }
    }

    static var suite: Suite {
        Suite("Recurring series", [
            test("thirteen meetings with one title propose a title and provider rule") { expect in
                let archive = standups + [facts("Tudor Meeting 2", at: 13 * 60 + 30)]
                guard let proposal = RecurringSeries.propose(
                    for: facts("Hindsight Daily"), among: archive
                ) else { return expect.fail("nothing proposed") }

                expect.equal(proposal.defaultTicks, [.title, .provider])
                expect.equal(proposal.lookalikeCount, 13, "the other meeting is not caught")
                let rule = proposal.rule(ticking: proposal.defaultTicks, from: facts("Hindsight Daily"))
                expect.equal(rule.titleIs, "Hindsight Daily")
                expect.equal(rule.provider, .slack)
                expect.isTrue(rule.weekdays.isEmpty, "the slot is offered, not assumed")
            },

            test("the slot clause covers every time they actually started") { expect in
                guard let proposal = RecurringSeries.propose(
                    for: facts("Hindsight Daily"), among: standups
                ) else { return expect.fail("nothing proposed") }
                // 11:28 through 11:32, padded by a quarter of an hour either way.
                expect.equal(proposal.window.after, 11 * 60 + 13)
                expect.equal(proposal.window.before, 11 * 60 + 47)
                expect.equal(proposal.weekdays, [2, 3, 4, 5, 6])
                let slot = proposal.rule(
                    ticking: [.title, .provider, .slot], from: facts("Hindsight Daily")
                )
                expect.isTrue(slot.matches(facts("Hindsight Daily", at: 11 * 60 + 45, weekday: 6)))
                expect.isFalse(
                    slot.matches(facts("Hindsight Daily", at: 16 * 60, weekday: 7)),
                    "a Saturday afternoon is not the standup"
                )
            },

            test("a calendar series is offered on its own") { expect in
                let archive = standups.map { fact -> MeetingFacts in
                    var copy = fact
                    copy.calendarSeriesID = "series-abc"
                    return copy
                }
                guard let proposal = RecurringSeries.propose(
                    for: facts("Standup", provider: .googleMeet, series: "series-abc"),
                    among: archive
                ) else { return expect.fail("nothing proposed") }
                expect.equal(proposal.defaultTicks, [.calendarSeries])
                let rule = proposal.rule(
                    ticking: proposal.defaultTicks,
                    from: facts("Standup", provider: .googleMeet, series: "series-abc")
                )
                expect.equal(rule.calendarSeriesIDs, ["series-abc"])
                expect.isNil(rule.titleIs, "the title changed once already")
            },

            test("two meetings that look alike are not a series") { expect in
                let archive = [facts("Kickoff", at: 9 * 60), facts("Kickoff", at: 9 * 60)]
                expect.isNil(RecurringSeries.propose(for: facts("Kickoff", at: 9 * 60), among: archive))
            },

            test("people who are always there are offered, one-offs are not") { expect in
                let archive = standups.enumerated().map { index, fact -> MeetingFacts in
                    var copy = fact
                    if index == 0 { copy.participantNames.append("Visitor") }
                    return copy
                }
                guard let proposal = RecurringSeries.propose(
                    for: facts("Hindsight Daily"), among: archive
                ) else { return expect.fail("nothing proposed") }
                expect.isFalse(proposal.participants.contains("Visitor"))
                expect.equal(proposal.participants.count, 2)
                let clause = proposal.clauses.first { $0.kind == .participants }
                expect.isFalse(clause?.isOnByDefault == true, "people are never ticked for you")
            },

            test("an empty rule admits nothing at all") { expect in
                expect.isFalse(FolderRule().matches(facts("Anything")))
            },
        ])
    }
}
