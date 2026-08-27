import AppKit
import Foundation
import PipitCore
import PipitServices
import PipitUI
import SwiftUI
import TestKit

/// The meetings window, and the date an imported recording is filed under.
///
/// Both exist because the archive is only navigable if the two things it is
/// ordered by are right: when a meeting happened, and who was in it.
enum MeetingsWindowTests {
    static var all: [Suite] { [recordedDateSuite, directorySuite, windowSuite] }

    // MARK: helpers

    /// A calendar pinned to one zone, so a date in a test means the same thing
    /// on every machine that runs it.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    /// A meeting on disk whose transcript holds the clusters named, plus the
    /// bucket for words no diarization interval claimed.
    static func makeMeeting(
        root: URL, clusters: [String], words: String = "the northwind renewal",
        source: MeetingSource = .googleMeet, title: String = "Design review",
        startedAt: Date = Date(timeIntervalSince1970: 1_787_070_000)
    ) throws -> (id: String, store: MeetingStore) {
        let repository = MeetingRepository(root: root.appendingPathComponent("Meetings"))
        let started = startedAt
        let created = try repository.createMeeting(
            source: source, provider: .unknown, startedAt: started,
            titles: TitleCandidates(provider: title, timestampFallback: "f"), now: started
        )
        _ = try created.store.updateMetadata {
            $0.durationSeconds = 600
            $0.processing = ProcessingStatus(state: .complete, updatedAt: started)
        }
        let keys = clusters + [SpeakerLabel.unattributed(track: .remote)]
        let utterances = keys.enumerated().map { index, key in
            Utterance(
                id: "u\(index)", start: Double(index) * 10, end: Double(index) * 10 + 8,
                track: .remote, rawSpeakerLabel: key, speakerKey: key,
                text: words, chunkID: "c1", model: "m"
            )
        }
        try created.store.writeCanonicalTranscript(
            CanonicalTranscript(generatedAt: started, utterances: utterances)
        )
        return (created.metadata.id, created.store)
    }

    /// Where a runtime built here puts the meetings it trashes.
    static func trashDirectory(under root: URL) -> URL {
        root.appendingPathComponent("Trash")
    }

    /// A runtime pointed at one temporary archive, with a Trash of its own.
    ///
    /// The Finder's own Trash would fill with the archives these tests build,
    /// so a trashed folder is moved here instead. It is also what lets a test
    /// see that a meeting was moved rather than unlinked.
    @MainActor
    static func makeRuntime(root: URL) -> PipitRuntime {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let trash = trashDirectory(under: root)
        let runtime = PipitRuntime(settingsDirectory: root, trash: { folder in
            try FileManager.default.createDirectory(
                at: trash, withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(
                at: folder, to: trash.appendingPathComponent(folder.lastPathComponent)
            )
        })
        var settings = runtime.settings
        settings.storageRootPath = root.appendingPathComponent("Meetings").path
        runtime.update(settings: settings)
        return runtime
    }

    /// Waits for work the window model started in the background, for up to a
    /// second. A test that fails says more than one that hangs.
    @MainActor
    static func waitFor(
        _ expect: Expect, _ what: String, until condition: () -> Bool
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        expect.fail("timed out waiting for \(what)")
    }

    static func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let date = formatter.date(from: text) else {
            preconditionFailure("test date \(text) does not parse")
        }
        return date
    }

    static func row(
        _ id: String,
        title: String,
        at started: Date,
        state: ProcessingState = .complete,
        speakers: [(String?, Int64?)] = [],
        notes: String = "",
        source: MeetingSource = .googleMeet,
        interrupted: Bool = false,
        archived: Bool = false
    ) -> MeetingRow {
        MeetingRow(
            summary: MeetingSummary(
                id: id,
                directory: URL(fileURLWithPath: "/tmp/\(id)"),
                title: title,
                startedAt: started,
                durationSeconds: 600,
                source: source,
                provider: .unknown,
                processingState: state,
                wasInterrupted: interrupted,
                hasTranscript: state == .complete,
                recordingCount: 1,
                isArchived: archived
            ),
            speakers: speakers.enumerated().map { index, speaker in
                MeetingRowSpeaker(
                    key: "speaker_\(index)",
                    displayName: speaker.0,
                    identityID: speaker.1.map(IdentityID.init)
                )
            },
            notes: notes
        )
    }

    // MARK: - the date an import is filed under

    static var recordedDateSuite: Suite {
        Suite("ImportedRecordingDate", [
            test("the file's own timestamp beats the date the copy landed on") { expect in
                let now = date("2026-08-24 15:00:00")
                let chosen = RecordedDatePolicy.choose(
                    metadata: date("2026-07-02 09:30:00"),
                    filename: date("2026-08-01 12:00:00"),
                    fileCreated: now,
                    now: now
                )
                expect.equal(chosen.source, .fileMetadata)
                expect.equal(chosen.date, date("2026-07-02 09:30:00"))
            },

            test("a filename timestamp beats the copy's creation date") { expect in
                // The case this exists for: a voice memo dragged off a phone
                // keeps its name and loses its creation date.
                let now = date("2026-08-24 15:00:00")
                let chosen = RecordedDatePolicy.choose(
                    metadata: nil,
                    filename: date("2026-08-15 09:12:33"),
                    fileCreated: now,
                    now: now
                )
                expect.equal(chosen.source, .filename)
                expect.equal(chosen.date, date("2026-08-15 09:12:33"))
            },

            test("an implausible timestamp is skipped rather than believed") { expect in
                let now = date("2026-08-24 15:00:00")
                let epoch = RecordedDatePolicy.choose(
                    metadata: Date(timeIntervalSince1970: 0),
                    filename: nil,
                    fileCreated: date("2026-08-20 08:00:00"),
                    now: now
                )
                expect.equal(epoch.source, .fileCreated, "1970 is a container default, not a date")

                let ahead = RecordedDatePolicy.choose(
                    metadata: date("2031-01-01 00:00:00"),
                    filename: nil,
                    fileCreated: date("2026-08-20 08:00:00"),
                    now: now
                )
                expect.equal(ahead.source, .fileCreated, "five years ahead is a broken clock")

                let nothing = RecordedDatePolicy.choose(
                    metadata: nil, filename: nil, fileCreated: nil, now: now
                )
                expect.equal(nothing.source, .importTime)
                expect.equal(nothing.date, now)
            },

            test("a clock an hour ahead is still a real recording") { expect in
                let now = date("2026-08-24 15:00:00")
                let chosen = RecordedDatePolicy.choose(
                    metadata: date("2026-08-24 16:00:00"),
                    filename: nil, fileCreated: nil, now: now
                )
                expect.equal(chosen.source, .fileMetadata)
            },

            test("the shapes recorders actually write are read out of a filename") { expect in
                let calendar = MeetingsWindowTests.calendar
                func parsed(_ name: String) -> Date? {
                    RecordedDatePolicy.dateInFilename(name, calendar: calendar)
                }
                expect.equal(
                    parsed("New Recording 2026-08-15 09.12.33.m4a"),
                    date("2026-08-15 09:12:33"),
                    "Apple Voice Memos"
                )
                expect.equal(
                    parsed("20260815_091233.mp3"), date("2026-08-15 09:12:33"),
                    "Android recorders and Zoom"
                )
                expect.equal(
                    parsed("meeting-2026-08-15T09-12-33.wav"), date("2026-08-15 09:12:33"),
                    "an ISO-ish name with a filesystem-safe time"
                )
                expect.equal(
                    parsed("standup 2026-08-15.m4a"), date("2026-08-15 12:00:00"),
                    "a name with no time lands at midday, so the day survives a zone change"
                )
            },

            test("a run of digits that is not a date is left alone") { expect in
                let calendar = MeetingsWindowTests.calendar
                expect.isNil(
                    RecordedDatePolicy.dateInFilename("recording 1234567890.m4a", calendar: calendar),
                    "a unix timestamp is not the year 1234"
                )
                expect.isNil(
                    RecordedDatePolicy.dateInFilename("track 03.mp3", calendar: calendar)
                )
                expect.isNil(
                    RecordedDatePolicy.dateInFilename("2026-13-45.m4a", calendar: calendar),
                    "month 13 and day 45 are not a date"
                )
                expect.isNil(
                    RecordedDatePolicy.dateInFilename("call.m4a", calendar: calendar)
                )
                expect.equal(
                    RecordedDatePolicy.dateInFilename(
                        "REC 12345678 2026-08-15.m4a", calendar: calendar
                    ),
                    date("2026-08-15 12:00:00"),
                    "a serial number in front of the date does not hide it"
                )
                expect.equal(
                    RecordedDatePolicy.dateInFilename(
                        "standup 2026-08-15 47-12.m4a", calendar: calendar
                    ),
                    date("2026-08-15 12:00:00"),
                    "a duration where a time would sit does not take the date with it"
                )
            },

            test("a metadata string is read, and a bare year is refused") { expect in
                expect.equal(
                    RecordedDatePolicy.parseMetadataDate("2026-08-15T09:12:33Z"),
                    date("2026-08-15 09:12:33"),
                    "the QuickTime shape"
                )
                expect.equal(
                    RecordedDatePolicy.parseMetadataDate("2026-08-15T09:12:33.500Z"),
                    Date(timeIntervalSince1970: date("2026-08-15 09:12:33").timeIntervalSince1970 + 0.5),
                    "fractional seconds"
                )
                expect.isNil(
                    RecordedDatePolicy.parseMetadataDate("2026"),
                    "a year alone would put the meeting on the first of January"
                )
                expect.isNil(RecordedDatePolicy.parseMetadataDate(""))
            },
        ])
    }

