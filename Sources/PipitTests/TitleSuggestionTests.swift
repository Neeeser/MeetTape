import Foundation
import PipitCore
import TestKit

/// When the generated title is offered to the user, and when it is not.
///
/// A generated title exists on nearly every processed meeting, so the rule
/// deciding which of them ask a question is the whole feature.
enum TitleSuggestionTests {
    static func metadata(_ titles: TitleCandidates) -> MeetingMetadata {
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        return MeetingMetadata(
            id: "m1", source: .slackHuddle, provider: .slack,
            createdAt: started, startedAt: started, titles: titles
        )
    }

    static var suite: Suite {
        Suite("Title suggestions", [
            test("a meeting named by its huddle is offered the generated title") { expect in
                var titles = TitleCandidates(timestampFallback: "f")
                titles.provider = "Huddle in #engineering"
                titles.ai = "Pricing model rework"
                expect.equal(metadata(titles).titleSuggestion, "Pricing model rework")
            },

            test("a meeting named by a calendar event is offered it too") { expect in
                var titles = TitleCandidates(timestampFallback: "f")
                titles.calendar = "Weekly sync"
                titles.ai = "Pricing model rework"
                expect.equal(metadata(titles).titleSuggestion, "Pricing model rework")
            },

            test("an imported file is offered it against its filename") { expect in
                var titles = TitleCandidates(timestampFallback: "f")
                titles.filename = "Board meeting Aug 12"
                titles.ai = "Quarterly financial review"
                expect.equal(metadata(titles).titleSuggestion, "Quarterly financial review")
            },

            test("nothing is offered when the generated title already won") { expect in
                var titles = TitleCandidates(timestampFallback: "f")
                titles.window = "Meet - abc-defg-hij"
                titles.ai = "Pricing model rework"
                expect.equal(titles.resolvedOrigin, "ai")
                expect.isNil(metadata(titles).titleSuggestion)
            },

            test("nothing is offered once the user has named it themselves") { expect in
                var titles = TitleCandidates(timestampFallback: "f")
                titles.provider = "Huddle in #engineering"
                titles.ai = "Pricing model rework"
                titles.human = "Renewal call"
                expect.isNil(metadata(titles).titleSuggestion)
            },

            test("nothing is offered when no title was generated") { expect in
                var titles = TitleCandidates(timestampFallback: "f")
                titles.provider = "Huddle in #engineering"
                expect.isNil(metadata(titles).titleSuggestion)
                titles.ai = "   "
                expect.isNil(metadata(titles).titleSuggestion)
            },

            test("nothing is offered when it only differs by case") { expect in
                var titles = TitleCandidates(timestampFallback: "f")
                titles.provider = "Pricing model rework"
                titles.ai = "Pricing Model Rework"
                expect.isNil(metadata(titles).titleSuggestion)
            },

            test("nothing is offered when only stray whitespace separates them") { expect in
                var titles = TitleCandidates(timestampFallback: "f")
                titles.provider = "Pricing model rework  "
                titles.ai = "Pricing model rework"
                expect.isNil(metadata(titles).titleSuggestion)
            },

            test("declining settles it, and leaves the generated title on disk") { expect in
                var titles = TitleCandidates(timestampFallback: "f")
                titles.provider = "Huddle in #engineering"
                titles.ai = "Pricing model rework"
                var found = metadata(titles)
                expect.isTrue(found.titleSuggestion != nil)

                found.generatedTitleDeclined = true
                expect.isNil(found.titleSuggestion)
                // The fallback survives: clearing a title of their own later
                // still lands on the generated one rather than a timestamp.
                expect.equal(found.titles.ai, "Pricing model rework")
                found.titles.provider = nil
                expect.equal(found.displayTitle, "Pricing model rework")
            },

            test("accepting outranks the name it was offered against") { expect in
                var titles = TitleCandidates(timestampFallback: "f")
                titles.provider = "Huddle in #engineering"
                titles.ai = "Pricing model rework"
                var found = metadata(titles)
                let suggestion = found.titleSuggestion
                expect.equal(suggestion, "Pricing model rework")

                // What the runtime writes on Use it.
                found.titles.human = suggestion
                expect.equal(found.displayTitle, "Pricing model rework")
                expect.isNil(found.titleSuggestion, "and the offer is gone")
                expect.equal(
                    MeetingFolderName.base(for: found),
                    "Pricing model rework (\(MeetingFolderName.stamp(found.startedAt)))",
                    "so the folder follows"
                )
            },
        ])
    }
}
