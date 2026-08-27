import Foundation

/// Clearing up a meeting folder that a write put back after the meeting left
/// the archive.
///
/// Every write to a meeting goes through `AtomicFile`, which creates the
/// directories it needs. A job still running when the user moves a meeting to
/// the Trash therefore recreates the folder as a row holding whatever that one
/// stage wrote, and nothing says where it came from.
///
/// The date tells that scrap apart from the meeting itself. A folder written
/// after the move is scrap. A folder older than the move is the meeting, put
/// back from the Trash, and it is left exactly where it is.
public enum RecreatedFolder {
    /// What was found at the path, and what was done about it.
    public enum Verdict: Sendable, Equatable {
        /// Nothing there. The move is the last thing that touched the path.
        case absent
        /// Written after the move, so it was scrap and it is gone.
        case removed
        /// Older than the move. The meeting itself, put back from the Trash.
        case predatesTheMove
        /// There, but the volume reports no creation date, so it is kept.
        case undatable
    }

    /// How far a creation date may sit before the move and still count as
    /// written after it.
    ///
    /// HFS+ stores whole seconds and exFAT stores hundredths, so a folder
    /// written a moment after the move can report a moment before it. A meeting
    /// was created when it started recording, which is minutes to years
    /// earlier, so nothing real sits inside this.
    public static let grain: TimeInterval = 2

    /// Removes what is at `url` when it was written after `movedAt`.
    ///
    /// A folder whose date cannot be read is kept. Not every volume reports a
    /// creation date, and removing one that cannot be dated would take a
    /// meeting somebody had just put back, which has no way back.
    @discardableResult
    public static func discard(at url: URL, writtenAfter movedAt: Date) -> Verdict {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let created = creationDate(of: url) else { return .undatable }
        guard created >= movedAt.addingTimeInterval(-grain) else { return .predatesTheMove }
        try? FileManager.default.removeItem(at: url)
        return .removed
    }

    static func creationDate(of url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date
    }
}
