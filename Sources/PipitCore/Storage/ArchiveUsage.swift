import Foundation

/// What the meeting archive costs on disk.
///
/// The models tell you their size in Settings and the recordings did not, which
/// is backwards: the models are a fixed few gigabytes and the archive is the
/// part that grows with every call.
public struct ArchiveUsage: Sendable, Equatable {
    /// Allocated bytes rather than file bytes, because allocated bytes are what
    /// the volume loses. A meeting folder holds a dozen small JSON files where
    /// the two differ by a block each.
    public var bytes: Int64
    /// Meetings as the Meetings window counts them, so the number matches what
    /// the user can see. A recording folded into another one is part of a
    /// meeting, not a meeting.
    public var meetingCount: Int
    /// Free space on the volume the archive is on. Nil when the volume did not
    /// answer, which is what a network mount does.
    public var freeBytes: Int64?

    public init(bytes: Int64 = 0, meetingCount: Int = 0, freeBytes: Int64? = nil) {
        self.bytes = bytes
        self.meetingCount = meetingCount
        self.freeBytes = freeBytes
    }
}

extension MeetingRepository {
    /// Walks the archive and measures it.
    ///
    /// File-bound work over every meeting ever recorded, so callers run it off
    /// whichever actor they are on and show the last answer while it runs.
    public func usage() -> ArchiveUsage {
        var usage = ArchiveUsage(freeBytes: Self.freeBytes(on: archive.root))
        for directory in meetingDirectories() {
            usage.bytes += Self.allocatedBytes(of: directory)
            guard let metadata = try? MeetingStore(layout: MeetingLayout(root: directory))
                .readMetadata()
            else { continue }
            if metadata.mergedIntoMeetingID == nil { usage.meetingCount += 1 }
        }
        return usage
    }

    static func allocatedBytes(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private static func freeBytes(on url: URL) -> Int64? {
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
