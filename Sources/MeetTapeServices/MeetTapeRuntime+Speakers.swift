import Foundation
import MeetTapeCore
import MeetTapeLocalAI
import MeetTapeSpeakers

/// One row of the people list: who they are, how much voice material exists,
/// and how often they have been heard.
public struct SpeakerDirectoryEntry: Sendable, Equatable, Identifiable {
    public var identity: Identity
    public var profile: VoiceProfileStatus
    public var meetingCount: Int

    public var id: IdentityID { identity.id }

    public init(identity: Identity, profile: VoiceProfileStatus, meetingCount: Int) {
        self.identity = identity
        self.profile = profile
        self.meetingCount = meetingCount
    }
}

/// One speaker in one meeting, as the review panel shows them.
public struct MeetingSpeakerRow: Sendable, Equatable, Identifiable {
    public var clusterID: String
    public var displayName: String
    public var band: SpeakerConfidenceBand
    public var origin: SpeakerAssignmentOrigin
    public var identity: Identity?
    public var speechSeconds: Double
    public var provenance: SpeakerProvenance?
    /// Meetings this identity has been heard in, for the "seen before" context.
    public var meetingCount: Int

    public var id: String { clusterID }

    public init(
        clusterID: String, displayName: String, band: SpeakerConfidenceBand,
        origin: SpeakerAssignmentOrigin, identity: Identity?, speechSeconds: Double,
        provenance: SpeakerProvenance?, meetingCount: Int
    ) {
        self.clusterID = clusterID
        self.displayName = displayName
        self.band = band
        self.origin = origin
        self.identity = identity
        self.speechSeconds = speechSeconds
        self.provenance = provenance
        self.meetingCount = meetingCount
    }
}

extension MeetTapeRuntime {
    // MARK: - model management

    public var localModelsInstalled: Bool { localModelState.isUsable }

    public func refreshLocalModelState() async {
        guard let models else { return }
        localModelState = await models.currentState
    }

    /// Downloads and prepares the on-device models. Recording is unaffected
    /// while it runs; a meeting that finishes meanwhile queues.
    public func installLocalModels() async {
        guard let models else { return }
        do {
            _ = try await models.install()
        } catch {
            Log.app.error("model install failed: \(logSafeDescription(error), privacy: .public)")
        }
        await refreshLocalModelState()
    }

    /// Fetches the models again even though a usable copy is on disk. What the
    /// Re-download button calls, for an install pinned by an older build.
    public func reinstallLocalModels() async {
        guard let models else { return }
        do {
            try await models.reinstall()
        } catch {
            Log.app.error("model reinstall failed: \(logSafeDescription(error), privacy: .public)")
        }
        await refreshLocalModelState()
    }

    public func removeLocalModels() async {
        guard let models else { return }
        do {
            try await models.removeInstalledModels()
        } catch {
            Log.app.error("model removal failed: \(logSafeDescription(error), privacy: .public)")
        }
        await refreshLocalModelState()
    }

    // MARK: - the local user

    /// Makes sure one identity represents the person using this Mac.
    ///
    /// No training wizard: the microphone track of ordinary remote calls is the
    /// enrolment material, and it is correct by construction. This just gives
    /// that material somewhere to go.
    public func ensureLocalUserIdentity() async {
        guard let store = speakerStore else { return }
        do {
            if let identifier = settings.processing.localUserIdentityID,
               let existing = try await store.current(identifier) {
                if existing.resolvedName != settings.localUserName, !settings.localUserName.isEmpty {
                    _ = try await store.rename(existing.id, to: settings.localUserName)
                }
                return
            }
            let identity: Identity
            if let existing = try await store.localUser() {
                identity = existing
            } else {
                identity = try await store.createPerson(
                    name: settings.localUserName.isEmpty ? "Me" : settings.localUserName,
                    isLocalUser: true
                )
            }
            var updated = settings
            updated.processing.localUserIdentityID = identity.id
            update(settings: updated)
        } catch {
            Log.app.error("local identity unavailable: \(logSafeDescription(error), privacy: .public)")
        }
    }

    /// Forgets unnamed voices heard once and never matched again.
    public func pruneVoiceMemory() async {
        guard let store = speakerStore else { return }
        do {
            let removed = try await store.expireEphemeralIdentities()
            if removed > 0 {
                Log.app.info("expired \(removed, privacy: .public) unmatched voice candidates")
            }
        } catch {
            Log.app.error("voice memory prune failed: \(logSafeDescription(error), privacy: .public)")
        }
    }

    // MARK: - the people list

