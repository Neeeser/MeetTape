import Foundation
import MeetTapeCore

/// One diarization cluster offered for identification.
public struct SpeakerClusterInput: Sendable, Equatable {
    public var clusterID: String
    public var track: CaptureTrack
    public var speechSeconds: Double
    /// Centroid over the cluster's own chunk embeddings. A cluster centroid
    /// scores far better than any single chunk: at roughly nine seconds the 1st
    /// percentile of genuine scores is 0.28, and over two minutes it is 0.82.
    public var centroid: [Float]
    public var quality: Double

    public init(
        clusterID: String, track: CaptureTrack, speechSeconds: Double,
        centroid: [Float], quality: Double = 1
    ) {
        self.clusterID = clusterID
        self.track = track
        self.speechSeconds = speechSeconds
        self.centroid = centroid
        self.quality = quality
    }
}

/// What identification concluded about one cluster.
public struct ResolvedCluster: Sendable, Equatable {
    public var clusterID: String
    public var track: CaptureTrack
    public var identity: Identity?
    public var resolution: SpeakerResolution
    public var source: SpeakerAssignmentOrigin
    /// True when this cluster started a new unnamed identity.
    public var createdIdentity: Bool
    /// Meetings this identity has been heard in, including this one.
    public var meetingCount: Int

    public init(
        clusterID: String, track: CaptureTrack, identity: Identity?,
        resolution: SpeakerResolution, source: SpeakerAssignmentOrigin,
        createdIdentity: Bool, meetingCount: Int
    ) {
        self.clusterID = clusterID
        self.track = track
        self.identity = identity
        self.resolution = resolution
        self.source = source
        self.createdIdentity = createdIdentity
        self.meetingCount = meetingCount
    }

    public var displayName: String? { identity?.resolvedName }
}

