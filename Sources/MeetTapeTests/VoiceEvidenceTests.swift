import Foundation
import MeetTapeCore
import MeetTapeSpeakers
import SQLite3
import TestKit

/// What a stored voice vector was derived from, and what that makes possible.
///
/// The rule these pin: a vector's provenance is the audio behind it, and audio
/// does not move. Every test here does something that renumbers, merges or
/// re-labels the clustering and then asks whether the right vector can still be
/// found. Answering from cluster labels got each of these wrong in a different
/// way.
enum VoiceEvidenceTests {
    static func vector(seed: Int) -> [Float] { SpeakerIdentityTests.vector(seed: seed) }

    static func makeStore() throws -> (SpeakerStore, URL) { try SpeakerIdentityTests.makeStore() }

    private static func samples(
        _ store: SpeakerStore, _ id: IdentityID
    ) async throws -> Int {
        try await store.profileStatus(of: id, model: .fluidAudioOffline).sampleCount
    }

    private static func cluster(
        _ id: String, analysis: String, seconds: Double, seed: Int,
        from start: Double, track: CaptureTrack = .remote
    ) -> SpeakerClusterInput {
        SpeakerClusterInput(
            clusterID: id, track: track, speechSeconds: seconds, centroid: vector(seed: seed),
            spans: [AudioSpan(start: start, end: start + seconds)], analysisID: analysis
        )
    }

    static var suite: Suite {
        Suite("VoiceEvidence", [
            test("a re-analysis renumbers the clusters and the voice can still be taken back") { expect in
                // The defect this exists for: provenance recorded as a cluster
                // label stops matching the moment a re-analysis renumbers the
                // runs, so the vector the first confirmation stored became
                // unreachable and the person corrected away kept the voice.
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let service = SpeakerRecognitionService(store: store)
                let settings = SpeakerRecognitionSettings()

                let chris = try await store.createPerson(name: "Chris")
                _ = try await service.confirmCluster(
                    meetingID: "m1",
                    cluster: cluster(
                        "remote-001_speaker_00", analysis: "remote-001",
                        seconds: 120, seed: 71, from: 0
                    ),
                    identityID: chris.id, settings: settings
                )
                expect.equal(try await samples(store, chris.id), 1, "the confirmation enrols")

                // A second analysis over the same audio, with its own labels.
                // Nothing about the recording changed.
                let dana = try await store.createPerson(name: "Dana")
                _ = try await service.confirmCluster(
                    meetingID: "m1",
                    cluster: cluster(
                        "remote-002_speaker_03", analysis: "remote-002",
                        seconds: 120, seed: 71, from: 0
                    ),
                    identityID: dana.id, settings: settings
                )
                expect.equal(
                    try await samples(store, chris.id), 0,
                    "the audio is Dana's now, so Chris keeps nothing derived from it"
                )
                expect.equal(try await samples(store, dana.id), 1)
                expect.isFalse(
                    try await store.searchableProfiles(model: .fluidAudioOffline)
                        .contains { $0.identity.id == chris.id },
                    "and Chris is not a candidate at all, rather than one with a stale centroid"
                )
            },

            test("a correction records the audio it confirmed, not the label") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let service = SpeakerRecognitionService(store: store)
                let chris = try await store.createPerson(name: "Chris")
                _ = try await service.confirmUtterances(
                    meetingID: "m1", identityID: chris.id,
                    vectors: [
                        DiarizationChunkEmbedding(
                            clusterID: "confirmed", start: 0, end: 30, vector: vector(seed: 72)
                        ),
                        DiarizationChunkEmbedding(
                            clusterID: "confirmed", start: 90, end: 120, vector: vector(seed: 72)
                        ),
                    ],
                    track: .remote,
                    spans: [AudioSpan(start: 10, end: 40), AudioSpan(start: 100, end: 130)],
                    settings: SpeakerRecognitionSettings()
                )
                let stored = try await store.storedEmbeddings(of: chris.id)
                expect.equal(stored.count, 1)
                let evidence = try expect.unwrap(stored.first?.evidence.first)
                expect.equal(evidence.meetingID, "m1")
                expect.equal(evidence.track, .remote)
                expect.equal(
                    evidence.spans,
                    [AudioSpan(start: 10, end: 40), AudioSpan(start: 100, end: 130)],
                    "the lines the user confirmed, on the meeting timeline"
                )
                expect.isNil(
                    evidence.clusterID,
                    "a line correction belongs to no cluster, and does not pretend to"
                )
            },

            test("a vector keeps standing while most of its audio is still its owner's") { expect in
                // The opposite failure to the one above: dropping a vector on
                // any overlap at all destroyed twenty minutes of confirmed
                // material over a three-second correction that moves the
                // centroid by about a thousandth.
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let chris = try await store.createPerson(name: "Chris")
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: chris.id, vector: vector(seed: 73), model: .fluidAudioOffline,
                    speechSeconds: 1_200, qualityScore: 1, source: .humanConfirmedCluster,
                    evidence: [VoiceEvidence(
                        meetingID: "m1", track: .remote,
                        spans: [AudioSpan(start: 0, end: 1_200)],
                        confirmation: .humanConfirmedCluster, clusterID: "remote-001_speaker_00"
                    )]
                ))

                let displaced = try await store.retractEvidence(
                    VoiceEvidenceRetraction(
                        meetingID: "m1", track: .remote, spans: [AudioSpan(start: 600, end: 603)]
                    ),
                    keepingClaimant: false
                )
                expect.isTrue(displaced.isEmpty, "1197 seconds is still well over the bar")
                expect.equal(try await samples(store, chris.id), 1)

                let stored = try await expect.unwrap(store.storedEmbeddings(of: chris.id).first)
                let evidence = try expect.unwrap(stored.evidence.first)
                expect.close(
                    evidence.speechSeconds, 1_200, tolerance: 0.001,
                    "what the vector was computed from does not change by being corrected"
                )
                expect.close(
                    evidence.standingSeconds, 1_197, tolerance: 0.001,
                    "what still supports it does"
                )
            },