    // MARK: - the list

    static var directorySuite: Suite {
        Suite("MeetingsDirectory", [
            test("meetings are grouped by when, newest first") { expect in
                let now = date("2026-08-24 15:00:00")
                let calendar = MeetingsWindowTests.calendar
                let rows = [
                    row("a", title: "Design review", at: date("2026-08-24 14:15:00")),
                    row("b", title: "Standup", at: date("2026-08-23 09:32:00")),
                    row("c", title: "Weekly sync", at: date("2026-08-19 10:00:00")),
                    row("d", title: "July retro", at: date("2026-07-31 16:00:00")),
                ]
                let sections = MeetingsDirectoryFilter.sections(
                    rows, now: now, calendar: calendar
                )
                expect.equal(
                    sections.map(\.title),
                    ["Today", "Yesterday", "Earlier this month",
                     MeetingsDirectoryFilter.sectionTitle(
                         for: date("2026-07-31 16:00:00"), now: now, calendar: calendar)]
                )
                expect.equal(sections.first?.rows.map(\.id), ["a"])
                expect.equal(sections.last?.rows.map(\.id), ["d"])
            },

            test("a date ahead of now files under today rather than opening a section above it") { expect in
                // An imported file whose device clock ran ahead. The date is
                // kept. The heading is not invented.
                let now = date("2026-08-24 15:00:00")
                let rows = [row("a", title: "Voice memo", at: date("2026-08-24 23:30:00"))]
                let sections = MeetingsDirectoryFilter.sections(
                    rows, now: now, calendar: calendar
                )
                expect.equal(sections.map(\.title), ["Today"])
            },

            test("the unnamed filter is the list of meetings still asking for a name") { expect in
                let now = date("2026-08-24 15:00:00")
                let rows = [
                    row("a", title: "Named throughout", at: now,
                        speakers: [("Andrew", 1), ("Chris", 2)]),
                    row("b", title: "One voice left", at: now,
                        speakers: [("Andrew", 1), (nil, nil)]),
                    row("c", title: "Nobody named", at: now, speakers: [(nil, nil), (nil, nil)]),
                ]
                let visible = MeetingsDirectoryFilter.sections(
                    rows, filter: .unnamed, now: now, calendar: calendar
                ).flatMap(\.rows)
                expect.equal(visible.map(\.id), ["b", "c"])
                expect.equal(visible.map(\.unnamedCount), [1, 2])
            },

            test("needs attention holds a failure and a recording that stopped short") { expect in
                // A call that dropped and was rejoined is interrupted forever,
                // and once it has processed there is nothing to act on. Listing
                // it made the filter a drawer nothing ever leaves.
                let now = date("2026-08-24 15:00:00")
                let rows = [
                    row("a", title: "Fine", at: now),
                    row("b", title: "Failed", at: now, state: .failed),
                    row("c", title: "Cut short and unfinished", at: now,
                        state: .transcribing, interrupted: true),
                    row("d", title: "Rejoined and processed", at: now, interrupted: true),
                    row("e", title: "Still working", at: now, state: .transcribing),
                ]
                let visible = MeetingsDirectoryFilter.sections(
                    rows, filter: .needsAttention, now: now, calendar: calendar
                ).flatMap(\.rows)
                expect.equal(Set(visible.map(\.id)), ["b", "c"])
            },

            test("an archived meeting is in the archived list and no other") { expect in
                // Archiving is how a recording is put down. Leaving it under
                // All would make it a badge, and leaving a failed one under
                // Attention would keep work in front of the user that they
                // have already dismissed.
                let now = date("2026-08-24 15:00:00")
                let rows = [
                    row("a", title: "Kept", at: now, speakers: [(nil, nil)]),
                    row("b", title: "Put down", at: now, state: .failed,
                        speakers: [(nil, nil)], archived: true),
                ]
                func visible(_ filter: MeetingsFilter) -> [String] {
                    MeetingsDirectoryFilter.sections(
                        rows, filter: filter, now: now, calendar: calendar
                    ).flatMap(\.rows).map(\.id)
                }
                expect.equal(visible(.all), ["a"])
                expect.equal(visible(.unnamed), ["a"], "and it is not work waiting to be done")
                expect.equal(visible(.needsAttention), [], "nor a failure still asking for a look")
                expect.equal(visible(.archived), ["b"])
            },

            test("grouping a year of meetings costs about what grouping one month costs") { expect in
                // A month heading is formatted, and a `DateFormatter` built per
                // row cost about 0.13 ms of the main actor each. Search regroups
                // the whole archive on every keystroke, so 500 meetings spread
                // over two years spent 69 ms per keystroke building 500
                // formatters, against 4 ms for the same rows inside one month.
                // Measured against those same-month rows, which take every step
                // of this path except the formatter, so the answer does not
                // depend on how fast the machine is.
                let now = date("2026-08-24 15:00:00")
                func rows(spacing: TimeInterval) -> [MeetingRow] {
                    (0..<400).map { index in
                        row(
                            "m\(index)", title: "Meeting \(index)",
                            at: now.addingTimeInterval(-Double(index) * spacing)
                        )
                    }
                }
                func elapsed(_ rows: [MeetingRow]) -> Double {
                    let started = Date()
                    for _ in 0..<5 {
                        _ = MeetingsDirectoryFilter.sections(
                            rows, now: now, calendar: MeetingsWindowTests.calendar
                        )
                    }
                    return Date().timeIntervalSince(started)
                }
                _ = elapsed(rows(spacing: 86_400))
                let oneMonth = elapsed(rows(spacing: 3_600))
                let twoYears = elapsed(rows(spacing: 86_400))
                expect.isTrue(
                    twoYears < oneMonth * 4,
                    "one formatter per grouping, not per row: "
                        + "\(Int(twoYears * 1_000)) ms against \(Int(oneMonth * 1_000)) ms"
                )
            },

            test("search covers the title, the notes, the speakers and the transcript") { expect in
                let now = date("2026-08-24 15:00:00")
                let rows = [
                    row("a", title: "Design review", at: now, speakers: [("Priya Raman", 3)]),
                    row("b", title: "Standup", at: now, notes: "Northwind renewal decided"),
                    row("c", title: "Weekly sync", at: now),
                ]
                func found(_ query: String, transcripts: [String: String] = [:]) -> [String] {
                    MeetingsDirectoryFilter.sections(
                        rows, query: query, transcripts: transcripts, now: now, calendar: calendar
                    ).flatMap(\.rows).map(\.id)
                }
                expect.equal(found("design"), ["a"], "the title")
                expect.equal(found("priya"), ["a"], "a speaker's name")
                expect.equal(found("northwind"), ["b"], "the user's own notes")
                expect.equal(found("alignment"), [], "and nothing else, until the index exists")
                expect.equal(
                    found("alignment", transcripts: ["c": "so the alignment fix landed"]),
                    ["c"],
                    "the words, once the transcripts have been read"
                )
            },
        ])
    }

    // MARK: - the window

