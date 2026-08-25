import Foundation
import PipitCore
import SQLite3

/// SQLite's marker for "copy this value", needed because Swift hands C a
/// pointer whose lifetime ends at the call.
private let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SpeakerDatabaseError: Error, CustomStringConvertible, Sendable {
    case cannotOpen(path: String, message: String)
    case statementFailed(sql: String, message: String)
    case migrationFailed(version: Int, message: String)

    public var description: String {
        switch self {
        case .cannotOpen(let path, let message): "cannot open \(path): \(message)"
        case .statementFailed(_, let message): "statement failed: \(message)"
        case .migrationFailed(let version, let message):
            "migration to v\(version) failed: \(message)"
        }
    }

    /// Paths and SQL are safe to log; nothing here carries a name or a vector.
    public var logSafeDescription: String {
        switch self {
        case .cannotOpen: "cannot_open"
        case .statementFailed: "statement_failed"
        case .migrationFailed(let version, _): "migration_failed_v\(version)"
        }
    }
}

/// The voice-identity database.
///
/// Deliberately SQLite with Float32 blobs and no index over the vectors.
/// A full scan of 100,000 embeddings was measured at 1.6 ms, and the realistic
/// store for 100 named people plus 500 recurring voices is 3.1 MB, so an
/// approximate-nearest-neighbour index would add a dependency and a correctness
/// risk to solve a problem that does not exist.
///
/// Not thread-safe on its own: `SpeakerStore` owns the only instance and
/// serialises access.
final class SpeakerDatabase {
    private var handle: OpaquePointer?
    let url: URL

