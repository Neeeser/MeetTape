import Foundation
import PipitCore

/// Where the voice database lives.
///
/// Under Application Support and never inside a meeting folder. Embeddings are
/// biometric identifiers that match the same person across devices, rooms and
/// years, and a meeting folder is what a user copies, syncs and shares.
public enum SpeakerStoreLocation {
    public static func url(applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("Speakers", isDirectory: true)
            .appendingPathComponent("voices.sqlite")
    }
}

/// A profile as the matcher sees it: one identity and the one vector it is
/// scored against.
public struct SpeakerProfile: Sendable, Equatable {
    public var identity: Identity
    public var centroid: [Float]
    public var sampleCount: Int
    public var recordingCount: Int
    public var speechSeconds: Double

    public init(
        identity: Identity, centroid: [Float], sampleCount: Int,
        recordingCount: Int, speechSeconds: Double
    ) {
        self.identity = identity
        self.centroid = centroid
        self.sampleCount = sampleCount
        self.recordingCount = recordingCount
        self.speechSeconds = speechSeconds
    }

    public var status: VoiceProfileStatus {
        .from(samples: sampleCount, recordings: recordingCount, speechSeconds: speechSeconds)
    }
}

/// The local voice memory.
///
/// Everything here stays on this Mac. Embeddings are biometric identifiers: they
/// are never written into a meeting folder, never included in an export and
/// never uploaded, whichever backend transcribed or diarized the audio.
public actor SpeakerStore {
    private let database: SpeakerDatabase
    private let policy: SpeakerResolutionPolicy

    public init(url: URL, policy: SpeakerResolutionPolicy = .shipping) throws {
        self.database = try SpeakerDatabase(url: url)
        self.policy = policy
    }

    /// `~/Library/Application Support/Pipit/Speakers/voices.sqlite`.
    public static func defaultURL(applicationSupport: URL) -> URL {
        SpeakerStoreLocation.url(applicationSupport: applicationSupport)
    }

    public var databaseURL: URL { database.url }

    // MARK: - identities

    /// Qualified, because `searchableProfiles` joins a table that also has
    /// `updated_at` and SQLite rejects the ambiguity.
    private static let identityColumns = """
        identity.id, identity.kind, identity.display_name, identity.anonymous_number,
        identity.organization, identity.is_local_user, identity.state, identity.merged_into,
        identity.created_at, identity.updated_at, identity.last_seen_at, identity.notes,
        EXISTS(SELECT 1 FROM identity_avatar WHERE identity_avatar.identity_id = identity.id)
        """

    private func identity(from row: SpeakerDatabase.Row) -> Identity {
        Identity(
            id: IdentityID(row.int64(0)),
            kind: IdentityKind(rawValue: row.text(1)) ?? .anonymous,
            displayName: row.optionalText(2),
            anonymousNumber: row.optionalInt64(3).map(Int.init),
            aliases: [],
            organization: row.optionalText(4),
            notes: row.optionalText(11),
            badges: [],
            hasAvatar: row.bool(12),
            isLocalUser: row.bool(5),
            state: IdentityState(rawValue: row.text(6)) ?? .persistent,
            mergedInto: row.optionalInt64(7).map(IdentityID.init),
            createdAt: row.date(8),
            updatedAt: row.date(9),
            lastSeenAt: row.optionalDate(10)
        )
    }

    private func loadIdentity(_ id: IdentityID) throws -> Identity? {
        var found: Identity?
        try database.query(
            "SELECT \(Self.identityColumns) FROM identity WHERE identity.id = ?",
            [.int64(id.rawValue)]
        ) { found = self.identity(from: $0) }
        guard var identity = found else { return nil }
        identity.aliases = try aliases(of: id)
        identity.badges = try badges(of: id)
        return identity
    }

    private func aliases(of id: IdentityID) throws -> [String] {
        var out: [String] = []
        try database.query(
            "SELECT alias FROM identity_alias WHERE identity_id = ? ORDER BY alias",
            [.int64(id.rawValue)]
        ) { out.append($0.text(0)) }
        return out
    }

    /// Follows merge tombstones to the identity that is actually current.
    ///
    /// The chain is bounded because a merge always points at an identity that
    /// exists, but the guard is here anyway: a cycle would otherwise hang every
    /// read of a transcript.
    public func current(_ id: IdentityID) throws -> Identity? {
        var seen = Set<Int64>()
        var cursor = id
        while true {
            guard !seen.contains(cursor.rawValue) else { return nil }
            seen.insert(cursor.rawValue)
            guard let identity = try loadIdentity(cursor) else { return nil }
            guard let next = identity.mergedInto else { return identity }
            cursor = next
        }
    }

    public func identities(kind: IdentityKind? = nil, includeMerged: Bool = false) throws -> [Identity] {
        var sql = "SELECT \(Self.identityColumns) FROM identity WHERE 1=1"
        var bindings: [SQLValue] = []
        if let kind {
            sql += " AND identity.kind = ?"
            bindings.append(.text(kind.rawValue))
        }
        if !includeMerged { sql += " AND identity.merged_into IS NULL" }
        sql += " ORDER BY COALESCE(identity.display_name, ''), identity.anonymous_number, identity.id"
        var out: [Identity] = []
        try database.query(sql, bindings) { out.append(self.identity(from: $0)) }
        return try out.map {
            var identity = $0
            identity.aliases = try aliases(of: identity.id)
            identity.badges = try badges(of: identity.id)
            return identity
        }
    }

    public func localUser() throws -> Identity? {
        var found: Identity?
        try database.query(
            """
            SELECT \(Self.identityColumns) FROM identity
            WHERE identity.is_local_user = 1 AND identity.merged_into IS NULL LIMIT 1
            """
        ) { found = self.identity(from: $0) }
        return found
    }

    @discardableResult
    public func createPerson(
        name: String,
        organization: String? = nil,
        aliases: [String] = [],
        isLocalUser: Bool = false,
        now: Date = Date()
    ) throws -> Identity {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try database.transaction {
            if isLocalUser {
                try database.run("UPDATE identity SET is_local_user = 0 WHERE is_local_user = 1")
            }
            try database.run(
                """
                INSERT INTO identity(kind, display_name, organization, is_local_user, state,
                                     created_at, updated_at)
                VALUES('person', ?, ?, ?, 'persistent', ?, ?)
                """,
                [
                    .text(trimmed), .optionalText(organization), .bool(isLocalUser),
                    .date(now), .date(now),
                ]
            )
            let id = IdentityID(database.lastInsertedID)
            for alias in aliases where !alias.isEmpty {
                try database.run(
                    "INSERT OR IGNORE INTO identity_alias(identity_id, alias) VALUES(?, ?)",
                    [.int64(id.rawValue), .text(alias)]
                )
            }
            guard let identity = try loadIdentity(id) else {
                throw SpeakerDatabaseError.statementFailed(sql: "createPerson", message: "not found")
            }
            return identity
        }
    }

    /// Creates an unnamed identity for a voice worth remembering.
    ///
    /// Ephemeral until it is heard a second time. It takes part in matching from
    /// the start, because a candidate that cannot be matched can never become
    /// recurring, but it carries no number and is shown as an ordinary unknown
    /// speaker until it is promoted.
    @discardableResult
    public func createAnonymous(state: IdentityState = .ephemeral, now: Date = Date()) throws -> Identity {
        try database.transaction {
            try database.run(
                """
                INSERT INTO identity(kind, state, created_at, updated_at, last_seen_at)
                VALUES('anonymous', ?, ?, ?, ?)
                """,
                [.text(state.rawValue), .date(now), .date(now), .date(now)]
            )
            let id = IdentityID(database.lastInsertedID)
            if state == .persistent { try assignAnonymousNumber(id) }
            guard let identity = try loadIdentity(id) else {
                throw SpeakerDatabaseError.statementFailed(sql: "createAnonymous", message: "not found")
            }
            return identity
        }
    }

    /// Numbers are handed out at promotion, not at creation, so a user never
    /// sees gaps left by candidates that were heard once and expired.
    private func assignAnonymousNumber(_ id: IdentityID) throws {
        let next = (try database.scalarInt(
            "SELECT COALESCE(MAX(anonymous_number), 0) FROM identity"
        ) ?? 0) + 1
        try database.run(
            "UPDATE identity SET anonymous_number = ? WHERE id = ? AND anonymous_number IS NULL",
            [.int(next), .int64(id.rawValue)]
        )
    }

    /// Marks an ephemeral candidate as a voice worth keeping.
    @discardableResult
    public func promoteToPersistent(_ id: IdentityID, now: Date = Date()) throws -> Identity? {
        try database.transaction {
            try database.run(
                "UPDATE identity SET state = 'persistent', updated_at = ?, last_seen_at = ? WHERE id = ?",
                [.date(now), .date(now), .int64(id.rawValue)]
            )
            try assignAnonymousNumber(id)
            return try loadIdentity(id)
        }
    }

    /// Turns a recurring unnamed voice into a named person.
    ///
    /// One row changes. Every occurrence, cluster mapping and utterance override
    /// already points at this identifier, so nothing is re-transcribed,
    /// re-diarized or rewritten, and the profile the voice already built is kept.
    @discardableResult
    public func promoteToPerson(
        _ id: IdentityID, name: String, organization: String? = nil, now: Date = Date()
    ) throws -> Identity? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try loadIdentity(id) }
        try database.run(
            """
            UPDATE identity
            SET kind = 'person', display_name = ?, organization = COALESCE(?, organization),
                state = 'persistent', updated_at = ?
            WHERE id = ?
            """,
            [.text(trimmed), .optionalText(organization), .date(now), .int64(id.rawValue)]
        )
        // Naming a recurring voice is the human confirmation its seed vector
        // never had, so the vector stops being provisional at the same moment.
        try database.run(
            """
            UPDATE voice_embedding
            SET source_type = ?, is_human_verified = 1
            WHERE identity_id = ? AND source_type = ?
            """,
            [
                .text(VoiceEnrollmentSource.humanConfirmedCluster.rawValue),
                .int64(id.rawValue),
                .text(VoiceEnrollmentSource.anonymousSeed.rawValue),
            ]
        )
        // The stored centroid was built while this identity was anonymous, so
        // it can hold a merged-in seed that nobody confirmed. The purity filter
        // that keeps such a vector out of a named person's centroid only runs at
        // recompute time; without this the profile carried it until the next
        // enrol dropped it, and sample_count fell with no new information.
        try recomputeProfiles(for: id, now: now)
        return try loadIdentity(id)
    }

    @discardableResult
    public func rename(
        _ id: IdentityID, to name: String, organization: String?? = nil, now: Date = Date()
    ) throws -> Identity? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try loadIdentity(id) }
        if let organization {
            try database.run(
                "UPDATE identity SET display_name = ?, organization = ?, updated_at = ? WHERE id = ?",
                [.text(trimmed), .optionalText(organization), .date(now), .int64(id.rawValue)]
            )
        } else {
            try database.run(
                "UPDATE identity SET display_name = ?, updated_at = ? WHERE id = ?",
                [.text(trimmed), .date(now), .int64(id.rawValue)]
            )
        }
        return try loadIdentity(id)
    }

    /// Binds a platform handle to an identity, moving it if another held it.
    ///
    /// Replace rather than ignore: a handle can only be one person, and the
    /// newest confirmation is the correction of whatever the older one claimed.
    public func setHandle(_ handle: IdentityHandle, to id: IdentityID, now: Date = Date()) throws {
        let provider = handle.provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = handle.handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty, !value.isEmpty else { return }
        try database.run(
            """
            INSERT INTO identity_handle(provider, handle, identity_id, created_at)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(provider, handle)
            DO UPDATE SET identity_id = excluded.identity_id, created_at = excluded.created_at
            """,
            [.text(provider), .text(value), .int64(id.rawValue), .date(now)]
        )
    }

    /// The person behind a platform handle, resolved through any merges, or
    /// nil where nobody has been confirmed for it.
    public func identity(handle: String, provider: String) -> Identity? {
        var found: IdentityID?
        try? database.query(
            "SELECT identity_id FROM identity_handle WHERE provider = ? AND handle = ?",
            [.text(provider), .text(handle)]
        ) { row in
            if let raw = row.optionalInt64(0) { found = IdentityID(raw) }
        }
        guard let found else { return nil }
        return (try? current(found)) ?? nil
    }

    /// Every handle bound to an identity or to anything merged into it, so the
    /// People pane shows the links a merge carried in. The whole family, not
    /// one hop: merges chain, and a handle two merges deep still names this
    /// person, so it has to be visible where it can be withdrawn.
    public func handles(of id: IdentityID) throws -> [IdentityHandle] {
        let family = try identityFamily(id)
        var out: [IdentityHandle] = []
        let marks = family.map { _ in "?" }.joined(separator: ",")
        try database.query(
            """
            SELECT provider, handle FROM identity_handle
            WHERE identity_id IN (\(marks)) ORDER BY provider, handle
            """,
            family.map { .int64($0) }
        ) { row in
            guard let provider = row.optionalText(0), let handle = row.optionalText(1) else { return }
            out.append(IdentityHandle(provider: provider, handle: handle))
        }
        return out
    }

    /// Removes one handle binding. The identity and its voice stay; only the
    /// claim that this platform account is that person goes.
    public func removeHandle(_ handle: IdentityHandle) throws {
        try database.run(
            "DELETE FROM identity_handle WHERE provider = ? AND handle = ?",
            [.text(handle.provider), .text(handle.handle)]
        )
    }

    public func addAlias(_ alias: String, to id: IdentityID) throws {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try database.run(
            "INSERT OR IGNORE INTO identity_alias(identity_id, alias) VALUES(?, ?)",
            [.int64(id.rawValue), .text(trimmed)]
        )
    }

    private func badges(of id: IdentityID) throws -> [PersonBadge] {
        var out: [PersonBadge] = []
        try database.query(
            "SELECT platform FROM identity_badge WHERE identity_id = ? ORDER BY platform",
            [.int64(id.rawValue)]
        ) { row in
            // A row this build cannot name is dropped rather than shown. The
            // column is a closed set on the Swift side and the badge exists to
            // be drawn, so a platform with no icon has nothing to render.
            if let badge = PersonBadge(rawValue: row.text(0)) { out.append(badge) }
        }
        return out
    }

    // MARK: - what a person keeps about somebody

    /// Free text about a person, written into the participant block of every
    /// transcript they appear in. Empty clears it, so the block does not carry a
    /// blank line for somebody whose notes were deleted.
    public func setNotes(_ notes: String?, on id: IdentityID, now: Date = Date()) throws {
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        try database.run(
            "UPDATE identity SET notes = ?, updated_at = ? WHERE id = ?",
            [
                .optionalText((trimmed?.isEmpty ?? true) ? nil : trimmed),
                .date(now), .int64(id.rawValue),
            ]
        )
    }

    /// Replaces the whole badge set, because that is how the picker edits it:
    /// the user sees every platform at once and toggles the ones that apply.
    public func setBadges(_ badges: [PersonBadge], on id: IdentityID, now: Date = Date()) throws {
        try database.transaction {
            try database.run(
                "DELETE FROM identity_badge WHERE identity_id = ?", [.int64(id.rawValue)]
            )
            for badge in Set(badges) {
                try database.run(
                    "INSERT INTO identity_badge(identity_id, platform) VALUES(?, ?)",
                    [.int64(id.rawValue), .text(badge.rawValue)]
                )
            }
            try database.run(
                "UPDATE identity SET updated_at = ? WHERE id = ?",
                [.date(now), .int64(id.rawValue)]
            )
        }
    }

    /// Sets the organization on several people at once.
    ///
    /// A directory of a few hundred voices accumulates a department at a time,
    /// and doing it row by row is the same edit typed thirty times.
    public func setOrganization(
        _ organization: String?, on ids: [IdentityID], now: Date = Date()
    ) throws {
        guard !ids.isEmpty else { return }
        let trimmed = organization?.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        try database.run(
            "UPDATE identity SET organization = ?, updated_at = ? WHERE id IN (\(placeholders))",
            [
                .optionalText((trimmed?.isEmpty ?? true) ? nil : trimmed), .date(now),
            ] + ids.map { SQLValue.int64($0.rawValue) }
        )
    }

    /// The picture, fetched when something is about to draw it. `nil` clears it.
    public func setAvatar(_ png: Data?, on id: IdentityID, now: Date = Date()) throws {
        guard let png, !png.isEmpty else {
            try database.run(
                "DELETE FROM identity_avatar WHERE identity_id = ?", [.int64(id.rawValue)]
            )
            return
        }
        try database.run(
            """
            INSERT INTO identity_avatar(identity_id, image, updated_at) VALUES(?, ?, ?)
            ON CONFLICT(identity_id) DO UPDATE SET image = excluded.image,
                                                   updated_at = excluded.updated_at
            """,
            [.int64(id.rawValue), .blob(png), .date(now)]
        )
    }

    public func avatar(of id: IdentityID) throws -> Data? {
        var found: Data?
        try database.query(
            "SELECT image FROM identity_avatar WHERE identity_id = ?", [.int64(id.rawValue)]
        ) { found = $0.blob(0) }
        return found
    }

    public func setLocalUser(_ id: IdentityID, now: Date = Date()) throws {
        try database.transaction {
            try database.run("UPDATE identity SET is_local_user = 0 WHERE is_local_user = 1")
            try database.run(
                "UPDATE identity SET is_local_user = 1, updated_at = ? WHERE id = ?",
                [.date(now), .int64(id.rawValue)]
            )
        }
    }

    /// Points `source` at `target`.
    ///
    /// Nothing is rewritten. The source keeps its rows and its embeddings, reads
    /// follow the tombstone, and undoing the merge is clearing one column.
    ///
    /// The target's profile is recomputed over both sets, minus anything seeded
    /// automatically: a provisional vector nobody stood behind must not reach a
    /// named centroid by being merged into one. Only the source's now-unreachable
    /// derived profile is deleted.
    public func merge(_ source: IdentityID, into target: IdentityID, now: Date = Date()) throws {
        guard source != target else { return }
        // A merge that would form a cycle does nothing. Correcting the
        // direction would merge two people the caller did not ask to merge.
        // Point at the survivor, not at another tombstone: merging into an
        // identity that is itself merged left the source pointing at a dead row
        // and recomputed a profile nothing reads.
        guard let resolved = try current(target) else { return }
        if resolved.id == source { return }
        try database.transaction {
            try database.run(
                "UPDATE identity SET merged_into = ?, updated_at = ? WHERE id = ?",
                [.int64(resolved.id.rawValue), .date(now), .int64(source.rawValue)]
            )
            // The source's own centroid is now unreachable and would otherwise
            // keep answering profileStatus for it.
            try database.run(
                "DELETE FROM derived_profile WHERE identity_id = ?", [.int64(source.rawValue)]
            )
        }
        try recomputeProfiles(for: resolved.id, now: now)
    }

    public func unmerge(_ source: IdentityID, now: Date = Date()) throws {
        var previous: IdentityID?
        try database.query(
            "SELECT merged_into FROM identity WHERE id = ?", [.int64(source.rawValue)]
        ) { previous = $0.optionalInt64(0).map(IdentityID.init) }
        try database.run(
            "UPDATE identity SET merged_into = NULL, updated_at = ? WHERE id = ?",
            [.date(now), .int64(source.rawValue)]
        )
        if let previous { try recomputeProfiles(for: previous, now: now) }
        try recomputeProfiles(for: source, now: now)
    }

    /// Removes the identity and everything biometric that belongs to it.
    ///
    /// The whole merged family goes, not just the row named. Anything merged
    /// into this identity holds that same person's voice, and deleting only the
    /// survivor would clear the redirect and leave the vectors behind as a live
    /// match candidate: "delete this person" would be followed by Pipit
    /// recognizing them again under a number.
    public func delete(_ id: IdentityID) throws {
        let family = try identityFamily(id)
        let placeholders = family.map { _ in "?" }.joined(separator: ",")
        try database.transaction {
            try database.run(
                "DELETE FROM identity WHERE id IN (\(placeholders))",
                family.map { SQLValue.int64($0) }
            )
        }
    }

    /// Deletes the voice and keeps the name.
    ///
    /// Past transcripts still read "Chris", the occurrences still point at the
    /// same identity, and nothing about him can be matched from audio again
    /// until he is re-enrolled. Covers the merged family for the same reason
    /// `delete` does: separating a merge afterwards would otherwise rebuild a
    /// working profile from the vectors that were supposed to be gone.
    public func forgetVoice(of id: IdentityID, now: Date = Date()) throws {
        let family = try identityFamily(id)
        let placeholders = family.map { _ in "?" }.joined(separator: ",")
        let bindings = family.map { SQLValue.int64($0) }
        try database.transaction {
            try database.run(
                "DELETE FROM voice_embedding WHERE identity_id IN (\(placeholders))", bindings
            )
            try database.run(
                "DELETE FROM pending_enrollment WHERE identity_id IN (\(placeholders))", bindings
            )
            try database.run(
                "DELETE FROM derived_profile WHERE identity_id IN (\(placeholders))", bindings
            )
            try database.run(
                "UPDATE identity SET updated_at = ? WHERE id IN (\(placeholders))",
                [.date(now)] + bindings
            )
        }
    }

    // MARK: - enrolment

    /// Stores one verified vector and rebuilds the identity's centroid.
    ///
    /// The only callers are a human confirmation and the microphone track. A
    /// recognition result never reaches here: letting a match widen the profile
    /// it matched against is what turns one wrong answer into a permanent one.
    @discardableResult
    public func enrol(
        _ candidate: VoiceEnrollmentCandidate, now: Date = Date()
    ) throws -> Result<VoiceProfileStatus, VoiceEnrollmentRejection> {
        guard !candidate.vector.isEmpty else { return .failure(.emptyVector) }
        guard candidate.vector.count == candidate.model.dimension else {
            return .failure(.wrongDimension(got: candidate.vector.count, expected: candidate.model.dimension))
        }
        // Resolved through the merge tombstone. loadIdentity returns the
        // tombstone itself, and searchableProfiles skips tombstones, so every
        // vector written to a merged-away identity was stored and then never
        // used: the profile stopped improving with nothing to show for it.
        guard let identity = try current(candidate.identityID) else {
            return .failure(.identityMissing)
        }
        // A named profile only ever holds material a person stood behind.
        guard identity.kind != .person || candidate.source.mayEnrolNamedPerson else {
            return .failure(.identityMissing)
        }
        guard candidate.speechSeconds >= policy.enrolmentSpeechSeconds else {
            return .failure(.tooLittleSpeech(
                seconds: candidate.speechSeconds, required: policy.enrolmentSpeechSeconds
            ))
        }
        // A vector whose audio cannot be named again can never be retracted, and
        // a vector that cannot be retracted is what turns one wrong answer into a
        // permanent one. One recording per row, because the centroid stands for
        // one session and `recording_count` counts sessions.
        guard let meetingID = candidate.meetingID,
              candidate.evidence.allSatisfy({ $0.meetingID == meetingID })
        else { return .failure(.unusableEvidence) }

        try database.transaction {
            try database.run(
                """
                INSERT INTO voice_embedding(identity_id, model_identifier, embedding_dim, embedding,
                    quality_score, speech_seconds, source_type, source_meeting,
                    is_human_verified, created_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .int64(identity.id.rawValue),
                    .text(candidate.model.rawValue),
                    .int(candidate.model.dimension),
                    .blob(VoiceVector.encode(VoiceVector.l2Normalized(candidate.vector))),
                    .double(candidate.qualityScore),
                    .double(candidate.speechSeconds),
                    .text(candidate.source.rawValue),
                    .optionalText(candidate.meetingID),
                    .bool(candidate.source.isHumanVerified),
                    .date(now),
                ]
            )
            try writeEvidence(
                candidate.evidence, embeddingID: database.lastInsertedID, pendingID: nil, now: now
            )
            try pruneEmbeddings(of: identity.id, model: candidate.model)
        }
        try recomputeProfiles(for: identity.id, now: now)
        return .success(try profileStatus(of: identity.id, model: candidate.model))
    }

    /// Drops every stored vector that no longer stands on enough audio of its
    /// own, after some of the audio behind it was reassigned to somebody else.
    ///
    /// This is the whole retraction path, and it asks one question: which
    /// vectors were derived from audio overlapping the spans the user has just
    /// claimed for somebody. Overlapping audio cannot belong to two people, so
    /// every vector holding any of it is holding a voice that is not entirely
    /// theirs.
    ///
    /// Deliberately not a question about clusters. A re-analysis renumbers them,
    /// a merge moves their owner, and a line-level correction produces material
    /// belonging to no cluster at all, so a cluster-keyed answer is right only
    /// until the user does one of the things the application exists to let them
    /// do. Source audio does not move.
    ///
    /// What happens to a partially contradicted vector is decided by the bar
    /// that decided it could exist: a vector may be stored when 45 seconds of
    /// confirmed speech stands behind it, so it may remain stored while 45
    /// seconds still does. The contradicted spans stop counting either way, so a
    /// second correction is measured against what is left rather than against
    /// the original, and a vector cannot be kept alive by being corrected a
    /// little at a time. Below the bar the vector goes and the caller derives a
    /// replacement from the spans that are still theirs, which is deterministic
    /// because the spans are recorded.
    ///
    /// The alternative, dropping a vector on any overlap at all, was worse in
    /// the common case: correcting one three-second line inside a confirmed
    /// twenty-minute cluster would delete twenty minutes of good material over
    /// audio that moves the centroid by about a thousandth.
    @discardableResult
    public func retractEvidence(
        _ retraction: VoiceEvidenceRetraction, keepingClaimant: Bool, now: Date = Date()
    ) throws -> [IdentityID] {
        guard !retraction.spans.isEmpty else { return [] }
        var exempt: Set<Int64> = []
        if keepingClaimant, let claimant = retraction.claimedBy {
            exempt = Set(try identityFamily(try currentID(claimant)))
        }
        // The claimant is getting this audio, so any of it their own evidence
        // had been debited for is theirs again. Without this, correcting a line
        // away and back left the debit standing, and enough of those left a
        // vector below the bar over audio nobody disputes.
        if let claimant = retraction.claimedBy {
            try restoreSpans(for: claimant, retraction: retraction)
        }
        let contradicted = try contradictedRows(retraction, exempt: exempt)
        guard !contradicted.isEmpty else { return [] }

        try database.transaction {
            for row in contradicted {
                // Marked whether or not the vector survives, so that correcting
                // a little at a time is measured against what is left.
                try markContradicted(evidenceID: row.evidenceID, spans: retraction.spans)
                guard row.retract else { continue }
                if let embeddingID = row.embeddingID {
                    try database.run(
                        "DELETE FROM voice_embedding WHERE id = ?", [.int64(embeddingID)]
                    )
                }
                if let pendingID = row.pendingID {
                    // The parked accumulation too, or the next flush re-enrols
                    // speech that has just moved to somebody else.
                    try database.run(
                        "DELETE FROM pending_enrollment WHERE id = ?", [.int64(pendingID)]
                    )
                }
            }
        }
        // Resolved, because a row's owner may since have been merged and the
        // survivor is the one whose centroid was built over it.
        var affected: [IdentityID] = []
        for row in contradicted where row.retract {
            let current = try currentID(IdentityID(row.owner))
            if !affected.contains(current) { affected.append(current) }
        }
        // Rebuilt here rather than left to the caller. A centroid still built
        // over a vector that has just been deleted is the same wrong answer as
        // never having deleted it, and it only takes one call site forgetting.
        for identity in affected { try recomputeProfiles(for: identity, now: now) }
        return affected
    }

    /// Takes back everything one track of one meeting taught.
    ///
    /// For the case where the claim a whole track rests on is withdrawn rather
    /// than a stretch of it reassigned: the microphone track of a remote call is
    /// enrolled as the local user by construction, and a person saying it was
    /// somebody else withdraws that construction for that recording. There are
    /// no spans to name, because the unit is the track.
    @discardableResult
    public func retractTrack(
        meetingID: String, track: CaptureTrack, now: Date = Date()
    ) throws -> [IdentityID] {
        var embeddings: [Int64] = []
        var pending: [Int64] = []
        var owners: [Int64] = []
        try database.query(
            """
            SELECT e.voice_embedding_id, e.pending_enrollment_id,
                   COALESCE(v.identity_id, p.identity_id)
            FROM voice_evidence e
            LEFT JOIN voice_embedding v ON v.id = e.voice_embedding_id
            LEFT JOIN pending_enrollment p ON p.id = e.pending_enrollment_id
            WHERE e.meeting_id = ? AND e.track = ?
            """,
            [.text(meetingID), .text(track.rawValue)]
        ) { row in
            guard let owner = row.optionalInt64(2) else { return }
            if let id = row.optionalInt64(0) { embeddings.append(id) }
            if let id = row.optionalInt64(1) { pending.append(id) }
            owners.append(owner)
        }
        guard !embeddings.isEmpty || !pending.isEmpty else { return [] }
        try database.transaction {
            for (table, ids) in [("voice_embedding", embeddings), ("pending_enrollment", pending)]
            where !ids.isEmpty {
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                try database.run(
                    "DELETE FROM \(table) WHERE id IN (\(placeholders))",
                    ids.map { SQLValue.int64($0) }
                )
            }
        }
        var affected: [IdentityID] = []
        for owner in owners {
            let current = try currentID(IdentityID(owner))
            if !affected.contains(current) { affected.append(current) }
        }
        for identity in affected { try recomputeProfiles(for: identity, now: now) }
        return affected
    }

    private struct ContradictedRow {
        var evidenceID: Int64
        var embeddingID: Int64?
        var pendingID: Int64?
        var owner: Int64
        var retract: Bool
    }

    /// Every stored row whose evidence overlaps the retraction, and whether what
    /// is left of it is still enough.
    ///
    /// Span arithmetic happens here rather than in SQL because the spans are a
    /// set: two rows overlap when any of their intervals do, which SQL can
    /// express only as a join quadratic in turn count. The candidate set is one
    /// recording's rows on one track.
    private func contradictedRows(
        _ retraction: VoiceEvidenceRetraction, exempt: Set<Int64>
    ) throws -> [ContradictedRow] {
        struct Candidate {
            var evidenceID: Int64
            var embeddingID: Int64?
            var pendingID: Int64?
            var owner: Int64
        }
        var candidates: [Candidate] = []
        try database.query(
            """
            SELECT e.id, e.voice_embedding_id, e.pending_enrollment_id,
                   COALESCE(v.identity_id, p.identity_id)
            FROM voice_evidence e
            LEFT JOIN voice_embedding v ON v.id = e.voice_embedding_id
            LEFT JOIN pending_enrollment p ON p.id = e.pending_enrollment_id
            WHERE e.meeting_id = ? AND e.track = ?
            """,
            [.text(retraction.meetingID), .text(retraction.track.rawValue)]
        ) { row in
            guard let owner = row.optionalInt64(3) else { return }
            candidates.append(Candidate(
                evidenceID: row.int64(0),
                embeddingID: row.optionalInt64(1),
                pendingID: row.optionalInt64(2),
                owner: owner
            ))
        }
        let wanted = candidates.filter { !exempt.contains($0.owner) }
        guard !wanted.isEmpty else { return [] }

        // Only the audio still standing behind each vector. A span already given
        // away counts for nothing, which is what makes a run of small
        // corrections add up instead of each being weighed against the whole.
        var standing: [Int64: [AudioSpan]] = [:]
        let placeholders = wanted.map { _ in "?" }.joined(separator: ",")
        try database.query(
            "SELECT evidence_id, start_time, end_time FROM voice_evidence_span"
                + " WHERE evidence_id IN (\(placeholders)) AND contradicted = 0",
            wanted.map { SQLValue.int64($0.evidenceID) }
        ) { row in
            standing[row.int64(0), default: []]
                .append(AudioSpan(start: row.double(1), end: row.double(2)))
        }

        var out: [ContradictedRow] = []
        for candidate in wanted {
            let spans = standing[candidate.evidenceID] ?? []
            guard AudioSpan.intersect(spans, retraction.spans) > 0 else { continue }
            let remaining = AudioSpan.subtracting(retraction.spans, from: spans)
            out.append(ContradictedRow(
                evidenceID: candidate.evidenceID,
                embeddingID: candidate.embeddingID,
                pendingID: candidate.pendingID,
                owner: candidate.owner,
                retract: AudioSpan.totalDuration(remaining) < policy.enrolmentSpeechSeconds
            ))
        }
        return out
    }

    /// Un-marks the spans an identity is being given back.
    private func restoreSpans(
        for identity: IdentityID, retraction: VoiceEvidenceRetraction
    ) throws {
        let family = try identityFamily(try currentID(identity))
        let placeholders = family.map { _ in "?" }.joined(separator: ",")
        var evidenceIDs: [Int64] = []
        try database.query(
            """
            SELECT DISTINCT e.id
            FROM voice_evidence e
            LEFT JOIN voice_embedding v ON v.id = e.voice_embedding_id
            LEFT JOIN pending_enrollment p ON p.id = e.pending_enrollment_id
            WHERE e.meeting_id = ? AND e.track = ?
              AND COALESCE(v.identity_id, p.identity_id) IN (\(placeholders))
            """,
            [.text(retraction.meetingID), .text(retraction.track.rawValue)]
                + family.map { SQLValue.int64($0) }
        ) { evidenceIDs.append($0.int64(0)) }
        for evidenceID in evidenceIDs {
            try restamp(
                evidenceID: evidenceID, spans: retraction.spans,
                from: true, to: false
            )
        }
    }

    /// Splits an evidence row's spans around a set of times and flips the
    /// overlapping part.
    ///
    /// Splitting rather than flipping whole rows, in both directions. A
    /// contradicted row records exactly one earlier retraction's overlap, so a
    /// later claim covering part of it would otherwise give back audio nobody
    /// claimed.
    private func restamp(
        evidenceID: Int64, spans: [AudioSpan], from: Bool, to flag: Bool
    ) throws {
        var existing: [(id: Int64, span: AudioSpan)] = []
        try database.query(
            "SELECT id, start_time, end_time FROM voice_evidence_span"
                + " WHERE evidence_id = ? AND contradicted = ?",
            [.int64(evidenceID), .bool(from)]
        ) { row in
            existing.append((row.int64(0), AudioSpan(start: row.double(1), end: row.double(2))))
        }
        for entry in existing {
            guard AudioSpan.intersect([entry.span], spans) > 0 else { continue }
            try database.run("DELETE FROM voice_evidence_span WHERE id = ?", [.int64(entry.id)])
            for kept in AudioSpan.subtracting(spans, from: [entry.span]) {
                try insertSpan(evidenceID: evidenceID, span: kept, contradicted: from)
            }
            for moved in AudioSpan.union(spans).compactMap({ cut -> AudioSpan? in
                let start = max(entry.span.start, cut.start)
                let end = min(entry.span.end, cut.end)
                return end > start ? AudioSpan(start: start, end: end) : nil
            }) {
                try insertSpan(evidenceID: evidenceID, span: moved, contradicted: flag)
            }
        }
    }

    /// Splits an evidence row's spans around the reassigned audio and marks the
    /// overlapping part as no longer supporting the vector.
    private func markContradicted(evidenceID: Int64, spans removed: [AudioSpan]) throws {
        try restamp(evidenceID: evidenceID, spans: removed, from: false, to: true)
    }

    private func insertSpan(evidenceID: Int64, span: AudioSpan, contradicted: Bool) throws {
        try database.run(
            "INSERT INTO voice_evidence_span(evidence_id, start_time, end_time, contradicted)"
                + " VALUES(?, ?, ?, ?)",
            [.int64(evidenceID), .double(span.start), .double(span.end), .bool(contradicted)]
        )
    }

    /// Writes the audio behind one vector.
    private func writeEvidence(
        _ evidence: [VoiceEvidence], embeddingID: Int64?, pendingID: Int64?, now: Date
    ) throws {
        for item in evidence {
            try database.run(
                """
                INSERT INTO voice_evidence(voice_embedding_id, pending_enrollment_id, meeting_id,
                    track, confirmation_source, human_verified, analysis_id, cluster_id,
                    created_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .optionalInt64(embeddingID), .optionalInt64(pendingID),
                    .text(item.meetingID), .text(item.track.rawValue),
                    .text(item.confirmation.rawValue), .bool(item.isHumanVerified),
                    .optionalText(item.analysisID), .optionalText(item.clusterID),
                    .date(now),
                ]
            )
            let evidenceID = database.lastInsertedID
            for span in item.spans {
                try insertSpan(evidenceID: evidenceID, span: span, contradicted: false)
            }
        }
    }

    /// The audio behind a set of rows, keyed by the row it belongs to.
    private func loadEvidence(column: String, ids: [Int64]) throws -> [Int64: [VoiceEvidence]] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        var rows: [(owner: Int64, evidenceID: Int64, evidence: VoiceEvidence)] = []
        try database.query(
            """
            SELECT \(column), id, meeting_id, track, confirmation_source, human_verified,
                   analysis_id, cluster_id
            FROM voice_evidence WHERE \(column) IN (\(placeholders))
            """,
            ids.map { SQLValue.int64($0) }
        ) { row in
            guard let owner = row.optionalInt64(0),
                  let track = CaptureTrack(rawValue: row.text(3)),
                  let source = VoiceEnrollmentSource(rawValue: row.text(4))
            else { return }
            rows.append((owner, row.int64(1), VoiceEvidence(
                meetingID: row.text(2), track: track, spans: [],
                confirmation: source, isHumanVerified: row.bool(5),
                analysisID: row.optionalText(6), clusterID: row.optionalText(7)
            )))
        }
        guard !rows.isEmpty else { return [:] }
        var spans: [Int64: [AudioSpan]] = [:]
        var standing: [Int64: [AudioSpan]] = [:]
        let spanPlaceholders = rows.map { _ in "?" }.joined(separator: ",")
        try database.query(
            "SELECT evidence_id, start_time, end_time, contradicted FROM voice_evidence_span"
                + " WHERE evidence_id IN (\(spanPlaceholders))",
            rows.map { SQLValue.int64($0.evidenceID) }
        ) { row in
            let span = AudioSpan(start: row.double(1), end: row.double(2))
            spans[row.int64(0), default: []].append(span)
            if !row.bool(3) { standing[row.int64(0), default: []].append(span) }
        }
        var out: [Int64: [VoiceEvidence]] = [:]
        for row in rows {
            var evidence = row.evidence
            evidence.spans = AudioSpan.union(spans[row.evidenceID] ?? [])
            evidence.standingSpans = AudioSpan.union(standing[row.evidenceID] ?? [])
            out[row.owner, default: []].append(evidence)
        }
        return out
    }

    /// Every stored vector for an identity's merged family, with the audio each
    /// was derived from. Read by the tests that pin retraction, and by the
    /// developer tool.
    public func storedEmbeddings(
        of id: IdentityID, model: EmbeddingModelIdentifier? = nil
    ) throws -> [StoredVoiceEmbedding] {
        let family = try identityFamily(try currentID(id))
        let placeholders = family.map { _ in "?" }.joined(separator: ",")
        var filter = ""
        var bindings = family.map { SQLValue.int64($0) }
        if let model {
            filter = " AND model_identifier = ?"
            bindings.append(.text(model.rawValue))
        }
        var rows: [(Int64, IdentityID, EmbeddingModelIdentifier, Double, Double, Bool, Date)] = []
        try database.query(
            """
            SELECT id, identity_id, model_identifier, speech_seconds, quality_score,
                   is_human_verified, created_at, embedding_dim
            FROM voice_embedding WHERE identity_id IN (\(placeholders))\(filter)
            ORDER BY created_at, id
            """,
            bindings
        ) { row in
            rows.append((
                row.int64(0), IdentityID(row.int64(1)),
                EmbeddingModelIdentifier(rawValue: row.text(2), dimension: row.int(7)),
                row.double(3), row.double(4), row.bool(5), row.date(6)
            ))
        }
        let evidence = try loadEvidence(column: "voice_embedding_id", ids: rows.map(\.0))
        return rows.map {
            StoredVoiceEmbedding(
                id: $0.0, identityID: $0.1, model: $0.2, speechSeconds: $0.3,
                qualityScore: $0.4, isHumanVerified: $0.5, createdAt: $0.6,
                evidence: evidence[$0.0] ?? []
            )
        }
    }

    /// Forgets that a meeting was ever heard.
    ///
    /// Called when its folder is deleted. Only the occurrence rows go: the
    /// voice material a person confirmed lives in `voice_embedding` and stays,
    /// so deleting one accidental recording does not cost the profile every
    /// other meeting built. Left behind, these rows kept counting a meeting
    /// that no longer exists towards "heard in 3 meetings".
    @discardableResult
    public func deleteOccurrences(meetingID: String) throws -> Int {
        try database.run(
            "DELETE FROM speaker_occurrence WHERE meeting_id = ?", [.text(meetingID)]
        )
        return database.changes
    }

    /// Forgets who a cluster was said to be.
    ///
    /// The occurrence row stays, because the cluster was still heard; what goes
    /// is the identity, the human-verified flag and the band, so nothing later
    /// treats a retracted answer as a confirmed one.
    public func clearOccurrenceIdentity(meetingID: String, clusterID: String) throws {
        try database.run(
            """
            UPDATE speaker_occurrence
            SET resolved_identity_id = NULL, resolution_source = ?, human_verified = 0,
                threshold_band = ?, updated_at = ?
            WHERE meeting_id = ? AND cluster_id = ?
            """,
            [
                .text(SpeakerAssignmentOrigin.ai.rawValue),
                .text(SpeakerConfidenceBand.unknown.rawValue),
                .date(Date()),
                .text(meetingID), .text(clusterID),
            ]
        )
    }

    /// Keeps the newest, highest-quality vectors and drops the rest.
    ///
    /// Separation stops improving past about five confirmed recordings, so the
    /// cap costs nothing measurable and bounds the store by construction.
    private func pruneEmbeddings(of id: IdentityID, model: EmbeddingModelIdentifier) throws {
        try database.run(
            """
            DELETE FROM voice_embedding
            WHERE id IN (
              SELECT id FROM voice_embedding
              WHERE identity_id = ? AND model_identifier = ?
              ORDER BY quality_score DESC, speech_seconds DESC, created_at DESC
              LIMIT -1 OFFSET ?
            )
            """,
            [.int64(id.rawValue), .text(model.rawValue), .int(policy.maximumEmbeddingsPerIdentity)]
        )
    }

    /// Holds a vector derived from confirmed speech that is not yet enough to
    /// enrol on its own. Corrections accumulate here until they clear the bar.
    public func addPendingEnrollment(
        _ candidate: VoiceEnrollmentCandidate, now: Date = Date()
    ) throws {
        guard !candidate.vector.isEmpty else { return }
        // Validated here rather than only in enrol. A row of the wrong length
        // can never flush, so without this it sticks in the queue forever and
        // every later correction pays for a re-embed that cannot land.
        guard candidate.vector.count == candidate.model.dimension else { return }
        guard let meetingID = candidate.meetingID,
              candidate.evidence.allSatisfy({ $0.meetingID == meetingID })
        else { return }
        guard let identity = try current(candidate.identityID) else { return }
        // One row per meeting. The caller re-embeds the whole confirmed set each
        // time, so a second round of corrections on the same meeting supersedes
        // the first rather than counting the same speech twice.
        try database.run(
            """
            DELETE FROM pending_enrollment
            WHERE identity_id = ? AND model_identifier = ?
              AND source_meeting IS ?
            """,
            [
                .int64(identity.id.rawValue), .text(candidate.model.rawValue),
                .optionalText(candidate.meetingID),
            ]
        )
        try database.transaction {
            try database.run(
                """
                INSERT INTO pending_enrollment(identity_id, model_identifier, embedding, embedding_dim,
                    speech_seconds, quality_score, source_type, source_meeting, created_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .int64(identity.id.rawValue),
                    .text(candidate.model.rawValue),
                    .blob(VoiceVector.encode(VoiceVector.l2Normalized(candidate.vector))),
                    .int(candidate.vector.count),
                    .double(candidate.speechSeconds),
                    .double(candidate.qualityScore),
                    .text(candidate.source.rawValue),
                    .optionalText(candidate.meetingID),
                    .date(now),
                ]
            )
            // Parked material is retractable on the same terms as stored
            // material. Without evidence here, reassigning a line whose speech is
            // still accumulating left it in the queue and the next flush enrolled
            // audio the user had already given to somebody else.
            try writeEvidence(
                candidate.evidence, embeddingID: nil, pendingID: database.lastInsertedID, now: now
            )
        }
    }

    /// Turns accumulated confirmed speech into one enrolment once it reaches the
    /// duration bar, and clears what it consumed.
    @discardableResult
    public func flushPendingEnrollment(
        for id: IdentityID, model: EmbeddingModelIdentifier, now: Date = Date()
    ) throws -> Bool {
        struct Group {
            var ids: [Int64] = []
            var vectors: [[Float]] = []
            var seconds = 0.0
            var quality = 0.0
        }
        // Grouped by meeting. One vector must stand for one session: mixing two
        // meetings' audio into a single centroid is the thing recording_count
        // exists to measure, and the row can only name one of them, so the
        // other's hasEnrolment stayed false and it re-embedded forever.
        // The whole family. addPendingEnrollment resolves before writing, so
        // rows parked under an identity that was later merged away sat under the
        // old identifier: confirmed speech that no flush could ever reach.
        let id = try currentID(id)
        let family = try identityFamily(id)
        let placeholders = family.map { _ in "?" }.joined(separator: ",")
        var groups: [String: Group] = [:]
        try database.query(
            """
            SELECT embedding, speech_seconds, quality_score, source_meeting, id
            FROM pending_enrollment
            WHERE identity_id IN (\(placeholders)) AND model_identifier = ?
            ORDER BY created_at
            """,
            family.map { SQLValue.int64($0) } + [.text(model.rawValue)]
        ) { row in
            let key = row.optionalText(3) ?? ""
            var group = groups[key] ?? Group()
            if let vector = row.vector(0) { group.vectors.append(vector) }
            group.seconds += row.double(1)
            group.quality = max(group.quality, row.double(2))
            group.ids.append(row.int64(4))
            groups[key] = group
        }
        // The audio behind the parked rows travels with them into the vector
        // they become. Losing it here would make a flushed enrolment the one
        // kind nothing could retract.
        let parkedEvidence = try loadEvidence(
            column: "pending_enrollment_id", ids: groups.values.flatMap(\.ids)
        )

        var enrolled = false
        for (key, group) in groups.sorted(by: { $0.key < $1.key }) {
            guard !group.vectors.isEmpty, group.seconds >= policy.enrolmentSpeechSeconds else {
                continue
            }
            let evidence = mergedEvidence(group.ids.flatMap { parkedEvidence[$0] ?? [] })
            guard !evidence.isEmpty else { continue }
            // One meeting contributes one vector of this kind, enforced where it
            // is written rather than by a check the caller makes first. Reading
            // the confirmed lines and embedding them takes seconds, so two
            // corrections a moment apart both passed that check and both
            // enrolled: one session's audio then occupied two of the twenty
            // retained samples and evicted a genuinely different recording.
            let meetingID = key.isEmpty ? nil : key
            try database.run(
                """
                DELETE FROM voice_embedding
                WHERE identity_id IN (\(placeholders)) AND model_identifier = ?
                  AND source_type = ? AND source_meeting IS ?
                """,
                family.map { SQLValue.int64($0) } + [
                    .text(model.rawValue), .text(VoiceEnrollmentSource.humanConfirmedUtterances.rawValue),
                    .optionalText(meetingID),
                ]
            )
            let candidate = VoiceEnrollmentCandidate(
                identityID: id,
                vector: VoiceVector.centroid(group.vectors),
                model: model,
                speechSeconds: group.seconds,
                qualityScore: group.quality,
                source: .humanConfirmedUtterances,
                evidence: evidence
            )
            guard case .success = try enrol(candidate, now: now) else { continue }
            enrolled = true
            // Only what was consumed. A meeting still short of the bar keeps
            // accumulating.
            try database.run(
                """
                DELETE FROM pending_enrollment
                WHERE identity_id IN (\(placeholders))
                  AND model_identifier = ? AND source_meeting IS ?
                """,
                family.map { SQLValue.int64($0) } + [
                    .text(model.rawValue), .optionalText(key.isEmpty ? nil : key),
                ]
            )
        }
        return enrolled
    }

    /// One row per recording and track, spans unioned.
    ///
    /// Several parked rows describe the same session, so a flush that kept them
    /// separate would store the same interval many times and make the row count
    /// grow with how often the user corrected rather than with what was said.
    private func mergedEvidence(_ evidence: [VoiceEvidence]) -> [VoiceEvidence] {
        struct Key: Hashable {
            var meetingID: String
            var track: CaptureTrack
        }
        var order: [Key] = []
        var byKey: [Key: VoiceEvidence] = [:]
        for item in evidence {
            let key = Key(meetingID: item.meetingID, track: item.track)
            if var existing = byKey[key] {
                existing.spans = AudioSpan.union(existing.spans + item.spans)
                existing.standingSpans = AudioSpan.union(existing.standingSpans + item.standingSpans)
                existing.isHumanVerified = existing.isHumanVerified || item.isHumanVerified
                byKey[key] = existing
            } else {
                order.append(key)
                byKey[key] = item
            }
        }
        return order.compactMap { byKey[$0] }
    }

    /// Whether one meeting has already contributed an enrolment of this kind.
    ///
    /// A meeting is one source of material. Correcting more lines in it later
    /// should refine nothing rather than stack another near-identical vector
    /// from the same session into a profile meant to be diverse.
    public func hasEnrolment(
        identityID: IdentityID, meetingID: String, source: VoiceEnrollmentSource,
        model: EmbeddingModelIdentifier
    ) throws -> Bool {
        // The whole family, because enrol writes to the survivor: after a merge
        // the earlier enrolment sits under the merged-away identifier, and
        // asking about the survivor alone answered no. The caller then
        // re-embedded that meeting on every later correction and stacked
        // near-identical vectors until they evicted the diverse ones.
        let family = try identityFamily(currentID(identityID))
        let placeholders = family.map { _ in "?" }.joined(separator: ",")
        var found = false
        try database.query(
            """
            SELECT 1 FROM voice_embedding
            WHERE identity_id IN (\(placeholders))
              AND source_meeting = ? AND source_type = ? AND model_identifier = ?
            LIMIT 1
            """,
            family.map { SQLValue.int64($0) } + [
                .text(meetingID), .text(source.rawValue), .text(model.rawValue),
            ]
        ) { _ in found = true }
        return found
    }

    public func pendingSpeechSeconds(
        for id: IdentityID, model: EmbeddingModelIdentifier
    ) throws -> Double {
        let family = try identityFamily(try currentID(id))
        let placeholders = family.map { _ in "?" }.joined(separator: ",")
        var total = 0.0
        try database.query(
            """
            SELECT COALESCE(SUM(speech_seconds), 0) FROM pending_enrollment
            WHERE identity_id IN (\(placeholders)) AND model_identifier = ?
            """,
            family.map { SQLValue.int64($0) } + [.text(model.rawValue)]
        ) { total = $0.double(0) }
        return total
    }

    // MARK: - profiles

    /// Every identity merged into `id`, plus `id` itself.
    /// Every identity that reads as this one: itself and anything merged into
    /// it, transitively.
    public func family(of id: IdentityID) throws -> [IdentityID] {
        try identityFamily(id).map(IdentityID.init)
    }

    /// The identifier an identity currently reads as, or itself when it is not
    /// merged or has gone missing.
    private func currentID(_ id: IdentityID) throws -> IdentityID {
        (try current(id))?.id ?? id
    }

    private func identityFamily(_ id: IdentityID) throws -> [Int64] {
        var family = [id.rawValue]
        var frontier = [id.rawValue]
        var guardCount = 0
        while !frontier.isEmpty, guardCount < 1_000 {
            guardCount += 1
            let placeholders = frontier.map { _ in "?" }.joined(separator: ",")
            var next: [Int64] = []
            try database.query(
                "SELECT id FROM identity WHERE merged_into IN (\(placeholders))",
                frontier.map { SQLValue.int64($0) }
            ) { next.append($0.int64(0)) }
            let fresh = next.filter { !family.contains($0) }
            family.append(contentsOf: fresh)
            frontier = fresh
        }
        return family
    }

    /// Rebuilds the centroid an identity is scored against, over its own
    /// verified vectors and those of anything merged into it.
    public func recomputeProfiles(for id: IdentityID, now: Date = Date()) throws {
        let family = try identityFamily(id)
        let placeholders = family.map { _ in "?" }.joined(separator: ",")
        // A named profile only ever holds material a person stood behind.
        // `enrol` refuses a provisional seed directly, and merging an unnamed
        // voice into a person must not smuggle one in through the back door.
        let isPerson = (try loadIdentity(id))?.kind == .person
        let purity = isPerson ? " AND is_human_verified = 1" : ""
        var byModel: [String: (vectors: [[Float]], dimension: Int, seconds: Double, recordings: Set<String>)] = [:]
        try database.query(
            """
            SELECT model_identifier, embedding, embedding_dim, speech_seconds, source_meeting
            FROM voice_embedding WHERE identity_id IN (\(placeholders))\(purity)
            """,
            family.map { SQLValue.int64($0) }
        ) { row in
            let model = row.text(0)
            guard let vector = row.vector(1) else { return }
            var entry = byModel[model] ?? ([], row.int(2), 0, [])
            entry.vectors.append(vector)
            entry.dimension = row.int(2)
            entry.seconds += row.double(3)
            if let meeting = row.optionalText(4) { entry.recordings.insert(meeting) }
            byModel[model] = entry
        }

        try database.transaction {
            try database.run(
                "DELETE FROM derived_profile WHERE identity_id = ?", [.int64(id.rawValue)]
            )
            for (model, entry) in byModel where !entry.vectors.isEmpty {
                try database.run(
                    """
                    INSERT INTO derived_profile(identity_id, model_identifier, centroid, embedding_dim,
                        sample_count, recording_count, speech_seconds, updated_at)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .int64(id.rawValue), .text(model),
                        .blob(VoiceVector.encode(VoiceVector.centroid(entry.vectors))),
                        .int(entry.dimension), .int(entry.vectors.count),
                        .int(max(entry.recordings.count, entry.vectors.isEmpty ? 0 : 1)),
                        .double(entry.seconds), .date(now),
                    ]
                )
            }
        }
    }

    public func profileStatus(
        of id: IdentityID, model: EmbeddingModelIdentifier
    ) throws -> VoiceProfileStatus {
        var status = VoiceProfileStatus.none
        try database.query(
            """
            SELECT sample_count, recording_count, speech_seconds FROM derived_profile
            WHERE identity_id = ? AND model_identifier = ?
            """,
            [.int64(id.rawValue), .text(model.rawValue)]
        ) { row in
            status = .from(
                samples: row.int(0), recordings: row.int(1), speechSeconds: row.double(2)
            )
        }
        return status
    }

    /// Every profile the matcher may compare against.
    ///
    /// Merged identities are excluded because their vectors already count
    /// towards the identity they were merged into; including both would let one
    /// person occupy two ranks and eat their own margin.
    ///
    /// `excludingSeededIn` drops unnamed voices whose every vector came from one
    /// meeting, when that is the meeting being resolved. Without it a second
    /// resolution pass scores a cluster against the profile seeded from that
    /// same cluster, matches itself at 1.0, and reports a voice heard once as
    /// one heard before.
    /// Unnamed profiles whose material came only from this meeting.
    ///
    /// The complement of `excludingSeededIn`. Re-analysing a meeting gives every
    /// cluster a new key, so the reuse guard keyed on the key stopped firing and
    /// the exclusion hid the identity the previous run had seeded: the same
    /// voice produced a second profile, then a third, and their centroids being
    /// near-identical meant the margin gate stopped that person ever being
    /// recognised again.
    public func profilesSeededOnlyIn(
        meetingID: String, model: EmbeddingModelIdentifier
    ) throws -> [SpeakerProfile] {
        try allProfiles(model: model).filter {
            try $0.identity.kind == .anonymous
                && !hasEmbeddingOutside(meetingID: meetingID, identityID: $0.identity.id)
        }
    }

    public func searchableProfiles(
        model: EmbeddingModelIdentifier, excludingSeededIn meetingID: String? = nil
    ) throws -> [SpeakerProfile] {
        let profiles = try allProfiles(model: model)
        guard let meetingID else { return profiles }
        // An unnamed identity whose every vector came from this meeting is not
        // evidence about this meeting: it would score against the profile seeded
        // from its own audio and be announced as a voice heard before.
        return try profiles.filter {
            try $0.identity.kind != .anonymous
                || hasEmbeddingOutside(meetingID: meetingID, identityID: $0.identity.id)
        }
    }

    private func allProfiles(model: EmbeddingModelIdentifier) throws -> [SpeakerProfile] {
        var rows: [(Identity, [Float], Int, Int, Double)] = []
        try database.query(
            """
            SELECT \(Self.identityColumns), p.centroid, p.sample_count, p.recording_count, p.speech_seconds
            FROM identity
            JOIN derived_profile p ON p.identity_id = identity.id
            WHERE identity.merged_into IS NULL AND p.model_identifier = ?
            """,
            [.text(model.rawValue)]
        ) { row in
            guard let centroid = row.vector(13) else { return }
            rows.append((self.identity(from: row), centroid, row.int(14), row.int(15), row.double(16)))
        }
        return rows.map {
            SpeakerProfile(
                identity: $0.0, centroid: $0.1, sampleCount: $0.2,
                recordingCount: $0.3, speechSeconds: $0.4
            )
        }
    }

    /// Whether an identity's merged family holds a vector from any meeting but
    /// this one.
    ///
    /// Filtered here rather than in SQL because the family is transitive: A
    /// merged into B merged into C. A correlated subquery walked one level, so
    /// C's own material from a third meeting was invisible, and a recurring
    /// voice with real history elsewhere was dropped from the gallery while
    /// simultaneously being offered as seeded-only. recomputeProfiles builds C's
    /// centroid over the whole chain, and this has to agree with it.
    private func hasEmbeddingOutside(meetingID: String, identityID: IdentityID) throws -> Bool {
        let family = try identityFamily(identityID)
        let placeholders = family.map { _ in "?" }.joined(separator: ",")
        var found = false
        try database.query(
            """
            SELECT 1 FROM voice_embedding
            WHERE identity_id IN (\(placeholders))
              AND (source_meeting IS NULL OR source_meeting != ?)
            LIMIT 1
            """,
            family.map { SQLValue.int64($0) } + [.text(meetingID)]
        ) { _ in found = true }
        return found
    }

    // MARK: - occurrences

    private static let occurrenceColumns = """
        id, meeting_id, cluster_id, track, speech_seconds, resolved_identity_id,
        resolution_source, score, runner_up_score, margin, threshold_band,
        human_verified, expected_participant, model_identifier, created_at, updated_at,
        embedding_dim
        """

    private func occurrence(from row: SpeakerDatabase.Row) -> SpeakerOccurrence {
        SpeakerOccurrence(
            id: row.int64(0),
            meetingID: row.text(1),
            clusterID: row.text(2),
            track: CaptureTrack(rawValue: row.text(3)) ?? .remote,
            speechSeconds: row.double(4),
            resolvedIdentityID: row.optionalInt64(5).map(IdentityID.init),
            source: SpeakerAssignmentOrigin(rawValue: row.text(6)) ?? .ai,
            score: row.optionalDouble(7),
            runnerUpScore: row.optionalDouble(8),
            margin: row.optionalDouble(9),
            band: SpeakerConfidenceBand(rawValue: row.text(10)) ?? .unknown,
            humanVerified: row.bool(11),
            wasExpectedParticipant: row.bool(12),
            // The row's own dimension, not the current constant. Reporting
            // every vector as 256 would defeat the check the column exists for.
            embeddingModel: row.optionalText(13).map {
                EmbeddingModelIdentifier(rawValue: $0, dimension: row.int(16))
            },
            createdAt: row.date(14),
            updatedAt: row.date(15)
        )
    }

    /// Writes the decision about one cluster, keeping the vector it was decided
    /// from so a later re-resolution needs no audio.
    @discardableResult
    public func recordOccurrence(
        meetingID: String,
        clusterID: String,
        track: CaptureTrack,
        speechSeconds: Double,
        embedding: [Float]?,
        model: EmbeddingModelIdentifier?,
        resolution: SpeakerResolution?,
        identityID: IdentityID?,
        source: SpeakerAssignmentOrigin,
        humanVerified: Bool,
        wasExpectedParticipant: Bool,
        now: Date = Date()
    ) throws -> Int64 {
        let vector = embedding.map { VoiceVector.encode(VoiceVector.l2Normalized($0)) }
        try database.run(
            """
            INSERT INTO speaker_occurrence(meeting_id, cluster_id, track, speech_seconds, embedding,
                embedding_dim, model_identifier, resolved_identity_id, resolution_source, score,
                runner_up_score, margin, threshold_band, human_verified, expected_participant,
                created_at, updated_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(meeting_id, cluster_id) DO UPDATE SET
                speech_seconds = excluded.speech_seconds,
                embedding = COALESCE(excluded.embedding, speaker_occurrence.embedding),
                embedding_dim = COALESCE(excluded.embedding_dim, speaker_occurrence.embedding_dim),
                model_identifier = COALESCE(excluded.model_identifier, speaker_occurrence.model_identifier),
                score = excluded.score,
                runner_up_score = excluded.runner_up_score,
                margin = excluded.margin,
                expected_participant = excluded.expected_participant,
                updated_at = excluded.updated_at,
                -- An automatic pass must not undo a person's answer. Scores and
                -- margins above are diagnostics and are always refreshed; the
                -- decision itself only moves when the incoming row is itself a
                -- human confirmation.
                resolved_identity_id = CASE
                    WHEN speaker_occurrence.human_verified = 1 AND excluded.human_verified = 0
                    THEN speaker_occurrence.resolved_identity_id
                    ELSE excluded.resolved_identity_id END,
                resolution_source = CASE
                    WHEN speaker_occurrence.human_verified = 1 AND excluded.human_verified = 0
                    THEN speaker_occurrence.resolution_source
                    ELSE excluded.resolution_source END,
                threshold_band = CASE
                    WHEN speaker_occurrence.human_verified = 1 AND excluded.human_verified = 0
                    THEN speaker_occurrence.threshold_band
                    ELSE excluded.threshold_band END,
                human_verified = CASE
                    WHEN speaker_occurrence.human_verified = 1 THEN 1
                    ELSE excluded.human_verified END
            """,
            [
                .text(meetingID), .text(clusterID), .text(track.rawValue), .double(speechSeconds),
                .optionalBlob(vector), .optionalInt64(model.map { Int64($0.dimension) }),
                .optionalText(model?.rawValue), .optionalInt64(identityID?.rawValue),
                .text(source.rawValue), .optionalDouble(resolution?.best?.score),
                .optionalDouble(resolution?.runnerUp?.score), .optionalDouble(resolution?.margin),
                .text((resolution?.band ?? (identityID == nil ? .unknown : .high)).rawValue),
                .bool(humanVerified), .bool(wasExpectedParticipant), .date(now), .date(now),
            ]
        )
        var id: Int64 = database.lastInsertedID
        try database.query(
            "SELECT id FROM speaker_occurrence WHERE meeting_id = ? AND cluster_id = ?",
            [.text(meetingID), .text(clusterID)]
        ) { id = $0.int64(0) }
        return id
    }

    public func occurrences(meetingID: String) throws -> [SpeakerOccurrence] {
        var out: [SpeakerOccurrence] = []
        try database.query(
            "SELECT \(Self.occurrenceColumns) FROM speaker_occurrence WHERE meeting_id = ? ORDER BY cluster_id",
            [.text(meetingID)]
        ) { out.append(self.occurrence(from: $0)) }
        return out
    }

    /// The vector one cluster was decided from, for one embedding model.
    ///
    /// Filtered by model on purpose: a vector from another extractor is not
    /// comparable, and returning it would let it be scored or enrolled against
    /// the wrong centroid.
    public func occurrenceEmbedding(
        meetingID: String, clusterID: String, model: EmbeddingModelIdentifier = .fluidAudioOffline
    ) throws -> [Float]? {
        var vector: [Float]?
        try database.query(
            """
            SELECT embedding FROM speaker_occurrence
            WHERE meeting_id = ? AND cluster_id = ? AND model_identifier = ?
            """,
            [.text(meetingID), .text(clusterID), .text(model.rawValue)]
        ) { vector = $0.vector(0) }
        return vector
    }

    public func occurrences(identityID: IdentityID) throws -> [SpeakerOccurrence] {
        let family = try identityFamily(identityID)
        let placeholders = family.map { _ in "?" }.joined(separator: ",")
        var out: [SpeakerOccurrence] = []
        try database.query(
            """
            SELECT \(Self.occurrenceColumns) FROM speaker_occurrence
            WHERE resolved_identity_id IN (\(placeholders)) ORDER BY created_at DESC
            """,
            family.map { SQLValue.int64($0) }
        ) { out.append(self.occurrence(from: $0)) }
        return out
    }

    /// Meetings whose transcripts need their cached names refreshed after a
    /// rename, a promotion or a merge.
    public func meetingsReferencing(_ id: IdentityID) throws -> [String] {
        let family = try identityFamily(id)
        let placeholders = family.map { _ in "?" }.joined(separator: ",")
        var out: [String] = []
        try database.query(
            """
            SELECT DISTINCT meeting_id FROM speaker_occurrence
            WHERE resolved_identity_id IN (\(placeholders))
            """,
            family.map { SQLValue.int64($0) }
        ) { out.append($0.text(0)) }
        return out
    }

    /// How many meetings a voice has been heard in, which is what "seen before"
    /// shows the user.
    public func meetingCount(for id: IdentityID) throws -> Int {
        try meetingsReferencing(id).count
    }

    public func noteSeen(_ id: IdentityID, at date: Date) throws {
        try database.run(
            "UPDATE identity SET last_seen_at = ?, updated_at = ? WHERE id = ?",
            [.date(date), .date(date), .int64(id.rawValue)]
        )
    }

    // MARK: - maintenance

    /// Forgets unnamed candidates that were heard once and never matched.
    ///
    /// Only ephemeral anonymous identities with no human involvement are
    /// touched, and only their profile: the meetings they appeared in keep their
    /// speaker labels, so expiry loses a future match and no history.
    @discardableResult
    public func expireEphemeralIdentities(now: Date = Date()) throws -> Int {
        let cutoff = now.addingTimeInterval(-Double(policy.ephemeralExpiryDays) * 86_400)
        var doomed: [Int64] = []
        try database.query(
            """
            SELECT id FROM identity
            WHERE kind = 'anonymous' AND state = 'ephemeral' AND merged_into IS NULL
              AND COALESCE(last_seen_at, created_at) < ?
              AND id NOT IN (SELECT identity_id FROM voice_embedding WHERE is_human_verified = 1)
            """,
            [.date(cutoff)]
        ) { doomed.append($0.int64(0)) }
        guard !doomed.isEmpty else { return 0 }
        try database.transaction {
            for id in doomed {
                try database.run("DELETE FROM identity WHERE id = ?", [.int64(id)])
            }
        }
        return doomed.count
    }

    /// Counts, for Settings. No names and no vectors leave this call.
    public func statistics() throws -> Statistics {
        var stats = Statistics()
        try database.query(
            "SELECT kind, state, COUNT(*) FROM identity WHERE merged_into IS NULL GROUP BY kind, state"
        ) { row in
            let count = row.int(2)
            switch (row.text(0), row.text(1)) {
            case ("person", _): stats.namedPeople += count
            case ("anonymous", "persistent"): stats.recurringVoices += count
            case ("anonymous", _): stats.candidateVoices += count
            default: break
            }
        }
        try database.query("SELECT COUNT(*) FROM voice_embedding") { stats.embeddings = $0.int(0) }
        stats.storageBytes = (try? FileManager.default.attributesOfItem(atPath: database.url.path)[.size] as? Int64) ?? 0
        return stats
    }

    public struct Statistics: Sendable, Equatable {
        public var namedPeople = 0
        public var recurringVoices = 0
        public var candidateVoices = 0
        public var embeddings = 0
        public var storageBytes: Int64 = 0

        public init() {}
    }
}
