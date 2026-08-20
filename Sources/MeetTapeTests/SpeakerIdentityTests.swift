import Foundation
import MeetTapeCore
import MeetTapeSpeakers
import TestKit

/// The rules that decide whether a voice gets a name, and what may ever be
/// written into a profile.
///
/// Every threshold here has a measurement behind it, and every one of them is a
/// value that a well-meaning change could relax into a wrong name on somebody
/// else's transcript.
enum SpeakerIdentityTests {

    // MARK: helpers

    static let policy = SpeakerResolutionPolicy.shipping

    static func person(_ id: Int64, _ score: Double, expected: Bool = false) -> SpeakerCandidate {
        SpeakerCandidate(
            identityID: IdentityID(id), kind: .person, displayName: "P\(id)",
            score: score, isExpectedParticipant: expected
        )
    }

    static func anonymous(_ id: Int64, _ score: Double) -> SpeakerCandidate {
        SpeakerCandidate(
            identityID: IdentityID(id), kind: .anonymous, displayName: "Anonymous #\(id)",
            score: score
        )
    }

    /// A deterministic unit vector, so two calls with the same seed are the same
    /// voice and different seeds are far apart.
    static func vector(seed: Int, dimension: Int = 256, jitter: Float = 0) -> [Float] {
        var state = UInt64(bitPattern: Int64(seed) &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407)
        var out = [Float](repeating: 0, count: dimension)
        for index in 0..<dimension {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(Double(state >> 11) / Double(UInt64(1) << 53)) - 0.5
            out[index] = unit + jitter * Float(index % 7)
        }
        return VoiceVector.l2Normalized(out)
    }

    static func makeStore() throws -> (SpeakerStore, URL) {
        let root = try ManifestTests.makeTemporaryDirectory()
        let store = try SpeakerStore(url: root.appendingPathComponent("voices.sqlite"))
        return (store, root)
    }

    // MARK: suites

    static var policySuite: Suite {
        Suite("SpeakerPolicy", [
            test("naming a person needs score, margin and duration together") { expect in
                let candidates = [person(1, 0.81), person(2, 0.40)]
                let resolved = policy.resolve(candidates: candidates, speechSeconds: 84)
                expect.equal(resolved.band, .high)
                expect.equal(resolved.outcome, .assign(IdentityID(1)))
                expect.close(resolved.margin ?? 0, 0.41, tolerance: 0.001)
            },

            test("a score that clears the bar with too little speech is not a name") { expect in
                // 45 seconds is where the false-reject rate at 0.70 drops below
                // 1.5%. Below it the genuine floor sits under any safe threshold.
                let resolved = policy.resolve(candidates: [person(1, 0.95), person(2, 0.20)], speechSeconds: 30)
                expect.notEqual(resolved.band, .high)
                expect.isFalse(resolved.outcome.isAutomatic)
            },

            test("under ten seconds nothing is named, whatever it scored") { expect in
                // At nine seconds the 1st percentile of genuine scores is 0.282
                // and an impostor reached 0.821.
                let resolved = policy.resolve(candidates: [person(1, 0.99)], speechSeconds: 9)
                expect.equal(resolved.band, .unknown)
                expect.equal(resolved.outcome, .unknown)
                expect.isTrue(resolved.suggestions.isEmpty, "not even a suggestion below the floor")
                expect.equal(resolved.best?.identityID, IdentityID(1), "the reason is still reported")
            },

            test("two close candidates are never named automatically") { expect in
                // The measured worst case: an impostor at 0.957 outranking the
                // true speaker's own 0.951. Score alone names the wrong person.
                let resolved = policy.resolve(
                    candidates: [person(1, 0.957), person(2, 0.951)], speechSeconds: 300
                )
                expect.isFalse(resolved.outcome.isAutomatic, "margin 0.006 must not auto-assign")
                expect.equal(resolved.band, .medium)
                expect.equal(resolved.suggestions.count, 2)
            },

            test("a listed participant relaxes the margin and nothing else") { expect in
                let listed = policy.resolve(
                    candidates: [person(1, 0.80, expected: true), person(2, 0.73)],
                    speechSeconds: 90
                )
                expect.equal(listed.outcome, .assign(IdentityID(1)), "0.07 clears the relaxed bar")

                let unlisted = policy.resolve(
                    candidates: [person(1, 0.80), person(2, 0.73)], speechSeconds: 90
                )
                expect.isFalse(unlisted.outcome.isAutomatic, "0.07 does not clear the normal bar")

                // The score gate itself never moves for a listed participant.
                let weak = policy.resolve(
                    candidates: [person(1, 0.62, expected: true)], speechSeconds: 300
                )
                expect.isFalse(weak.outcome.isAutomatic, "being invited is not evidence of speaking")
            },

            test("an unnamed voice is linked at a stricter bar than a named one") { expect in
                // 0.75 rather than 0.70, because the false-link rate for a
                // genuinely new voice grows with pool size where named matching
                // does not, and a wrong anonymous merge corrupts a profile no
                // human has ever looked at.
                let borderline = policy.resolve(
                    candidates: [anonymous(7, 0.72), anonymous(8, 0.40)], speechSeconds: 120
                )
                expect.isFalse(borderline.outcome.isAutomatic)

                let linked = policy.resolve(
                    candidates: [anonymous(7, 0.80), anonymous(8, 0.40)], speechSeconds: 120
                )
                expect.equal(linked.outcome, .seenBefore(IdentityID(7)))
                expect.equal(linked.band, .high)
            },

            test("one candidate has no runner-up, so it clears the whole bar alone") { expect in
                // The margin gate exists because the worst impostor over 326
                // verified-distinct speakers scored 0.957 against the true
                // speaker's own 0.951. Treating an absent runner-up as scoring
                // zero made the margin the whole score, so any score over 0.10
                // passed and a gallery holding one voice decided on score alone.
                let alone = policy.resolve(candidates: [person(1, 0.72)], speechSeconds: 300)
                expect.isFalse(
                    alone.outcome.isAutomatic,
                    "0.72 clears the score but proves no separation from anyone"
                )
                let clear = policy.resolve(candidates: [person(1, 0.81)], speechSeconds: 300)
                expect.equal(
                    clear.outcome, .assign(IdentityID(1)),
                    "0.70 plus the 0.10 it would have needed over a runner-up"
                )

                // The same for a remembered unnamed voice, at its own bar.
                expect.isFalse(
                    policy.resolve(candidates: [anonymous(7, 0.80)], speechSeconds: 120)
                        .outcome.isAutomatic
                )
                expect.equal(
                    policy.resolve(candidates: [anonymous(7, 0.86)], speechSeconds: 120).outcome,
                    .seenBefore(IdentityID(7))
                )
            },

            test("an ambiguous unnamed match stays two separate voices") { expect in
                let resolved = policy.resolve(
                    candidates: [anonymous(7, 0.79), anonymous(8, 0.76)], speechSeconds: 200
                )
                expect.isFalse(resolved.outcome.isAutomatic, "0.03 of margin is not a merge")
            },

            test("at most three candidates are offered, and none below the bar") { expect in
                let resolved = policy.resolve(
                    candidates: [person(1, 0.66), person(2, 0.64), person(3, 0.62),
                                 person(4, 0.60), person(5, 0.30)],
                    speechSeconds: 60
                )
                expect.equal(resolved.band, .medium)
                expect.equal(resolved.suggestions.count, 3)
                expect.isTrue(resolved.suggestions.allSatisfy { $0.score >= policy.mediumScore })
            },

            test("an empty gallery is Unknown rather than an error") { expect in
                let resolved = policy.resolve(candidates: [], speechSeconds: 300)
                expect.equal(resolved.outcome, .unknown)
                expect.isNil(resolved.best)
            },

            test("only clean speech past the enrolment bar becomes a remembered voice") { expect in
                expect.isFalse(policy.qualifiesForAnonymousProfile(speechSeconds: 44))
                expect.isTrue(policy.qualifiesForAnonymousProfile(speechSeconds: 45))
                expect.isFalse(policy.qualifiesForEnrolment(speechSeconds: 30))
                expect.isTrue(policy.qualifiesForEnrolment(speechSeconds: 60))
            },
        ])
    }

