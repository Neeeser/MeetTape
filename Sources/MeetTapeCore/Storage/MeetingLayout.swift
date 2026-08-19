import Foundation

/// Every path inside one meeting directory.
///
/// The archive is ordinary files in ordinary folders. Deleting MeetTape leaves a
/// readable recording, a readable transcript and readable notes behind.
public struct MeetingLayout: Sendable, Equatable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var segments: URL { root.appendingPathComponent("segments", isDirectory: true) }
    public var manifest: URL { segments.appendingPathComponent("manifest.jsonl") }
    public var metadata: URL { root.appendingPathComponent("metadata.json") }
    public var rawTranscript: URL { root.appendingPathComponent("transcript.raw.json") }
    /// Who spoke when, as the diarizer produced it. Immutable, and separate from
    /// the words because the two come from independently chosen backends and
    /// re-analysing speakers must never invalidate a transcription.
    public var rawDiarization: URL { root.appendingPathComponent("diarization.raw.json") }
    public var speakerMap: URL { root.appendingPathComponent("speakers.map.json") }
    public var canonicalTranscript: URL { root.appendingPathComponent("transcript.json") }
    public var transcriptMarkdown: URL { root.appendingPathComponent("transcript.md") }
    public var notes: URL { root.appendingPathComponent("notes.md") }
    public var summary: URL { root.appendingPathComponent("summary.md") }
    public var mixedAudio: URL { root.appendingPathComponent("mixed.caf") }
    /// Raw API responses, kept verbatim as ground truth for what the model said.
    public var apiResponses: URL { root.appendingPathComponent("api", isDirectory: true) }
    /// Imported originals live here untouched.
    public var originals: URL { root.appendingPathComponent("original", isDirectory: true) }

    public func segmentFile(track: CaptureTrack, index: Int) -> URL {
        segments.appendingPathComponent(String(format: "%@.%04d.caf", track.segmentPrefix, index))
    }

    public func segmentFileName(track: CaptureTrack, index: Int) -> String {
        String(format: "%@.%04d.caf", track.segmentPrefix, index)
    }

    public func apiResponseFile(named name: String) -> URL {
        apiResponses.appendingPathComponent(name)
    }
}

/// Builds meeting directory identifiers and locates them under the archive root.
public struct MeetingArchiveLayout: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static var defaultRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Documents/MeetTape/Meetings", isDirectory: true)
    }

    public func directory(forMeetingID id: String, startedAt: Date) -> URL {
        let components = Calendar.current.dateComponents([.year, .month], from: startedAt)
        let year = String(format: "%04d", components.year ?? 1970)
        let month = String(format: "%02d", components.month ?? 1)
        return root
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    public func layout(forMeetingID id: String, startedAt: Date) -> MeetingLayout {
        MeetingLayout(root: directory(forMeetingID: id, startedAt: startedAt))
    }

    /// `2026-08-18-1418-slack-engineering-huddle`
    public static func meetingID(startedAt: Date, source: MeetingSource, title: String?) -> String {
        let stamp = timestampSlug(startedAt)
        let sourceSlug = slugify(source.rawValue)
        let titleSlug = title.map { slugify($0) } ?? ""
        let parts = [stamp, sourceSlug, titleSlug].filter { !$0.isEmpty }
        return parts.joined(separator: "-")
    }

    public static func timestampSlug(_ date: Date) -> String {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date
        )
        return String(
            format: "%04d-%02d-%02d-%02d%02d",
            components.year ?? 1970, components.month ?? 1, components.day ?? 1,
            components.hour ?? 0, components.minute ?? 0
        )
    }

    /// Lowercase ASCII, hyphen separated, bounded length. Non-ASCII titles fold to
    /// their closest ASCII form so the directory name stays typeable.
    public static func slugify(_ text: String, maxLength: Int = 48) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        var out = ""
        var lastWasSeparator = true
        for character in folded {
            if character.isLetter || character.isNumber, character.isASCII {
                out.append(character)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                out.append("-")
                lastWasSeparator = true
            }
            if out.count >= maxLength { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// A directory name that does not collide with an existing one.
    public func uniqueMeetingID(base: String, startedAt: Date) -> String {
        var candidate = base
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory(forMeetingID: candidate, startedAt: startedAt).path) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}