/// Matches clusters to identities and owns everything that writes to a profile.
///
/// The division that matters: recognition reads, human confirmation writes.
/// Nothing in `resolve` adds a vector to a named profile, at any confidence, so
/// a wrong automatic answer that nobody corrects leaves the profile exactly as
/// it was and cannot compound.
public actor SpeakerRecognitionService {
    private let store: SpeakerStore
    private let policy: SpeakerResolutionPolicy

    public init(store: SpeakerStore, policy: SpeakerResolutionPolicy = .shipping) {
        self.store = store
        self.policy = policy
    }

    public var resolutionPolicy: SpeakerResolutionPolicy { policy }
    public var speakerStore: SpeakerStore { store }

    // MARK: - recognition

    /// Identifies every cluster in one meeting against the whole gallery.
    ///
    /// The gallery is searched globally: an expected-participant list relaxes
    /// the margin a listed candidate needs and nothing else, so an unexpected
    /// guest is left Unknown rather than forced onto whoever was invited.
    public func resolve(
        meetingID: String,
        clusters: [SpeakerClusterInput],
        expectedParticipants: Set<IdentityID> = [],
        settings: SpeakerRecognitionSettings,
        model: EmbeddingModelIdentifier = .fluidAudioOffline,
        now: Date = Date()
    ) async throws -> [ResolvedCluster] {
        var profiles = try await store.searchableProfiles(model: model)
        if !settings.recognizeKnownVoices { profiles.removeAll { $0.identity.kind == .person } }
        if !settings.rememberRecurringVoices { profiles.removeAll { $0.identity.kind == .anonymous } }

        var results: [ResolvedCluster] = []
        for cluster in clusters {
            let resolved = try await resolveOne(
                meetingID: meetingID, cluster: cluster, profiles: &profiles,
                expectedParticipants: expectedParticipants, settings: settings,
                model: model, now: now
            )
            results.append(resolved)
        }
        return results
    }

    private func resolveOne(
        meetingID: String,
        cluster: SpeakerClusterInput,
        profiles: inout [SpeakerProfile],
        expectedParticipants: Set<IdentityID>,
        settings: SpeakerRecognitionSettings,
        model: EmbeddingModelIdentifier,
        now: Date
    ) async throws -> ResolvedCluster {
        let probe = VoiceVector.l2Normalized(cluster.centroid)
        let candidates: [SpeakerCandidate] = probe.isEmpty ? [] : profiles.map { profile in
            SpeakerCandidate(
                identityID: profile.identity.id,
                kind: profile.identity.kind,
                displayName: profile.identity.resolvedName,
                score: VoiceVector.cosine(probe, profile.centroid),
                isExpectedParticipant: expectedParticipants.contains(profile.identity.id)
            )
        }
        let resolution = policy.resolve(candidates: candidates, speechSeconds: cluster.speechSeconds)

        var identity: Identity?
        var source: SpeakerAssignmentOrigin = .ai
        var created = false

        switch resolution.outcome {
        case .assign(let id):
            identity = try await store.current(id)
            source = .voiceProfile
            if let identity { try await store.noteSeen(identity.id, at: now) }

        case .seenBefore(let id):
            // Hearing a candidate a second time is what makes it a recurring
            // voice. The profile itself is not touched: an automatic link may
            // never add a vector.
            identity = try await store.current(id)
            source = .anonymousVoice
            if let found = identity, found.state == .ephemeral {
                identity = try await store.promoteToPersistent(found.id, now: now) ?? found
            }
            if let identity { try await store.noteSeen(identity.id, at: now) }

        case .suggest, .unknown:
            // A voice with enough clean speech is worth remembering even when
            // nobody knows who it is. Below the bar it stays a speaker number in
            // this meeting and leaves nothing behind.
            if settings.rememberRecurringVoices, !probe.isEmpty,
               policy.qualifiesForAnonymousProfile(speechSeconds: cluster.speechSeconds) {
                let fresh = try await store.createAnonymous(state: .ephemeral, now: now)
                _ = try await store.enrol(
                    VoiceEnrollmentCandidate(
                        identityID: fresh.id,
                        vector: probe,
                        model: model,
                        speechSeconds: cluster.speechSeconds,
                        qualityScore: cluster.quality,
                        source: .anonymousSeed,
                        meetingID: meetingID,
                        clusterID: cluster.clusterID
                    ),
                    now: now
                )
                identity = fresh
                created = true
                if let refreshed = try await store.searchableProfiles(model: model)
                    .first(where: { $0.identity.id == fresh.id }) {
                    profiles.append(refreshed)
                }
            }
        }

        try await store.recordOccurrence(
            meetingID: meetingID,
            clusterID: cluster.clusterID,
            track: cluster.track,
            speechSeconds: cluster.speechSeconds,
            embedding: probe.isEmpty ? nil : probe,
            model: model,
            resolution: resolution,
            identityID: identity?.id,
            source: created ? .ai : source,
            humanVerified: false,
            wasExpectedParticipant: identity.map { expectedParticipants.contains($0.id) } ?? false,
            now: now
        )

        var heardIn = 0
        if let identity { heardIn = (try? await store.meetingCount(for: identity.id)) ?? 0 }

        // A voice heard for the first time is remembered but not announced:
        // the meeting still shows a speaker number, because "seen before" is
        // only true once it has been.
        return ResolvedCluster(
            clusterID: cluster.clusterID,
            track: cluster.track,
            identity: created ? nil : identity,
            resolution: resolution,
            source: created ? .ai : source,
            createdIdentity: created,
            meetingCount: heardIn
        )
    }

    // MARK: - human confirmation

    /// A person said a whole cluster is someone. That is identity truth, and it
    /// is the main way profiles get built.
    public func confirmCluster(
        meetingID: String,
        cluster: SpeakerClusterInput,
        identityID: IdentityID,
        settings: SpeakerRecognitionSettings,
        model: EmbeddingModelIdentifier = .fluidAudioOffline,
        now: Date = Date()
    ) async throws -> VoiceProfileStatus {
        let vector = VoiceVector.l2Normalized(cluster.centroid)
        try await store.recordOccurrence(
            meetingID: meetingID,
            clusterID: cluster.clusterID,
            track: cluster.track,
            speechSeconds: cluster.speechSeconds,
            embedding: vector.isEmpty ? nil : vector,
            model: model,
            resolution: nil,
            identityID: identityID,
            source: .human,
            humanVerified: true,
            wasExpectedParticipant: false,
            now: now
        )
        guard settings.learnFromCorrections, !vector.isEmpty else {
            return try await store.profileStatus(of: identityID, model: model)
        }
        _ = try await store.enrol(
            VoiceEnrollmentCandidate(
                identityID: identityID,
                vector: vector,
                model: model,
                speechSeconds: cluster.speechSeconds,
                qualityScore: cluster.quality,
                source: .humanConfirmedCluster,
                meetingID: meetingID,
                clusterID: cluster.clusterID
            ),
            now: now
        )
        return try await store.profileStatus(of: identityID, model: model)
    }

    /// A person corrected individual lines.
    ///
    /// One line is identity truth and almost never enough audio: below ten
    /// seconds the 1st percentile of genuine scores is 0.28. Confirmed material
    /// accumulates and enrols in one piece once it reaches the duration bar.
    public func confirmUtterances(
        meetingID: String,
        identityID: IdentityID,
        vectors: [DiarizationChunkEmbedding],
        settings: SpeakerRecognitionSettings,
        model: EmbeddingModelIdentifier = .fluidAudioOffline,
        now: Date = Date()
    ) async throws -> VoiceProfileStatus {
        guard settings.learnFromCorrections, !vectors.isEmpty else {
            return try await store.profileStatus(of: identityID, model: model)
        }
        let seconds = vectors.reduce(0) { $0 + $1.duration }
        try await store.addPendingEnrollment(
            VoiceEnrollmentCandidate(
                identityID: identityID,
                vector: VoiceVector.centroid(vectors.map(\.vector)),
                model: model,
                speechSeconds: seconds,
                qualityScore: 1,
                source: .humanConfirmedUtterances,
                meetingID: meetingID
            ),
            now: now
        )
        _ = try await store.flushPendingEnrollment(for: identityID, model: model, now: now)
        return try await store.profileStatus(of: identityID, model: model)
    }

    /// The local user's own voice, from the track where their identity is known
    /// by construction.
    ///
    /// This is what makes an in-person or imported recording recognizable:
    /// enrolling on remote-call audio and testing on room audio cost 0.01 to
    /// 0.03 of similarity, with every cross-domain minimum still far above the
    /// highest impostor score.
    public func learnLocalUserVoice(
        meetingID: String,
        identityID: IdentityID,
        vector: [Float],
        speechSeconds: Double,
        quality: Double,
        model: EmbeddingModelIdentifier = .fluidAudioOffline,
        now: Date = Date()
    ) async throws -> VoiceProfileStatus {
        _ = try await store.enrol(
            VoiceEnrollmentCandidate(
                identityID: identityID,
                vector: vector,
                model: model,
                speechSeconds: speechSeconds,
                qualityScore: quality,
                source: .micTrackDeterministic,
                meetingID: meetingID
            ),
            now: now
        )
        return try await store.profileStatus(of: identityID, model: model)
    }

    /// Whether the local user's profile still wants material from this meeting.
    ///
    /// Stops once the retained-sample cap is reached, which bounds both the work
    /// and the store. Separation was flat past about five confirmed recordings,
    /// so the last few samples buy diversity rather than accuracy.
    public func wantsLocalUserSample(
        identityID: IdentityID, model: EmbeddingModelIdentifier = .fluidAudioOffline
    ) async throws -> Bool {
        let status = try await store.profileStatus(of: identityID, model: model)
        return status.sampleCount < policy.maximumEmbeddingsPerIdentity
    }
}