    static var vectorSuite: Suite {
        Suite("VoiceVector", [
            test("similarity is computed on normalized vectors, not raw dot products") { expect in
                let base = vector(seed: 1)
                let scaled = base.map { $0 * 17 }
                expect.close(VoiceVector.cosine(base, scaled), 1.0, tolerance: 0.0001)
                expect.close(VoiceVector.cosine(base, vector(seed: 2)), 0, tolerance: 0.3)
            },

            test("a centroid sits closer to its own samples than to another voice") { expect in
                let mine = (0..<5).map { vector(seed: 100, jitter: Float($0) * 0.01) }
                let centroid = VoiceVector.centroid(mine)
                let ownScore = VoiceVector.cosine(centroid, mine[0])
                let otherScore = VoiceVector.cosine(centroid, vector(seed: 900))
                expect.isTrue(ownScore > otherScore + 0.3, "\(ownScore) vs \(otherScore)")
                expect.close(
                    VoiceVector.cosine(centroid, centroid), 1.0, tolerance: 0.0001
                )
            },

            test("vectors survive the blob round trip byte for byte") { expect in
                let original = vector(seed: 42)
                let decoded = try expect.unwrap(VoiceVector.decode(VoiceVector.encode(original)))
                expect.equal(decoded.count, 256)
                expect.equal(VoiceVector.encode(original).count, 1_024, "Float32, 4 bytes each")
                for index in 0..<original.count {
                    expect.close(Double(decoded[index]), Double(original[index]), tolerance: 1e-7)
                }
            },

            test("a truncated blob decodes as nothing rather than as garbage") { expect in
                var data = VoiceVector.encode(vector(seed: 1))
                data.removeLast()
                expect.isNil(VoiceVector.decode(data))
            },
        ])
    }

