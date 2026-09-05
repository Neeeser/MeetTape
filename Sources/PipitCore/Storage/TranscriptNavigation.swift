import Foundation

/// Where the reader is being taken in a transcript: through one speaker's
/// turns, or through the places a word appears.
///
/// Pure data over the display blocks, so stepping and counting are decided
/// without a view and tested directly. The view scrolls to `current` and
/// tints the matches.
public struct TranscriptNavigation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Every turn by one resolved name inside one recording. Names are only
        /// comparable within a recording's own diarization.
        case speaker(name: String, recordingID: String)
        /// Every occurrence of a query, case-insensitively.
        case find(String)
    }

    /// One place to land: a block, and for a search the characters inside its
    /// paragraph, as UTF-16 offsets for the text view that draws them.
    public struct Target: Equatable, Sendable {
        public var blockID: String
        public var location: Int
        public var length: Int

        public init(blockID: String, location: Int = 0, length: Int = 0) {
            self.blockID = blockID
            self.location = location
            self.length = length
        }
    }

    public var kind: Kind
    public var targets: [Target]
    public var index: Int

    public var current: Target? { targets.indices.contains(index) ? targets[index] : nil }

    /// What the strip says: the speaker's name, or the words looked for.
    public var label: String {
        switch kind {
        case .speaker(let name, _): name
        case .find(let query): query
        }
    }

    /// "2 of 7", or "0 of 0" for a search with nothing to show.
    public var counter: String {
        targets.isEmpty ? "0 of 0" : "\(index + 1) of \(targets.count)"
    }

    public var isSearch: Bool {
        if case .find = kind { return true }
        return false
    }

    /// Wraps at either end, so the last turn is followed by the first.
    public mutating func next() {
        guard !targets.isEmpty else { return }
        index = (index + 1) % targets.count
    }

    public mutating func previous() {
        guard !targets.isEmpty else { return }
        index = (index - 1 + targets.count) % targets.count
    }

    /// The matches inside one block, for tinting, and which of them is the
    /// current one.
    public func matches(in blockID: String) -> (all: [Target], current: Target?) {
        let all = targets.filter { $0.blockID == blockID }
        let current = current.flatMap { $0.blockID == blockID ? $0 : nil }
        return (all, current)
    }

    public static func speaker(
        _ name: String, recordingID: String, in blocks: [CombinedLineBlock]
    ) -> TranscriptNavigation {
        let targets = blocks
            .filter { $0.recordingID == recordingID && $0.speakerName == name }
            .map { Target(blockID: $0.id) }
        return TranscriptNavigation(kind: .speaker(name: name, recordingID: recordingID), targets: targets, index: 0)
    }

    /// Every occurrence in reading order. A query of only whitespace finds
    /// nothing rather than every character.
    public static func find(_ query: String, in blocks: [CombinedLineBlock]) -> TranscriptNavigation {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var targets: [Target] = []
        if !needle.isEmpty {
            for block in blocks {
                let text = block.paragraph().text as NSString
                var searchFrom = 0
                while searchFrom < text.length {
                    let found = text.range(
                        of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                        range: NSRange(location: searchFrom, length: text.length - searchFrom)
                    )
                    guard found.location != NSNotFound else { break }
                    targets.append(Target(blockID: block.id, location: found.location, length: found.length))
                    searchFrom = found.location + max(found.length, 1)
                }
            }
        }
        return TranscriptNavigation(kind: .find(query), targets: targets, index: 0)
    }

    /// The same search again after the transcript changed, kept on the same
    /// place where it still exists.
    public func refreshed(in blocks: [CombinedLineBlock]) -> TranscriptNavigation {
        var fresh: TranscriptNavigation
        switch kind {
        case .speaker(let name, let recordingID): fresh = .speaker(name, recordingID: recordingID, in: blocks)
        case .find(let query): fresh = .find(query, in: blocks)
        }
        if let current, let kept = fresh.targets.firstIndex(of: current) { fresh.index = kept }
        return fresh
    }
}
