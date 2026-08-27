import Foundation

/// A name the cloud model heard someone called, offered for confirmation.
///
/// Never written into `speakers.map.json`. That file holds what the meeting
/// concluded. This holds what a model proposes about the part the meeting could
/// not conclude, and the two are kept apart so accepting one is an ordinary
/// human assignment rather than a machine origin the user has to unpick later.
public struct SpeakerNameSuggestion: Sendable, Equatable, Codable, Identifiable {
    /// The speaker key this names, in the meeting's own namespace.
    public var label: String
    public var name: String
    /// The model's own score, kept for the ordering and the band and never
    /// shown as a percentage. A cosine similarity and a model confidence are
    /// both numbers a reader would misread as a probability.
    public var confidence: Double
    /// The line that earned the guess, verbatim from the transcript.
    ///
    /// Required rather than optional: a name with nothing behind it is the
    /// failure mode this whole design exists to keep off screen, and dropping
    /// it at the boundary is cheaper than explaining it in the UI.
    public var quote: String
    /// Where that line starts, in seconds from the beginning of the meeting.
    public var atSeconds: Double
    /// Whether the full name came from the calendar invite rather than from
    /// the words. Worth saying, because it is the one part of the suggestion
    /// that was not heard out loud.
    public var expandedFromCalendar: Bool

    public var id: String { label }

    public init(
        label: String, name: String, confidence: Double, quote: String,
        atSeconds: Double, expandedFromCalendar: Bool = false
    ) {
        self.label = label
        self.name = name
        self.confidence = confidence
        self.quote = quote
        self.atSeconds = atSeconds
        self.expandedFromCalendar = expandedFromCalendar
    }

    /// The floor a suggestion has to clear to be drawn.
    ///
    /// Higher than the 0.35 the old auto-apply path used. That number was
    /// picked for a name being written for you, where a wrong one is worse than
    /// a missing one. This one is picked for a pill dismissed by hand, where a
    /// pill dismissed every meeting is worse than no pill at all.
    public static let minimumConfidence = 0.5

    public var band: SpeakerConfidenceBand {
        confidence >= 0.8 ? .high : .medium
    }
}

/// Every suggestion for one meeting, as written to `raw/speaker.suggestions.json`.
public struct SpeakerSuggestionSet: Sendable, Equatable, Codable {
    public var version: Int
    public var suggestions: [SpeakerNameSuggestion]
    /// Labels the user said no to. Kept so a re-run does not offer the same
    /// wrong name again, the way `SpeakerMap.clearedKeys` keeps a cleared name
    /// from being written back.
    public var dismissedLabels: [String]
    public var generatedAt: Date?

    public init(
        version: Int = 1, suggestions: [SpeakerNameSuggestion] = [],
        dismissedLabels: [String] = [], generatedAt: Date? = nil
    ) {
        self.version = version
        self.suggestions = suggestions
        self.dismissedLabels = dismissedLabels
        self.generatedAt = generatedAt
    }

    /// What the speaker strip should draw, given who still has no name.
    ///
    /// Filtered here rather than at the view, so the pipeline, the window model
    /// and any future caller all answer the same question the same way. A label
    /// that has since been named by hand drops out on its own, which is what
    /// makes accepting one pill remove exactly that pill.
    public func visible(forUnnamed unnamed: Set<String>) -> [SpeakerNameSuggestion] {
        let dismissed = Set(dismissedLabels)
        return suggestions
            .filter { unnamed.contains($0.label) }
            .filter { !dismissed.contains($0.label) }
            .filter { $0.confidence >= SpeakerNameSuggestion.minimumConfidence }
            .filter { !$0.name.isEmpty && !$0.quote.isEmpty }
            .sorted { $0.confidence > $1.confidence }
    }

    public mutating func dismiss(_ label: String) {
        guard !dismissedLabels.contains(label) else { return }
        dismissedLabels.append(label)
    }
}