    /// A conversation recorded in two halves, each with its own transcript and
    /// its own speaker map, linked as one meeting.
    static func makeRejoinedCall(root: URL) throws -> (MeetingRepository, String) {
        let repository = MeetingRepository(root: root.appendingPathComponent("Meetings"))
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let first = try repository.createMeeting(
            source: .googleMeet, provider: .googleMeet, startedAt: started,
            titles: TitleCandidates(provider: "Weekly sync", timestampFallback: "f"), now: started
        )
        let second = try repository.createMeeting(
            source: .googleMeet, provider: .googleMeet,
            startedAt: started.addingTimeInterval(900),
            titles: TitleCandidates(provider: "Weekly sync", timestampFallback: "f"),
            now: started.addingTimeInterval(900)
        )
        for (store, text, at) in [
            (first.store, "before the drop", started),
            (second.store, "after the rejoin", started.addingTimeInterval(900)),
        ] {
            _ = try store.updateMetadata {
                $0.durationSeconds = 600
                $0.processing = ProcessingStatus(state: .complete, updatedAt: at)
            }
            try store.writeCanonicalTranscript(CanonicalTranscript(
                generatedAt: at,
                utterances: [
                    Utterance(
                        id: "\(text)-1", start: 0, end: 30, track: .remote, rawSpeakerLabel: nil,
                        speakerKey: "remote-001_speaker_00", text: text, chunkID: "c", model: "m"
                    ),
                ]
            ))
        }
        // Both halves number their speakers from zero, and only the first has a
        // name for its own.
        var firstMap = SpeakerMap()
        firstMap.assign("Chris Vaughn", to: "remote-001_speaker_00", identityID: IdentityID(2))
        try first.store.writeSpeakerMap(firstMap)

        _ = try second.store.updateMetadata { $0.mergedIntoMeetingID = first.metadata.id }
        _ = try first.store.updateMetadata { $0.absorbedMeetingIDs = [second.metadata.id] }
        return (repository, first.metadata.id)
    }

    static var windowSuite: Suite {
        Suite("MeetingsWindow", [
            test("the window opens a meeting that no filter is showing") { expect in
                try await aFilteredOutMeetingStillOpens(expect)
            },

            test("the list counts the voices a meeting has not named") { expect in
                try await unnamedVoicesReachTheList(expect)
            },

            test("the meeting the pane is showing stays selected when the list is read again") {
                expect in try await selectionSurvivesAReload(expect)
            },

            test("a name set on a speaker reaches the list without reopening the window") { expect in
                try await aNewNameReachesTheList(expect)
            },

            test("a title typed into the pane reaches the list") { expect in
                try await aNewTitleReachesTheList(expect)
            },

            test("a title committed with Return reaches the list too") { expect in
                try await aCommittedTitleReachesTheList(expect)
            },

            test("a meeting recorded while the window is open joins the search index") { expect in
                try await aLaterMeetingJoinsTheSearchIndex(expect)
            },

            test("the pane catches up with a meeting that finished while it was closed") { expect in
                try await theOpenPaneCatchesUp(expect)
            },

            test("a rewritten transcript is searchable by the words it holds now") { expect in
                try await searchFollowsARewrittenTranscript(expect)
            },

            test("a meeting transcribed after the list was read joins the search index") {
                expect in try await aLaterTranscriptJoinsTheSearchIndex(expect)
            },

            test("a rebuilt transcript is searchable by the words it holds now") { expect in
                try await searchFollowsARebuild(expect)
            },

            test("a correction on the second half of a call reaches the conversation's row") {
                expect in try await aFoldedHalfReachesTheConversationsRow(expect)
            },

            test("a receipt leaves out the lines a person had already set") {
                expect in try await aReceiptLeavesOutLinesAPersonSet(expect)
            },

            test("a receipt leaves out a line corrected a moment earlier") {
                expect in try await aReceiptLeavesOutAFreshCorrection(expect)
            },

            test("naming a speaker reports the lines of the recording it changed") {
                expect in try await aReceiptCountsOneRecordingsLines(expect)
            },

            test("search finds a word said after the call dropped and was rejoined") {
                expect in try await searchReachesBothHalvesOfACall(expect)
            },

            test("a transcript that will not decode still leaves the meeting in the list") {
                expect in try await aCorruptTranscriptKeepsItsRow(expect)
            },

            test("a change to a meeting the pane is not showing still reaches its row") {
                expect in try await anotherMeetingsRowKeepsUp(expect)
            },

            test("combining takes the folded recording's row out of the list") {
                expect in try await combiningTakesTheFoldedRowOutOfTheList(expect)
            },

            test("separating gives the later recording its row and its words back") {
                expect in try await separatingRestoresTheRowAndTheIndex(expect)
            },

            test("a cluster that says almost nothing is not counted as work to do") {
                expect in try await aSilentClusterIsNotWorkToDo(expect)
            },

            test("a call recorded in two halves reports the voices in both") {
                expect in try await bothHalvesReachTheRow(expect)
            },

            test("the strip offers a chip for every voice the list counts") {
                expect in try await theStripCoversWhatTheListCounts(expect)
            },

            test("naming the voice heard after a rejoin writes that half's map") {
                expect in try await namingTheSecondHalfWritesItsOwnMap(expect)
            },

            test("the microphone track is not a voice waiting for a name") {
                expect in try await theMicrophoneTrackIsNotUnnamed(expect)
            },

            test("naming a speaker on a folded half drops the conversation's words") {
                expect in try await namingOnAFoldedHalfDropsTheConversationsWords(expect)
            },

            test("a read in flight does not put back words a rewrite has replaced") { expect in
                // The archive-wide read holds the transcript as it was before
                // the rewrite. Merging it back, with the meeting marked as
                // covered, left search answering from the old file for the life
                // of the window, because nothing asks again for a meeting the
                // index believes it holds.
                expect.equal(
                    MeetingsDirectoryFilter.admissible(
                        read: ["a": "old words", "b": "untouched"], droppedWhileReading: ["a"]
                    ),
                    ["b": "untouched"]
                )
                expect.equal(
                    MeetingsDirectoryFilter.admissible(
                        read: ["a": "words"], droppedWhileReading: []
                    ),
                    ["a": "words"],
                    "and an ordinary read is kept whole"
                )
            },

            test("moving a meeting to the Trash takes every folder it was recorded in") {
                expect in try await trashingMovesEveryFolder(expect)
            },

            test("archiving takes the row out of the list and leaves the files alone") {
                expect in try await archivingKeepsTheFiles(expect)
            },

            test("a right-click acts on the row under the pointer, not the selection") {
                expect in try await aRightClickActsOnTheRowUnderIt(expect)
            },

            test("trashing a meeting stops its voices counting it") {
                expect in try await trashingDropsTheOccurrences(expect)
            },

            test("a folder that will not move keeps its row and its occurrences") {
                expect in try await aFolderThatWillNotMoveKeepsItsRow(expect)
            },

            test("archiving survives the next write to the meeting's metadata") {
                expect in try await archivingSurvivesAMetadataWrite(expect)
            },

            test("archiving writes what was typed into the pane before it closes it") {
                expect in try await archivingSavesTheEdit(expect)
            },

            test("the footer counts the meetings the filter holds") {
                expect in try await theFooterCountsWhatTheFilterHolds(expect)
            },

            test("what the move could not do is said one cause at a time") { expect in
                // Every refusal used to read as a recording in progress, which
                // sent the reader looking for a call that had already ended.
                expect.isNil(MeetingsWindowModel.problemText(recording: nil, failed: []))
                let one = try expect.unwrap(
                    MeetingsWindowModel.problemText(recording: "Standup", failed: [])
                )
                expect.isTrue(one.contains("Standup is being recorded"), "got \(one)")
                let other = try expect.unwrap(
                    MeetingsWindowModel.problemText(recording: nil, failed: ["Design review"])
                )
                expect.isTrue(
                    other.contains("would not move") && !other.contains("being recorded"),
                    "a folder that would not move is not a recording. got \(other)"
                )
                let both = try expect.unwrap(
                    MeetingsWindowModel.problemText(
                        recording: "Standup", failed: ["Design review"]
                    )
                )
                expect.isTrue(both.contains("Standup") && both.contains("Design review"))
                let volume = try expect.unwrap(
                    MeetingsWindowModel.problemText(
                        recording: nil, failed: [], noTrash: ["Design review"]
                    )
                )
                expect.isTrue(
                    volume.contains("volume with no Trash"),
                    "a share with no Trash is not a fault on one meeting. got \(volume)"
                )
            },

            test("a row names the day when its heading does not") { expect in
                // Only Today and Yesterday name a day. Under a month heading a
                // clock time alone left no way to tell which day a meeting was
                // without opening it.
                let now = date("2026-08-24 15:00:00")
                let calendar = MeetingsWindowTests.calendar
                for (moment, why) in [
                    (date("2026-08-24 14:15:00"), "today"),
                    (date("2026-08-23 09:32:00"), "yesterday"),
                ] {
                    expect.equal(
                        Format.listDate(moment, now: now, calendar: calendar),
                        Format.timeOfDay(moment), why
                    )
                }
                let older = Format.listDate(
                    date("2026-07-31 16:00:00"), now: now, calendar: calendar
                )
                expect.notEqual(
                    older, Format.timeOfDay(date("2026-07-31 16:00:00")),
                    "and anything older carries its date"
                )
                expect.isTrue(older.contains("31"), "which names the day: got \(older)")
            },
        ])
    }

