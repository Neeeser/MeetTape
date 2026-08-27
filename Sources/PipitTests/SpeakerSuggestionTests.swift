import Foundation
import PipitCore
import TestKit

/// The gate between what a model proposes and what the speaker strip draws.
///
/// Every rule here exists because the alternative is a wrong name on screen
/// asking to be accepted, which is worse than no name at all.
enum SpeakerSuggestionTests {

    static func suggestion(
        _ label: String, _ name: String, confidence: Double = 0.9,
        quote: String = "Ben, do you want to take this?", atSeconds: Double = 12
    ) -> SpeakerNameSuggestion {
        SpeakerNameSuggestion(
            label: label, name: name, confidence: confidence, quote: quote, atSeconds: atSeconds
        )
    }

    static var suite: Suite {
        Suite("SpeakerSuggestions", [
            test("a suggestion is drawn only for a speaker who still has no name") { expect in
                let set = SpeakerSuggestionSet(suggestions: [
                    suggestion("speaker_00", "Ben"),
                    suggestion("speaker_01", "Joe"),
                ])
                // speaker_01 was named by hand after the model answered, so its
                // pill goes away without anything having to delete it.
                let visible = set.visible(forUnnamed: ["speaker_00"])
                expect.equal(visible.count, 1)
                expect.equal(visible.first?.name, "Ben")
            },

            test("a dismissed label is not offered again") { expect in
                var set = SpeakerSuggestionSet(suggestions: [suggestion("speaker_00", "Ben")])
                expect.equal(set.visible(forUnnamed: ["speaker_00"]).count, 1)
                set.dismiss("speaker_00")
                expect.isTrue(
                    set.visible(forUnnamed: ["speaker_00"]).isEmpty,
                    "a name turned down came back"
                )
                // A second dismissal of the same label must not grow the list.
                set.dismiss("speaker_00")
                expect.equal(set.dismissedLabels.count, 1)
            },

            test("a re-run keeps dismissals but replaces the suggestions") { expect in
                var set = SpeakerSuggestionSet(suggestions: [suggestion("speaker_00", "Ben")])
                set.dismiss("speaker_00")
                set.suggestions = [
                    suggestion("speaker_00", "Benjamin"), suggestion("speaker_02", "Nicolo"),
                ]
                let visible = set.visible(forUnnamed: ["speaker_00", "speaker_02"])
                expect.equal(visible.count, 1, "the dismissed speaker came back under a new name")
                expect.equal(visible.first?.name, "Nicolo")
            },

            test("a guess below the floor is not drawn") { expect in
                let set = SpeakerSuggestionSet(suggestions: [
                    suggestion("speaker_00", "Ben", confidence: 0.49),
                    suggestion("speaker_01", "Joe", confidence: 0.5),
                ])
                let visible = set.visible(forUnnamed: ["speaker_00", "speaker_01"])
                expect.equal(visible.count, 1)
                expect.equal(visible.first?.name, "Joe", "the floor is inclusive")
            },

            test("a name with no line behind it is dropped") { expect in
                let set = SpeakerSuggestionSet(suggestions: [
                    suggestion("speaker_00", "Ben", quote: ""),
                    suggestion("speaker_01", "", quote: "Thanks Joe."),
                ])
                expect.isTrue(
                    set.visible(forUnnamed: ["speaker_00", "speaker_01"]).isEmpty,
                    "a suggestion with no quote or no name reached the strip"
                )
            },

            test("the most confident guess is drawn first") { expect in
                let set = SpeakerSuggestionSet(suggestions: [
                    suggestion("speaker_00", "Ben", confidence: 0.62),
                    suggestion("speaker_01", "Joe", confidence: 0.94),
                ])
                let visible = set.visible(forUnnamed: ["speaker_00", "speaker_01"])
                expect.equal(visible.map(\.name), ["Joe", "Ben"])
            },

            test("the band reads as a word rather than a percentage") { expect in
                expect.equal(suggestion("s", "Ben", confidence: 0.94).band, .high)
                expect.equal(suggestion("s", "Ben", confidence: 0.62).band, .medium)
            },

            test("a meeting with no suggestions file reads as an empty set") { expect in
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("pipit-suggestions-\(UUID().uuidString)")
                let store = MeetingStore(layout: MeetingLayout(root: directory))
                try store.createDirectories()
                defer { try? FileManager.default.removeItem(at: directory) }

                expect.isTrue(store.readSpeakerSuggestions().suggestions.isEmpty)

                try store.writeSpeakerSuggestions(
                    SpeakerSuggestionSet(suggestions: [suggestion("speaker_00", "Ben")])
                )
                let read = store.readSpeakerSuggestions()
                expect.equal(read.suggestions.count, 1)
                expect.equal(read.suggestions.first?.quote, "Ben, do you want to take this?")
                // Never in the speaker map: that file is what the meeting
                // concluded, and this is a proposal about what it could not.
                expect.isTrue(try store.readSpeakerMap().entries.isEmpty)
            },

            test("metadata written before the missing-key flag existed still decodes") { expect in
                // Every meeting already on disk lacks this key. Decoding one as
                // a failure would make the whole archive unreadable.
                let json = """
                {"state":"complete","updatedAt":"2026-08-26T16:00:29.792Z",
                 "attempts":{"enriching":1},"completedStages":["recording","enriching"]}
                """
                let status = try ArchiveCoding.decode(
                    ProcessingStatus.self, from: Data(json.utf8), path: "metadata.json"
                )
                expect.equal(status.state, .complete)
                expect.isFalse(status.skippedForMissingKey)
            },
        ])
    }
}
