import Foundation

/// Where an imported recording's date came from.
///
/// Kept on the meeting so the archive can say whether the date is the one the
/// recorder wrote or the one the copy landed on. Nothing downstream branches on
/// it: a date is a date, and this exists to be shown.
public enum RecordedDateSource: String, Codable, Sendable, CaseIterable {
    /// The container's own creation date: QuickTime, MP4, ID3 or iTunes.
    case fileMetadata = "file_metadata"
    /// A timestamp in the filename, which is what most voice recorders write.
    case filename
    /// The file's creation date on this Mac.
    case fileCreated = "file_created"
    /// Nothing said when it was recorded, so the import time stands in.
    case importTime = "import_time"

    public var displayName: String {
        switch self {
        case .fileMetadata: "from the file's own timestamp"
        case .filename: "from the filename"
        case .fileCreated: "from the file's date on this Mac"
        case .importTime: "when it was imported"
        }
    }

    /// Whether the date is the recorder's own statement rather than a stand-in.
    public var isOriginal: Bool {
        switch self {
        case .fileMetadata, .filename: true
        case .fileCreated, .importTime: false
        }
    }
}

public struct RecordedDate: Sendable, Equatable {
    public var date: Date
    public var source: RecordedDateSource

    public init(date: Date, source: RecordedDateSource) {
        self.date = date
        self.source = source
    }
}

/// Decides when an imported recording was actually made.
///
/// An imported file's creation date on this Mac is the moment it was copied,
/// not the moment it was recorded: AirDrop, a download and a copy off a phone
/// all stamp today. The recorder itself says the real date in two places, and
/// both are read before the filesystem is believed.
public enum RecordedDatePolicy {
    /// 1990-01-01. Below this the value is a default a container wrote rather
    /// than a recording anybody made.
    public static let earliest = Date(timeIntervalSince1970: 631_152_000)

    /// A day of slack, because a file written by a device whose clock runs
    /// ahead is still a real recording.
    public static let futureTolerance: TimeInterval = 86_400

    public static func isPlausible(_ date: Date, now: Date) -> Bool {
        date >= earliest && date <= now.addingTimeInterval(futureTolerance)
    }

    /// The first candidate that could be a recording date, in order of how much
    /// the recorder had to say about it.
    ///
    /// The filename outranks the filesystem: a file named
    /// "2026-08-15 09.12.33.m4a" copied today carries the recorder's own
    /// statement, and the copy's creation date carries today's.
    public static func choose(
        metadata: Date?, filename: Date?, fileCreated: Date?, now: Date
    ) -> RecordedDate {
        let candidates: [(Date?, RecordedDateSource)] = [
            (metadata, .fileMetadata),
            (filename, .filename),
            (fileCreated, .fileCreated),
        ]
        for (date, source) in candidates {
            guard let date, isPlausible(date, now: now) else { continue }
            return RecordedDate(date: date, source: source)
        }
        return RecordedDate(date: now, source: .importTime)
    }

    /// A date and, where the name carries one, a time, out of a filename.
    ///
    /// Covers what recorders actually write: "2026-08-15 09.12.33",
    /// "20260815_091233", "2026-08-15T09-12-33" and the bare date. A run of
    /// digits that is not a date fails on the calendar rather than on the
    /// shape, so a unix timestamp in a filename is not read as the year 1234.
    ///
    /// A candidate the calendar refuses is followed by the next one along. Some
    /// recorders write a serial number in front of the date, and that run of
    /// digits matches the shape and swallows the date behind it.
    public static func dateInFilename(
        _ name: String, calendar: Calendar = .current
    ) -> Date? {
        let stem = (name as NSString).deletingPathExtension
        let pattern = filenamePattern
        let length = (stem as NSString).length
        var from = 0
        while from < length {
            // Transparent bounds so the digit guards either side of the pattern
            // still see the characters before the point the search resumed
            // from. Without them, resuming inside a run of digits reads the
            // tail of that run as a year.
            guard let match = pattern.firstMatch(
                in: stem, options: [.withTransparentBounds, .withoutAnchoringBounds],
                range: NSRange(location: from, length: length - from)
            ) else { return nil }
            // One character past the start of this candidate, rather than past
            // the whole span it matched. A run of digits matches the time group
            // as well and takes the date after it into the match.
            from = match.range.location + 1

            func number(_ index: Int) -> Int? {
                let group = match.range(at: index)
                guard group.location != NSNotFound, let swiftRange = Range(group, in: stem) else {
                    return nil
                }
                return Int(stem[swiftRange])
            }
            guard let year = number(1), let month = number(2), let day = number(3) else { continue }

            let hour = number(4)
            // A name that carries no time lands at midday rather than at
            // midnight, so a date read in one time zone and shown in another
            // stays on the day the recorder named.
            if let date = resolve(
                year: year, month: month, day: day,
                hour: hour ?? 12, minute: number(5) ?? 0, second: number(6) ?? 0,
                calendar: calendar
            ) {
                return date
            }
            // A time no clock shows does not take the date with it. Names carry
            // a duration where a time would sit, and "2026-08-15 47-12" is
            // still the fifteenth: 47 hours rolls the date two days forward and
            // the day check then threw the whole name away.
            if hour != nil, let date = resolve(
                year: year, month: month, day: day, hour: 12, minute: 0, second: 0,
                calendar: calendar
            ) {
                return date
            }
        }
        return nil
    }

    /// The date those numbers name, or nil where the calendar does not hold it.
    ///
    /// The day is checked back out of the result, because `date(from:)` rolls a
    /// component past its range into the next one rather than refusing it.
    private static func resolve(
        year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int,
        calendar: Calendar
    ) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date)
                  == DateComponents(year: year, month: month, day: day)
        else { return nil }
        return date
    }

    /// A date out of a metadata string, for the containers that store one as
    /// text rather than as a date.
    ///
    /// A value with no day in it is refused. "2026" alone would put a meeting
    /// on the first of January, which is worse than saying nothing.
    public static func parseMetadataDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for formatter in isoFormatters {
            if let date = formatter.date(from: trimmed) { return date }
        }
        for formatter in textFormatters {
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    // MARK: - parsers

    /// Built per call rather than held: `NSRegularExpression` and
    /// `DateFormatter` are reference types the language will not call Sendable,
    /// and this runs a handful of times per import.
    private static var filenamePattern: NSRegularExpression {
        // Year, month and day with any of the usual separators or none, then an
        // optional time. The digit guards either side stop a longer run of
        // digits being read as a date.
        let pattern =
            "(?<![0-9])([0-9]{4})[-_.:]?([0-9]{2})[-_.:]?([0-9]{2})"
            + "(?:[T _-]+([0-9]{2})[-_.:]?([0-9]{2})(?:[-_.:]?([0-9]{2}))?)?(?![0-9])"
        // The pattern is a literal, so a failure here is a programming error
        // rather than anything a file can cause.
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("filename date pattern does not compile")
        }
        return expression
    }

    private static var isoFormatters: [ISO8601DateFormatter] {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [plain, fractional]
    }

    /// The shapes QuickTime, EXIF and ID3 write when they do not write ISO 8601.
    private static var textFormatters: [DateFormatter] {
        ["yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd HH:mm:ss", "yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd"]
            .map { format in
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = format
                return formatter
            }
    }
}
