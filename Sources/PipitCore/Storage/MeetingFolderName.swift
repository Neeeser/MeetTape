import Foundation

/// What a meeting's folder is called in Finder.
///
/// The identifier names the meeting to the application; this names it to the
/// person browsing `~/Documents/Pipit/Meetings`. Title first, because a one-off
/// meeting is remembered by its title and a recurring one is remembered by its
/// series, and both are found faster when the title is what the eye lands on.
/// The date follows so that a daily standup has forty distinguishable folders
/// instead of forty collisions.
///
/// `Hindsight Daily (Aug 18, 9:02 AM)`
public enum MeetingFolderName {
    /// The longest a title may run inside a folder name.
    private static let titleLimit = 60

    /// How far back a cut may search for a space before giving up and cutting
    /// mid-word.
    private static let wordBoundaryReach = 12

    /// The name for a meeting, before uniqueness is applied.
    public static func base(for metadata: MeetingMetadata) -> String {
        base(
            title: metadata.titles.resolvedOrigin == "timestamp"
                // `displayTitle` is "Manual recording, Aug 18, 2026 at 2:18 PM"
                // in this case, and using it would write the date twice.
                ? metadata.source.displayName
                : metadata.displayTitle,
            source: metadata.source,
            startedAt: metadata.startedAt
        )
    }

    /// The rules, reachable without a whole metadata document.
    public static func base(
        title: String,
        source: MeetingSource,
        startedAt: Date
    ) -> String {
        var name = sanitize(title)
        if name.isEmpty { name = sanitize(source.displayName) }
        if name.isEmpty { name = "Recording" }
        let suffix = " (\(stamp(startedAt)))"
        return fitToFilesystem(name, suffix: suffix) + suffix
    }

    /// The most bytes a single path component may take on macOS.
    private static let nameLimit = 255

    /// Trims the title until the whole name fits `NAME_MAX`.
    ///
    /// The character cap above is about readability. This is about the folder
    /// being creatable at all: a title of sixty emoji is sixty characters and
    /// two hundred and forty bytes, and with the date after it `createMeeting`
    /// threw and the recording never started.
    private static func fitToFilesystem(_ name: String, suffix: String) -> String {
        let budget = nameLimit - suffix.utf8.count
        guard budget > 0 else { return "Recording" }
        var fitted = name
        while fitted.utf8.count > budget, !fitted.isEmpty {
            fitted.removeLast()
        }
        let trimmed = trim(fitted)
        return trimmed.isEmpty ? "Recording" : trimmed
    }

    /// `Aug 03, 9:02 AM`
    ///
    /// Fixed English rather than the system locale, so changing the Mac's
    /// region does not leave two naming styles in one archive. The day is
    /// padded because within a month folder an unpadded `Aug 3` sorts after
    /// `Aug 18`, which breaks the one ordering title-first naming exists to
    /// give.
    public static func stamp(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents(
            [.month, .day, .hour, .minute], from: date
        )
        let month = monthAbbreviations[max(1, min(12, parts.month ?? 1)) - 1]
        let hour24 = parts.hour ?? 0
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        let period = hour24 < 12 ? "AM" : "PM"
        return String(
            format: "%@ %02d, %d:%02d %@",
            month, parts.day ?? 1, hour12, parts.minute ?? 0, period
        )
    }

    private static let monthAbbreviations = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// A title reduced to something a folder can be called.
    ///
    /// Case, spaces and accented letters survive. `MeetingArchiveLayout.slugify`
    /// folds those away because the names it builds are typed at a shell; these
    /// are read in Finder, so `Café sync` stays as written.
    private static func sanitize(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        for character in text {
            // Both break a macOS path: `/` is the separator, and `:` is still
            // translated to one by the Finder.
            if character == "/" || character == ":" {
                out.append(pendingSpace && !out.isEmpty ? " -" : "-")
                pendingSpace = false
                continue
            }
            if character.isNewline || character.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(character)
        }
        return trim(truncate(trim(out)))
    }

    /// A leading dot hides the folder, and trailing punctuation reads as an
    /// accident.
    private static func trim(_ text: String) -> String {
        var value = Substring(text)
        while let first = value.first, first == "." || first.isWhitespace {
            value = value.dropFirst()
        }
        while let last = value.last,
              last.isWhitespace || last == "." || last == "-" || last == "," || last == ";" {
            value = value.dropLast()
        }
        return String(value)
    }

    /// Cut at a word boundary when one is close to the limit, so a name ends on
    /// a whole word rather than mid-syllable.
    private static func truncate(_ text: String) -> String {
        guard text.count > titleLimit else { return text }
        let cut = text.index(text.startIndex, offsetBy: titleLimit)
        let head = text[text.startIndex..<cut]
        if let space = head.lastIndex(of: " "),
           head.distance(from: space, to: head.endIndex) <= wordBoundaryReach {
            return String(head[head.startIndex..<space])
        }
        return String(head)
    }
}