    /// Bumped for every schema change. Migrations are additive; nothing here
    /// ever drops a column or a table that holds user data.
    static let latestVersion: Int32 = 2

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw SpeakerDatabaseError.cannotOpen(path: url.path, message: message)
        }
        handle = db
        // Without this, any contention returns SQLITE_BUSY on the first attempt.
        // The app and the evaluation tool open the same file, and a five second
        // wait turns a dropped enrolment into a short pause.
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try execute("PRAGMA synchronous=NORMAL;")
        try migrate()
    }

    deinit { sqlite3_close(handle) }

    // MARK: - migrations

    private func migrate() throws {
        var version = try scalarInt("PRAGMA user_version;").map(Int32.init) ?? 0
        // A file written by a newer build is not something this one can reason
        // about. Refusing is safer than reading it against the older schema.
        guard version <= Self.latestVersion else {
            throw SpeakerDatabaseError.migrationFailed(
                version: Int(version), message: "written by a newer build"
            )
        }
        while version < Self.latestVersion {
            let next = version + 1
            do {
                try execute("BEGIN IMMEDIATE;")
                // Re-read under the write lock. The version above was read
                // without one, so two processes opening a new database together
                // both saw 0; the loser then ran the schema against a populated
                // file and threw out of init, leaving that launch with no voice
                // memory. pipit-eval opens the same file as the app.
                let current = try scalarInt("PRAGMA user_version;").map(Int32.init) ?? 0
                if current >= next {
                    try execute("COMMIT;")
                    version = current
                    continue
                }
                try applyMigration(to: next)
                try execute("PRAGMA user_version = \(next);")
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw SpeakerDatabaseError.migrationFailed(
                    version: Int(next), message: "\(error)"
                )
            }
            version = next
        }
        try adoptEvidenceTables()
    }

    /// Brings a database written by an earlier state of this branch up to the
    /// current schema.
    ///
    /// Pipit has not shipped, so there is no released schema to migrate from
    /// and no migration ladder to maintain. What does exist is a development
    /// machine holding a store whose vectors predate the evidence tables. Those
    /// vectors record no audio, and a vector whose audio cannot be named again
    /// is exactly what this schema exists to forbid: nothing can retract it when
    /// the person it belongs to turns out to be somebody else. The identities,
    /// their names and their history stay; the unretractable vectors go, and the
    /// profiles rebuild from what is confirmed next.
    private func adoptEvidenceTables() throws {
        let present = try scalarInt(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'voice_evidence';"
        ) ?? 0
        guard present == 0 else { return }
        try execute(Self.evidenceTables)
        try execute("DELETE FROM voice_embedding;")
        try execute("DELETE FROM pending_enrollment;")
        try execute("DELETE FROM derived_profile;")
    }

    private func applyMigration(to version: Int32) throws {
        switch version {
        case 1: try execute(Self.schemaV1)
        case 2: try execute(Self.personDetailTables)
        default:
            // Advancing user_version for a step that did nothing marks the
            // schema as migrated when it is not, and the loop never retries.
            // Failing here rolls the transaction back instead.
            throw SpeakerDatabaseError.migrationFailed(
                version: Int(version), message: "no migration defined"
            )
        }
    }

    static var schemaV1: String { schemaCore + evidenceTables }

    /// What a person keeps about somebody, as opposed to what the matcher keeps.
    ///
    /// Notes ride on the identity row so a delete carries them off with
    /// everything else, and badges take the same shape as `identity_alias`
    /// because they are the same kind of thing: a small set of values belonging
    /// to one identity, cascading with it.
    ///
    /// The picture is a table of its own rather than a column, so listing four
    /// hundred people stays one cheap query and does not read four hundred PNGs
    /// to draw a sidebar. In the database rather than a sibling directory
    /// because the cascade then covers it too, and nothing has to sweep for an
    /// avatar whose person is gone.
    static let personDetailTables = """
        ALTER TABLE identity ADD COLUMN notes TEXT;

        CREATE TABLE identity_badge(
          identity_id INTEGER NOT NULL REFERENCES identity(id) ON DELETE CASCADE,
          platform TEXT NOT NULL,
          PRIMARY KEY(identity_id, platform)
        );

        CREATE TABLE identity_avatar(
          identity_id INTEGER PRIMARY KEY REFERENCES identity(id) ON DELETE CASCADE,
          image BLOB NOT NULL,
          updated_at REAL NOT NULL
        );
        """

    static let schemaCore = """
        CREATE TABLE identity(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          kind TEXT NOT NULL CHECK (kind IN ('person','anonymous')),
          display_name TEXT,
          anonymous_number INTEGER,
          organization TEXT,
          is_local_user INTEGER NOT NULL DEFAULT 0,
          state TEXT NOT NULL CHECK (state IN ('ephemeral','persistent')),
          merged_into INTEGER REFERENCES identity(id) ON DELETE SET NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          last_seen_at REAL
        );
        CREATE INDEX idx_identity_kind ON identity(kind, state);

        CREATE TABLE identity_alias(
          identity_id INTEGER NOT NULL REFERENCES identity(id) ON DELETE CASCADE,
          alias TEXT NOT NULL,
          PRIMARY KEY(identity_id, alias)
        );

        CREATE TABLE voice_embedding(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          identity_id INTEGER NOT NULL REFERENCES identity(id) ON DELETE CASCADE,
          model_identifier TEXT NOT NULL,
          embedding_dim INTEGER NOT NULL,
          embedding BLOB NOT NULL,
          quality_score REAL NOT NULL,
          speech_seconds REAL NOT NULL,
          source_type TEXT NOT NULL,
          source_meeting TEXT,
          is_human_verified INTEGER NOT NULL DEFAULT 1,
          created_at REAL NOT NULL
        );
        CREATE INDEX idx_embedding_identity ON voice_embedding(identity_id, model_identifier);

        CREATE TABLE derived_profile(
          identity_id INTEGER NOT NULL REFERENCES identity(id) ON DELETE CASCADE,
          model_identifier TEXT NOT NULL,
          centroid BLOB NOT NULL,
          embedding_dim INTEGER NOT NULL,
          sample_count INTEGER NOT NULL,
          recording_count INTEGER NOT NULL,
          speech_seconds REAL NOT NULL,
          updated_at REAL NOT NULL,
          PRIMARY KEY(identity_id, model_identifier)
        );

        CREATE TABLE speaker_occurrence(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          meeting_id TEXT NOT NULL,
          cluster_id TEXT NOT NULL,
          track TEXT NOT NULL,
          speech_seconds REAL NOT NULL,
          embedding BLOB,
          embedding_dim INTEGER,
          model_identifier TEXT,
          resolved_identity_id INTEGER REFERENCES identity(id) ON DELETE SET NULL,
          resolution_source TEXT NOT NULL,
          score REAL,
          runner_up_score REAL,
          margin REAL,
          threshold_band TEXT NOT NULL,
          human_verified INTEGER NOT NULL DEFAULT 0,
          expected_participant INTEGER NOT NULL DEFAULT 0,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          UNIQUE(meeting_id, cluster_id)
        );
        CREATE INDEX idx_occurrence_identity ON speaker_occurrence(resolved_identity_id);
        CREATE INDEX idx_occurrence_meeting ON speaker_occurrence(meeting_id);

        CREATE TABLE pending_enrollment(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          identity_id INTEGER NOT NULL REFERENCES identity(id) ON DELETE CASCADE,
          model_identifier TEXT NOT NULL,
          embedding BLOB NOT NULL,
          embedding_dim INTEGER NOT NULL,
          speech_seconds REAL NOT NULL,
          quality_score REAL NOT NULL,
          source_type TEXT NOT NULL,
          source_meeting TEXT,
          created_at REAL NOT NULL
        );
        CREATE INDEX idx_pending_identity ON pending_enrollment(identity_id, model_identifier);
        """

    static let evidenceTables = """
        -- The audio a vector was derived from: a recording, a track, and time
        -- spans inside it. This is the provenance retraction reads, and it is
        -- deliberately expressed in coordinates nothing rewrites. A cluster
        -- label is renumbered by every re-analysis, ownership moves on every
        -- merge, and a line-level correction produces material belonging to no
        -- cluster at all, so any of those as the record of what a vector covers
        -- is correct only until the user does something the application exists
        -- to let them do.
        CREATE TABLE voice_evidence(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          voice_embedding_id INTEGER REFERENCES voice_embedding(id) ON DELETE CASCADE,
          pending_enrollment_id INTEGER REFERENCES pending_enrollment(id) ON DELETE CASCADE,
          meeting_id TEXT NOT NULL,
          track TEXT NOT NULL,
          confirmation_source TEXT NOT NULL,
          human_verified INTEGER NOT NULL DEFAULT 0,
          -- Context for a reader, never read to decide what a vector covers.
          analysis_id TEXT,
          cluster_id TEXT,
          created_at REAL NOT NULL,
          CHECK ((voice_embedding_id IS NULL) <> (pending_enrollment_id IS NULL))
        );
        CREATE INDEX idx_evidence_embedding ON voice_evidence(voice_embedding_id);
        CREATE INDEX idx_evidence_pending ON voice_evidence(pending_enrollment_id);
        CREATE INDEX idx_evidence_meeting ON voice_evidence(meeting_id, track);

        CREATE TABLE voice_evidence_span(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          evidence_id INTEGER NOT NULL REFERENCES voice_evidence(id) ON DELETE CASCADE,
          start_time REAL NOT NULL,
          end_time REAL NOT NULL,
          -- Set when the user has since given this audio to somebody else. The
          -- span stays, because it is the record of what the vector was computed
          -- from and deleting it would make the row claim the vector is purer
          -- than it is. What it stops counting towards is how much audio still
          -- supports the vector, which is what decides whether the vector may
          -- remain stored.
          contradicted INTEGER NOT NULL DEFAULT 0,
          CHECK (end_time >= start_time)
        );
        CREATE INDEX idx_span_evidence ON voice_evidence_span(evidence_id);
        """

    // MARK: - primitives

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw SpeakerDatabaseError.statementFailed(sql: sql, message: message)
        }
    }

    /// Runs `body` inside a transaction, rolling back if it throws.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try execute("COMMIT;")
            return value
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func scalarInt(_ sql: String) throws -> Int? {
        var value: Int?
        try query(sql) { row in value = row.int(0) }
        return value
    }

    var lastInsertedID: Int64 { sqlite3_last_insert_rowid(handle) }

    var changes: Int { Int(sqlite3_changes(handle)) }

    /// Prepares, binds, steps to completion and finalises.
    func run(_ sql: String, _ bindings: [SQLValue] = []) throws {
        try query(sql, bindings) { _ in }
    }

    /// Prepares, binds and calls `row` for each result.
    func query(_ sql: String, _ bindings: [SQLValue] = [], row: (Row) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_finalize(statement)
            throw SpeakerDatabaseError.statementFailed(sql: sql, message: message)
        }
        defer { sqlite3_finalize(statement) }
        for (index, binding) in bindings.enumerated() {
            binding.bind(to: statement, at: Int32(index + 1))
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                row(Row(statement: statement))
            } else if step == SQLITE_DONE {
                break
            } else {
                throw SpeakerDatabaseError.statementFailed(
                    sql: sql, message: String(cString: sqlite3_errmsg(handle))
                )
            }
        }
    }

    struct Row {
        let statement: OpaquePointer

        func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
        func int64(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
        func bool(_ index: Int32) -> Bool { sqlite3_column_int64(statement, index) != 0 }
        func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }

        func optionalInt64(_ index: Int32) -> Int64? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : int64(index)
        }

        func optionalDouble(_ index: Int32) -> Double? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : double(index)
        }

        func text(_ index: Int32) -> String {
            guard let pointer = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: pointer)
        }

        func optionalText(_ index: Int32) -> String? {
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(index)
        }

        func date(_ index: Int32) -> Date { Date(timeIntervalSince1970: double(index)) }

        func optionalDate(_ index: Int32) -> Date? {
            optionalDouble(index).map { Date(timeIntervalSince1970: $0) }
        }

        func blob(_ index: Int32) -> Data? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL,
                  let pointer = sqlite3_column_blob(statement, index)
            else { return nil }
            return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, index)))
        }

        func vector(_ index: Int32) -> [Float]? {
            blob(index).flatMap(VoiceVector.decode)
        }
    }
}

