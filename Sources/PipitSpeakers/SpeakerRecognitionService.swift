import Foundation
import PipitCore

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
    /// The audio the centroid was built over, on the meeting timeline. Carried
    /// so that confirming this cluster records what it covers rather than only
    /// which label the diarizer gave it, and so two clusters can be asked
    /// whether they overlap in time.
    public var spans: [AudioSpan]
    /// The diarization run the cluster belongs to. Context, kept out of every
    /// retraction decision because a re-analysis replaces it.
    public var analysisID: String?

    public init(
        clusterID: String, track: CaptureTrack, speechSeconds: Double,
        centroid: [Float], quality: Double = 1,
        spans: [AudioSpan] = [], analysisID: String? = nil
    ) {
        self.clusterID = clusterID
        self.track = track
        self.speechSeconds = speechSeconds
        self.centroid = centroid
        self.quality = quality
        self.spans = AudioSpan.union(spans)
        self.analysisID = analysisID
    }

    /// What a vector derived from this cluster was derived from.
    public func evidence(meetingID: String, confirmation: VoiceEnrollmentSource) -> VoiceEvidence {
        VoiceEvidence(
            meetingID: meetingID, track: track, spans: spans,
            confirmation: confirmation, analysisID: analysisID, clusterID: clusterID
        )
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
        // Voices this meeting itself created are not candidates for it. A
        // cluster would otherwise score 1.0 against the profile seeded from its
        // own vector on an earlier pass and be reported as heard before, and a
        // sibling cluster would link to it within the one meeting it has ever
        // been heard in.
        var profiles = try await store.searchableProfiles(
            model: model, excludingSeededIn: meetingID
        )
        if !settings.recognizeKnownVoices { profiles.removeAll { $0.identity.kind == .person } }
        if !settings.rememberRecurringVoices { profiles.removeAll { $0.identity.kind == .anonymous } }

        var results: [ResolvedCluster] = []
        // Which audio each identity has already been given in this meeting.
        //
        // Not a flat exclusion. The tuned clusterer prefers splitting a speaker
        // over merging two, so one recurring voice arriving as two clusters is
        // the expected failure and both may be that person. What one person
        // cannot do is talk over themselves, so the test is overlap in time
        // rather than "already used".
        var claimed: [IdentityID: [AudioSpan]] = [:]
        let ordered = clusters.sorted {
            ($0.spans.first?.start ?? 0) < ($1.spans.first?.start ?? 0)
        }
        for cluster in ordered {
            let resolved = try await resolveOne(
                meetingID: meetingID, cluster: cluster, profiles: profiles,
                expectedParticipants: expectedParticipants, settings: settings,
                model: model, claimed: claimed, now: now
            )
            var owner = resolved.identity?.id
            if owner == nil {
                owner = try await existingLink(
                    meetingID: meetingID, clusterID: cluster.clusterID
                )?.id
            }
            if let owner { claimed[owner, default: []] += cluster.spans }
            results.append(resolved)
        }
        return results
    }

    /// Identities already speaking over this cluster's audio.
    private func concurrent(
        with cluster: SpeakerClusterInput, claimed: [IdentityID: [AudioSpan]]
    ) -> Set<IdentityID> {
        var out: Set<IdentityID> = []
        for (identity, spans) in claimed
        where AudioSpan.intersect(spans, cluster.spans) > policy.simultaneousSpeechSeconds {
            out.insert(identity)
        }
        return out
    }

    private func resolveOne(
        meetingID: String,
        cluster: SpeakerClusterInput,
        profiles: [SpeakerProfile],
        expectedParticipants: Set<IdentityID>,
        settings: SpeakerRecognitionSettings,
        model: EmbeddingModelIdentifier,
        claimed: [IdentityID: [AudioSpan]],
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
        let resolution = policy.resolve(
            candidates: candidates, speechSeconds: cluster.speechSeconds,
            concurrent: concurrent(with: cluster, claimed: claimed)
        )

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
                switch try await sameMeetingCandidate(
                    meetingID: meetingID, cluster: cluster, probe: probe,
                    model: model, claimed: claimed
                ) {
                case .reuse(let existing):
                    identity = existing
                    created = true
                case .abstain:
                    // Close to a voice this meeting already made a candidate of,
                    // but not close enough to be it. Remembering it anyway is
                    // what poisons the memory: two profiles a few hundredths
                    // apart split each other's margin, so neither is ever
                    // recognised again, and that outlives the meeting.
                    break
                case .fresh:
                    let fresh = try await store.createAnonymous(state: .ephemeral, now: now)
                    _ = try await store.enrol(
                        VoiceEnrollmentCandidate(
                            identityID: fresh.id,
                            vector: probe,
                            model: model,
                            speechSeconds: cluster.speechSeconds,
                            qualityScore: cluster.quality,
                            source: .anonymousSeed,
                            evidence: [cluster.evidence(
                                meetingID: meetingID, confirmation: .anonymousSeed
                            )]
                        ),
                        now: now
                    )
                    identity = fresh
                    created = true
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

    /// What to do about an unnamed voice this meeting has already made a
    /// candidate of.
    enum SameMeetingCandidate {
        /// This cluster is that voice: the same cluster on an earlier pass, or
        /// the other half of a speaker the clusterer split.
        case reuse(Identity)
        /// Close, but not close enough to say. Remember nothing.
        case abstain
        /// A different voice. Worth remembering on its own.
        case fresh
    }

    /// Decides whether this cluster is a voice this meeting already remembered.
    ///
    /// Three answers rather than two, because the middle case is the one that
    /// does lasting damage. A cluster half-matching a candidate this meeting
    /// seeded is either the same person the clusterer split or a different
    /// person who sounds like them, and creating a second profile is wrong
    /// either way: two centroids a few hundredths apart split each other's
    /// margin, so from then on neither is recognised anywhere.
    private func sameMeetingCandidate(
        meetingID: String, cluster: SpeakerClusterInput, probe: [Float],
        model: EmbeddingModelIdentifier, claimed: [IdentityID: [AudioSpan]]
    ) async throws -> SameMeetingCandidate {
        // The same cluster on an earlier pass over this meeting. Resolving twice
        // must remember one voice, not two.
        if let identity = try await existingLink(
            meetingID: meetingID, clusterID: cluster.clusterID
        ) {
            return .reuse(identity)
        }

        // Re-analysis renumbers the runs, so the same voice arrives under a new
        // key and the check above misses it. The candidates this meeting seeded
        // are excluded from the gallery, correctly, so without this the voice
        // creates a second unnamed identity holding the same vector, and a third
        // on the next re-analysis.
        //
        // Reused rather than linked: this is still a voice heard once, so it does
        // not become one heard before.
        guard !probe.isEmpty else { return .fresh }
        // Not one that is speaking over this cluster. Those are two people, and
        // reusing one here would merge them. A candidate that merely spoke
        // elsewhere in the meeting is the split this exists to repair.
        let concurrent = concurrent(with: cluster, claimed: claimed)
        let seeded = try await store.profilesSeededOnlyIn(meetingID: meetingID, model: model)
            .filter { !concurrent.contains($0.identity.id) }
        var ranked: [(identity: Identity, score: Double)] = []
        for profile in seeded {
            ranked.append((profile.identity, VoiceVector.cosine(probe, profile.centroid)))
        }
        ranked.sort { $0.score > $1.score }
        guard let best = ranked.first else { return .fresh }
        // The same separation a link to a remembered voice needs. Two seeds a few
        // hundredths apart are two people the clusterer split, and picking the
        // higher would merge them on nothing.
        let runnerUp = ranked.dropFirst().first?.score
        let separated = runnerUp.map { best.score - $0 >= policy.anonymousLinkMargin } ?? true
        if best.score >= policy.anonymousLinkScore, separated { return .reuse(best.identity) }
        if best.score >= policy.anonymousSuggestScore { return .abstain }
        return .fresh
    }

    /// The unnamed identity a cluster is already linked to in this meeting.
    private func existingLink(meetingID: String, clusterID: String) async throws -> Identity? {
        let occurrences = try await store.occurrences(meetingID: meetingID)
        guard let occurrence = occurrences.first(where: { $0.clusterID == clusterID }),
              let identityID = occurrence.resolvedIdentityID,
              let identity = try await store.current(identityID),
              identity.kind == .anonymous
        else { return nil }
        return identity
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
        let evidence = cluster.evidence(meetingID: meetingID, confirmation: .humanConfirmedCluster)
        let retraction = VoiceEvidenceRetraction.claiming(evidence, for: identityID)
        // Before the learning guard, and only for other identities: the user has
        // said this audio is someone else's, so whoever holds a vector derived
        // from it is holding a voice that is not theirs, and refusing to remove
        // it because learning is switched off leaves them auto-named from it
        // forever. This identity's own row is dealt with below, where it can be
        // replaced rather than only removed.
        _ = try await store.retractEvidence(retraction, keepingClaimant: true, now: now)
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
        // This cluster's audio belongs to whoever is being confirmed now and to
        // nobody else, so any earlier enrolment from it goes first: correcting a
        // name applied a moment ago otherwise left the vector inside the first
        // person's profile, human-verified, and the next meeting auto-named them
        // as that person. This identity's own earlier row goes too, because the
        // fresh one replaces it rather than joining it and doubling that one
        // recording's weight.
        //
        _ = try await store.retractEvidence(retraction, keepingClaimant: false, now: now)
        _ = try await store.enrol(
            VoiceEnrollmentCandidate(
                identityID: identityID,
                vector: vector,
                model: model,
                speechSeconds: cluster.speechSeconds,
                qualityScore: cluster.quality,
                source: .humanConfirmedCluster,
                evidence: [evidence]
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
        track: CaptureTrack,
        spans: [AudioSpan],
        settings: SpeakerRecognitionSettings,
        model: EmbeddingModelIdentifier = .fluidAudioOffline,
        now: Date = Date()
    ) async throws -> VoiceProfileStatus {
        guard settings.learnFromCorrections, !vectors.isEmpty, !spans.isEmpty else {
            return try await store.profileStatus(of: identityID, model: model)
        }
        let seconds = vectors.reduce(0) { $0 + $1.duration }
        // Quality is how much confirmed speech stands behind the vector, not a
        // flat 1. A literal 1 sorted every correction ahead of the measured
        // quality on mic-track and cluster enrolments, so one session's
        // corrections evicted a profile's genuinely diverse recordings.
        let quality = min(1, seconds / (policy.enrolmentSpeechSeconds * 2))
        try await store.addPendingEnrollment(
            VoiceEnrollmentCandidate(
                identityID: identityID,
                vector: VoiceVector.centroid(vectors.map(\.vector)),
                model: model,
                speechSeconds: seconds,
                qualityScore: quality,
                source: .humanConfirmedUtterances,
                evidence: [VoiceEvidence(
                    meetingID: meetingID, track: track, spans: spans,
                    confirmation: .humanConfirmedUtterances
                )]
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
        spans: [AudioSpan],
        model: EmbeddingModelIdentifier = .fluidAudioOffline,
        now: Date = Date()
    ) async throws -> VoiceProfileStatus? {
        guard !spans.isEmpty else { return nil }
        // The microphone track is the local user only when it holds the local
        // user. Echo cancellation is disabled on some device pairings and falls
        // back to plain capture, so on speakers the far end reaches the
        // microphone too, and a listener in a long presentation is not the
        // dominant voice on their own track. Dominance alone would then enrol
        // the presenter here, human-verified, into the one profile no person
        // ever confirms.
        //
        // Anything on this meeting's other track is by construction not the
        // local user, so a strong match against one is bleed.
        if let bleed = try await matchesAnotherTrack(
            meetingID: meetingID, vector: vector, model: model
        ) {
            Log.processing.notice(
                "mic track not enrolled: matches this meeting's \(bleed.track?.rawValue ?? "uncomparable", privacy: .public) audio at \(String(format: "%.2f", bleed.score), privacy: .public)"
            )
            return nil
        }

        _ = try await store.enrol(
            VoiceEnrollmentCandidate(
                identityID: identityID,
                vector: vector,
                model: model,
                speechSeconds: speechSeconds,
                qualityScore: quality,
                source: .micTrackDeterministic,
                evidence: [VoiceEvidence(
                    meetingID: meetingID, track: .mic, spans: spans,
                    confirmation: .micTrackDeterministic
                )]
            ),
            now: now
        )
        return try await store.profileStatus(of: identityID, model: model)
    }

    /// The closest cluster on a track other than the microphone, when it is
    /// close enough to be the same voice.
    ///
    /// Scored at the same bar that links a voice to one already remembered: the
    /// question is identical, and answering it more loosely here would let bleed
    /// through into a profile nothing later corrects.
    private func matchesAnotherTrack(
        meetingID: String, vector: [Float], model: EmbeddingModelIdentifier
    ) async throws -> (track: CaptureTrack?, score: Double)? {
        let probe = VoiceVector.l2Normalized(vector)
        var closest: (track: CaptureTrack, score: Double)?
        var comparable = 0
        let others = try await store.occurrences(meetingID: meetingID)
            .filter { $0.track != .mic }
        for occurrence in others {
            guard let other = try await store.occurrenceEmbedding(
                meetingID: meetingID, clusterID: occurrence.clusterID, model: model
            ) else { continue }
            comparable += 1
            let score = VoiceVector.cosine(probe, other)
            if score >= policy.anonymousLinkScore, score > (closest?.score ?? 0) {
                closest = (occurrence.track, score)
            }
        }
        if let closest { return closest }
        // Fails closed. A cloud diarizer produces no vectors, and they are only
        // filled in later by a pass that both recognition settings can switch
        // off, so with the wrong combination there was nothing to compare
        // against and the check silently passed everything. The same hole opens
        // when the far end produced no clusters at all: an unreadable track or a
        // tap that recorded silence leaves `others` empty, and treating "nothing
        // to compare against" as "no bleed" is the failure this guard exists to
        // stop. The caller has already established that the far end has audio.
        // Refusing costs one meeting's worth of learning; allowing costs the one
        // profile no person ever confirms or reviews.
        guard comparable > 0 else { return (others.first?.track, 0) }
        return nil
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