    static var storeSuite: Suite {
        Suite("SpeakerStore", [
            test("a person, their embeddings and their profile round trip") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }

                let chris = try await store.createPerson(name: "Chris", organization: "Acme")
                let result = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: chris.id, vector: vector(seed: 3), model: .fluidAudioOffline,
                    speechSeconds: 90, qualityScore: 1, source: .humanConfirmedCluster,
                    meetingID: "m1", clusterID: "c1"
                ))
                guard case .success = result else {
                    return expect.fail("enrolment refused: \(result)")
                }
                let profiles = try await store.searchableProfiles(model: .fluidAudioOffline)
                expect.equal(profiles.count, 1)
                expect.equal(profiles.first?.identity.resolvedName, "Chris")
                expect.equal(profiles.first?.identity.organization, "Acme")
                expect.equal(profiles.first?.centroid.count, 256)
                expect.equal(profiles.first?.sampleCount, 1)
            },

            test("a profile is never compared across embedding models") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let chris = try await store.createPerson(name: "Chris")
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: chris.id, vector: vector(seed: 3), model: .fluidAudioOffline,
                    speechSeconds: 90, qualityScore: 1, source: .humanConfirmedCluster
                ))
                let other = EmbeddingModelIdentifier(rawValue: "some-future-model-512", dimension: 512)
                expect.isTrue(
                    try await store.searchableProfiles(model: other).isEmpty,
                    "a vector from another model must not be a candidate"
                )
            },

            test("recognition never writes a profile, however confident it was") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let service = SpeakerRecognitionService(store: store)
                let chris = try await store.createPerson(name: "Chris")
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: chris.id, vector: vector(seed: 5), model: .fluidAudioOffline,
                    speechSeconds: 120, qualityScore: 1, source: .humanConfirmedCluster
                ))
                let before = try await store.profileStatus(of: chris.id, model: .fluidAudioOffline)

                // The same voice again, matched at the highest confidence.
                let resolved = try await service.resolve(
                    meetingID: "m2",
                    clusters: [SpeakerClusterInput(
                        clusterID: "run-001_speaker_00", track: .remote,
                        speechSeconds: 300, centroid: vector(seed: 5)
                    )],
                    settings: SpeakerRecognitionSettings(),
                    now: Date()
                )
                expect.equal(resolved.first?.identity?.id, chris.id, "the match itself should work")
                expect.equal(resolved.first?.source, .voiceProfile)

                let after = try await store.profileStatus(of: chris.id, model: .fluidAudioOffline)
                expect.equal(
                    after.sampleCount, before.sampleCount,
                    "a High automatic match must never add a vector"
                )
            },

            test("a named profile refuses a vector nobody stood behind") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let chris = try await store.createPerson(name: "Chris")
                let result = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: chris.id, vector: vector(seed: 6), model: .fluidAudioOffline,
                    speechSeconds: 300, qualityScore: 1, source: .anonymousSeed
                ))
                guard case .failure = result else {
                    return expect.fail("a seed vector must not enter a named profile")
                }
                expect.equal(
                    try await store.profileStatus(of: chris.id, model: .fluidAudioOffline).sampleCount,
                    0
                )
            },

            test("a correction with too little audio behind it is refused") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let chris = try await store.createPerson(name: "Chris")
                let result = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: chris.id, vector: vector(seed: 7), model: .fluidAudioOffline,
                    speechSeconds: 12, qualityScore: 1, source: .humanConfirmedCluster
                ))
                guard case .failure(let reason) = result else {
                    return expect.fail("12 seconds is below the enrolment bar")
                }
                expect.equal(reason, .tooLittleSpeech(seconds: 12, required: 45))
            },

            test("correcting more lines in one meeting refines it, and enrols once") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let chris = try await store.createPerson(name: "Chris")

                // Each round re-embeds the whole confirmed set, so a later round
                // supersedes the earlier one rather than counting it again.
                for seconds in [15.0, 30.0] {
                    try await store.addPendingEnrollment(VoiceEnrollmentCandidate(
                        identityID: chris.id, vector: vector(seed: 8), model: .fluidAudioOffline,
                        speechSeconds: seconds, qualityScore: 1,
                        source: .humanConfirmedUtterances, meetingID: "m1"
                    ))
                }
                expect.close(
                    try await store.pendingSpeechSeconds(for: chris.id, model: .fluidAudioOffline),
                    30, tolerance: 0.001,
                    "the second round replaces the first, it does not add to it"
                )
                expect.isFalse(
                    try await store.flushPendingEnrollment(for: chris.id, model: .fluidAudioOffline),
                    "30 seconds is not enough"
                )

                try await store.addPendingEnrollment(VoiceEnrollmentCandidate(
                    identityID: chris.id, vector: vector(seed: 8), model: .fluidAudioOffline,
                    speechSeconds: 50, qualityScore: 1,
                    source: .humanConfirmedUtterances, meetingID: "m1"
                ))
                expect.isTrue(
                    try await store.flushPendingEnrollment(for: chris.id, model: .fluidAudioOffline),
                    "50 seconds clears it"
                )
                expect.equal(
                    try await store.profileStatus(of: chris.id, model: .fluidAudioOffline).sampleCount,
                    1, "one embedding for the meeting, not one per round"
                )
                expect.isTrue(
                    try await store.hasEnrolment(
                        identityID: chris.id, meetingID: "m1",
                        source: .humanConfirmedUtterances, model: .fluidAudioOffline
                    ),
                    "and the meeting it came from is recorded, so it is not redone"
                )
            },

            test("re-analysing a meeting reuses the voice it already remembered") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let service = SpeakerRecognitionService(store: store)
                let settings = SpeakerRecognitionSettings()
                let voice = vector(seed: 44)

                let first = try await service.resolve(
                    meetingID: "m1",
                    clusters: [SpeakerClusterInput(
                        clusterID: "remote-001_speaker_00", track: .remote,
                        speechSeconds: 120, centroid: voice
                    )],
                    settings: settings
                )
                expect.isTrue(first.first?.createdIdentity == true)
                // A first-time voice is remembered but not announced, so the
                // identity comes back nil and the occurrence row carries it.
                let occurrences = try await store.occurrences(meetingID: "m1")
                let created = try expect.unwrap(
                    occurrences.first { $0.clusterID == "remote-001_speaker_00" }?.resolvedIdentityID
                )

                // A re-analysis renumbers the run, so the same voice arrives
                // under a key nothing has seen.
                let second = try await service.resolve(
                    meetingID: "m1",
                    clusters: [SpeakerClusterInput(
                        clusterID: "remote-002_speaker_00", track: .remote,
                        speechSeconds: 120, centroid: voice
                    )],
                    settings: settings
                )
                _ = second
                let after = try await store.occurrences(meetingID: "m1")
                expect.equal(
                    after.first { $0.clusterID == "remote-002_speaker_00" }?.resolvedIdentityID,
                    created,
                    "the same voice in the same meeting is the same unnamed person"
                )
                expect.equal(
                    try await store.identities(kind: .anonymous).count, 1,
                    "re-analysing must not leave a second profile holding one voice"
                )
                expect.isTrue(
                    second.first?.createdIdentity == true,
                    "and it is still a voice heard once, not one heard before"
                )
                expect.notEqual(
                    second.first?.source, .anonymousVoice,
                    "reuse is not the same claim as having heard this voice elsewhere"
                )
            },

            test("enrolling a merged identity reaches the person it reads as") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let duplicate = try await store.createPerson(name: "Andrew")
                let survivor = try await store.createPerson(name: "Andrew Neeser")
                try await store.merge(duplicate.id, into: survivor.id)

                // A caller holding the old identifier, which is what a stored
                // localUserIdentityID is after a merge.
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: duplicate.id, vector: vector(seed: 21),
                    model: .fluidAudioOffline, speechSeconds: 240, qualityScore: 1,
                    source: .micTrackDeterministic, meetingID: "m1"
                ))

                let profiles = try await store.searchableProfiles(model: .fluidAudioOffline)
                expect.equal(profiles.count, 1, "the vector is searchable, not stranded")
                expect.equal(profiles.first?.identity.id, survivor.id)
                expect.equal(
                    try await store.profileStatus(
                        of: survivor.id, model: .fluidAudioOffline
                    ).sampleCount,
                    1
                )
            },

            test("two meetings below the bar are not merged into one vector") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let chris = try await store.createPerson(name: "Chris")
                for meeting in ["m1", "m2"] {
                    try await store.addPendingEnrollment(VoiceEnrollmentCandidate(
                        identityID: chris.id, vector: vector(seed: 8), model: .fluidAudioOffline,
                        speechSeconds: 30, qualityScore: 1,
                        source: .humanConfirmedUtterances, meetingID: meeting
                    ))
                }
                expect.isFalse(
                    try await store.flushPendingEnrollment(for: chris.id, model: .fluidAudioOffline),
                    "60 seconds across two sessions is not 60 seconds of one"
                )
                // Neither meeting is marked, so both keep accumulating.
                for meeting in ["m1", "m2"] {
                    expect.isFalse(try await store.hasEnrolment(
                        identityID: chris.id, meetingID: meeting,
                        source: .humanConfirmedUtterances, model: .fluidAudioOffline
                    ))
                }
                expect.close(
                    try await store.pendingSpeechSeconds(for: chris.id, model: .fluidAudioOffline),
                    60, tolerance: 0.001
                )
            },

            test("the microphone track may enrol the local user without a confirmation") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let service = SpeakerRecognitionService(store: store)
                let me = try await store.createPerson(name: "Andrew", isLocalUser: true)
                let status = try await service.learnLocalUserVoice(
                    meetingID: "m1", identityID: me.id, vector: vector(seed: 11),
                    speechSeconds: 240, quality: 1
                )
                expect.equal(status?.sampleCount, 1)
                expect.equal(try await store.localUser()?.id, me.id)
            },

            test("the microphone track refuses a voice heard on this call's other track") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let service = SpeakerRecognitionService(store: store)
                let me = try await store.createPerson(name: "Andrew", isLocalUser: true)

                // The far end, already diarized on the remote track.
                let presenter = vector(seed: 77)
                try await store.recordOccurrence(
                    meetingID: "m1", clusterID: "remote-001_speaker_00", track: .remote,
                    speechSeconds: 1_800, embedding: presenter, model: .fluidAudioOffline,
                    resolution: nil, identityID: nil, source: .ai,
                    humanVerified: false, wasExpectedParticipant: false
                )

                // Echo cancellation was unavailable and the user was listening,
                // so the presenter dominates the microphone track too.
                let declined = try await service.learnLocalUserVoice(
                    meetingID: "m1", identityID: me.id, vector: presenter,
                    speechSeconds: 1_800, quality: 1
                )
                expect.isNil(declined, "bleed is not the person holding the microphone")
                expect.isTrue(
                    try await store.searchableProfiles(model: .fluidAudioOffline).isEmpty,
                    "and nothing reached the one profile no person ever confirms"
                )

                // A different voice on the same call still enrols.
                let mine = try await service.learnLocalUserVoice(
                    meetingID: "m1", identityID: me.id, vector: vector(seed: 12),
                    speechSeconds: 240, quality: 1
                )
                expect.equal(mine?.sampleCount, 1)
            },

            test("naming a recurring voice keeps its history and its profile") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let voice = try await store.createAnonymous(state: .persistent)
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: voice.id, vector: vector(seed: 12), model: .fluidAudioOffline,
                    speechSeconds: 120, qualityScore: 1, source: .anonymousSeed, meetingID: "m1"
                ))
                try await store.recordOccurrence(
                    meetingID: "m1", clusterID: "run-001_speaker_00", track: .remote,
                    speechSeconds: 120, embedding: vector(seed: 12), model: .fluidAudioOffline,
                    resolution: nil, identityID: voice.id, source: .anonymousVoice,
                    humanVerified: false, wasExpectedParticipant: false
                )

                let promoted = try await store.promoteToPerson(
                    voice.id, name: "Samantha", organization: "Acme"
                )
                let named = try expect.unwrap(promoted)
                expect.equal(named.id, voice.id, "promotion must not change the identifier")
                expect.equal(named.kind, .person)
                expect.equal(named.resolvedName, "Samantha")
                expect.equal(
                    try await store.occurrences(identityID: voice.id).count, 1,
                    "every historical occurrence still points at the same identity"
                )
                expect.equal(
                    try await store.profileStatus(of: voice.id, model: .fluidAudioOffline).sampleCount,
                    1,
                    "the profile the voice already built is kept"
                )
            },

            test("a merge redirects instead of rewriting, and can be undone") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let first = try await store.createAnonymous(state: .persistent)
                let second = try await store.createAnonymous(state: .persistent)
                for identity in [first, second] {
                    _ = try await store.enrol(VoiceEnrollmentCandidate(
                        identityID: identity.id, vector: vector(seed: 13), model: .fluidAudioOffline,
                        speechSeconds: 90, qualityScore: 1, source: .anonymousSeed,
                        meetingID: "m\(identity.id.rawValue)"
                    ))
                    try await store.recordOccurrence(
                        meetingID: "m\(identity.id.rawValue)", clusterID: "c", track: .remote,
                        speechSeconds: 90, embedding: vector(seed: 13), model: .fluidAudioOffline,
                        resolution: nil, identityID: identity.id, source: .anonymousVoice,
                        humanVerified: false, wasExpectedParticipant: false
                    )
                }

                try await store.merge(second.id, into: first.id)
                expect.equal(
                    try await store.current(second.id)?.id, first.id,
                    "a read of the merged identity resolves to the survivor"
                )
                expect.equal(
                    try await store.searchableProfiles(model: .fluidAudioOffline).count, 1,
                    "one person must not occupy two ranks and eat their own margin"
                )
                expect.equal(
                    try await store.profileStatus(of: first.id, model: .fluidAudioOffline).sampleCount,
                    2,
                    "the survivor is scored against both sets of vectors"
                )
                expect.equal(try await store.meetingCount(for: first.id), 2)

                try await store.unmerge(second.id)
                expect.equal(try await store.current(second.id)?.id, second.id)
                expect.equal(
                    try await store.searchableProfiles(model: .fluidAudioOffline).count, 2
                )
            },

            test("forgetting a voice removes the biometric and keeps the person") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let chris = try await store.createPerson(name: "Chris")
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: chris.id, vector: vector(seed: 14), model: .fluidAudioOffline,
                    speechSeconds: 120, qualityScore: 1, source: .humanConfirmedCluster,
                    meetingID: "m1", clusterID: "c1"
                ))
                try await store.recordOccurrence(
                    meetingID: "m1", clusterID: "c1", track: .remote, speechSeconds: 120,
                    embedding: vector(seed: 14), model: .fluidAudioOffline, resolution: nil,
                    identityID: chris.id, source: .human, humanVerified: true,
                    wasExpectedParticipant: false
                )

                try await store.forgetVoice(of: chris.id)
                expect.isTrue(try await store.searchableProfiles(model: .fluidAudioOffline).isEmpty)
                expect.equal(try await store.current(chris.id)?.resolvedName, "Chris")
                expect.equal(
                    try await store.occurrences(meetingID: "m1").first?.resolvedIdentityID, chris.id,
                    "past transcripts keep the name"
                )
            },

            test("deleting a person takes every vector with them") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let chris = try await store.createPerson(name: "Chris")
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: chris.id, vector: vector(seed: 15), model: .fluidAudioOffline,
                    speechSeconds: 120, qualityScore: 1, source: .humanConfirmedCluster
                ))
                try await store.delete(chris.id)
                expect.isNil(try await store.current(chris.id))
                expect.isTrue(try await store.searchableProfiles(model: .fluidAudioOffline).isEmpty)
                let statistics = try await store.statistics()
                expect.equal(statistics.embeddings, 0, "ON DELETE CASCADE carried the vectors away")
            },

            test("retained embeddings are capped so the store cannot grow without bound") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let chris = try await store.createPerson(name: "Chris")
                for index in 0..<30 {
                    _ = try await store.enrol(VoiceEnrollmentCandidate(
                        identityID: chris.id, vector: vector(seed: 200 + index),
                        model: .fluidAudioOffline, speechSeconds: 60, qualityScore: 1,
                        source: .humanConfirmedCluster, meetingID: "m\(index)"
                    ))
                }
                expect.equal(
                    try await store.profileStatus(of: chris.id, model: .fluidAudioOffline).sampleCount,
                    policy.maximumEmbeddingsPerIdentity
                )
            },

            test("a candidate heard once expires; one heard twice does not") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let old = Date(timeIntervalSince1970: 1_600_000_000)
                let heardOnce = try await store.createAnonymous(state: .ephemeral, now: old)
                let heardTwice = try await store.createAnonymous(state: .ephemeral, now: old)
                _ = try await store.promoteToPersistent(heardTwice.id, now: old)

                // Seeded the way the recognizer actually creates one. A
                // candidate with no vector at all is not a state production can
                // produce, and testing only that shape hid an inverted
                // predicate that made expiry a no-op forever.
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: heardOnce.id, vector: vector(seed: 61),
                    model: .fluidAudioOffline, speechSeconds: 60, qualityScore: 0.9,
                    source: .anonymousSeed, meetingID: "m1"
                ), now: old)

                let removed = try await store.expireEphemeralIdentities(now: Date())
                expect.equal(removed, 1)
                expect.isNil(try await store.current(heardOnce.id))
                expect.equal(try await store.current(heardTwice.id)?.id, heardTwice.id)
            },

            test("a candidate a person confirmed is never expired") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let old = Date(timeIntervalSince1970: 1_600_000_000)
                let confirmed = try await store.createAnonymous(state: .ephemeral, now: old)
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: confirmed.id, vector: vector(seed: 62),
                    model: .fluidAudioOffline, speechSeconds: 90, qualityScore: 1,
                    source: .humanConfirmedCluster, meetingID: "m1"
                ), now: old)

                expect.equal(try await store.expireEphemeralIdentities(now: Date()), 0)
                expect.equal(try await store.current(confirmed.id)?.id, confirmed.id)
            },

            test("an automatic pass never overwrites a speaker a person confirmed") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let chris = try await store.createPerson(name: "Chris")

                try await store.recordOccurrence(
                    meetingID: "m1", clusterID: "run-001_speaker_02", track: .remote,
                    speechSeconds: 120, embedding: vector(seed: 63), model: .fluidAudioOffline,
                    resolution: nil, identityID: chris.id, source: .human,
                    humanVerified: true, wasExpectedParticipant: false
                )
                // The same cluster re-resolved automatically, concluding nothing.
                try await store.recordOccurrence(
                    meetingID: "m1", clusterID: "run-001_speaker_02", track: .remote,
                    speechSeconds: 120, embedding: vector(seed: 63), model: .fluidAudioOffline,
                    resolution: nil, identityID: nil, source: .ai,
                    humanVerified: false, wasExpectedParticipant: false
                )

                let occurrence = try expect.unwrap(
                    try await store.occurrences(meetingID: "m1").first
                )
                expect.equal(
                    occurrence.resolvedIdentityID, chris.id,
                    "a later automatic pass must not clear a person's answer"
                )
                expect.equal(occurrence.source, .human)
                expect.isTrue(occurrence.humanVerified)
                expect.equal(try await store.meetingCount(for: chris.id), 1)
            },

            test("deleting a person takes the whole merged family's vectors") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let voice = try await store.createAnonymous(state: .persistent)
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: voice.id, vector: vector(seed: 64), model: .fluidAudioOffline,
                    speechSeconds: 90, qualityScore: 1, source: .anonymousSeed, meetingID: "m1"
                ))
                let chris = try await store.createPerson(name: "Chris")
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: chris.id, vector: vector(seed: 64), model: .fluidAudioOffline,
                    speechSeconds: 90, qualityScore: 1, source: .humanConfirmedCluster,
                    meetingID: "m2"
                ))
                try await store.merge(voice.id, into: chris.id)

                try await store.delete(chris.id)
                expect.isNil(try await store.current(chris.id))
                expect.isNil(
                    try await store.current(voice.id),
                    "the merged identity holds the same person's voice and goes with them"
                )
                expect.isTrue(
                    try await store.searchableProfiles(model: .fluidAudioOffline).isEmpty,
                    "deleting a person must not leave their voice matchable"
                )
                expect.equal(try await store.statistics().embeddings, 0)
            },

            test("a merged identity still resolves to itself after separating") { expect in
                // The meeting files keep the identity they were written with, so
                // separating a merge can find them again. Rewriting the link on
                // merge left the meeting attributed to the wrong person with no
                // way back.
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let ann = try await store.createPerson(name: "Ann")
                let bob = try await store.createPerson(name: "Bob")
                try await store.recordOccurrence(
                    meetingID: "m1", clusterID: "c1", track: .remote, speechSeconds: 90,
                    embedding: vector(seed: 71), model: .fluidAudioOffline, resolution: nil,
                    identityID: ann.id, source: .human, humanVerified: true,
                    wasExpectedParticipant: false
                )

                try await store.merge(ann.id, into: bob.id)
                expect.equal(try await store.current(ann.id)?.resolvedName, "Bob")
                expect.equal(
                    try await store.occurrences(meetingID: "m1").first?.resolvedIdentityID, ann.id,
                    "the occurrence keeps the identity it was written with"
                )

                try await store.unmerge(ann.id)
                expect.equal(
                    try await store.current(ann.id)?.resolvedName, "Ann",
                    "separating restores who the meeting was about"
                )
            },

            test("forgetting a voice covers what was merged into it") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let voice = try await store.createAnonymous(state: .persistent)
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: voice.id, vector: vector(seed: 65), model: .fluidAudioOffline,
                    speechSeconds: 90, qualityScore: 1, source: .anonymousSeed, meetingID: "m1"
                ))
                let chris = try await store.createPerson(name: "Chris")
                try await store.merge(voice.id, into: chris.id)

                try await store.forgetVoice(of: chris.id)
                try await store.unmerge(voice.id)
                expect.isTrue(
                    try await store.searchableProfiles(model: .fluidAudioOffline).isEmpty,
                    "separating a merge must not resurrect a forgotten voice"
                )
                expect.equal(try await store.current(chris.id)?.resolvedName, "Chris")
            },

            test("merging an unnamed voice into a person keeps the profile human-verified") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let chris = try await store.createPerson(name: "Chris")
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: chris.id, vector: vector(seed: 66), model: .fluidAudioOffline,
                    speechSeconds: 90, qualityScore: 1, source: .humanConfirmedCluster,
                    meetingID: "m1"
                ))
                let voice = try await store.createAnonymous(state: .persistent)
                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: voice.id, vector: vector(seed: 900), model: .fluidAudioOffline,
                    speechSeconds: 90, qualityScore: 1, source: .anonymousSeed, meetingID: "m2"
                ))

                try await store.merge(voice.id, into: chris.id)
                expect.equal(
                    try await store.profileStatus(of: chris.id, model: .fluidAudioOffline).sampleCount,
                    1,
                    "a provisional seed must not reach a named centroid through a merge"
                )
                let profile = try expect.unwrap(
                    try await store.searchableProfiles(model: .fluidAudioOffline)
                        .first { $0.identity.id == chris.id }
                )
                expect.isTrue(
                    VoiceVector.cosine(profile.centroid, vector(seed: 66)) > 0.99,
                    "Chris is still scored against his own confirmed voice alone"
                )
            },
        ])
    }

    static var recognitionSuite: Suite {
        Suite("SpeakerRecognition", [
            test("a new voice with enough speech is remembered but not announced") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let service = SpeakerRecognitionService(store: store)
                let resolved = try await service.resolve(
                    meetingID: "m1",
                    clusters: [SpeakerClusterInput(
                        clusterID: "run-001_speaker_00", track: .remote,
                        speechSeconds: 120, centroid: vector(seed: 21)
                    )],
                    settings: SpeakerRecognitionSettings(), now: Date()
                )
                expect.isTrue(resolved.first?.createdIdentity == true)
                expect.isNil(resolved.first?.identity, "the first meeting still shows a number")
                let stored = try await store.identities(kind: .anonymous)
                expect.equal(stored.count, 1)
                expect.equal(stored.first?.state, .ephemeral)
            },

            test("the same voice in a second meeting becomes a recurring identity") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let service = SpeakerRecognitionService(store: store)
                let cluster = SpeakerClusterInput(
                    clusterID: "run-001_speaker_00", track: .remote,
                    speechSeconds: 120, centroid: vector(seed: 22)
                )
                _ = try await service.resolve(
                    meetingID: "m1", clusters: [cluster],
                    settings: SpeakerRecognitionSettings(), now: Date()
                )
                let second = try await service.resolve(
                    meetingID: "m2", clusters: [cluster],
                    settings: SpeakerRecognitionSettings(), now: Date()
                )
                expect.equal(second.first?.source, .anonymousVoice)
                let identity = try expect.unwrap(second.first?.identity)
                expect.equal(identity.state, .persistent)
                expect.equal(identity.anonymousNumber, 1)
                expect.equal(second.first?.meetingCount, 2)
            },

            test("resolving the same meeting twice does not invent a voice heard before") { expect in
                // The second pass would otherwise score the cluster against the
                // profile seeded from its own vector, match at 1.0, and promote
                // a voice heard exactly once into a recurring identity.
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let service = SpeakerRecognitionService(store: store)
                let cluster = SpeakerClusterInput(
                    clusterID: "run-001_speaker_00", track: .remote,
                    speechSeconds: 120, centroid: vector(seed: 51)
                )
                _ = try await service.resolve(
                    meetingID: "m1", clusters: [cluster],
                    settings: SpeakerRecognitionSettings(), now: Date()
                )
                let again = try await service.resolve(
                    meetingID: "m1", clusters: [cluster],
                    settings: SpeakerRecognitionSettings(), now: Date()
                )
                expect.isNil(again.first?.identity, "it has still only ever been heard once")
                expect.notEqual(again.first?.source, .anonymousVoice)
                let identities = try await store.identities(kind: .anonymous)
                expect.equal(identities.count, 1, "and no second candidate was created")
                expect.equal(
                    identities.first?.state, .ephemeral,
                    "nothing promoted it: promotion means a second meeting"
                )
            },

            test("two clusters in one meeting are not linked to each other as heard before") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let service = SpeakerRecognitionService(store: store)
                // The diarizer split one person into two clusters. Merging them
                // is the user's call; claiming the second was "heard before"
                // when both are in this one meeting is not.
                let resolved = try await service.resolve(
                    meetingID: "m1",
                    clusters: [
                        SpeakerClusterInput(
                            clusterID: "run-001_speaker_00", track: .remote,
                            speechSeconds: 120, centroid: vector(seed: 52)
                        ),
                        SpeakerClusterInput(
                            clusterID: "run-001_speaker_01", track: .remote,
                            speechSeconds: 120, centroid: vector(seed: 52)
                        ),
                    ],
                    settings: SpeakerRecognitionSettings(), now: Date()
                )
                expect.equal(resolved.count, 2)
                expect.isTrue(
                    resolved.allSatisfy { $0.source != .anonymousVoice },
                    "neither cluster was heard before this meeting"
                )
            },

            test("a voice heard in a second meeting is still recognized") { expect in
                // The guard above must not cost the feature it protects.
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let service = SpeakerRecognitionService(store: store)
                let cluster = SpeakerClusterInput(
                    clusterID: "run-001_speaker_00", track: .remote,
                    speechSeconds: 120, centroid: vector(seed: 53)
                )
                _ = try await service.resolve(
                    meetingID: "m1", clusters: [cluster],
                    settings: SpeakerRecognitionSettings(), now: Date()
                )
                let second = try await service.resolve(
                    meetingID: "m2", clusters: [cluster],
                    settings: SpeakerRecognitionSettings(), now: Date()
                )
                expect.equal(second.first?.source, .anonymousVoice)
                expect.equal(second.first?.identity?.state, .persistent)
            },

            test("a brief interjection leaves nothing behind") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let service = SpeakerRecognitionService(store: store)
                _ = try await service.resolve(
                    meetingID: "m1",
                    clusters: [SpeakerClusterInput(
                        clusterID: "run-001_speaker_04", track: .remote,
                        speechSeconds: 6, centroid: vector(seed: 23)
                    )],
                    settings: SpeakerRecognitionSettings(), now: Date()
                )
                expect.isTrue(
                    try await store.identities(kind: .anonymous).isEmpty,
                    "six seconds of speech is not an identity"
                )
            },

            test("switching recurring voices off leaves no unnamed identities") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let service = SpeakerRecognitionService(store: store)
                _ = try await service.resolve(
                    meetingID: "m1",
                    clusters: [SpeakerClusterInput(
                        clusterID: "run-001_speaker_00", track: .remote,
                        speechSeconds: 300, centroid: vector(seed: 24)
                    )],
                    settings: SpeakerRecognitionSettings(rememberRecurringVoices: false),
                    now: Date()
                )
                expect.isTrue(try await store.identities(kind: .anonymous).isEmpty)
            },

            test("confirming a cluster names it and builds the profile") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let service = SpeakerRecognitionService(store: store)
                let chris = try await store.createPerson(name: "Chris")
                let status = try await service.confirmCluster(
                    meetingID: "m1",
                    cluster: SpeakerClusterInput(
                        clusterID: "run-001_speaker_01", track: .remote,
                        speechSeconds: 95, centroid: vector(seed: 25)
                    ),
                    identityID: chris.id,
                    settings: SpeakerRecognitionSettings()
                )
                expect.equal(status.sampleCount, 1)
                let recorded = try await store.occurrences(meetingID: "m1").first
                let occurrence = try expect.unwrap(recorded)
                expect.isTrue(occurrence.humanVerified)
                expect.equal(occurrence.source, .human)
            },

            test("one meeting contributes one enrolment, however many lines are corrected") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let chris = try await store.createPerson(name: "Chris")
                let model = EmbeddingModelIdentifier.fluidAudioOffline
                expect.isFalse(try await store.hasEnrolment(
                    identityID: chris.id, meetingID: "m1",
                    source: .humanConfirmedUtterances, model: model
                ))

                _ = try await store.enrol(VoiceEnrollmentCandidate(
                    identityID: chris.id, vector: vector(seed: 72), model: model,
                    speechSeconds: 60, qualityScore: 0.5,
                    source: .humanConfirmedUtterances, meetingID: "m1"
                ))
                expect.isTrue(try await store.hasEnrolment(
                    identityID: chris.id, meetingID: "m1",
                    source: .humanConfirmedUtterances, model: model
                ))
                expect.isFalse(
                    try await store.hasEnrolment(
                        identityID: chris.id, meetingID: "m2",
                        source: .humanConfirmedUtterances, model: model
                    ),
                    "a different meeting is still fresh material"
                )
            },

            test("learning from corrections can be switched off entirely") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let service = SpeakerRecognitionService(store: store)
                let chris = try await store.createPerson(name: "Chris")
                let status = try await service.confirmCluster(
                    meetingID: "m1",
                    cluster: SpeakerClusterInput(
                        clusterID: "c", track: .remote, speechSeconds: 300, centroid: vector(seed: 26)
                    ),
                    identityID: chris.id,
                    settings: SpeakerRecognitionSettings(learnFromCorrections: false)
                )
                expect.equal(status.sampleCount, 0, "the name is applied, the voice is not learned")
                expect.equal(
                    try await store.occurrences(meetingID: "m1").first?.resolvedIdentityID, chris.id
                )
            },
        ])
    }

    static var all: [Suite] { [policySuite, vectorSuite, storeSuite, recognitionSuite] }
}