    public func speakerDirectory(kind: IdentityKind? = nil) async -> [SpeakerDirectoryEntry] {
        guard let store = speakerStore else { return [] }
        do {
            let identities = try await store.identities(kind: kind)
            var rows: [SpeakerDirectoryEntry] = []
            for identity in identities {
                // A candidate heard once is not shown as a recurring voice: it
                // becomes one only when it turns up again.
                if identity.kind == .anonymous, identity.state == .ephemeral { continue }
                rows.append(SpeakerDirectoryEntry(
                    identity: identity,
                    profile: try await store.profileStatus(of: identity.id, model: .fluidAudioOffline),
                    meetingCount: try await store.meetingCount(for: identity.id)
                ))
            }
            return rows
        } catch {
            Log.app.error("people list unavailable: \(logSafeDescription(error), privacy: .public)")
            return []
        }
    }

    public func voiceMemoryStatistics() async -> SpeakerStore.Statistics? {
        guard let store = speakerStore else { return nil }
        return try? await store.statistics()
    }

    /// Which meetings a voice has been heard in, for the "seen before" panel.
    public func meetingsHeard(identityID: IdentityID, limit: Int = 6) async -> [MeetingSummary] {
        guard let store = speakerStore else { return [] }
        guard let ids = try? await store.meetingsReferencing(identityID) else { return [] }
        let wanted = Set(ids)
        return repository.listMeetings().filter { wanted.contains($0.id) }.prefix(limit).map { $0 }
    }

    public func renamePerson(
        _ identityID: IdentityID, to name: String, organization: String? = nil
    ) async {
        guard let store = speakerStore else { return }
        do {
            let current = try await store.current(identityID)
            if current?.kind == .anonymous {
                _ = try await store.promoteToPerson(
                    identityID, name: name, organization: organization
                )
            } else {
                _ = try await store.rename(identityID, to: name, organization: .some(organization))
            }
            // ensureLocalUserIdentity renames this identity back to
            // settings.localUserName at every launch, so renaming yourself in
            // the People tab reverted on the next start, and new meetings kept
            // labelling the microphone track with the old name.
            if current?.isLocalUser == true {
                var updated = settings
                updated.localUserName = name
                update(settings: updated)
            }
            try await pipeline.refreshCachedNames(for: identityID)
            refreshRecentMeetings()
        } catch {
            Log.app.error("rename failed: \(logSafeDescription(error), privacy: .public)")
        }
    }

    /// Says two identities are one person.
    ///
    /// Nothing is deleted and no transcript is rewritten. The merged identity
    /// keeps its rows and points at the other, reads follow the pointer, and
    /// undoing it is clearing one column.
    public func mergeIdentities(_ source: IdentityID, into target: IdentityID) async {
        guard let store = speakerStore else { return }
        do {
            try await store.merge(source, into: target)
            try await pipeline.refreshCachedNames(for: source)
            refreshRecentMeetings()
        } catch {
            Log.app.error("merge failed: \(logSafeDescription(error), privacy: .public)")
        }
    }

    public func separateIdentity(_ identityID: IdentityID) async {
        guard let store = speakerStore else { return }
        do {
            try await store.unmerge(identityID)
            try await pipeline.refreshCachedNames(for: identityID)
        } catch {
            Log.app.error("unmerge failed: \(logSafeDescription(error), privacy: .public)")
        }
    }

    /// Deletes the biometric material and keeps the name.
    ///
    /// Past transcripts still say Chris. Nothing about his voice can be matched
    /// from audio again until he is confirmed on a new recording.
    public func forgetVoice(of identityID: IdentityID) async {
        guard let store = speakerStore else { return }
        do {
            try await store.forgetVoice(of: identityID)
        } catch {
            Log.app.error("forget voice failed: \(logSafeDescription(error), privacy: .public)")
        }
    }

    public func deletePerson(_ identityID: IdentityID) async {
        guard let store = speakerStore else { return }
        do {
            let family = try await store.family(of: identityID)
            try await store.delete(identityID)
            // Otherwise the stored identifier names a row that no longer
            // exists, and every new meeting writes it into its speaker map.
            if let stored = settings.processing.localUserIdentityID, family.contains(stored) {
                var updated = settings
                updated.processing.localUserIdentityID = nil
                update(settings: updated)
            }
        } catch {
            Log.app.error("delete person failed: \(logSafeDescription(error), privacy: .public)")
        }
    }

    // MARK: - meeting speaker review

