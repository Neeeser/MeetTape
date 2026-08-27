import Foundation
import PipitCore
import PipitLocalAI
import PipitSpeakers

/// One line of a turn, and the stretch of it a person named.
///
/// In the line's own coordinates. A turn's lines are not in time order, so a
/// window belongs to a line rather than to the track: chunks overlap by eight
/// seconds and a near-duplicate is only dropped above a similarity bar, so the
/// line printed second can begin before the line printed first.
public struct SpeakerRangePart: Sendable, Equatable {
    public var utteranceID: String
    public var startSeconds: Double
    public var endSeconds: Double

    public init(utteranceID: String, startSeconds: Double, endSeconds: Double) {
        self.utteranceID = utteranceID
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// One speaker in one meeting, as the meetings window shows them.
/// One proposed name, and the speaker it is proposed for.
public struct MeetingSuggestionRow: Sendable, Equatable, Identifiable {
    public var clusterID: String
    public var recordingID: String
    /// What the speaker strip calls this speaker today, so the pill and the
    /// chip it points at read the same.
    public var speakerLabel: String
    public var suggestion: SpeakerNameSuggestion

    public var id: String { "\(recordingID)/\(clusterID)" }

    public init(
        clusterID: String, recordingID: String, speakerLabel: String,
        suggestion: SpeakerNameSuggestion
    ) {
        self.clusterID = clusterID
        self.recordingID = recordingID
        self.speakerLabel = speakerLabel
        self.suggestion = suggestion
    }
}

public struct MeetingSpeakerRow: Sendable, Equatable, Identifiable {
    public var clusterID: String
    /// The recording this cluster was diarized in.
    ///
    /// A cluster identifier only means something inside one recording, and both
    /// halves of a dropped call number their speakers from zero. Naming one
    /// therefore has to say which recording it belongs to, or the name lands on
    /// a different person in the other half.
    public var recordingID: String
    public var displayName: String
    public var band: SpeakerConfidenceBand
    public var origin: SpeakerAssignmentOrigin
    public var identity: Identity?
    public var speechSeconds: Double
    public var provenance: SpeakerProvenance?
    /// Meetings this identity has been heard in, for the "seen before" context.
    public var meetingCount: Int

    /// Whether this cluster is still waiting for a name.
    ///
    /// Recorded when the row is built, from whether the meeting's own speaker
    /// map holds a name for the cluster. Not read back out of `displayName`,
    /// which falls back to a generated name. The microphone track is named "Me"
    /// from Settings and the fallback for that key is also "Me", so comparing
    /// the two drew the user's own voice as a voice asking for a name on every
    /// meeting recorded with the default name.
    ///
    /// Not read from the identity beside it either. A named cluster whose
    /// identity row could not be read still has a name, and drawing it as
    /// unnamed would put work in front of the user that they have already done.
    public var isUnnamed: Bool

    public var id: String { "\(recordingID)/\(clusterID)" }

    /// Whether this row is worth putting in front of a reader.
    ///
    /// A diarizer can emit a label that ends up owning no transcript time: one
    /// cloud-diarized meeting listed eleven speakers, six of them showing 0s.
    /// There is nothing a user can do with a speaker who never says anything,
    /// so the speaker strip leaves them out. A cluster somebody has already
    /// named stays visible whatever it owns, because hiding it would hide their
    /// own work. This is display only, and the cluster still resolves anywhere
    /// an operation names it.
    public var hasSpeechToShow: Bool {
        // The same half second the meetings list counts a voice from, so the
        // list cannot report work this strip refuses to draw.
        speechSeconds >= TranscriptSpeaker.audibleSeconds || origin == .human
    }

    public init(
        clusterID: String, recordingID: String, displayName: String, isUnnamed: Bool,
        band: SpeakerConfidenceBand,
        origin: SpeakerAssignmentOrigin, identity: Identity?, speechSeconds: Double,
        provenance: SpeakerProvenance?, meetingCount: Int
    ) {
        self.clusterID = clusterID
        self.recordingID = recordingID
        self.displayName = displayName
        self.isUnnamed = isUnnamed
        self.band = band
        self.origin = origin
        self.identity = identity
        self.speechSeconds = speechSeconds
        self.provenance = provenance
        self.meetingCount = meetingCount
    }
}

/// One meeting a person was heard in, for the list on their profile.
public struct PersonAppearance: Identifiable, Sendable, Equatable {
    public let meetingID: String
    public let title: String
    public let startedAt: Date
    /// How long this person spoke in it, over every track and every recording
    /// of the conversation.
    public let speechSeconds: Double
    /// Whether a mixdown is on disk, which is what a sample plays from.
    public let hasAudio: Bool

    public var id: String { meetingID }

    public init(
        meetingID: String, title: String, startedAt: Date, speechSeconds: Double, hasAudio: Bool
    ) {
        self.meetingID = meetingID
        self.title = title
        self.startedAt = startedAt
        self.speechSeconds = speechSeconds
        self.hasAudio = hasAudio
    }
}

/// A stretch of one person's speech, and the file it plays from.
///
/// The file names the recording. Either half of a dropped call keeps its own
/// timeline, and the span is on the timeline of the mixdown beside it.
public struct VoiceSample: Sendable, Equatable {
    public let audio: URL
    public let start: Double
    public let end: Double

    public var duration: Double { max(0, end - start) }

    public init(audio: URL, start: Double, end: Double) {
        self.audio = audio
        self.start = start
        self.end = end
    }
}

extension PipitRuntime {
    // MARK: - model management

    public var localModelsInstalled: Bool { localModelState.isUsable }

    public func refreshLocalModelState() async {
        guard let models else { return }
        localModelState = await models.currentState
    }

    /// Downloads and prepares the on-device models. Recording is unaffected
    /// while it runs; a meeting that finishes meanwhile queues.
    public func installLocalModels() async {
        await installLocalModels(LocalModelUnit.required(for: settings))
    }

    /// The units the current settings need, handed to the manager as the set to
    /// judge itself against and as the set to fetch.
    ///
    /// Both, in that order, on this one call: a download started right after a
    /// model change used to race the settings write that names the units, so
    /// picking Cohere fetched Parakeet.
    public func installLocalModels(_ units: Set<LocalModelUnit>) async {
        guard let models else { return }
        await models.setRequired(units)
        do {
            _ = try await models.install(units: units)
        } catch {
            Log.app.error("model install failed: \(logSafeDescription(error), privacy: .public)")
        }
        await refreshLocalModelState()
    }

    /// Records which engine transcribes on this Mac, and answers with the units
    /// that choice needs.
    ///
    /// Separate from the download so a caller that owns the download itself, the
    /// setup wizard, can start it its own way.
    @discardableResult
    public func applyLocalTranscriptionModel(
        _ model: LocalTranscriptionModel
    ) -> Set<LocalModelUnit> {
        var updated = settings
        updated.processing.localTranscriptionModel = model
        update(settings: updated)
        return LocalModelUnit.required(for: updated)
    }

    /// Picking a model is the consent for its download, so the fetch starts on
    /// the click rather than at the next meeting.
    public func chooseLocalTranscriptionModel(_ model: LocalTranscriptionModel) async {
        await installLocalModels(applyLocalTranscriptionModel(model))
    }

    /// Removes one unit's files. The other units stay usable.
    public func removeLocalModel(_ unit: LocalModelUnit) async {
        guard let models else { return }
        await models.remove(unit: unit)
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
                    // Past meetings cache the name beside the identity, and every
                    // other rename path refreshes them. Off the ordered chain:
                    // this walks every meeting the local user appears in and
                    // rewrites each one's markdown, and the chain is what carries
                    // arming a recording and what quit waits on.
                    let identityID = existing.id
                    runProcessing { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.pipeline.refreshCachedNames(for: identityID)
                            self.refreshRecentMeetings()
                        } catch {
                            Log.app.error(
                                "name refresh failed: \(logSafeDescription(error), privacy: .public)"
                            )
                        }
                    }
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

    /// Says which person in the directory is the one using this Mac.
    ///
    /// The identity owns the answer and Settings caches their name from it. The
    /// two used to be set separately: a free-text field held a name, the store
    /// held a flag, and `ensureLocalUserIdentity` pushed the name onto the
    /// flagged row at every launch, so picking the wrong one left the
    /// microphone track labelled from a field that named nobody.
    public func setLocalUser(_ identityID: IdentityID) async {
        guard let store = speakerStore else { return }
        do {
            guard let identity = try await store.current(identityID) else { return }
            try await store.setLocalUser(identity.id)
            var updated = settings
            updated.processing.localUserIdentityID = identity.id
            updated.localUserName = identity.resolvedName
            update(settings: updated)
            Log.app.info("local user set to identity \(identity.id.rawValue, privacy: .public)")
        } catch {
            Log.app.error("local user not set: \(logSafeDescription(error), privacy: .public)")
        }
    }

    /// Repairs the archive once, for meetings recorded before the microphone
    /// track was written into voice memory.
    func backfillLocalUserOccurrences() async {
        guard !settings.processing.localUserOccurrencesBackfilled else { return }
        // A voice database that failed to open is a launch that can write
        // nothing. Marking the pass done here would spend the one shot on it
        // and leave the archive unrepaired on every later launch.
        guard speakerStore != nil else { return }
        let written = await pipeline.backfillLocalUserOccurrences()
        var updated = settings
        updated.processing.localUserOccurrencesBackfilled = true
        update(settings: updated)
        Log.app.info("microphone tracks recorded for \(written, privacy: .public) recordings")
    }

    // MARK: - reading a few sentences aloud

    /// Where the audio of a spoken enrolment is kept.
    public var voiceEnrollmentArchive: VoiceEnrollmentArchive {
        VoiceEnrollmentArchive(applicationSupport: applicationSupport)
    }

    /// A path for the next enrolment recording, under the person it is of.
    public func newEnrollmentRecording() async -> URL? {
        await ensureLocalUserIdentity()
        guard let identityID = settings.processing.localUserIdentityID else { return nil }
        return try? voiceEnrollmentArchive.newRecording(
            for: identityID, id: UUID().uuidString.lowercased()
        )
    }

    /// Adds a recording of the person at this Mac reading aloud to their voice
    /// profile, and reports what the profile holds afterwards.
    public func enrolSpokenSample(
        audio: URL
    ) async throws(SpokenEnrollmentError) -> VoiceProfileStatus {
        guard let identityID = settings.processing.localUserIdentityID else {
            throw .noLocalUser
        }
        let status = try await pipeline.enrolSpokenSample(audio: audio, identityID: identityID)
        refreshRecentMeetings()
        return status
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

    /// Every meeting a person was heard in, newest first.
    ///
    /// The list on their profile, rather than a count: what a reader wants from
    /// "heard in nine meetings" is which nine, and a way into each transcript.
    ///
    /// Occurrences are per recording and a dropped call is two recordings of one
    /// conversation, so each is resolved to the conversation it belongs to and
    /// the seconds of both halves are added together.
    public func appearances(of identityID: IdentityID, limit: Int = 60) async -> [PersonAppearance] {
        guard let store = speakerStore else { return [] }
        guard let occurrences = try? await store.occurrences(identityID: identityID) else {
            return []
        }
        guard !occurrences.isEmpty else { return [] }
        // The rows the list can already answer for, read once. Resolving every
        // occurrence through `logicalMeeting` instead walked the archive
        // directory per row, and after the microphone track started writing one
        // row per meeting that is one walk per meeting in the archive.
        let listed = repository.listMeetings()
        let conversations = Set(listed.map(\.id))
        var seconds: [String: Double] = [:]
        for occurrence in occurrences {
            // Only a folded half needs resolving: its own identifier is not in
            // the list, because the conversation is listed under the recording
            // it started with.
            let conversation = conversations.contains(occurrence.meetingID)
                ? occurrence.meetingID
                : repository.logicalMeeting(id: occurrence.meetingID)?
                    .primary.metadata.id ?? occurrence.meetingID
            seconds[conversation, default: 0] += occurrence.speechSeconds
        }
        return listed
            .filter { seconds[$0.id] != nil }
            .prefix(limit)
            .map { summary in
                PersonAppearance(
                    meetingID: summary.id,
                    title: summary.title,
                    startedAt: summary.startedAt,
                    speechSeconds: seconds[summary.id] ?? 0,
                    hasAudio: repository.stores(ofConversation: summary).contains {
                        FileManager.default.fileExists(atPath: $0.layout.recordingAudio.path)
                    }
                )
            }
    }

    /// A stretch of one person's speech from one meeting, to play back.
    ///
    /// Their longest turn, because the longest is the one least likely to be a
    /// word said over somebody else, and the mixdown it points at is aligned to
    /// the same timeline the transcript is on.
    public func voiceSample(
        of identityID: IdentityID, inMeeting meetingID: String
    ) async -> VoiceSample? {
        guard let store = speakerStore else { return nil }
        guard let logical = repository.logicalMeeting(id: meetingID) else { return nil }
        let family = Set((try? await store.family(of: identityID)) ?? [identityID])
        for recording in logical.recordings {
            let audio = recording.store.layout.recordingAudio
            guard FileManager.default.fileExists(atPath: audio.path),
                  let map = try? recording.store.readSpeakerMap(),
                  let transcript = try? recording.store.readCanonicalTranscript()
            else { continue }
            let keys = Set(
                map.entries
                    .filter { $0.value.identityID.map(family.contains) ?? false }
                    .map(\.key)
            )
            guard !keys.isEmpty else { continue }
            guard let longest = transcript.utterances
                .filter({ keys.contains($0.speakerKey) })
                .max(by: { $0.end - $0.start < $1.end - $1.start })
            else { continue }
            let start = max(0, longest.start)
            return VoiceSample(
                audio: audio,
                start: start,
                end: min(longest.end, start + Self.voiceSampleSeconds)
            )
        }
        return nil
    }

    /// Long enough to recognise a voice, short enough that a person listens to
    /// the whole of it before deciding.
    private static let voiceSampleSeconds: Double = 8

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

    /// The platform accounts confirmed as this person, merged family included.
    public func personHandles(of identityID: IdentityID) async -> [IdentityHandle] {
        guard let store = speakerStore else { return [] }
        return (try? await store.handles(of: identityID)) ?? []
    }

    /// Withdraws the claim that a platform account is this person. Their voice
    /// and their name stay; only the account link goes.
    public func unlinkHandle(_ handle: IdentityHandle) async {
        guard let store = speakerStore else { return }
        do {
            try await store.removeHandle(handle)
        } catch {
            Log.app.error("unlink failed: \(logSafeDescription(error), privacy: .public)")
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
            // Every identifier that reads as this person, because the vectors
            // go for the whole family and a reading filed under a row that has
            // since been merged away would otherwise stay on disk. Forgetting a
            // voice that leaves its audio behind is a promise half kept.
            let family = (try? await store.family(of: identityID)) ?? [identityID]
            try await store.forgetVoice(of: identityID)
            for member in family { voiceEnrollmentArchive.remove(for: member) }
        } catch {
            Log.app.error("forget voice failed: \(logSafeDescription(error), privacy: .public)")
        }
    }

    /// Free text about a person, and the markdown that carries it.
    ///
    /// Every transcript this person appears in is re-rendered, because the notes
    /// are written into the participant block of each one and a stale block is
    /// what the downstream reader will actually see.
    public func setNotes(_ notes: String?, on identityID: IdentityID) async {
        guard let store = speakerStore else { return }
        do {
            try await store.setNotes(notes, on: identityID)
            try await pipeline.refreshCachedNames(for: identityID)
        } catch {
            Log.app.error("notes update failed: \(logSafeDescription(error), privacy: .public)")
        }
    }

    public func setBadges(_ badges: [PersonBadge], on identityID: IdentityID) async {
        guard let store = speakerStore else { return }
        do {
            try await store.setBadges(badges, on: identityID)
        } catch {
            Log.app.error("badge update failed: \(logSafeDescription(error), privacy: .public)")
        }
    }

    public func setOrganization(_ organization: String?, on identityIDs: [IdentityID]) async {
        guard let store = speakerStore else { return }
        do {
            try await store.setOrganization(organization, on: identityIDs)
            for identityID in identityIDs {
                try await pipeline.refreshCachedNames(for: identityID)
            }
        } catch {
            Log.app.error("organization update failed: \(logSafeDescription(error), privacy: .public)")
        }
    }

    public func setAvatar(_ png: Data?, on identityID: IdentityID) async {
        guard let store = speakerStore else { return }
        do {
            try await store.setAvatar(png, on: identityID)
        } catch {
            Log.app.error("avatar update failed: \(logSafeDescription(error), privacy: .public)")
        }
    }

    public func avatar(of identityID: IdentityID) async -> Data? {
        guard let store = speakerStore else { return nil }
        return try? await store.avatar(of: identityID)
    }

    public func deletePeople(_ identityIDs: [IdentityID]) async {
        for identityID in identityIDs { await deletePerson(identityID) }
    }

    public func deletePerson(_ identityID: IdentityID) async {
        guard let store = speakerStore else { return }
        do {
            let family = try await store.family(of: identityID)
            // Collected first: once the row is gone `meetingsReferencing` cannot
            // find it, and the participant block of every transcript this person
            // is in still holds the notes the confirmation just said were
            // removed.
            let affected = (try? await store.meetingsReferencing(identityID)) ?? []
            for member in family { voiceEnrollmentArchive.remove(for: member) }
            try await store.delete(identityID)
            await pipeline.rerenderMeetings(affected)
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

    /// Every speaker in one conversation, with how each was decided.
    ///
    /// Every recording of it, not only the first. A call that dropped and was
    /// rejoined is two recordings and one row in the list, and reading the
    /// first alone meant a voice that only spoke after the drop had no chip:
    /// the list counted it as work to do and the strip offered no way to do it.
    ///
    /// Each row carries the recording its cluster belongs to, because a cluster
    /// identifier means nothing outside one recording's own diarization.
    public func speakers(inMeeting meetingID: String) async -> [MeetingSpeakerRow] {
        // Answers for either half of a dropped call, and holds every recording
        // of the conversation, so nothing on disk is unreachable through an
        // identifier a notification or a link still carries.
        guard let recordings = repository.logicalMeeting(id: meetingID)?.recordings else {
            return []
        }
        var rows: [MeetingSpeakerRow] = []
        for (index, recording) in recordings.enumerated() {
            guard let transcript = try? recording.store.readCanonicalTranscript(),
                  let map = try? recording.store.readSpeakerMap()
            else { continue }
            for speaker in transcript.speakers {
                let key = speaker.key
                // Words no interval claimed are not a speaker. Offering the row
                // for naming would put a name on a scatter of backchannels
                // spoken over other people, and then feed those spans to the
                // enrolment that builds that person's voice profile.
                if key.hasSuffix(SpeakerLabel.unattributed) { continue }
                let assignment = map.entries[key]
                let stored = map.displayName(for: key)
                var identity: Identity?
                var heardIn = 0
                if let identifier = assignment?.identityID, let store = speakerStore {
                    identity = try? await store.current(identifier)
                    heardIn = (try? await store.meetingCount(for: identifier)) ?? 0
                }
                // Both halves call their first speaker the same thing, so a
                // generated name says which half it came from. A name a person
                // typed stands on its own.
                let fallback = recordings.count > 1
                    ? "\(SpeakerMap.fallbackName(for: key)), part \(index + 1)"
                    : SpeakerMap.fallbackName(for: key)
                rows.append(MeetingSpeakerRow(
                    clusterID: key,
                    recordingID: recording.metadata.id,
                    displayName: stored ?? fallback,
                    isUnnamed: stored == nil,
                    // Absent provenance means nothing measured this, so it is
                    // not High. The badge reads a human or microphone-track
                    // assignment from its origin, and everything else falls
                    // back honestly.
                    band: assignment?.provenance?.band ?? .unknown,
                    origin: assignment?.origin ?? .ai,
                    identity: identity,
                    speechSeconds: speaker.speechSeconds,
                    provenance: assignment?.provenance,
                    meetingCount: heardIn
                ))
            }
        }
        return rows
    }

    /// Names the model proposed for speakers this meeting could not name.
    ///
    /// Read against the speaker map as it stands now, so a label named by hand
    /// since the suggestion was written drops out of the answer. That is what
    /// makes accepting one pill remove exactly that pill and leave the rest.
    public func speakerSuggestions(inMeeting meetingID: String) -> [MeetingSuggestionRow] {
        guard let recordings = repository.logicalMeeting(id: meetingID)?.recordings else {
            return []
        }
        var rows: [MeetingSuggestionRow] = []
        for (index, recording) in recordings.enumerated() {
            guard let map = try? recording.store.readSpeakerMap() else { continue }
            let set = recording.store.readSpeakerSuggestions()
            guard !set.suggestions.isEmpty else { continue }
            guard let keys = try? recording.store.readTranscriptSpeakers().map(\.key) else {
                continue
            }
            // A person who clears a name has said no to it. Offering the same
            // name straight back is the automatic naming this whole change
            // exists to stop, one step further along.
            let unnamed = Set(
                keys.filter { map.entries[$0] == nil && !map.clearedKeys.contains($0) }
            )
            for suggestion in set.visible(forUnnamed: unnamed) {
                // The same fallback the speaker chips draw, so a pill and the
                // chip it points at agree on what that speaker is called.
                let label = recordings.count > 1
                    ? "\(SpeakerMap.fallbackName(for: suggestion.label)), part \(index + 1)"
                    : SpeakerMap.fallbackName(for: suggestion.label)
                rows.append(MeetingSuggestionRow(
                    clusterID: suggestion.label,
                    recordingID: recording.metadata.id,
                    speakerLabel: label,
                    suggestion: suggestion
                ))
            }
        }
        return rows
    }

    /// Records that the user turned a suggestion down, so a re-run does not
    /// offer the same name again.
    public func dismissSpeakerSuggestion(clusterID: String, recordingID: String) {
        writeSuggestions(recordingID: recordingID) { $0.dismiss(clusterID) }
    }

    /// Turns down every suggestion still showing for one meeting.
    public func dismissAllSpeakerSuggestions(inMeeting meetingID: String) {
        let rows = speakerSuggestions(inMeeting: meetingID)
        for recordingID in Set(rows.map(\.recordingID)) {
            let labels = rows.filter { $0.recordingID == recordingID }.map(\.clusterID)
            writeSuggestions(recordingID: recordingID) { set in
                for label in labels { set.dismiss(label) }
            }
        }
    }

    /// Named for a recording rather than a meeting on purpose. A suggestion
    /// belongs to the half of a rejoined call it was made in, and the ordinary
    /// lookup hides a half that has been folded into another, so a dismissal on
    /// part two used to find no folder, write nothing, and let the same pill
    /// come back on the next read.
    private func writeSuggestions(
        recordingID: String, _ body: (inout SpeakerSuggestionSet) -> Void
    ) {
        guard let recording = repository.findMeeting(id: recordingID, includingMerged: true)
        else { return }
        var set = recording.store.readSpeakerSuggestions()
        body(&set)
        do {
            try recording.store.writeSpeakerSuggestions(set)
        } catch {
            Log.app.error(
                "suggestion update failed: \(logSafeDescription(error), privacy: .public)"
            )
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

    /// Divides the transcript at a word and gives the stretch that follows, or
    /// a phrase inside a turn, to one speaker.
    public func assignSpeakerRange(
        name: String, meetingID: String, track: CaptureTrack, parts: [SpeakerRangePart],
        identityID: IdentityID? = nil
    ) {
        runProcessing { [weak self] in
            guard let self else { return }
            do {
                _ = try await pipeline.applySpeakerRange(
                    name, meetingID: meetingID, track: track, parts: parts,
                    identityID: identityID
                )
            } catch {
                Log.app.error("range speaker not saved: \(logSafeDescription(error), privacy: .public)")
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
        guard let found = repository.findMeeting(id: meetingID, includingMerged: true) else { return }
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