/// A bound parameter. Enumerated rather than overloaded so a call site reads as
/// a list of values in order.
enum SQLValue {
    case text(String)
    case optionalText(String?)
    case int(Int)
    case int64(Int64)
    case optionalInt64(Int64?)
    case bool(Bool)
    case double(Double)
    case optionalDouble(Double?)
    case date(Date)
    case optionalDate(Date?)
    case blob(Data)
    case optionalBlob(Data?)
    case null

    func bind(to statement: OpaquePointer, at index: Int32) {
        switch self {
        case .text(let value):
            sqlite3_bind_text(statement, index, value, -1, transientDestructor)
        case .optionalText(let value):
            if let value {
                sqlite3_bind_text(statement, index, value, -1, transientDestructor)
            } else {
                sqlite3_bind_null(statement, index)
            }
        case .int(let value): sqlite3_bind_int64(statement, index, Int64(value))
        case .int64(let value): sqlite3_bind_int64(statement, index, value)
        case .optionalInt64(let value):
            if let value {
                sqlite3_bind_int64(statement, index, value)
            } else {
                sqlite3_bind_null(statement, index)
            }
        case .bool(let value): sqlite3_bind_int64(statement, index, value ? 1 : 0)
        case .double(let value): sqlite3_bind_double(statement, index, value)
        case .optionalDouble(let value):
            if let value {
                sqlite3_bind_double(statement, index, value)
            } else {
                sqlite3_bind_null(statement, index)
            }
        case .date(let value): sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
        case .optionalDate(let value):
            if let value {
                sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, index)
            }
        case .blob(let data):
            _ = data.withUnsafeBytes {
                sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transientDestructor)
            }
        case .optionalBlob(let data):
            if let data {
                _ = data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transientDestructor)
                }
            } else {
                sqlite3_bind_null(statement, index)
            }
        case .null: sqlite3_bind_null(statement, index)
        }
    }
}
