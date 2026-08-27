import Foundation
import PipitCore
import TestKit

/// Telling the summary and the generated notes apart again, on the way out of
/// one file.
enum SummaryDocumentTests {
    static var suite: Suite {
        Suite("SummaryDocument", [
            test("both sections come back separately") { expect in
                let document = SummaryDocument(
                    markdown: "## Summary\n\nWe agreed on the pilot.\n\n## Notes\n\n- Chris sends the list."
                )
                expect.equal(document.summary, "We agreed on the pilot.")
                expect.equal(document.generatedNotes, "- Chris sends the list.")
            },

            test("a summary written without notes leaves the notes empty") { expect in
                let document = SummaryDocument(markdown: "## Summary\n\nWe agreed on the pilot.")
                expect.equal(document.summary, "We agreed on the pilot.")
                expect.isNil(document.generatedNotes)
            },

            test("notes written without a summary read as notes") { expect in
                // Notes on with summaries off is a real setting, so a file that
                // opens with the notes heading is a real file. It used to read
                // as the summary, which put the notes on the Summary tab with
                // the heading showing in the body.
                let document = SummaryDocument(markdown: "## Notes\n\n- Chris sends the list.")
                expect.equal(document.generatedNotes, "- Chris sends the list.")
                expect.isNil(document.summary)
            },

            test("a notes heading inside legacy prose is not a boundary") { expect in
                // Only at the very start of the file. A summary written before
                // the split whose prose happens to mention the words is still
                // one summary, and moving half of it to another tab would be
                // worse than leaving the words where they are.
                let text = "We agreed on the pilot.\n\n## Notes were taken by Chris."
                expect.equal(SummaryDocument(markdown: text).summary, text)
            },

            test("a heading is only a heading when the line ends there") { expect in
                // A legacy summary can open with those words in a sentence. It
                // is a summary, and reading it as notes would put the whole
                // meeting on a tab the user has no reason to open.
                let text = "## Notes were taken by Chris and sent round afterwards."
                let document = SummaryDocument(markdown: text)
                expect.equal(document.summary, text)
                expect.isNil(document.generatedNotes)
            },

            test("a notes-only document round-trips") { expect in
                let original = SummaryDocument(generatedNotes: "- Chris sends the list.")
                expect.equal(SummaryDocument(markdown: original.markdown), original)
            },

            test("a file with no heading reads as the summary") { expect in
                // Every summary.md written before the split, and any a person
                // edited by hand. It has always shown on the Summary tab and
                // still does.
                let document = SummaryDocument(markdown: "Call with Capital One about retrieval.")
                expect.equal(document.summary, "Call with Capital One about retrieval.")
                expect.isNil(document.generatedNotes)
            },

            test("an empty file is an empty document") { expect in
                expect.isTrue(SummaryDocument(markdown: "").isEmpty)
                expect.isTrue(SummaryDocument(markdown: "   \n\n  ").isEmpty)
            },

            test("a heading with nothing under it is not a section") { expect in
                let document = SummaryDocument(markdown: "## Summary\n\n\n## Notes\n\n- One.")
                expect.isNil(document.summary, "an empty heading became an empty summary")
                expect.equal(document.generatedNotes, "- One.")
            },

            test("a heading inside the prose does not split the file") { expect in
                // The notes carry markdown of their own. Only the first notes
                // heading after the summary heading is a boundary.
                let document = SummaryDocument(
                    markdown: "## Summary\n\nWe agreed.\n\n## Notes\n\n- One.\n\n## Notes\n\n- Two."
                )
                expect.equal(document.summary, "We agreed.")
                expect.equal(document.generatedNotes, "- One.\n\n## Notes\n\n- Two.")
            },

            test("what enrichment writes reads back unchanged") { expect in
                let original = SummaryDocument(
                    summary: "We agreed on the pilot.", generatedNotes: "- Chris sends the list."
                )
                expect.equal(SummaryDocument(markdown: original.markdown), original)
            },
        ])
    }
}