    /// Every speaker in one meeting, with how it was decided.
    public func speakers(inMeeting meetingID: String) async -> [MeetingSpeakerRow] {
        guard let found = repository.findMeeting(id: meetingID),
              let transcript = try? found.store.readCanonicalTranscript(),
              let map = try? found.store.readSpeakerMap()
        else { return [] }

        var speech: [String: Double] = [:]
        for utterance in transcript.utterances {
            speech[utterance.speakerKey, default: 0] += max(0, utterance.end - utterance.start)
        }

        var rows: [MeetingSpeakerRow] = []
        for key in transcript.speakerKeys {
            let assignment = map.entries[key]
            var identity: Identity?
            var heardIn = 0
            if let identifier = assignment?.identityID, let store = speakerStore {
                identity = try? await store.current(identifier)
                heardIn = (try? await store.meetingCount(for: identifier)) ?? 0
            }
            rows.append(MeetingSpeakerRow(
                clusterID: key,
                displayName: assignment?.displayName ?? SpeakerMap.fallbackName(for: key),
                // Absent provenance means nothing measured this, so it is not
                // High. The badge reads a human or microphone-track assignment
                // from its origin, and everything else falls back honestly.
                band: assignment?.provenance?.band ?? .unknown,
                origin: assignment?.origin ?? .ai,
                identity: identity,
                speechSeconds: speech[key] ?? 0,
                provenance: assignment?.provenance,
                meetingCount: heardIn
            ))
        }
        return rows
    }

    /// Changes the speaker on one transcript line.
    public func assignUtteranceSpeaker(
        name: String, utteranceID: String, meetingID: String, identityID: IdentityID? = nil
    ) {
        runProcessing { [weak self] in
            guard let self else { return }
            do {
                _ = try await pipeline.applyUtteranceSpeaker(
                    name, utteranceID: utteranceID, meetingID: meetingID, identityID: identityID
                )
            } catch {
                Log.app.error("line speaker not saved: \(logSafeDescription(error), privacy: .public)")
            }
            onProcessingUpdate?(meetingID)
        }
    }

    /// Changes the speaker on several selected lines at once.
    public func assignUtteranceSpeakers(
        name: String, utteranceIDs: [String], meetingID: String, identityID: IdentityID? = nil
    ) {
        runProcessing { [weak self] in
            guard let self else { return }
            do {
                try await pipeline.applyUtteranceSpeaker(
                    name, utteranceIDs: utteranceIDs, meetingID: meetingID, identityID: identityID
                )
            } catch {
                Log.app.error("line speakers not saved: \(logSafeDescription(error), privacy: .public)")
            }
            onProcessingUpdate?(meetingID)
        }
    }

    /// Re-runs clustering, optionally at a count the user chose.
    ///
    /// Words are untouched. Where the meeting's prepared state is still in
    /// memory this costs about a second rather than a full pass.
    public func reanalyzeSpeakers(
        meetingID: String, speakerCount: Int?,
        completion: @escaping @Sendable @MainActor () -> Void = {}
    ) {
        runProcessing { [weak self] in
            guard let self else { return completion() }
            do {
                try await pipeline.reanalyzeSpeakers(
                    meetingID: meetingID, speakerCount: speakerCount
                )
            } catch {
                Log.app.error("re-analysis failed: \(logSafeDescription(error), privacy: .public)")
            }
            onProcessingUpdate?(meetingID)
            refreshRecentMeetings()
            completion()
        }
    }

    /// Re-runs identity resolution after the expected-participant list changed.
    /// No audio is read and nothing is transcribed.
    public func refreshSpeakerIdentities(meetingID: String) {
        runProcessing { [weak self] in
            guard let self else { return }
            do {
                try await pipeline.refreshSpeakerIdentities(meetingID: meetingID)
            } catch {
                Log.app.error("identity refresh failed: \(logSafeDescription(error), privacy: .public)")
            }
            onProcessingUpdate?(meetingID)
        }
    }

    /// Records who the user says was in the meeting.
    ///
    /// A soft prior for recognition and nothing more: the gallery is still
    /// searched globally, and a name on this list is never forced onto a
    /// speaker who did not match.
    public func setExpectedParticipants(
        _ names: [String], meetingID: String
    ) async {
        guard let found = repository.findMeeting(id: meetingID) else { return }
        var linked: [Participant] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var identityID: IdentityID?
            if let store = speakerStore {
                let people = try? await store.identities(kind: .person)
                identityID = people?.first {
                    $0.resolvedName.compare(trimmed, options: .caseInsensitive) == .orderedSame
                }?.id
            }
            linked.append(Participant(
                displayName: trimmed, origin: .human, identityID: identityID
            ))
        }
        do {
            _ = try found.store.updateMetadata { metadata in
                metadata.participants.removeAll { $0.origin == .human }
                metadata.participants.append(contentsOf: linked)
            }
        } catch {
            Log.app.error("participants not saved: \(logSafeDescription(error), privacy: .public)")
        }
        refreshSpeakerIdentities(meetingID: meetingID)
    }
}
