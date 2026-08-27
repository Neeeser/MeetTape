import Foundation
import PipitCore
import PipitServices
import PipitSpeakers
import SQLite3
import TestKit

/// What a person keeps about somebody, and how a few hundred of them are put on
/// screen.
///
/// Notes and badges are the first fields on an identity that exist only for a
/// reader, so the rules that already cover names have to be shown to cover
/// these too: a delete takes them, a merge leaves them where an unmerge finds
/// them again, and the picture goes with the row.
enum PeopleDirectoryTests {

    // MARK: helpers

    static func makeStore() throws -> (SpeakerStore, URL) {
        let root = try ManifestTests.makeTemporaryDirectory()
        let store = try SpeakerStore(url: root.appendingPathComponent("voices.sqlite"))
        return (store, root)
    }

    static func entry(
        _ id: Int64,
        name: String? = nil,
        organization: String? = nil,
        notes: String? = nil,
        aliases: [String] = [],
        anonymousNumber: Int? = nil,
        profile: VoiceProfileStatus = .none,
        meetings: Int = 0,
        isLocalUser: Bool = false
    ) -> SpeakerDirectoryEntry {
        SpeakerDirectoryEntry(
            identity: Identity(
                id: IdentityID(id),
                kind: name == nil ? .anonymous : .person,
                displayName: name,
                anonymousNumber: anonymousNumber,
                aliases: aliases,
                organization: organization,
                notes: notes,
                isLocalUser: isLocalUser,
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)
            ),
            profile: profile,
            meetingCount: meetings
        )
    }

    static func utterance(_ speaker: String, _ text: String, at start: Double) -> Utterance {
        Utterance(
            id: "u-\(start)", start: start, end: start + 2, track: .remote,
            rawSpeakerLabel: speaker, speakerKey: speaker, text: text,
            chunkID: "c0", model: "test"
        )
    }

    // MARK: suites

    static var all: [Suite] {
        [storeSuite, filterSuite, renderSuite, exportSuite, meetingsSuite, localUserSuite]
    }

    static var storeSuite: Suite {
        Suite("PersonDetail", [
            test("notes, badges and a picture round trip") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let chris = try await store.createPerson(name: "Chris", organization: "Acme")

                try await store.setNotes("Owns the ingest retries.", on: chris.id)
                try await store.setBadges([.slack, .zoom], on: chris.id)
                try await store.setAvatar(Data([0x89, 0x50, 0x4E, 0x47]), on: chris.id)

                let read = try await expect.unwrap(store.current(chris.id))
                expect.equal(read.notes, "Owns the ingest retries.")
                expect.equal(read.badges, [.slack, .zoom])
                expect.isTrue(read.hasAvatar, "the list needs to know a picture exists")
                expect.equal(try await store.avatar(of: chris.id), Data([0x89, 0x50, 0x4E, 0x47]))
            },

            test("blank notes clear the field rather than storing whitespace") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let chris = try await store.createPerson(name: "Chris")
                try await store.setNotes("something", on: chris.id)
                try await store.setNotes("   \n ", on: chris.id)
                // A participant block built from whitespace prints a name with
                // an empty line under it in every transcript they are in.
                expect.isNil(try await store.current(chris.id)?.notes)
            },

            test("replacing the badge set removes what is no longer there") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let chris = try await store.createPerson(name: "Chris")
                try await store.setBadges([.slack, .zoom, .phone], on: chris.id)
                try await store.setBadges([.zoom], on: chris.id)
                expect.equal(try await store.current(chris.id)?.badges, [.zoom])
            },

            test("deleting a person takes their notes, badges and picture") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let chris = try await store.createPerson(name: "Chris")
                try await store.setNotes("Owns the ingest retries.", on: chris.id)
                try await store.setBadges([.slack], on: chris.id)
                try await store.setAvatar(Data([0x89, 0x50]), on: chris.id)

                try await store.delete(chris.id)

                expect.isNil(try await store.current(chris.id))
                expect.isNil(
                    try await store.avatar(of: chris.id),
                    "the cascade has to reach the picture, or a deleted person leaves their face behind"
                )
            },

            test("a merged person keeps their own notes for an unmerge to find") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let chris = try await store.createPerson(name: "Chris")
                let duplicate = try await store.createPerson(name: "C. Fowler")
                try await store.setNotes("The other row's notes.", on: duplicate.id)
                try await store.setNotes("Owns the ingest retries.", on: chris.id)

                try await store.merge(duplicate.id, into: chris.id)
                // Reads resolve through the tombstone, so the duplicate reads as
                // Chris and shows his notes.
                expect.equal(try await store.current(duplicate.id)?.notes, "Owns the ingest retries.")

                try await store.unmerge(duplicate.id)
                expect.equal(
                    try await store.current(duplicate.id)?.notes, "The other row's notes.",
                    "a merge moves nothing, so separating it has to find the notes still there"
                )
            },

            test("one organization is set across a whole selection") { expect in
                let (store, root) = try makeStore()
                defer { try? FileManager.default.removeItem(at: root) }
                let people = try await [
                    store.createPerson(name: "Chris"),
                    store.createPerson(name: "Dana"),
                    store.createPerson(name: "Priya"),
                ]
                try await store.setOrganization("Acme", on: [people[0].id, people[2].id])
                expect.equal(try await store.current(people[0].id)?.organization, "Acme")
                expect.isNil(try await store.current(people[1].id)?.organization)
                expect.equal(try await store.current(people[2].id)?.organization, "Acme")
            },

            test("a version 1 database gains the new fields and keeps its people") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let url = root.appendingPathComponent("voices.sqlite")
                try writeVersionOneDatabase(at: url, name: "Chris")

                let store = try SpeakerStore(url: url)
                let people = try await store.identities(kind: .person)
                expect.equal(people.count, 1, "the migration must not drop anybody")
                expect.equal(people.first?.resolvedName, "Chris")
                expect.isNil(people.first?.notes)
                expect.equal(people.first?.badges, [])

                // And the columns the migration added are writable, which is
                // what it was for.
                let chris = try expect.unwrap(people.first)
                try await store.setNotes("Still here.", on: chris.id)
                try await store.setBadges([.slack], on: chris.id)
                expect.equal(try await store.current(chris.id)?.notes, "Still here.")
                expect.equal(try await store.current(chris.id)?.badges, [.slack])
            },
        ])
    }

    static var filterSuite: Suite {
        Suite("PeopleDirectoryFilter", [
            test("you are the first section, whatever your organization is") {
                expect in
                // The row wanted most often and hardest to find: filed under an
                // organization it sits among colleagues, in alphabetical order,
                // named like anybody else.
                let entries = [
                    entry(1, name: "Andrew", organization: "Acme", isLocalUser: true),
                    entry(2, name: "Aaron", organization: "Acme"),
                    entry(3, name: "Priya"),
                    entry(4, anonymousNumber: 2),
                ]
                let sections = PeopleDirectoryFilter.sections(entries)
                expect.equal(sections.first?.title, PeopleDirectoryFilter.youTitle)
                expect.equal(sections.first?.entries.map(\.identity.resolvedName), ["Andrew"])
                expect.isFalse(
                    sections.dropFirst().contains { $0.entries.contains { $0.identity.isLocalUser } },
                    "one row, in one place"
                )
                expect.equal(
                    sections.dropFirst().first?.entries.map(\.identity.resolvedName), ["Aaron"],
                    "the organization keeps everybody else"
                )
            },

            test("a search that does not match you leaves the section out") {
                expect in
                let entries = [
                    entry(1, name: "Andrew", isLocalUser: true),
                    entry(2, name: "Priya"),
                ]
                expect.equal(
                    PeopleDirectoryFilter.sections(entries, query: "priya").map(\.title),
                    [PeopleDirectoryFilter.noOrganizationTitle]
                )
            },

            test("search reaches the organization, the aliases and the notes") { expect in
                let entries = [
                    entry(1, name: "Chris Fowler", organization: "Acme"),
                    entry(2, name: "Dana Kwon", aliases: ["DK"]),
                    entry(3, name: "Priya Raman", notes: "Owns the ingest retries."),
                ]
                func names(_ query: String) -> [String] {
                    PeopleDirectoryFilter.sections(entries, query: query)
                        .flatMap(\.entries).map(\.identity.resolvedName)
                }
                expect.equal(names("acme"), ["Chris Fowler"])
                expect.equal(names("dk"), ["Dana Kwon"], "an alias is how a name was written elsewhere")
                expect.equal(
                    names("ingest"), ["Priya Raman"],
                    "notes are the field people fill in to tell two similar voices apart"
                )
                expect.equal(names("nobody"), [])
            },

            test("unnamed voices sit below the people, in numeric order") { expect in
                let entries = [
                    entry(10, anonymousNumber: 10),
                    entry(9, anonymousNumber: 9),
                    entry(1, name: "Chris Fowler", organization: "Acme"),
                ]
                let sections = PeopleDirectoryFilter.sections(entries)
                expect.equal(sections.map(\.title), ["Acme", PeopleDirectoryFilter.unnamedTitle])
                expect.equal(
                    sections.last?.entries.map(\.identity.anonymousNumber), [9, 10],
                    "#9 sorts before #10, which sorting the text would not do"
                )
            },

            test("people with no organization group above the unnamed voices") { expect in
                let entries = [
                    entry(1, name: "Chris Fowler", organization: "Acme"),
                    entry(2, name: "Dana Kwon"),
                    entry(3, anonymousNumber: 3),
                ]
                expect.equal(
                    PeopleDirectoryFilter.sections(entries).map(\.title),
                    ["Acme", PeopleDirectoryFilter.noOrganizationTitle,
                     PeopleDirectoryFilter.unnamedTitle]
                )
            },

            test("each filter admits what it says it does") { expect in
                let entries = [
                    entry(1, name: "Chris Fowler", profile: .ready(samples: 4, recordings: 4, speechSeconds: 600)),
                    entry(2, name: "Dana Kwon"),
                    entry(3, anonymousNumber: 3, profile: .learning(samples: 1, recordings: 1, speechSeconds: 60)),
                ]
                func count(_ filter: PeopleFilter) -> Int {
                    PeopleDirectoryFilter.sections(entries, filter: filter).flatMap(\.entries).count
                }
                expect.equal(count(.all), 3)
                expect.equal(count(.named), 2)
                expect.equal(count(.unnamed), 1)
                expect.equal(count(.withVoiceProfile), 2)
            },
        ])
    }

    static var renderSuite: Suite {
        Suite("TranscriptParticipants", [
            test("the participant block carries organization and notes above the dialogue") { expect in
                let transcript = CanonicalTranscript(
                    generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    utterances: [utterance("s1", "We ship Friday.", at: 0)]
                )
                var speakers = SpeakerMap()
                speakers.assign("Priya Raman", to: "s1")
                let markdown = TranscriptRenderer().markdown(
                    transcript: transcript,
                    speakers: speakers,
                    title: "Roadmap sync",
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    durationSeconds: 600,
                    participants: [
                        TranscriptParticipant(
                            name: "Priya Raman", organization: "Acme",
                            notes: "Owns the ingest retries."
                        )
                    ]
                )
                let participantsAt = try expect.unwrap(markdown.range(of: "## Participants"))
                let dialogueAt = try expect.unwrap(markdown.range(of: "We ship Friday."))
                expect.isTrue(
                    participantsAt.lowerBound < dialogueAt.lowerBound,
                    "a reader who meets the notes after the conversation has already decided who everybody is"
                )
                expect.isTrue(markdown.contains("**Priya Raman** · Acme"))
                expect.isTrue(markdown.contains("Owns the ingest retries."))
            },

            test("nobody with notes means no participant section at all") { expect in
                let transcript = CanonicalTranscript(
                    generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    utterances: [utterance("s1", "We ship Friday.", at: 0)]
                )
                var speakers = SpeakerMap()
                speakers.assign("Priya Raman", to: "s1")
                let markdown = TranscriptRenderer().markdown(
                    transcript: transcript,
                    speakers: speakers,
                    title: "Roadmap sync",
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    durationSeconds: 600,
                    participants: [TranscriptParticipant(name: "Priya Raman")]
                )
                expect.isFalse(
                    markdown.contains("## Participants"),
                    "a name with nothing attached adds nothing the dialogue does not already say"
                )
            },
        ])
    }

    /// The participant block is derived, so the question is never whether the
    /// database is right: it is whether the markdown on disk was rewritten when
    /// the database changed.
    static var exportSuite: Suite {
        Suite("ParticipantBlockRefresh", [
            test("rebuilding a transcript keeps the participant block") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let (store, storeRoot) = try makeStore()
                defer { try? FileManager.default.removeItem(at: storeRoot) }

                let (pipeline, meeting, _) = try await makeRenderedMeeting(
                    root: root, store: store, notes: "Owns the ingest retries."
                )
                expect.isTrue(try markdown(meeting).contains("Owns the ingest retries."))

                // Rebuild re-assembles and re-renders. Rendering without the
                // participants erased a block nothing would put back until
                // somebody happened to edit this person again.
                try await pipeline.rebuildTranscript(
                    meetingID: try meeting.readMetadata().id
                )

                expect.isTrue(
                    try markdown(meeting).contains("Owns the ingest retries."),
                    "a derived file rebuilt from source has to be rebuilt whole"
                )
            },

            test("deleting a person clears their notes from transcripts already rendered") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let (store, storeRoot) = try makeStore()
                defer { try? FileManager.default.removeItem(at: storeRoot) }

                let (pipeline, meeting, chris) = try await makeRenderedMeeting(
                    root: root, store: store, notes: "Owns the ingest retries."
                )
                expect.isTrue(try markdown(meeting).contains("Owns the ingest retries."))

                // What the runtime does: the meetings are collected while the row
                // still exists, because afterwards nothing can find them.
                let affected = try await store.meetingsReferencing(chris.id)
                try await store.delete(chris.id)
                await pipeline.rerenderMeetings(affected)

                expect.isFalse(
                    try markdown(meeting).contains("Owns the ingest retries."),
                    "the confirmation says the notes are removed, so they cannot stay in the export"
                )
            },
        ])
    }

    static func markdown(_ store: MeetingStore) throws -> String {
        try String(contentsOf: store.layout.transcriptMarkdown, encoding: .utf8)
    }

    /// A meeting on disk whose transcript.md has been rendered once, with one
    /// named person linked to its only speaker.
    static func makeRenderedMeeting(
        root: URL, store: SpeakerStore, notes: String
    ) async throws -> (ProcessingPipeline, MeetingStore, Identity) {
        let meeting = try PipelineTests.makeRecordedMeeting(root: root)
        // Raw words and diarization on disk, so a rebuild has something to
        // re-assemble from and the test is not passing on an early return.
        var raw = try meeting.store.readRawTranscript()
        raw.chunks.append(RawTranscriptChunk(
            id: "remote_chunk_001", track: .remote, timelineOffset: 0,
            durationSeconds: 6, model: "stub", responseFormat: "local_text",
            segments: [RawTranscriptSegment(
                start: 0, end: 2, text: "we ship friday", speaker: nil,
                words: [
                    RawTranscriptWord(start: 0.0, end: 0.4, text: " we"),
                    RawTranscriptWord(start: 0.5, end: 0.8, text: " ship"),
                    RawTranscriptWord(start: 0.9, end: 1.2, text: " friday"),
                ]
            )],
            purpose: .words
        ))
        try meeting.store.writeRawTranscript(raw)
        var diarization = try meeting.store.readRawDiarization()
        diarization.setActive(DiarizationRun(
            id: "run-remote", track: .remote, backend: "stub",
            producedAt: Date(timeIntervalSince1970: 0), timelineOffset: 0,
            intervals: [DiarizationInterval(start: 0, end: 2, clusterID: "A")]
        ))
        try meeting.store.writeRawDiarization(diarization)

        let chris = try await store.createPerson(name: "Chris")
        try await store.setNotes(notes, on: chris.id)
        try await store.recordOccurrence(
            meetingID: meeting.metadata.id, clusterID: "remote-001_speaker_00", track: .remote,
            speechSeconds: 120, embedding: nil, model: nil, resolution: nil,
            identityID: chris.id, source: .human,
            humanVerified: true, wasExpectedParticipant: false
        )

        try meeting.store.writeCanonicalTranscript(CanonicalTranscript(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            utterances: [utterance("remote-001_speaker_00", "We ship Friday.", at: 0)]
        ))
        var map = SpeakerMap()
        map.assign("Chris", to: "remote-001_speaker_00", identityID: chris.id)
        try meeting.store.writeSpeakerMap(map)

        let pipeline = ProcessingPipeline(
            repository: meeting.repository,
            backend: FakeAIBackend(),
            backends: ProcessingBackends(
                transcription: { _, _ in fatalError("not reached") },
                diarization: { _, _ in fatalError("not reached") },
                speakers: SpeakerRecognitionService(store: store)
            ),
            clock: ManualClock(),
            settingsProvider: { AppSettings() },
            wait: { _ in }
        )
        // The first render, so the assertions are about a rewrite rather than
        // about a file appearing.
        try await pipeline.refreshCachedNames(for: chris.id)
        return (pipeline, meeting.store, chris)
    }


    /// The meetings on a person's profile, and the audio behind them.
    static var meetingsSuite: Suite {
        Suite("PersonMeetings", [
            test("a person's profile lists the meetings they were heard in") {
                expect in try await appearancesListEveryMeeting(expect)
            },

            test("a sample plays this person's longest turn") {
                expect in try await theSampleIsTheLongestTurn(expect)
            },

            test("a person with no audio on disk offers nothing to play") {
                expect in try await noAudioMeansNoSample(expect)
            },
        ])
    }

    /// A meeting on disk with one named speaker, and a stand-in for the
    /// mixdown. Nothing here decodes the audio, so a file that exists is
    /// everything the sample needs from it.
    @MainActor
    static func makeAppearance(
        store: SpeakerStore, identityID: IdentityID,
        root: URL, title: String, at started: Date, turns: [(Double, Double)],
        writingAudio: Bool = true
    ) async throws -> String {
        let meeting = try MeetingsWindowTests.makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: title, startedAt: started
        )
        var map = SpeakerMap()
        map.assign("Ben", to: "remote-001_speaker_00", identityID: identityID)
        try meeting.store.writeSpeakerMap(map)
        try meeting.store.writeCanonicalTranscript(CanonicalTranscript(
            generatedAt: started,
            utterances: turns.enumerated().map { index, turn in
                Utterance(
                    id: "u\(index)", start: turn.0, end: turn.1, track: .remote,
                    rawSpeakerLabel: "remote-001_speaker_00",
                    speakerKey: "remote-001_speaker_00",
                    text: "the northwind renewal", chunkID: "c1", model: "m"
                )
            }
        ))
        if writingAudio {
            try Data([0x00]).write(to: meeting.store.layout.recordingAudio)
        }
        try await store.recordOccurrence(
            meetingID: meeting.id, clusterID: "remote-001_speaker_00", track: .remote,
            speechSeconds: turns.reduce(0) { $0 + ($1.1 - $1.0) }, embedding: nil, model: nil,
            resolution: nil, identityID: identityID, source: .human,
            humanVerified: true, wasExpectedParticipant: false
        )
        return meeting.id
    }

    @MainActor
    static func appearancesListEveryMeeting(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = MeetingsWindowTests.makeRuntime(root: root)
        let store = try expect.unwrap(runtime.speakerStore)
        let ben = try await store.createPerson(name: "Ben")

        let older = try await makeAppearance(
            store: store, identityID: ben.id, root: root,
            title: "Design review", at: Date(timeIntervalSince1970: 1_787_000_000),
            turns: [(0, 12)]
        )
        let newer = try await makeAppearance(
            store: store, identityID: ben.id, root: root,
            title: "Weekly sync", at: Date(timeIntervalSince1970: 1_787_900_000),
            turns: [(0, 4), (10, 15)]
        )

        let appearances = await runtime.appearances(of: ben.id)
        expect.equal(appearances.map(\.meetingID), [newer, older], "newest first")
        expect.equal(appearances.first?.title, "Weekly sync")
        expect.equal(appearances.first?.speechSeconds, 9)
        expect.isTrue(appearances.allSatisfy(\.hasAudio))

        // Nobody else's meetings, and nobody else's silence.
        let stranger = try await store.createPerson(name: "Priya")
        expect.isTrue(
            await runtime.appearances(of: stranger.id).isEmpty,
            "a person heard in nothing has nothing to list"
        )
    }

    @MainActor
    static func theSampleIsTheLongestTurn(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = MeetingsWindowTests.makeRuntime(root: root)
        let store = try expect.unwrap(runtime.speakerStore)
        let ben = try await store.createPerson(name: "Ben")
        let meetingID = try await makeAppearance(
            store: store, identityID: ben.id, root: root,
            title: "Weekly sync", at: Date(timeIntervalSince1970: 1_787_900_000),
            turns: [(0, 3), (30, 60)]
        )

        let sample = try expect.unwrap(await runtime.voiceSample(of: ben.id, inMeeting: meetingID))
        expect.equal(sample.start, 30, "the longest turn, not the first")
        expect.equal(sample.end, 38, "capped, because nobody listens to thirty seconds to place a voice")
        expect.equal(sample.audio.lastPathComponent, "recording.m4a")

        // A merged duplicate reads as the person it was merged into, so the
        // sample follows the same pointer every other read does.
        let duplicate = try await store.createPerson(name: "B. Baker")
        try await store.merge(ben.id, into: duplicate.id)
        _ = try expect.unwrap(await runtime.voiceSample(of: duplicate.id, inMeeting: meetingID))
    }

    @MainActor
    static func noAudioMeansNoSample(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = MeetingsWindowTests.makeRuntime(root: root)
        let store = try expect.unwrap(runtime.speakerStore)
        let ben = try await store.createPerson(name: "Ben")
        let meetingID = try await makeAppearance(
            store: store, identityID: ben.id, root: root,
            title: "Weekly sync", at: Date(timeIntervalSince1970: 1_787_900_000),
            turns: [(0, 20)], writingAudio: false
        )

        // Compaction removes the mixdown of an old meeting. The row stays, and
        // the button that would play nothing is not offered.
        expect.isFalse(await runtime.appearances(of: ben.id).first?.hasAudio ?? true)
        expect.isNil(await runtime.voiceSample(of: ben.id, inMeeting: meetingID))
    }


    /// Which person in the directory is the one at this Mac.
    static var localUserSuite: Suite {
        Suite("LocalUser", [
            test("choosing who you are moves the flag and the name with it") {
                expect in try await choosingYouMovesTheFlagAndTheName(expect)
            },

            test("forgetting a voice takes the readings that built it") {
                expect in try await forgettingAVoiceTakesTheReadings(expect)
            },
        ])
    }

    @MainActor
    static func choosingYouMovesTheFlagAndTheName(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = MeetingsWindowTests.makeRuntime(root: root)
        let store = try expect.unwrap(runtime.speakerStore)

        await runtime.ensureLocalUserIdentity()
        let first = try expect.unwrap(try await store.localUser())
        let andrew = try await store.createPerson(name: "Andrew Neeser")

        await runtime.setLocalUser(andrew.id)

        expect.equal(runtime.settings.processing.localUserIdentityID, andrew.id)
        expect.equal(runtime.settings.localUserName, "Andrew Neeser", "Settings caches their name")
        expect.equal(try await store.localUser()?.id, andrew.id)
        expect.isFalse(
            try await store.current(first.id)?.isLocalUser ?? true,
            "two rows cannot both be the person at the keyboard"
        )

        // The launch sync writes the name in Settings onto the flagged row. It
        // ran against the row picked here, so a name set anywhere had to be the
        // one Settings holds, or the next start would put the old one back.
        await runtime.ensureLocalUserIdentity()
        expect.equal(try await store.current(andrew.id)?.resolvedName, "Andrew Neeser")
    }


    /// A reading is kept so the vector it produced can be heard and re-derived,
    /// which means forgetting the voice has to take it. Across the whole family:
    /// vectors go for every identifier that reads as this person, and audio filed
    /// under one that has since been merged away is still audio of them.
    @MainActor
    static func forgettingAVoiceTakesTheReadings(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = MeetingsWindowTests.makeRuntime(root: root)
        let store = try expect.unwrap(runtime.speakerStore)
        let old = try await store.createPerson(name: "Andrew")
        let current = try await store.createPerson(name: "Andrew Neeser")
        try await store.merge(old.id, into: current.id)

        let archive = runtime.voiceEnrollmentArchive
        let reading = try archive.newRecording(for: old.id, id: "take-one")
        try Data([0x00]).write(to: reading)
        expect.equal(archive.recordings(for: old.id).count, 1)

        await runtime.forgetVoice(of: current.id)

        expect.isTrue(
            archive.recordings(for: old.id).isEmpty,
            "the audio of a merged-away row is audio of the person it reads as"
        )
    }

    /// The schema as version 1 shipped it, frozen here on purpose.
    ///
    /// A migration test that builds its fixture from the current source cannot
    /// fail: the "old" database would gain every change alongside the migration
    /// meant to introduce it. This copy stays as version 1 was.
    static func writeVersionOneDatabase(at url: URL, name: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw MigrationFixtureError.cannotOpen
        }
        defer { sqlite3_close(handle) }
        let sql = """
            PRAGMA foreign_keys=ON;
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
            CREATE TABLE voice_evidence(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              voice_embedding_id INTEGER REFERENCES voice_embedding(id) ON DELETE CASCADE,
              pending_enrollment_id INTEGER REFERENCES pending_enrollment(id) ON DELETE CASCADE,
              meeting_id TEXT NOT NULL,
              track TEXT NOT NULL,
              confirmation_source TEXT NOT NULL,
              human_verified INTEGER NOT NULL DEFAULT 0,
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
              contradicted INTEGER NOT NULL DEFAULT 0,
              CHECK (end_time >= start_time)
            );
            CREATE INDEX idx_span_evidence ON voice_evidence_span(evidence_id);
            INSERT INTO identity(kind, display_name, is_local_user, state, created_at, updated_at)
            VALUES('person', '\(name)', 0, 'persistent', 0, 0);
            PRAGMA user_version = 1;
            """
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw MigrationFixtureError.schemaFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }

    enum MigrationFixtureError: Error {
        case cannotOpen
        case schemaFailed(String)
    }
}