    // MARK: - the window, on the main actor
    //
    // The window model and the runtime are main-actor types and neither is
    // Sendable, so a test that holds one across an await has to be isolated to
    // that actor rather than hopping onto it for each statement.

    /// A recording that has just finished has to land on screen even while the
    /// sidebar is filtered to something it is not in. The pane is opened by
    /// identifier rather than through the list, so what the filter is showing
    /// decides nothing about what can be read.
    @MainActor
    static func aFilteredOutMeetingStillOpens(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root.appendingPathComponent("Meetings"))
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .imported, provider: .unknown, startedAt: started,
            titles: TitleCandidates(window: "Voice memo", timestampFallback: "f"), now: started
        )

        let model = MeetingsWindowModel(runtime: makeRuntime(root: root))
        await model.reload()
        model.filter = .needsAttention
        expect.equal(model.rows.map(\.id), [created.metadata.id], "the archive holds it")
        expect.equal(
            model.sections.flatMap(\.rows).count, 0, "and the filter is showing nothing"
        )

        model.show(meetingID: created.metadata.id)

        expect.equal(model.selection, [created.metadata.id])
        expect.equal(model.detail?.meetingID, created.metadata.id)
        expect.equal(model.detail?.title, "Voice memo")
        UITests.render(
            MeetingsWindowView(model: model), size: NSSize(width: 1_120, height: 720)
        )
    }

    /// The case the Unnamed filter exists for. A cluster nobody has named has no
    /// entry in the speaker map at all, so a row built from the map alone
    /// reported nothing to do in exactly the meetings holding the most of it.
    @MainActor
    static func unnamedVoicesReachTheList(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try makeMeeting(
            root: root, clusters: ["remote-001_speaker_00", "remote-001_speaker_01", "local"]
        )
        var map = SpeakerMap()
        map.assign("Chris Vaughn", to: "remote-001_speaker_00", identityID: IdentityID(7))
        try meeting.store.writeSpeakerMap(map)
        try meeting.store.writeNotes("Northwind renewal")

        let rows = await makeRuntime(root: root).meetingRows()

        expect.equal(rows.count, 1)
        guard let row = rows.first else { return }
        expect.equal(row.id, meeting.id)
        expect.equal(row.namedSpeakers.map(\.displayName), ["Chris Vaughn"])
        expect.equal(
            row.namedSpeakers.first?.identityID, IdentityID(7),
            "the identifier travels, so the colour matches the People window"
        )
        expect.equal(row.unnamedCount, 2, "two clusters, and no name on either")
        expect.equal(
            row.speakers.count, 3,
            "and the bucket for words no interval claimed is not one of them"
        )
        expect.equal(row.notes, "Northwind renewal", "which search reads")
        expect.isTrue(
            MeetingsFilter.unnamed.admits(row), "so the filter that lists the work finds it"
        )
    }

    /// A recording that finished after the read began is not in the rows it
    /// returns. Pruning the selection to what the read saw moved the user off
    /// the meeting a notification had just opened.
    @MainActor
    static func selectionSurvivesAReload(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeMeeting(root: root, clusters: ["local"], title: "Standup")
        let opened = try makeMeeting(root: root, clusters: ["local"], title: "Design review")

        let model = MeetingsWindowModel(runtime: makeRuntime(root: root))
        model.show(meetingID: opened.id)
        // The folder goes away between the click and the read, which is what a
        // meeting recorded after the read began looks like from here.
        try FileManager.default.removeItem(at: opened.store.layout.root)
        await model.reload()

        expect.equal(model.selection, [opened.id])
        expect.equal(model.detail?.meetingID, opened.id)
    }

    /// The list draws its faces from each meeting's speaker map, and renaming
    /// rewrites that file. Reading the archive again only when the processing
    /// stage changed left the row showing a name the meeting no longer has.
    @MainActor
    static func aNewNameReachesTheList(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try makeMeeting(root: root, clusters: ["remote-001_speaker_00"])

        let model = MeetingsWindowModel(runtime: makeRuntime(root: root))
        await model.reload()
        expect.equal(model.rows.first?.namedSpeakers.count, 0, "nobody named yet")

        var map = SpeakerMap()
        map.assign("Priya Raman", to: "remote-001_speaker_00")
        try meeting.store.writeSpeakerMap(map)
        await model.refresh(meetingID: meeting.id)

        expect.equal(model.rows.first?.namedSpeakers.map(\.displayName), ["Priya Raman"])
        expect.equal(model.rows.first?.unnamedCount, 0)
    }

    @MainActor
    static func aNewTitleReachesTheList(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try makeMeeting(root: root, clusters: ["local"], title: "Design review")

        let model = MeetingsWindowModel(runtime: makeRuntime(root: root))
        await model.reload()
        model.show(meetingID: meeting.id)
        model.detail?.title = "Northwind renewal"
        model.detail?.saveEdits()

        await waitFor(expect, "the row to take the new title") {
            model.rows.first?.title == "Northwind renewal"
        }
    }

    /// Return in the title field writes immediately rather than waiting for the
    /// debounce. That path wrote the file and told nobody, so the row went on
    /// showing the old title until the archive was read again, which is the one
    /// case where the user is watching for the change.
    @MainActor
    static func aCommittedTitleReachesTheList(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try makeMeeting(root: root, clusters: ["local"], title: "Design review")

        let model = MeetingsWindowModel(runtime: makeRuntime(root: root))
        await model.reload()
        model.show(meetingID: meeting.id)
        model.detail?.title = "Northwind renewal"
        model.detail?.save()

        await waitFor(expect, "the row to take the committed title") {
            model.rows.first?.title == "Northwind renewal"
        }
    }

    /// The window keeps its model when it closes, so the pane is still on the
    /// meeting it was showing when it opens again. Reading only the list left it
    /// on the transcript that did not exist yet.
    @MainActor
    static func theOpenPaneCatchesUp(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root.appendingPathComponent("Meetings"))
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .googleMeet, provider: .unknown, startedAt: started,
            titles: TitleCandidates(provider: "Design review", timestampFallback: "f"), now: started
        )

        let model = MeetingsWindowModel(runtime: makeRuntime(root: root))
        await model.reload()
        model.show(meetingID: created.metadata.id)
        // Opening the pane starts a read of its own. It has to finish before
        // the transcript lands, or that read is the one that picks it up and
        // the reopen is never tested.
        try? await Task.sleep(for: .milliseconds(50))
        expect.isNil(model.detail?.transcript, "nothing transcribed yet")

        try created.store.writeCanonicalTranscript(CanonicalTranscript(
            generatedAt: started,
            utterances: [Utterance(
                id: "u0", start: 0, end: 4, track: .remote,
                rawSpeakerLabel: "remote-001_speaker_00", speakerKey: "remote-001_speaker_00",
                text: "so the northwind renewal", chunkID: "c1", model: "m"
            )]
        ))
        await model.reload()

        expect.equal(model.detail?.combinedLines.count, 1)
    }

    /// Renaming a speaker rewrites `transcript.md`, and the words the index
    /// holds are the ones it had before. The rewrite lands after the click, so
    /// the index is read again when the change reports back.
    @MainActor
    static func searchFollowsARewrittenTranscript(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try makeMeeting(root: root, clusters: ["remote-001_speaker_00"])
        try meeting.store.writeTranscriptMarkdown("Speaker 1: the northwind renewal")

        let model = MeetingsWindowModel(runtime: makeRuntime(root: root))
        await model.reload()
        model.show(meetingID: meeting.id)
        await waitFor(expect, "the transcripts to be read") { model.searchesTranscripts }
        model.query = "priya"
        expect.equal(model.sections.flatMap(\.rows).count, 0, "that name is not in it yet")

        try meeting.store.writeTranscriptMarkdown("Priya Raman: the northwind renewal")
        await model.refresh(meetingID: meeting.id)

        expect.equal(model.sections.flatMap(\.rows).map(\.id), [meeting.id])
    }

    /// A meeting still being transcribed is in the list before it has any words.
    /// Counting it as read because the index had looked at it once meant its
    /// words were never picked up, and it stayed unsearchable for the life of
    /// the window.
    @MainActor
    static func aLaterTranscriptJoinsTheSearchIndex(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try makeMeeting(root: root, clusters: ["local"], title: "Design review")

        let model = MeetingsWindowModel(runtime: makeRuntime(root: root))
        await model.reload()
        await waitFor(expect, "the first pass over the archive") { model.searchesTranscripts }

        try meeting.store.writeTranscriptMarkdown("Andrew: the northwind renewal")
        await model.reload()
        model.query = "northwind"

        await waitFor(expect, "the words to reach the index") {
            model.sections.flatMap(\.rows).map(\.id) == [meeting.id]
        }
    }

    /// A rebuild rewrites `transcript.md` and nothing else watches one finish.
    /// Dropping the words and waiting for the next reload left search answering
    /// from the transcript the meeting used to have.
    @MainActor
    static func searchFollowsARebuild(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try makeMeeting(root: root, clusters: ["local"], title: "Design review")
        try meeting.store.writeTranscriptMarkdown("Andrew: the northwind renewal")

        let model = MeetingsWindowModel(runtime: makeRuntime(root: root))
        await model.reload()
        await waitFor(expect, "the transcripts to be read") { model.searchesTranscripts }
        expect.equal(model.selection.count, 1, "the first row is selected")

        // Standing in for the assembler, which has no chunks to work from here.
        // What the window owes is the read back, whatever the rebuild wrote.
        try meeting.store.writeTranscriptMarkdown("Andrew: the audio sdk call")
        model.rebuildSelection()
        model.query = "audio sdk"

        await waitFor(expect, "the rebuilt words to reach search") {
            model.sections.flatMap(\.rows).map(\.id) == [meeting.id]
        }
    }

    /// A conversation recorded in two halves is one row, and the pane opens on
    /// the half a notification named. Every operation named by that identifier
    /// has to reach the conversation: looking the row up under the folded half's
    /// own identifier found nothing, and placing what came back under the
    /// identifier that was asked for put a second row for one conversation in
    /// the list.
    @MainActor
    static func aFoldedHalfReachesTheConversationsRow(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Design review"
        )
        let second = try makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Design review, rejoined"
        )

        let runtime = makeRuntime(root: root)
        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        model.show(meetingID: second.id)
        runtime.combine(meetingID: second.id, into: first.id, reason: "a test")
        await model.reload()

        expect.equal(model.rows.map(\.id), [first.id], "one row for the conversation")
        expect.equal(
            model.detail?.meetingID, second.id, "the pane is still keyed on the half it opened on"
        )

        var map = SpeakerMap()
        map.assign("Priya Raman", to: "remote-001_speaker_00")
        try first.store.writeSpeakerMap(map)
        await model.refresh(meetingID: second.id)

        expect.equal(model.rows.count, 1, "and not a second row for the same conversation")
        expect.equal(model.rows.first?.namedSpeakers.map(\.displayName), ["Priya Raman"])
    }

    /// A cluster identifier names a speaker inside one recording, and both
    /// halves of a rejoined call number their speakers from zero. Naming a
    /// cluster writes the speaker map of the recording the pane is keyed on, so
    /// counting every line in the conversation carrying that identifier claimed
    /// the change had reached lines in the other half that it had not.
    @MainActor
    static func aReceiptCountsOneRecordingsLines(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Design review",
            startedAt: Date(timeIntervalSince1970: 1_787_066_400)
        )
        let second = try makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Design review, rejoined"
        )

        let runtime = makeRuntime(root: root)
        runtime.combine(meetingID: second.id, into: first.id, reason: "a test")
        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        model.show(meetingID: first.id)
        await waitFor(expect, "the pane to read both halves") {
            (model.detail?.combinedLines.count ?? 0) > 1 && !(model.detail?.speakerRows.isEmpty ?? true)
        }
        guard let row = model.detail?.speakerRows.first(where: {
            $0.clusterID == "remote-001_speaker_00"
        }) else {
            expect.fail("the cluster is not in the speaker strip")
            return
        }

        model.assignCluster(row, toNewPerson: "Priya Raman")

        expect.equal(
            model.receipt?.text,
            "Named Priya Raman on 1 line. transcript.md and the speaker map are rewritten."
        )
    }

    /// A correction on a line beats the cluster's own entry, so naming the
    /// cluster around it leaves that line reading exactly as it did. Counting
    /// it made the receipt claim a line nothing had changed.
    @MainActor
    static func aReceiptLeavesOutLinesAPersonSet(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root.appendingPathComponent("Meetings"))
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .googleMeet, provider: .unknown, startedAt: started,
            titles: TitleCandidates(provider: "Design review", timestampFallback: "f"), now: started
        )
        _ = try created.store.updateMetadata {
            $0.durationSeconds = 600
            $0.processing = ProcessingStatus(state: .complete, updatedAt: started)
        }
        func line(_ id: String, _ start: Double, _ end: Double) -> Utterance {
            Utterance(
                id: id, start: start, end: end, track: .remote,
                rawSpeakerLabel: "remote-001_speaker_00", speakerKey: "remote-001_speaker_00",
                text: "the northwind renewal", chunkID: "c1", model: "m"
            )
        }
        let lines = [line("u0", 0, 8), line("u1", 10, 18), line("u2", 20, 28)]
        try created.store.writeCanonicalTranscript(
            CanonicalTranscript(generatedAt: started, utterances: lines)
        )
        // The middle line already belongs to somebody the user named on the
        // line itself, which the cluster's entry does not decide.
        var map = SpeakerMap()
        map.overrideUtterance(
            lines[1],
            with: SpeakerAssignment(displayName: "Tim Okafor", origin: .human),
            at: started
        )
        try created.store.writeSpeakerMap(map)

        let model = MeetingsWindowModel(runtime: makeRuntime(root: root))
        await model.reload()
        model.show(meetingID: created.metadata.id)
        await waitFor(expect, "the pane to read the meeting") {
            !(model.detail?.speakerRows.isEmpty ?? true)
        }
        guard let row = model.detail?.speakerRows.first else {
            expect.fail("the cluster is not in the speaker strip")
            return
        }

        model.assignCluster(row, toNewPerson: "Priya Raman")

        expect.equal(
            model.receipt?.text,
            "Named Priya Raman on 2 lines. transcript.md and the speaker map are rewritten."
        )
    }

    /// A correction made in the pane is drawn straight away and reaches disk a
    /// moment later, so a receipt taken in between counts what is on screen. The
    /// pane wrote the new name onto the line without recording that a person had
    /// set it, and the next receipt counted a line the cluster's entry no longer
    /// names.
    @MainActor
    static func aReceiptLeavesOutAFreshCorrection(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root.appendingPathComponent("Meetings"))
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .googleMeet, provider: .unknown, startedAt: started,
            titles: TitleCandidates(provider: "Design review", timestampFallback: "f"), now: started
        )
        _ = try created.store.updateMetadata {
            $0.durationSeconds = 600
            $0.processing = ProcessingStatus(state: .complete, updatedAt: started)
        }
        func line(_ id: String, _ key: String, _ start: Double, _ end: Double) -> Utterance {
            Utterance(
                id: id, start: start, end: end, track: .remote, rawSpeakerLabel: key,
                speakerKey: key, text: "the northwind renewal", chunkID: "c1", model: "m"
            )
        }
        // Another speaker between them, so the first line is a turn of its own
        // and can be corrected without taking the third line with it.
        try created.store.writeCanonicalTranscript(CanonicalTranscript(
            generatedAt: started,
            utterances: [
                line("u0", "remote-001_speaker_00", 0, 8),
                line("u1", "remote-001_speaker_01", 10, 18),
                line("u2", "remote-001_speaker_00", 20, 28),
            ]
        ))

        let model = MeetingsWindowModel(runtime: makeRuntime(root: root))
        await model.reload()
        model.show(meetingID: created.metadata.id)
        await waitFor(expect, "the pane to read the meeting") {
            !(model.detail?.speakerRows.isEmpty ?? true)
        }
        let blocks = CombinedLineBlock.blocks(from: model.detail?.combinedLines ?? [])
        guard let first = blocks.first,
              let row = model.detail?.speakerRows.first(where: {
                  $0.clusterID == "remote-001_speaker_00"
              })
        else {
            expect.fail("the meeting did not read back as three turns")
            return
        }
        expect.equal(first.lines.count, 1, "the first turn is the line being corrected")

        model.detail?.assignBlock(first, toNewPerson: "Tim Okafor")
        model.assignCluster(row, toNewPerson: "Priya Raman")

        expect.equal(
            model.receipt?.text,
            "Named Priya Raman on 1 line. transcript.md and the speaker map are rewritten."
        )
    }

    /// A call recorded in two halves keeps the second half's words in the
    /// second half's own folder, and the list draws one row for the
    /// conversation. An index built from the first half alone could not find
    /// anything said after the call dropped.
    @MainActor
    static func searchReachesBothHalvesOfACall(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeMeeting(root: root, clusters: ["local"], title: "Design review")
        let second = try makeMeeting(
            root: root, clusters: ["local"], title: "Design review, rejoined"
        )
        try first.store.writeTranscriptMarkdown("Andrew: the northwind renewal")
        try second.store.writeTranscriptMarkdown("Andrew: the audio sdk call")

        let runtime = makeRuntime(root: root)
        runtime.combine(meetingID: second.id, into: first.id, reason: "a test")

        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        await waitFor(expect, "the transcripts to be read") { model.searchesTranscripts }
        model.query = "audio sdk"

        expect.equal(
            model.sections.flatMap(\.rows).map(\.id), [first.id],
            "a word from after the drop finds the conversation"
        )
    }

    /// The clusters a row counts come from `transcript.json`, which is the one
    /// file in the folder a half-written or hand-edited copy can make
    /// undecodable. Losing the row would take the meeting out of the archive
    /// listing altogether.
    @MainActor
    static func aCorruptTranscriptKeepsItsRow(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try makeMeeting(root: root, clusters: ["remote-001_speaker_00"])
        var map = SpeakerMap()
        map.assign("Chris Vaughn", to: "remote-001_speaker_00", identityID: IdentityID(7))
        try meeting.store.writeSpeakerMap(map)
        try Data(#"{"utterances": [{"speakerK"#.utf8)
            .write(to: meeting.store.layout.canonicalTranscript)

        let rows = await makeRuntime(root: root).meetingRows()

        expect.equal(rows.count, 1, "the meeting is still listed")
        expect.equal(rows.first?.namedSpeakers.map(\.displayName), ["Chris Vaughn"])
        expect.equal(rows.first?.unnamedCount, 0, "and nothing is invented to ask about")
    }

    /// The runtime reports a stage boundary and every speaker change for
    /// whichever meeting it happened to, which is not always the one the pane is
    /// showing. Reading the row again only for the pane's own meeting left every
    /// other row in the list describing the meeting as it was when the window
    /// opened, including the state badge on a recording that had finished.
    @MainActor
    static func anotherMeetingsRowKeepsUp(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let earlier = try makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Standup",
            startedAt: Date(timeIntervalSince1970: 1_787_066_400)
        )
        _ = try makeMeeting(root: root, clusters: ["remote-001_speaker_00"], title: "Design review")

        let model = MeetingsWindowModel(runtime: makeRuntime(root: root))
        await model.reload()
        expect.equal(model.detail?.title, "Design review", "the newest meeting is the one open")

        var map = SpeakerMap()
        map.assign("Priya Raman", to: "remote-001_speaker_00")
        try earlier.store.writeSpeakerMap(map)
        await model.refresh(meetingID: earlier.id)

        expect.equal(
            model.rows.first { $0.id == earlier.id }?.namedSpeakers.map(\.displayName),
            ["Priya Raman"]
        )
    }

    /// Combining is done from the pane, and the archive listing hides a folded
    /// continuation. The row for the half that was folded in stayed in the list
    /// until the window was closed and opened again, so one conversation had two
    /// rows and one of them opened a meeting the listing no longer holds.
    @MainActor
    static func combiningTakesTheFoldedRowOutOfTheList(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeMeeting(
            root: root, clusters: ["local"], title: "Design review",
            startedAt: Date(timeIntervalSince1970: 1_787_066_400)
        )
        let second = try makeMeeting(
            root: root, clusters: ["local"], title: "Design review, rejoined"
        )
        _ = try second.store.updateMetadata {
            $0.possibleContinuationOf = first.id
            $0.possibleContinuationReason = "the call dropped and was rejoined"
        }

        let model = MeetingsWindowModel(runtime: makeRuntime(root: root))
        await model.reload()
        model.show(meetingID: second.id)
        model.combineWithEarlier()

        // In the same turn, not after the archive read. The combine is already
        // on disk when the call returns, and a selection left on the folded row
        // dangles on a row about to disappear for as long as the pane takes to
        // reload.
        expect.equal(model.selection, [first.id], "the conversation's own row is selected")
        await waitFor(expect, "the folded recording's row to leave the list") {
            model.rows.map(\.id) == [first.id]
        }
        expect.equal(model.selection, [first.id], "and the selection survives the read")
    }

    /// Separating is done from the pane too. The recording that comes back is a
    /// row of its own again, and the words it holds are its own. The index entry
    /// for the conversation held both halves, so a word only the second half
    /// said went on matching the first.
    @MainActor
    static func separatingRestoresTheRowAndTheIndex(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeMeeting(
            root: root, clusters: ["local"], title: "Design review",
            startedAt: Date(timeIntervalSince1970: 1_787_066_400)
        )
        let second = try makeMeeting(
            root: root, clusters: ["local"], title: "Design review, rejoined"
        )
        try first.store.writeTranscriptMarkdown("Andrew: the northwind renewal")
        try second.store.writeTranscriptMarkdown("Andrew: the audio sdk call")

        let runtime = makeRuntime(root: root)
        runtime.combine(meetingID: second.id, into: first.id, reason: "a test")

        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        await waitFor(expect, "the transcripts to be read") { model.searchesTranscripts }
        model.show(meetingID: first.id)
        model.separate(second.id)

        await waitFor(expect, "the separated recording to have a row again") {
            model.rows.count == 2
        }
        model.query = "audio sdk"
        await waitFor(expect, "search to answer for the recording holding those words") {
            model.sections.flatMap(\.rows).map(\.id) == [second.id]
        }
    }

    /// A diarizer can emit a label that owns almost none of the transcript: one
    /// cloud-diarized meeting listed eleven speakers, six of them at 0s. The
    /// speaker strip leaves those out, so a row that counted them put the
    /// meeting under Unnamed with nothing in it to name, which is the drawer
    /// nothing ever leaves.
    @MainActor
    static func aSilentClusterIsNotWorkToDo(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root.appendingPathComponent("Meetings"))
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .googleMeet, provider: .unknown, startedAt: started,
            titles: TitleCandidates(provider: "Design review", timestampFallback: "f"), now: started
        )
        _ = try created.store.updateMetadata {
            $0.durationSeconds = 600
            $0.processing = ProcessingStatus(state: .complete, updatedAt: started)
        }
        func line(_ id: String, _ key: String, _ start: Double, _ end: Double) -> Utterance {
            Utterance(
                id: id, start: start, end: end, track: .remote, rawSpeakerLabel: key,
                speakerKey: key, text: "the northwind renewal", chunkID: "c1", model: "m"
            )
        }
        try created.store.writeCanonicalTranscript(CanonicalTranscript(
            generatedAt: started,
            utterances: [
                line("u0", "remote-001_speaker_00", 0, 8),
                line("u1", "remote-001_speaker_01", 8, 8.2),
            ]
        ))
        var map = SpeakerMap()
        map.assign("Chris Vaughn", to: "remote-001_speaker_00", identityID: IdentityID(7))
        try created.store.writeSpeakerMap(map)

        let runtime = makeRuntime(root: root)
        let strip = await runtime.speakers(inMeeting: created.metadata.id)
            .filter(\.hasSpeechToShow)
        expect.equal(
            strip.map(\.clusterID), ["remote-001_speaker_00"],
            "the strip offers nothing to name"
        )

        let rows = await runtime.meetingRows()
        guard let row = rows.first else {
            expect.fail("the meeting is not in the archive")
            return
        }
        expect.equal(row.unnamedCount, 0, "so the list counts no work either")
        expect.equal(row.speakers.map(\.key), ["remote-001_speaker_00"])
        expect.isFalse(
            MeetingsFilter.unnamed.admits(row),
            "and the filter that lists the work does not hold it"
        )
    }

    @MainActor
    static func aLaterMeetingJoinsTheSearchIndex(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeMeeting(root: root, clusters: ["local"])
        try first.store.writeTranscriptMarkdown("Andrew: the northwind renewal")

        let model = MeetingsWindowModel(runtime: makeRuntime(root: root))
        await model.reload()
        await waitFor(expect, "the first transcript to be read") { model.searchesTranscripts }

        let second = try makeMeeting(root: root, clusters: ["local"], title: "Weekly sync")
        try second.store.writeTranscriptMarkdown("Andrew: the audio sdk call")
        await model.reload()
        model.query = "audio sdk"

        await waitFor(expect, "the new transcript to be read") {
            model.sections.flatMap(\.rows).map(\.id) == [second.id]
        }
    }

    /// The microphone track is named by the pipeline, from the name in Settings,
    /// which is "Me" on a fresh install. That is also the name a cluster with no
    /// entry at all falls back to, so deciding "unnamed" by comparing the two
    /// drew the user's own voice as a voice asking for a name.
    @MainActor
    static func theMicrophoneTrackIsNotUnnamed(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try makeMeeting(
            root: root, clusters: [SpeakerLabel.localUser, "remote-001_speaker_00"]
        )
        // What the assembling stage writes for a meeting recorded from this
        // Mac's microphone.
        var map = SpeakerMap()
        map.entries[SpeakerLabel.localUser] = SpeakerAssignment(
            displayName: "Me", origin: .deterministic
        )
        try meeting.store.writeSpeakerMap(map)

        let rows = await makeRuntime(root: root).speakers(inMeeting: meeting.id)
        guard let mine = rows.first(where: { $0.clusterID == SpeakerLabel.localUser }) else {
            expect.fail("the microphone track is not in the speaker strip")
            return
        }
        expect.equal(mine.displayName, "Me")
        expect.isFalse(mine.isUnnamed, "the map named it, whatever the fallback would have been")
        expect.isTrue(
            rows.first { $0.clusterID == "remote-001_speaker_00" }?.isUnnamed ?? false,
            "and a cluster the map says nothing about still is"
        )
    }

    /// The index answers under the conversation's identifier and holds every
    /// recording of it, while the pane opened on the half a notification named
    /// is keyed on that half. Dropping the words under the pane's own identifier
    /// removed nothing, so a batch read in flight put the pre-rename transcript
    /// back and search answered from it for the life of the window.
    @MainActor
    static func namingOnAFoldedHalfDropsTheConversationsWords(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Design review",
            startedAt: Date(timeIntervalSince1970: 1_787_066_400)
        )
        let second = try makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Design review, rejoined"
        )
        try first.store.writeTranscriptMarkdown("Speaker 1: the northwind renewal")
        try second.store.writeTranscriptMarkdown("Speaker 1: the audio sdk call")

        let runtime = makeRuntime(root: root)
        let model = MeetingsWindowModel(runtime: runtime)
        await model.reload()
        model.show(meetingID: second.id)
        runtime.combine(meetingID: second.id, into: first.id, reason: "a test")
        await model.reload()
        expect.equal(
            model.detail?.meetingID, second.id, "the pane is keyed on the half it opened on"
        )

        model.query = "audio sdk"
        await waitFor(expect, "both halves to reach the index") {
            model.sections.flatMap(\.rows).map(\.id) == [first.id]
        }
        model.query = ""
        expect.isTrue(model.indexHolds(first.id), "the conversation's words are in the index")

        await waitFor(expect, "the pane to read the folded half") {
            !(model.detail?.speakerRows.isEmpty ?? true)
        }
        guard let row = model.detail?.speakerRows.first(where: {
            $0.clusterID == "remote-001_speaker_00"
        }) else {
            expect.fail("the cluster is not in the speaker strip")
            return
        }
        model.assignCluster(row, toNewPerson: "Priya Raman")

        expect.isFalse(
            model.indexHolds(first.id),
            "the rename rewrites transcript.md, so the words the index holds are stale"
        )
    }

    /// The list draws one row for a conversation recorded in two halves, so
    /// reading the first half alone left a voice that only spoke after the drop
    /// in no row at all.
    @MainActor
    static func bothHalvesReachTheRow(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, conversation) = try makeRejoinedCall(root: root)

        let runtime = PipitRuntime(settingsDirectory: root)
        var settings = runtime.settings
        settings.storageRootPath = root.appendingPathComponent("Meetings").path
        runtime.update(settings: settings)

        let rows = await runtime.meetingRows()
        expect.equal(rows.count, 1, "one row for one conversation")
        guard let row = rows.first else { return }
        expect.equal(row.id, conversation)
        expect.equal(row.speakers.count, 2, "one voice from each half")
        expect.equal(row.namedSpeakers.map(\.displayName), ["Chris Vaughn"])
        expect.equal(row.unnamedCount, 1, "the far end after the rejoin")
        expect.equal(
            Set(row.speakers.map(\.key)).count, 2,
            "both halves number their speakers from zero, so the keys are qualified rather "
                + "than collided"
        )
    }

    /// A cluster identifier names a speaker inside one recording, and both
    /// halves of a rejoined call number theirs from zero. A name given to the
    /// voice heard after the drop therefore has to reach the second half's own
    /// speaker map and leave the first half's alone.
    @MainActor
    static func namingTheSecondHalfWritesItsOwnMap(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, conversation) = try makeRejoinedCall(root: root)

        let model = MeetingsWindowModel(runtime: makeRuntime(root: root))
        await model.reload()
        model.show(meetingID: conversation)
        await waitFor(expect, "the pane to read both halves") {
            (model.detail?.speakerRows.count ?? 0) == 2
        }
        guard let after = model.detail?.speakerRows.first(where: {
            $0.recordingID != conversation
        }) else {
            expect.fail("the voice heard after the rejoin has no chip")
            return
        }
        expect.isTrue(after.isUnnamed, "and it is the one asking for a name")

        model.assignCluster(after, toNewPerson: "Priya Raman")

        guard let logical = repository.logicalMeeting(id: conversation),
              let continuation = logical.continuations.first
        else {
            expect.fail("the conversation lost its second half")
            return
        }
        await waitFor(expect, "the name to reach the second half") {
            (try? continuation.store.readSpeakerMap())?
                .displayName(for: "remote-001_speaker_00") == "Priya Raman"
        }
        expect.equal(
            (try? logical.primary.store.readSpeakerMap())?
                .displayName(for: "remote-001_speaker_00"),
            "Chris Vaughn",
            "and the voice heard before the drop keeps the name it already had"
        )
    }

    /// The list counts the work and the strip is where the work is done, so a
    /// meeting the Unnamed filter lists has to offer a chip for every voice it
    /// counted. Reading one recording's speakers made the filter a drawer
    /// nothing ever left: the row said one voice needed a name and the pane it
    /// opened showed one chip that was already named.
    @MainActor
    static func theStripCoversWhatTheListCounts(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, conversation) = try makeRejoinedCall(root: root)

        let runtime = PipitRuntime(settingsDirectory: root)
        var settings = runtime.settings
        settings.storageRootPath = root.appendingPathComponent("Meetings").path
        runtime.update(settings: settings)

        guard let row = await runtime.meetingRows().first else {
            expect.fail("the conversation has no row")
            return
        }
        let strip = await runtime.speakers(inMeeting: conversation).filter(\.hasSpeechToShow)
        expect.equal(
            strip.count, row.speakers.count,
            "the strip draws every voice the row counted"
        )
        expect.equal(
            strip.filter(\.isUnnamed).count, row.unnamedCount,
            "and the work the list reports is work the strip can do"
        )
        expect.equal(Set(strip.map(\.id)).count, strip.count, "each chip is its own row")
        expect.equal(
            Set(strip.map(\.recordingID)).count, 2,
            "one from each recording of the call"
        )
        // Both halves call their first speaker the same thing, so an unnamed
        // chip says which half it came from.
        expect.isTrue(
            strip.contains { $0.isUnnamed && $0.displayName.hasSuffix("part 2") },
            "got \(strip.map(\.displayName))"
        )
    }

    // MARK: - archiving and trashing

    /// Both halves of a rejoined call are one row, so trashing that row has to
    /// take both folders. Leaving the second half behind would put a recording
    /// in the archive that no row can reach.
    @MainActor
    static func trashingMovesEveryFolder(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repository, meetingID) = try makeRejoinedCall(root: root)
        let folders = (repository.logicalMeeting(id: meetingID)?.recordings ?? [])
            .map(\.store.layout.root)
        expect.equal(folders.count, 2, "a call recorded in two halves")

        let model = MeetingsWindowModel(runtime: makeRuntime(root: root))
        await model.reload()
        expect.equal(model.rows.map(\.id), [meetingID])
        guard let target = model.rows.first else { return expect.fail("no row to move") }

        model.confirmTrash([target])
        guard let pending = model.pendingTrash else {
            return expect.fail("the move asks first")
        }
        expect.isTrue(pending.title.contains("Weekly sync"), "got \(pending.title)")
        expect.isTrue(
            pending.message.contains("moved to the Trash rather than deleted"),
            "the warning says where the files go. got \(pending.message)"
        )
        expect.equal(pending.folderCount, 2)
        expect.isTrue(
            pending.message.contains("2 folders"),
            "and it counts both halves of the call. got \(pending.message)"
        )
        await model.performTrash(pending)

        let trash = trashDirectory(under: root)
        for folder in folders {
            expect.isFalse(
                FileManager.default.fileExists(atPath: folder.path),
                "\(folder.lastPathComponent) has left the archive"
            )
            expect.isTrue(
                FileManager.default.fileExists(
                    atPath: trash.appendingPathComponent(folder.lastPathComponent).path
                ),
                "and is in the Trash, whole, rather than unlinked"
            )
        }
        let moved = MeetingLayout(root: trash.appendingPathComponent(folders[0].lastPathComponent))
        expect.isTrue(
            FileManager.default.fileExists(atPath: moved.metadata.path),
            "with the files it held still in it"
        )
        expect.equal(model.rows.count, 0, "and the list has nothing left")
        expect.isTrue(model.selection.isEmpty)
        expect.isNil(model.detail, "the pane is not left reading files that are gone")
        expect.isFalse(model.indexHolds(meetingID), "search does not answer for it either")
    }

    /// Archiving is about the list. Every file stays exactly where it was, and
    /// the Archived filter is where the meeting is put back from.
    @MainActor
    static func archivingKeepsTheFiles(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try makeMeeting(root: root, clusters: ["remote-001_speaker_00"])
        let folder = meeting.store.layout.root

        let model = MeetingsWindowModel(runtime: makeRuntime(root: root))
        await model.reload()
        guard let target = model.rows.first else { return expect.fail("nothing recorded") }

        model.setArchived(true, [target])
        await waitFor(expect, "the archived row to leave the list") {
            model.sections.flatMap(\.rows).isEmpty
        }
        expect.isTrue(
            FileManager.default.fileExists(atPath: folder.path), "the folder is untouched"
        )
        expect.isTrue(
            FileManager.default.fileExists(atPath: meeting.store.layout.canonicalTranscript.path),
            "and so is the transcript"
        )
        expect.isTrue(model.selection.isEmpty, "and nothing is selected under All")

        model.filter = .archived
        expect.equal(
            model.sections.flatMap(\.rows).map(\.id), [meeting.id],
            "the archived list is where it went"
        )

        guard let archived = model.rows.first else { return expect.fail("the row is gone") }
        expect.isTrue(archived.isArchived)
        model.setArchived(false, [archived])
        await waitFor(expect, "the meeting to come back") {
            model.rows.first?.isArchived == false
        }
        model.filter = .all
        expect.equal(model.sections.flatMap(\.rows).map(\.id), [meeting.id])
    }

    /// A right-click on a row that is not selected acts on that row. Acting on
    /// the selection instead would delete meetings the pointer was never over.
    @MainActor
    static func aRightClickActsOnTheRowUnderIt(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let first = try makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Design review",
            startedAt: started
        )
        let second = try makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Standup",
            startedAt: started.addingTimeInterval(3_600)
        )

        let model = MeetingsWindowModel(runtime: makeRuntime(root: root))
        await model.reload()
        model.select(first.id, extending: false)
        guard let other = model.rows.first(where: { $0.id == second.id }) else {
            return expect.fail("the second meeting is not in the list")
        }
        expect.equal(model.contextTargets(for: other).map(\.id), [second.id])

        model.select(second.id, extending: true)
        expect.equal(
            Set(model.contextTargets(for: other).map(\.id)), [first.id, second.id],
            "and a row inside the selection acts on all of it"
        )
    }

    /// The wiring from the window's move through to the voice memory. Without
    /// it a trashed meeting kept counting towards "heard in 3 meetings".
    @MainActor
    static func trashingDropsTheOccurrences(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try makeMeeting(root: root, clusters: ["remote-001_speaker_00"])
        let runtime = makeRuntime(root: root)
        let store = try expect.unwrap(runtime.speakerStore)
        let chris = try await store.createPerson(name: "Chris")
        try await store.recordOccurrence(
            meetingID: meeting.id, clusterID: "remote-001_speaker_00", track: .remote,
            speechSeconds: 120, embedding: nil, model: nil, resolution: nil,
            identityID: chris.id, source: .human,
            humanVerified: true, wasExpectedParticipant: false
        )
        expect.equal(try await store.meetingCount(for: chris.id), 1)

        expect.equal(
            await runtime.trashMeetings([meeting.id])[meeting.id], .trashed, "the folder went"
        )

        expect.equal(try await store.meetingCount(for: chris.id), 0)
    }

    /// The archived flag lives in `metadata.json`, which the pipeline rewrites
    /// at every stage boundary. `updateMetadata` reads, changes and writes the
    /// whole document, so a field it does not know about has to survive that.
    @MainActor
    static func archivingSurvivesAMetadataWrite(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try makeMeeting(root: root, clusters: ["remote-001_speaker_00"])
        let runtime = makeRuntime(root: root)

        runtime.setArchived(true, meetingIDs: [meeting.id])
        _ = try meeting.store.updateMetadata { $0.durationSeconds = 900 }

        expect.isTrue(try meeting.store.readMetadata().isArchived)
        let summary = runtime.repository.summary(forDirectory: meeting.store.layout.root)
        expect.isTrue(summary?.isArchived == true, "and the list reads it back")

        runtime.setArchived(false, meetingIDs: [meeting.id])
        expect.isFalse(try meeting.store.readMetadata().isArchived)
    }

    /// Archiving leaves every file where it is, so a title half-typed when the
    /// row was archived still belongs to a meeting.
    @MainActor
    static func archivingSavesTheEdit(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try makeMeeting(root: root, clusters: ["remote-001_speaker_00"])

        let model = MeetingsWindowModel(runtime: makeRuntime(root: root))
        await model.reload()
        await waitFor(expect, "the pane to open") { model.detail?.title.isEmpty == false }
        model.detail?.title = "Renamed while archiving"
        guard let target = model.rows.first else { return expect.fail("nothing recorded") }

        model.setArchived(true, [target])

        expect.equal(
            try meeting.store.readMetadata().displayTitle, "Renamed while archiving",
            "the title reached disk before the pane was dropped"
        )
    }

    /// The footer counts against what the filter holds. Against the archive it
    /// read "1 of 2" under All with nothing typed in the search field.
    @MainActor
    static func theFooterCountsWhatTheFilterHolds(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        _ = try makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Design review",
            startedAt: started
        )
        _ = try makeMeeting(
            root: root, clusters: ["remote-001_speaker_00"], title: "Standup",
            startedAt: started.addingTimeInterval(3_600)
        )

        let model = MeetingsWindowModel(runtime: makeRuntime(root: root))
        await model.reload()
        expect.equal(model.filteredRows.count, 2)
        let both = model.totalDuration

        guard let target = model.rows.first else { return expect.fail("nothing recorded") }
        model.setArchived(true, [target])
        await waitFor(expect, "the archived row to leave the list") {
            model.filteredRows.count == 1
        }
        expect.equal(
            model.sections.flatMap(\.rows).count, model.filteredRows.count,
            "so the footer says one meeting rather than one of two"
        )
        expect.isTrue(
            model.totalDuration < both, "and the total is the time the list adds up to"
        )

        model.filter = .archived
        expect.equal(model.filteredRows.count, 1)
    }

    /// A move that cannot finish stops before the recording the conversation
    /// started with, so the row that reaches what is left stays in the list.
    /// Nothing about the meeting is forgotten either, because the meeting is
    /// still there.
    @MainActor
    static func aFolderThatWillNotMoveKeepsItsRow(_ expect: Expect) async throws {
        let root = try ManifestTests.makeTemporaryDirectory()
        let (repository, meetingID) = try makeRejoinedCall(root: root)
        guard let logical = repository.logicalMeeting(id: meetingID),
              let continuation = logical.continuations.first
        else { return expect.fail("the call was not recorded in two halves") }
        let locked = continuation.store.layout.root
        // Locked the way the Finder locks a file, which is the ordinary reason
        // a folder will not move.
        let unlock = { try? FileManager.default.setAttributes(
            [.immutable: false], ofItemAtPath: locked.path
        ) }
        defer { try? FileManager.default.removeItem(at: root) }
        defer { unlock() }
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)

        let runtime = makeRuntime(root: root)
        let store = try expect.unwrap(runtime.speakerStore)
        let chris = try await store.createPerson(name: "Chris")
        try await store.recordOccurrence(
            meetingID: meetingID, clusterID: "remote-001_speaker_00", track: .remote,
            speechSeconds: 120, embedding: nil, model: nil, resolution: nil,
            identityID: chris.id, source: .human,
            humanVerified: true, wasExpectedParticipant: false
        )

        let outcome = await runtime.trashMeetings([meetingID])[meetingID]

        expect.equal(outcome, .folderNotMoved)
        expect.isTrue(
            FileManager.default.fileExists(atPath: logical.primary.store.layout.root.path),
            "the recording the conversation started with is still there, so the row still is"
        )
        expect.equal(
            try await store.meetingCount(for: chris.id), 1,
            "and a meeting still in the archive still counts for the people who spoke in it"
        )
    }
}