            test("corrections add up until too little of the audio is left") { expect in
                // Measured against what is left rather than against the
                // original, so a vector cannot be kept alive by being corrected
                // a little at a time.
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let chris = try await store.createPerson(name: "Chris")
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: chris.id, vector: vector(seed: 74), model: .fluidAudioOffline,
                    speechSeconds: 60, qualityScore: 1, source: .humanConfirmedCluster,
                    evidence: [VoiceEvidence(
                        meetingID: "m1", track: .remote, spans: [AudioSpan(start: 0, end: 60)],
                        confirmation: .humanConfirmedCluster
                    )]
                ))
                for window in [AudioSpan(start: 0, end: 8), AudioSpan(start: 8, end: 14)] {
                    let displaced = try await store.retractEvidence(
                        VoiceEvidenceRetraction(meetingID: "m1", track: .remote, spans: [window]),
                        keepingClaimant: false
                    )
                    expect.isTrue(displaced.isEmpty, "46 seconds still clears the 45 second bar")
                }
                expect.equal(try await samples(store, chris.id), 1)

                let displaced = try await store.retractEvidence(
                    VoiceEvidenceRetraction(
                        meetingID: "m1", track: .remote, spans: [AudioSpan(start: 14, end: 20)]
                    ),
                    keepingClaimant: false
                )
                expect.equal(displaced.map(\.rawValue), [chris.id.rawValue])
                expect.equal(
                    try await samples(store, chris.id), 0,
                    "40 seconds is below the bar that let the vector be stored at all"
                )
            },

            test("audio on one track never retracts a vector from the other") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let me = try await store.createPerson(name: "Andrew", isLocalUser: true)
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: me.id, vector: vector(seed: 75), model: .fluidAudioOffline,
                    speechSeconds: 200, qualityScore: 1, source: .micTrackDeterministic,
                    evidence: [VoiceEvidence(
                        meetingID: "m1", track: .mic, spans: [AudioSpan(start: 0, end: 200)],
                        confirmation: .micTrackDeterministic
                    )]
                ))
                let displaced = try await store.retractEvidence(
                    VoiceEvidenceRetraction(
                        meetingID: "m1", track: .remote, spans: [AudioSpan(start: 0, end: 200)]
                    ),
                    keepingClaimant: false
                )
                expect.isTrue(
                    displaced.isEmpty,
                    "the far end speaking over you is not you being corrected"
                )
                expect.equal(try await samples(store, me.id), 1)
            },

            test("a merge moves who owns a vector and not what it was derived from") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let service = SpeakerRecognitionService(store: store)
                let settings = SpeakerRecognitionSettings()

                let heard = try await store.createAnonymous(state: .persistent)
                _ = try await service.confirmCluster(
                    meetingID: "m1",
                    cluster: cluster(
                        "remote-001_speaker_00", analysis: "remote-001",
                        seconds: 90, seed: 76, from: 0
                    ),
                    identityID: heard.id, settings: settings
                )
                let chris = try await store.createPerson(name: "Chris")
                try await store.merge(heard.id, into: chris.id)
                expect.equal(
                    try await samples(store, chris.id), 1,
                    "the merged voice counts towards the survivor"
                )

                // Somebody else is confirmed on the same audio. The vector now
                // reads as Chris's, and it is still the same audio.
                let dana = try await store.createPerson(name: "Dana")
                _ = try await service.confirmCluster(
                    meetingID: "m1",
                    cluster: cluster(
                        "remote-002_speaker_07", analysis: "remote-002",
                        seconds: 90, seed: 76, from: 0
                    ),
                    identityID: dana.id, settings: settings
                )
                expect.equal(
                    try await samples(store, chris.id), 0,
                    "retraction reaches a vector parked under a merged-away identifier"
                )
                expect.equal(try await samples(store, dana.id), 1)
            },

            test("undoing a merge gives each identity back its own audio") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let chris = try await store.createPerson(name: "Chris")
                let other = try await store.createAnonymous(state: .persistent)
                for (identity, start) in [(chris, 0.0), (other, 600.0)] {
                    _ = try await store.enrol(VoiceEnrollmentCandidate(
                        identityID: identity.id, vector: vector(seed: start == 0 ? 77 : 78),
                        model: .fluidAudioOffline, speechSeconds: 90, qualityScore: 1,
                        source: .humanConfirmedCluster,
                        evidence: [VoiceEvidence(
                            meetingID: "m1", track: .remote,
                            spans: [AudioSpan(start: start, end: start + 90)],
                            confirmation: .humanConfirmedCluster
                        )]
                    ))
                }
                try await store.merge(other.id, into: chris.id)
                expect.equal(try await samples(store, chris.id), 2)

                try await store.unmerge(other.id)
                expect.equal(
                    try await samples(store, chris.id), 1,
                    "a split gives each side back the vectors derived from its own audio"
                )
                expect.equal(try await samples(store, other.id), 1)

                // And retraction still lands on exactly one of them.
                let displaced = try await store.retractEvidence(
                    VoiceEvidenceRetraction(
                        meetingID: "m1", track: .remote, spans: [AudioSpan(start: 600, end: 690)]
                    ),
                    keepingClaimant: false
                )
                expect.equal(displaced.map(\.rawValue), [other.id.rawValue])
                expect.equal(try await samples(store, chris.id), 1)
                expect.equal(try await samples(store, other.id), 0)
            },

            test("removing one vector rebuilds the centroid over what is left") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let chris = try await store.createPerson(name: "Chris")
                let kept = vector(seed: 79)
                for (seed, meeting, start) in [(79, "m1", 0.0), (80, "m2", 0.0)] {
                    _ = try await store.enrol(VoiceEnrollmentCandidate(
                        identityID: chris.id, vector: vector(seed: seed),
                        model: .fluidAudioOffline, speechSeconds: 90, qualityScore: 1,
                        source: .humanConfirmedCluster,
                        evidence: [VoiceEvidence(
                            meetingID: meeting, track: .remote,
                            spans: [AudioSpan(start: start, end: start + 90)],
                            confirmation: .humanConfirmedCluster
                        )]
                    ))
                }
                let blended = try await expect.unwrap(
                    store.searchableProfiles(model: .fluidAudioOffline).first?.centroid
                )
                expect.isTrue(
                    VoiceVector.cosine(blended, VoiceVector.l2Normalized(kept)) < 0.999,
                    "two recordings make a centroid that is neither of them"
                )

                _ = try await store.retractEvidence(
                    VoiceEvidenceRetraction(
                        meetingID: "m2", track: .remote, spans: [AudioSpan(start: 0, end: 90)]
                    ),
                    keepingClaimant: false
                )
                let rebuilt = try await expect.unwrap(
                    store.searchableProfiles(model: .fluidAudioOffline).first?.centroid
                )
                expect.close(
                    VoiceVector.cosine(rebuilt, VoiceVector.l2Normalized(kept)), 1,
                    tolerance: 0.0001,
                    "and removing one leaves the centroid exactly the other"
                )
                expect.equal(
                    try await store.profileStatus(
                        of: chris.id, model: .fluidAudioOffline
                    ).recordingCount,
                    1
                )
            },

            test("one meeting contributes one vector however often it is confirmed") { expect in
                // Enforced where the vector is written rather than by a check the
                // caller makes first. Reading a meeting's confirmed lines and
                // embedding them takes seconds, so two corrections a moment apart
                // both passed that check and both enrolled: one session then held
                // two of the twenty retained samples and evicted a genuinely
                // different recording.
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let chris = try await store.createPerson(name: "Chris")
                for round in 0..<3 {
                    try await store.addPendingEnrollment(VoiceEnrollmentCandidate(
                        identityID: chris.id, vector: vector(seed: 82 + round),
                        model: .fluidAudioOffline, speechSeconds: 60, qualityScore: 1,
                        source: .humanConfirmedUtterances,
                        evidence: [VoiceEvidence(
                            meetingID: "m1", track: .remote,
                            spans: [AudioSpan(start: 0, end: 60)],
                            confirmation: .humanConfirmedUtterances
                        )]
                    ))
                    expect.isTrue(
                        try await store.flushPendingEnrollment(
                            for: chris.id, model: .fluidAudioOffline
                        ),
                        "each round has enough speech to enrol"
                    )
                }
                expect.equal(
                    try await samples(store, chris.id), 1,
                    "the later round replaces the earlier one rather than joining it"
                )
                expect.equal(
                    try await store.storedEmbeddings(of: chris.id).count, 1
                )
            },

            test("a store written before evidence existed opens, keeping its people") { expect in
                // MeetTape has not shipped, so this is not a released schema
                // being migrated: it is a development store from an earlier
                // state of this branch. Its identities are worth keeping. Its
                // vectors are not, because nothing records what audio they came
                // from and nothing could ever take them back.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let url = root.appendingPathComponent("voices.sqlite")
                try writePreEvidenceStore(at: url)

                let store = try SpeakerStore(url: url)
                let people = try await store.identities(kind: .person)
                expect.equal(people.map(\.displayName), ["Chris"], "the person is still there")
                expect.equal(
                    try await samples(store, people[0].id), 0,
                    "and the vector nothing could retract is gone"
                )

                // The store is fully usable afterwards, which is what says the
                // tables really were created rather than the read failing
                // quietly.
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: people[0].id, vector: vector(seed: 81),
                    model: .fluidAudioOffline, speechSeconds: 90, qualityScore: 1,
                    source: .humanConfirmedCluster,
                    evidence: [VoiceEvidence(
                        meetingID: "m9", track: .remote, spans: [AudioSpan(start: 0, end: 90)],
                        confirmation: .humanConfirmedCluster
                    )]
                ))
                expect.equal(try await samples(store, people[0].id), 1)
            },
        ])
    }

    /// A store shaped the way this branch wrote them before spans were
    /// recorded: identities and vectors, no evidence tables.
    private static func writePreEvidenceStore(at url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        ) == SQLITE_OK, let handle else {
            throw StorageError.meetingNotFound(id: url.path)
        }
        defer { sqlite3_close(handle) }
        let now = Date().timeIntervalSince1970
        let statements = """
            CREATE TABLE identity(
              id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, display_name TEXT,
              anonymous_number INTEGER, organization TEXT, is_local_user INTEGER NOT NULL DEFAULT 0,
              state TEXT NOT NULL, merged_into INTEGER, created_at REAL NOT NULL,
              updated_at REAL NOT NULL, last_seen_at REAL);
            CREATE TABLE identity_alias(identity_id INTEGER NOT NULL, alias TEXT NOT NULL,
              PRIMARY KEY(identity_id, alias));
            CREATE TABLE voice_embedding(
              id INTEGER PRIMARY KEY AUTOINCREMENT, identity_id INTEGER NOT NULL,
              model_identifier TEXT NOT NULL, embedding_dim INTEGER NOT NULL, embedding BLOB NOT NULL,
              quality_score REAL NOT NULL, speech_seconds REAL NOT NULL, source_type TEXT NOT NULL,
              source_meeting TEXT, source_cluster TEXT, is_human_verified INTEGER NOT NULL DEFAULT 1,
              created_at REAL NOT NULL);
            CREATE TABLE derived_profile(
              identity_id INTEGER NOT NULL, model_identifier TEXT NOT NULL, centroid BLOB NOT NULL,
              embedding_dim INTEGER NOT NULL, sample_count INTEGER NOT NULL,
              recording_count INTEGER NOT NULL, speech_seconds REAL NOT NULL,
              updated_at REAL NOT NULL, PRIMARY KEY(identity_id, model_identifier));
            CREATE TABLE speaker_occurrence(
              id INTEGER PRIMARY KEY AUTOINCREMENT, meeting_id TEXT NOT NULL, cluster_id TEXT NOT NULL,
              track TEXT NOT NULL, speech_seconds REAL NOT NULL, embedding BLOB, embedding_dim INTEGER,
              model_identifier TEXT, resolved_identity_id INTEGER, resolution_source TEXT NOT NULL,
              score REAL, runner_up_score REAL, margin REAL, threshold_band TEXT NOT NULL,
              human_verified INTEGER NOT NULL DEFAULT 0, expected_participant INTEGER NOT NULL DEFAULT 0,
              created_at REAL NOT NULL, updated_at REAL NOT NULL, UNIQUE(meeting_id, cluster_id));
            CREATE TABLE pending_enrollment(
              id INTEGER PRIMARY KEY AUTOINCREMENT, identity_id INTEGER NOT NULL,
              model_identifier TEXT NOT NULL, embedding BLOB NOT NULL, embedding_dim INTEGER NOT NULL,
              speech_seconds REAL NOT NULL, quality_score REAL NOT NULL, source_type TEXT NOT NULL,
              source_meeting TEXT, source_cluster TEXT, created_at REAL NOT NULL);
            INSERT INTO identity(kind, display_name, state, created_at, updated_at)
              VALUES('person', 'Chris', 'persistent', \(now), \(now));
            INSERT INTO voice_embedding(identity_id, model_identifier, embedding_dim, embedding,
                quality_score, speech_seconds, source_type, source_meeting, source_cluster,
                is_human_verified, created_at)
              VALUES(1, '\(EmbeddingModelIdentifier.fluidAudioOffline.rawValue)', 256, x'00',
                1, 90, 'human_confirmed_cluster', 'm1', 'remote-001_speaker_00', 1, \(now));
            INSERT INTO derived_profile(identity_id, model_identifier, centroid, embedding_dim,
                sample_count, recording_count, speech_seconds, updated_at)
              VALUES(1, '\(EmbeddingModelIdentifier.fluidAudioOffline.rawValue)', x'00', 256,
                1, 1, 90, \(now));
            PRAGMA user_version = 1;
            """
        guard sqlite3_exec(handle, statements, nil, nil, nil) == SQLITE_OK else {
            throw StorageError.meetingNotFound(id: url.path)
        }
    }
}
