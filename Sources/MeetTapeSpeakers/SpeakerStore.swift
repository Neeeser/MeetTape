import Foundation
import MeetTapeCore

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

    /// `~/Library/Application Support/MeetTape/Speakers/voices.sqlite`.
    public static func defaultURL(applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("Speakers", isDirectory: true)
            .appendingPathComponent("voices.sqlite")
    }

    public var databaseURL: URL { database.url }

    // MARK: - identities

    private static let identityColumns = """
        id, kind, display_name, anonymous_number, organization, is_local_user,
        state, merged_into, created_at, updated_at, last_seen_at
        """

    private func identity(from row: SpeakerDatabase.Row) -> Identity {
        Identity(
            id: IdentityID(row.int64(0)),
            kind: IdentityKind(rawValue: row.text(1)) ?? .anonymous,
            displayName: row.optionalText(2),
            anonymousNumber: row.optionalInt64(3).map(Int.init),
            aliases: [],
            organization: row.optionalText(4),
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
            "SELECT \(Self.identityColumns) FROM identity WHERE id = ?", [.int64(id.rawValue)]
        ) { found = self.identity(from: $0) }
        guard var identity = found else { return nil }
        identity.aliases = try aliases(of: id)
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
            sql += " AND kind = ?"
            bindings.append(.text(kind.rawValue))
        }
        if !includeMerged { sql += " AND merged_into IS NULL" }
        sql += " ORDER BY COALESCE(display_name, ''), anonymous_number, id"
        var out: [Identity] = []
        try database.query(sql, bindings) { out.append(self.identity(from: $0)) }
        return try out.map {
            var identity = $0
            identity.aliases = try aliases(of: identity.id)
            return identity
        }
    }

    public func localUser() throws -> Identity? {
        var found: Identity?
        try database.query(
            "SELECT \(Self.identityColumns) FROM identity WHERE is_local_user = 1 AND merged_into IS NULL LIMIT 1"
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

    public func addAlias(_ alias: String, to id: IdentityID) throws {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try database.run(
            "INSERT OR IGNORE INTO identity_alias(identity_id, alias) VALUES(?, ?)",
            [.int64(id.rawValue), .text(trimmed)]
        )
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
    /// Nothing is deleted and nothing is rewritten. The source keeps its rows and
    /// its embeddings, reads follow the tombstone, and the target's profile is
    /// recomputed over both sets of vectors, so undoing the merge is clearing one
    /// column.
    public func merge(_ source: IdentityID, into target: IdentityID, now: Date = Date()) throws {
        guard source != target else { return }
        // A merge that would form a cycle is refused rather than corrected, so a
        // wrong direction is a visible failure instead of a silent no-op.
        if let resolvedTarget = try current(target), resolvedTarget.id == source { return }
        try database.transaction {
            try database.run(
                "UPDATE identity SET merged_into = ?, updated_at = ? WHERE id = ?",
                [.int64(target.rawValue), .date(now), .int64(source.rawValue)]
            )
        }
        try recomputeProfiles(for: target, now: now)
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
    public func delete(_ id: IdentityID) throws {
        try database.run("DELETE FROM identity WHERE id = ?", [.int64(id.rawValue)])
    }

    /// Deletes the voice and keeps the name.
    ///
    /// Past transcripts still read "Chris", the occurrences still point at the
    /// same identity, and nothing about him can be matched from audio again
    /// until he is re-enrolled.
    public func forgetVoice(of id: IdentityID, now: Date = Date()) throws {
        try database.transaction {
            try database.run("DELETE FROM voice_embedding WHERE identity_id = ?", [.int64(id.rawValue)])
            try database.run("DELETE FROM pending_enrollment WHERE identity_id = ?", [.int64(id.rawValue)])
            try database.run("DELETE FROM derived_profile WHERE identity_id = ?", [.int64(id.rawValue)])
            try database.run(
                "UPDATE identity SET updated_at = ? WHERE id = ?", [.date(now), .int64(id.rawValue)]
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
        guard let identity = try loadIdentity(candidate.identityID) else {
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

        try database.transaction {
            try database.run(
                """
                INSERT INTO voice_embedding(identity_id, model_identifier, embedding_dim, embedding,
                    quality_score, speech_seconds, source_type, source_meeting, source_cluster,
                    is_human_verified, created_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .int64(candidate.identityID.rawValue),
                    .text(candidate.model.rawValue),
                    .int(candidate.model.dimension),
                    .blob(VoiceVector.encode(VoiceVector.l2Normalized(candidate.vector))),
                    .double(candidate.qualityScore),
                    .double(candidate.speechSeconds),
                    .text(candidate.source.rawValue),
                    .optionalText(candidate.meetingID),
                    .optionalText(candidate.clusterID),
                    .bool(candidate.source.isHumanVerified),
                    .date(now),
                ]
            )
            try pruneEmbeddings(of: candidate.identityID, model: candidate.model)
        }
        try recomputeProfiles(for: candidate.identityID, now: now)
        return .success(try profileStatus(of: candidate.identityID, model: candidate.model))
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
        try database.run(
            """
            INSERT INTO pending_enrollment(identity_id, model_identifier, embedding, embedding_dim,
                speech_seconds, quality_score, source_type, source_meeting, source_cluster, created_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .int64(candidate.identityID.rawValue),
                .text(candidate.model.rawValue),
                .blob(VoiceVector.encode(VoiceVector.l2Normalized(candidate.vector))),
                .int(candidate.model.dimension),
                .double(candidate.speechSeconds),
                .double(candidate.qualityScore),
                .text(candidate.source.rawValue),
                .optionalText(candidate.meetingID),
                .optionalText(candidate.clusterID),
                .date(now),
            ]
        )
    }

    /// Turns accumulated confirmed speech into one enrolment once it reaches the
    /// duration bar, and clears what it consumed.
    @discardableResult
    public func flushPendingEnrollment(
        for id: IdentityID, model: EmbeddingModelIdentifier, now: Date = Date()
    ) throws -> Bool {
        var vectors: [[Float]] = []
        var totalSeconds = 0.0
        var quality = 0.0
        var meeting: String?
        try database.query(
            """
            SELECT embedding, speech_seconds, quality_score, source_meeting
            FROM pending_enrollment WHERE identity_id = ? AND model_identifier = ?
            ORDER BY created_at
            """,
            [.int64(id.rawValue), .text(model.rawValue)]
        ) { row in
            if let vector = row.vector(0) { vectors.append(vector) }
            totalSeconds += row.double(1)
            quality = max(quality, row.double(2))
            meeting = meeting ?? row.optionalText(3)
        }
        guard !vectors.isEmpty, totalSeconds >= policy.enrolmentSpeechSeconds else { return false }

        let candidate = VoiceEnrollmentCandidate(
            identityID: id,
            vector: VoiceVector.centroid(vectors),
            model: model,
            speechSeconds: totalSeconds,
            qualityScore: quality,
            source: .humanConfirmedUtterances,
            meetingID: meeting
        )
        guard case .success = try enrol(candidate, now: now) else { return false }
        try database.run(
            "DELETE FROM pending_enrollment WHERE identity_id = ? AND model_identifier = ?",
            [.int64(id.rawValue), .text(model.rawValue)]
        )
        return true
    }

    public func pendingSpeechSeconds(
        for id: IdentityID, model: EmbeddingModelIdentifier
    ) throws -> Double {
        var total = 0.0
        try database.query(
            "SELECT COALESCE(SUM(speech_seconds), 0) FROM pending_enrollment WHERE identity_id = ? AND model_identifier = ?",
            [.int64(id.rawValue), .text(model.rawValue)]
        ) { total = $0.double(0) }
        return total
    }

    // MARK: - profiles

    /// Every identity merged into `id`, plus `id` itself.
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
        var byModel: [String: (vectors: [[Float]], dimension: Int, seconds: Double, recordings: Set<String>)] = [:]
        try database.query(
            """
            SELECT model_identifier, embedding, embedding_dim, speech_seconds, source_meeting
            FROM voice_embedding WHERE identity_id IN (\(placeholders))
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
    public func searchableProfiles(model: EmbeddingModelIdentifier) throws -> [SpeakerProfile] {
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
            guard let centroid = row.vector(11) else { return }
            rows.append((self.identity(from: row), centroid, row.int(12), row.int(13), row.double(14)))
        }
        return rows.map {
            SpeakerProfile(
                identity: $0.0, centroid: $0.1, sampleCount: $0.2,
                recordingCount: $0.3, speechSeconds: $0.4
            )
        }
    }

    // MARK: - occurrences

    private static let occurrenceColumns = """
        id, meeting_id, cluster_id, track, speech_seconds, resolved_identity_id,
        resolution_source, score, runner_up_score, margin, threshold_band,
        human_verified, expected_participant, model_identifier, created_at, updated_at
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
            embeddingModel: row.optionalText(13).map {
                EmbeddingModelIdentifier(rawValue: $0, dimension: EmbeddingModelIdentifier.fluidAudioOffline.dimension)
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
                resolved_identity_id = excluded.resolved_identity_id,
                resolution_source = excluded.resolution_source,
                score = excluded.score,
                runner_up_score = excluded.runner_up_score,
                margin = excluded.margin,
                threshold_band = excluded.threshold_band,
                human_verified = excluded.human_verified,
                expected_participant = excluded.expected_participant,
                updated_at = excluded.updated_at
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

    public func occurrenceEmbedding(meetingID: String, clusterID: String) throws -> [Float]? {
        var vector: [Float]?
        try database.query(
            "SELECT embedding FROM speaker_occurrence WHERE meeting_id = ? AND cluster_id = ?",
            [.text(meetingID), .text(clusterID)]
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
              AND id NOT IN (SELECT identity_id FROM voice_embedding WHERE source_type != 'human_confirmed_cluster')
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
