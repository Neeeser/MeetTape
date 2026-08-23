import Foundation

/// Moves a meeting folder from the pre-`raw/` layout to the current one.
///
/// The old layout kept every application file at the root and the manifest
/// inside `segments/`. This moves each file to its current home, one rename at
/// a time, so a crash partway through resumes on the next run: every step is
/// skipped when its source is already gone. Audio is not transcoded here;
/// `mixed.caf` and the segments stay where they are until compaction.
public enum MeetingLayoutMigration {
    /// True when any file is still at its old location.
    public static func needsMigration(layout: MeetingLayout) -> Bool {
        !pendingMoves(layout: layout).isEmpty
    }

    /// Moves everything still at an old location. Returns true when it moved
    /// anything. Throws on the first move that fails, leaving the rest for a
    /// retry; every completed move is durable.
    @discardableResult
    public static func migrate(layout: MeetingLayout) throws -> Bool {
        let moves = pendingMoves(layout: layout)
        guard !moves.isEmpty else { return false }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: layout.raw, withIntermediateDirectories: true)
        } catch {
            throw StorageError.directoryCreationFailed(path: layout.raw.path, underlying: "\(error)")
        }
        for move in moves {
            do {
                try fileManager.moveItem(at: move.from, to: move.to)
            } catch {
                throw StorageError.fileWriteFailed(path: move.to.path, underlying: "\(error)")
            }
        }
        return true
    }

    private struct Move {
        let from: URL
        let to: URL
    }

    /// The manifest first: it lives inside the old `segments/` directory, and
    /// the directory itself is moved right after, so the order matters.
    private static func pendingMoves(layout: MeetingLayout) -> [Move] {
        let candidates: [Move] = [
            Move(from: layout.legacyManifest, to: layout.manifest),
            Move(from: layout.legacySegments, to: layout.segments),
            Move(from: layout.legacyMetadata, to: layout.metadata),
            Move(from: layout.legacyRawTranscript, to: layout.rawTranscript),
            Move(from: layout.legacyRawDiarization, to: layout.rawDiarization),
            Move(from: layout.legacySpeakerMap, to: layout.speakerMap),
            Move(from: layout.legacyCanonicalTranscript, to: layout.canonicalTranscript),
            Move(from: layout.legacyAPIResponses, to: layout.apiResponses),
            Move(from: layout.legacyOriginals, to: layout.originals),
        ]
        let fileManager = FileManager.default
        return candidates.filter { move in
            fileManager.fileExists(atPath: move.from.path)
                && !fileManager.fileExists(atPath: move.to.path)
        }
    }
}
