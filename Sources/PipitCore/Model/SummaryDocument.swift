import Foundation

/// The two things enrichment writes into `summary.md`, told apart again.
///
/// One file rather than two, because the model produces both in one response
/// and a reader opening the folder should find one document rather than a pair
/// that has to be read together. The app shows them on different tabs, so the
/// split happens on the way out.
///
/// Parsed rather than stored separately so every meeting already on disk reads
/// correctly with nothing migrated. The headings are ours: `runEnrichment`
/// writes exactly `## Summary` and `## Notes`, and anything else in the file
/// was put there by a person and belongs to the summary, which is where an
/// older file's whole contents went.
public struct SummaryDocument: Sendable, Equatable {
    public var summary: String?
    /// What the model wrote as notes. Never the user's own notes, which live in
    /// `notes.md` and which enrichment does not touch.
    public var generatedNotes: String?

    public init(summary: String? = nil, generatedNotes: String? = nil) {
        self.summary = summary
        self.generatedNotes = generatedNotes
    }

    /// Whether there is anything worth writing. A model asked for a summary can
    /// answer with an empty string, and a file holding two headings and no
    /// prose is worse than no file.
    public var isEmpty: Bool { markdown.isEmpty }

    private static let summaryHeading = "## Summary"
    private static let notesHeading = "## Notes"

    public init(markdown: String) {
        let text = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // A file with no heading at all predates the split, or was edited by
        // hand. It reads as the summary, which is the tab it has always shown
        // on.
        guard let summaryRange = text.range(of: Self.summaryHeading) else {
            summary = text
            return
        }

        let afterSummary = text[summaryRange.upperBound...]
        if let notesRange = afterSummary.range(of: Self.notesHeading) {
            summary = Self.clean(afterSummary[..<notesRange.lowerBound])
            generatedNotes = Self.clean(afterSummary[notesRange.upperBound...])
        } else {
            summary = Self.clean(afterSummary)
        }

        // A heading with nothing under it is not a section. Enrichment skips a
        // part it was not asked for rather than writing an empty one, but a
        // response that came back blank could still produce one.
        if summary?.isEmpty == true { summary = nil }
        if generatedNotes?.isEmpty == true { generatedNotes = nil }
    }

    private static func clean(_ piece: Substring) -> String {
        String(piece).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The file as enrichment writes it. The inverse of `init(markdown:)` for
    /// anything this type produced.
    public var markdown: String {
        var parts: [String] = []
        if let summary, !summary.isEmpty { parts.append("\(Self.summaryHeading)\n\n\(summary)") }
        if let generatedNotes, !generatedNotes.isEmpty {
            parts.append("\(Self.notesHeading)\n\n\(generatedNotes)")
        }
        return parts.joined(separator: "\n\n")
    }
}
