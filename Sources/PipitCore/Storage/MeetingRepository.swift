import Foundation
import Synchronization

/// Reads and writes one meeting's archive files.
///
/// The filesystem is the source of truth. Nothing here needs a database, and any
/// index the UI keeps can be thrown away and rebuilt by walking these directories.
public struct MeetingStore: Sendable {
    public let layout: MeetingLayout

    public init(layout: MeetingLayout) { self.layout = layout }

    public func createDirectories() throws {
        for directory in [layout.root, layout.raw, layout.segments] {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw StorageError.directoryCreationFailed(path: directory.path, underlying: "\(error)")
            }
        }
    }

    // MARK: metadata

    public func readMetadata() throws -> MeetingMetadata {
        // The legacy fallback keeps a folder restored from an old backup
        // readable; the startup migration normalises it on the next launch.
        let url = FileManager.default.fileExists(atPath: layout.metadata.path)
            ? layout.metadata
            : layout.legacyMetadata
        let data = try read(url)
        return try ArchiveCoding.decode(MeetingMetadata.self, from: data, path: url.path)
    }

    public func writeMetadata(_ metadata: MeetingMetadata) throws {
        try AtomicFile.write(try ArchiveCoding.encode(metadata), to: layout.metadata)
    }

    /// Read, mutate, write, serialised per meeting file.
    ///
    /// The processing pipeline writes its stage while the user renames the
    /// meeting or edits its participants. Both sides read, change their own
    /// fields and write the whole document, so without a lock around the trio the
    /// slower writer restores a stale copy and the other edit disappears. Every
    /// mutation of `metadata.json` goes through here.
    @discardableResult
    public func updateMetadata(_ body: (inout MeetingMetadata) -> Void) throws -> MeetingMetadata {
        try MetadataSerialisation.withLock(for: layout.metadata) {
            var metadata = try readMetadata()
            body(&metadata)
            try writeMetadata(metadata)
            return metadata
        }
    }

    // MARK: notes

    /// Human notes. Never written by AI enrichment, which uses `summary.md`.
    public func readNotes() -> String {
        (try? String(contentsOf: layout.notes, encoding: .utf8)) ?? ""
    }

    public func writeNotes(_ text: String) throws {
        try AtomicFile.writeText(text, to: layout.notes)
    }

    public func appendNote(_ text: String, at date: Date) throws {
        var existing = readNotes()
        let stamp = ManifestCoding.string(from: date)
        if !existing.isEmpty, !existing.hasSuffix("\n") { existing += "\n" }
        existing += "- [\(stamp)] \(text)\n"
        try writeNotes(existing)
    }

    public func readSummary() -> String? {
        try? String(contentsOf: layout.summary, encoding: .utf8)
    }

    /// `summary.md` split into the summary and the generated notes, which the
    /// app shows on different tabs.
    public func readSummaryDocument() -> SummaryDocument {
        guard let text = readSummary() else { return SummaryDocument() }
        return SummaryDocument(markdown: text)
    }

    public func writeSummary(_ text: String) throws {
        try AtomicFile.writeText(text, to: layout.summary)
    }

    // MARK: transcripts

    public func readRawTranscript() throws -> RawTranscript {
        guard FileManager.default.fileExists(atPath: layout.rawTranscript.path) else {
            return RawTranscript()
        }
        let data = try read(layout.rawTranscript)
        return try ArchiveCoding.decode(RawTranscript.self, from: data, path: layout.rawTranscript.path)
    }

    public func writeRawTranscript(_ transcript: RawTranscript) throws {
        try AtomicFile.write(try ArchiveCoding.encode(transcript), to: layout.rawTranscript)
    }

    public func readRawDiarization() throws -> RawDiarization {
        guard FileManager.default.fileExists(atPath: layout.rawDiarization.path) else {
            return RawDiarization()
        }
        let data = try read(layout.rawDiarization)
        return try ArchiveCoding.decode(RawDiarization.self, from: data, path: layout.rawDiarization.path)
    }

    public func writeRawDiarization(_ diarization: RawDiarization) throws {
        try AtomicFile.write(try ArchiveCoding.encode(diarization), to: layout.rawDiarization)
    }

    /// Nil where no sensor watched this meeting, which is every recording made
    /// before this existed and every one where the client was never readable.
    /// Naming then falls back to the voice alone, which is what those meetings
    /// already do.
    public func readRawSensors() -> RawSensors? {
        guard FileManager.default.fileExists(atPath: layout.rawSensors.path),
              let data = try? read(layout.rawSensors)
        else { return nil }
        return try? ArchiveCoding.decode(
            RawSensors.self, from: data, path: layout.rawSensors.path
        )
    }

    public func writeRawSensors(_ sensors: RawSensors) throws {
        try AtomicFile.write(try ArchiveCoding.encode(sensors), to: layout.rawSensors)
    }

    /// Nil where nothing measured this meeting, which is every meeting
    /// processed before the evidence existed. The assembler then keeps every
    /// segment, which is what those meetings already show.
    public func readSpeechEvidence() -> SpeechEvidence? {
        guard FileManager.default.fileExists(atPath: layout.speechEvidence.path),
              let data = try? read(layout.speechEvidence)
        else { return nil }
        return try? ArchiveCoding.decode(
            SpeechEvidence.self, from: data, path: layout.speechEvidence.path
        )
    }

    public func writeSpeechEvidence(_ evidence: SpeechEvidence) throws {
        try AtomicFile.write(try ArchiveCoding.encode(evidence), to: layout.speechEvidence)
    }

    public func readSpeakerMap() throws -> SpeakerMap {
        guard FileManager.default.fileExists(atPath: layout.speakerMap.path) else { return SpeakerMap() }
        let data = try read(layout.speakerMap)
        return try ArchiveCoding.decode(SpeakerMap.self, from: data, path: layout.speakerMap.path)
    }

    public func writeSpeakerMap(_ map: SpeakerMap) throws {
        try AtomicFile.write(try ArchiveCoding.encode(map), to: layout.speakerMap)
    }

    /// An empty set where nothing has been suggested, which is every meeting
    /// recorded before this existed and every one processed with no API key.
    /// The speaker strip then draws no suggestion row, which is what those
    /// meetings already show.
    public func readSpeakerSuggestions() -> SpeakerSuggestionSet {
        guard FileManager.default.fileExists(atPath: layout.speakerSuggestions.path),
              let data = try? read(layout.speakerSuggestions),
              let set = try? ArchiveCoding.decode(
                  SpeakerSuggestionSet.self, from: data, path: layout.speakerSuggestions.path
              )
        else { return SpeakerSuggestionSet() }
        return set
    }

    public func writeSpeakerSuggestions(_ set: SpeakerSuggestionSet) throws {
        try AtomicFile.write(try ArchiveCoding.encode(set), to: layout.speakerSuggestions)
    }

    /// The transcript as it reads, which is the assembled transcript divided
    /// wherever a person put a boundary.
    ///
    /// Divided here rather than at each caller, because a reader that skipped it
    /// would see the undivided line and a correction made on one piece of it.
    /// That line then looks human-assigned along its whole length, and the
    /// enrolment check would embed the other speaker's half of it into the
    /// corrected person's voice profile. `writeCanonicalTranscript` still stores
    /// what the assembler produced: the cuts live in `speakers.map.json` and are
    /// applied on the way out.
    /// The folder this meeting was offered, if it was offered one.
    public func readFolderSuggestion() -> FolderSuggestion? {
        guard let data = try? Data(contentsOf: layout.folderSuggestion) else { return nil }
        return try? ArchiveCoding.decode(
            FolderSuggestion.self, from: data, path: layout.folderSuggestion.path
        )
    }

    public func writeFolderSuggestion(_ suggestion: FolderSuggestion) throws {
        try AtomicFile.write(try ArchiveCoding.encode(suggestion), to: layout.folderSuggestion)
    }

    public func readCanonicalTranscript() throws -> CanonicalTranscript? {
        guard var transcript = try readAssembledTranscript() else { return nil }
        let cuts = ((try? readSpeakerMap()) ?? SpeakerMap()).lineCuts
        guard !cuts.isEmpty else { return transcript }
        transcript.utterances = LineDivision.apply(cuts, to: transcript.utterances)
        return transcript
    }

    /// What the assembler wrote, before any boundary a person put in it.
    private func readAssembledTranscript() throws -> CanonicalTranscript? {
        guard FileManager.default.fileExists(atPath: layout.canonicalTranscript.path) else { return nil }
        let data = try read(layout.canonicalTranscript)
        return try ArchiveCoding.decode(CanonicalTranscript.self, from: data, path: layout.canonicalTranscript.path)
    }

    public func writeCanonicalTranscript(_ transcript: CanonicalTranscript) throws {
        try AtomicFile.write(try ArchiveCoding.encode(transcript), to: layout.canonicalTranscript)
    }

    /// Which speakers the transcript holds and how long each of them speaks, in
    /// the order they first speak.
    ///
    /// Decoded without the words behind each line, because a word carries two
    /// timings and an hour of speech is about a megabyte of them. The meetings
    /// list reads one of these per meeting on disk, and the boundaries a person
    /// put in the transcript divide lines rather than move them between
    /// speakers, so this reads what the assembler wrote.
    public func readTranscriptSpeakers() throws -> [TranscriptSpeaker] {
        guard FileManager.default.fileExists(atPath: layout.canonicalTranscript.path) else {
            return []
        }
        let data = try read(layout.canonicalTranscript)
        let document = try ArchiveCoding.decode(
            TranscriptSpeakers.self, from: data, path: layout.canonicalTranscript.path
        )
        var totals: [String: Double] = [:]
        var ordered: [String] = []
        for line in document.utterances {
            if totals[line.speakerKey] == nil { ordered.append(line.speakerKey) }
            totals[line.speakerKey, default: 0] += max(0, line.end - line.start)
        }
        return ordered.map { TranscriptSpeaker(key: $0, speechSeconds: totals[$0] ?? 0) }
    }

    /// The speaker and the span of each line of `transcript.json`, and nothing
    /// else.
    private struct TranscriptSpeakers: Decodable {
        struct Line: Decodable {
            var speakerKey: String
            var start: Double
            var end: Double
        }

        var utterances: [Line]
    }

    public func writeTranscriptMarkdown(_ text: String) throws {
        try AtomicFile.writeText(text, to: layout.transcriptMarkdown)
    }

    public func writeAPIResponse(_ data: Data, named name: String) throws {
        try AtomicFile.write(data, to: layout.apiResponseFile(named: name))
    }

    // MARK: alignments

    public func hasAlignment(chunkID: String) -> Bool {
        FileManager.default.fileExists(atPath: layout.alignmentFile(chunkID: chunkID).path)
    }

    public func readAlignment(chunkID: String) -> ChunkAlignment? {
        guard let data = try? read(layout.alignmentFile(chunkID: chunkID)) else { return nil }
        return try? ArchiveCoding.decode(
            ChunkAlignment.self, from: data, path: layout.alignmentFile(chunkID: chunkID).path
        )
    }

    public func writeAlignment(_ alignment: ChunkAlignment, chunkID: String) throws {
        try FileManager.default.createDirectory(
            at: layout.alignments, withIntermediateDirectories: true
        )
        try AtomicFile.write(
            try ArchiveCoding.encode(alignment), to: layout.alignmentFile(chunkID: chunkID)
        )
    }

    /// The raw transcript with every text-only chunk's segments filled in.
    ///
    /// An aligned chunk gets its aligned segments; one that was never aligned
    /// gets a single segment spanning the chunk, so the words still reach the
    /// timeline at chunk precision instead of vanishing. The raw file itself
    /// is never rewritten.
    public func readRawTranscriptForAssembly() throws -> RawTranscript {
        var raw = try readRawTranscript()
        for index in raw.chunks.indices {
            let chunk = raw.chunks[index]
            guard let text = chunk.text, chunk.segments.isEmpty else { continue }
            if let alignment = readAlignment(chunkID: chunk.id), !alignment.segments.isEmpty {
                raw.chunks[index].segments = alignment.segments
            } else {
                raw.chunks[index].segments = [RawTranscriptSegment(
                    start: 0, end: chunk.durationSeconds, text: text, speaker: nil
                )]
            }
        }
        return raw
    }

    // MARK: timeline

    public func readTimeline() throws -> RecordingTimeline {
        // The legacy fallback matches readMetadata: an unmigrated folder must
        // report its real duration and audio, not read as an empty meeting.
        let fileManager = FileManager.default
        let url: URL
        if fileManager.fileExists(atPath: layout.manifest.path) {
            url = layout.manifest
        } else if fileManager.fileExists(atPath: layout.legacyManifest.path) {
            url = layout.legacyManifest
        } else {
            return ManifestReader.timeline(
                from: ManifestReadResult(lines: [], hasTruncatedTail: false, unrecognisedLines: 0)
            )
        }
        return try ManifestReader.timeline(contentsOf: url)
    }

    // MARK: audio

    /// Where one track's audio reads from.
    ///
    /// Decided by the metadata, never by listing the disk: after compaction the
    /// archive file stands in for the segment chain, and a meeting that has not
    /// been compacted reads its segments even if stray files exist elsewhere.
    public func trackAudioLocation(
        track: CaptureTrack, metadata: MeetingMetadata, timeline: RecordingTimeline
    ) -> TrackAudioLocation {
        if let archive = metadata.audioArchive {
            guard let record = archive.track(track) else {
                // A compacted meeting whose archive has no record for this
                // track recorded nothing worth archiving on it. The segment
                // chain must not be offered instead: its directory may already
                // be gone, and the metadata, not the disk, decides.
                return TrackAudioLocation(segments: [], directory: layout.trackArchiveDirectory)
            }
            return .archived(
                track: track, record: record,
                directory: layout.trackArchiveDirectory,
                compactedAt: archive.compactedAt
            )
        }
        // Archive-versus-segments is decided above, by the metadata alone. The
        // directory check below only answers where the segment chain lives for
        // a folder whose layout migration has not run.
        let directory = FileManager.default.fileExists(atPath: layout.segments.path)
            ? layout.segments
            : layout.legacySegments
        return TrackAudioLocation(segments: timeline.segments(track: track), directory: directory)
    }

    private func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw StorageError.fileReadFailed(path: url.path, underlying: "\(error)")
        }
    }
}

/// A meeting as the UI needs to list it. Built from files; cheap enough to rebuild.
public struct MeetingSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let directory: URL
    public let title: String
    public let startedAt: Date
    public let durationSeconds: Double
    public let source: MeetingSource
    public let provider: MeetingProvider
    public let processingState: ProcessingState
    public let wasInterrupted: Bool
    public let hasTranscript: Bool
    /// How many recordings the conversation is held in. More than one when a
    /// call dropped and was rejoined.
    public let recordingCount: Int
    /// Whether the user took this meeting out of the list. The files are all
    /// still on disk.
    public let isArchived: Bool
    /// The folder this meeting is filed in, read from where it sits on disk.
    /// Nil for one still under `YYYY/MM`.
    public let folderName: String?

    public init(
        id: String, directory: URL, title: String, startedAt: Date, durationSeconds: Double,
        source: MeetingSource, provider: MeetingProvider, processingState: ProcessingState,
        wasInterrupted: Bool, hasTranscript: Bool, recordingCount: Int = 1,
        isArchived: Bool = false, folderName: String? = nil
    ) {
        self.id = id
        self.directory = directory
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.source = source
        self.provider = provider
        self.processingState = processingState
        self.wasInterrupted = wasInterrupted
        self.hasTranscript = hasTranscript
        self.recordingCount = recordingCount
        self.isArchived = isArchived
        self.folderName = folderName
    }
}

/// One lock per `metadata.json`, shared by every writer in the process.
///
/// The file is small and rewritten whole, so serialising the read-modify-write is
/// cheap, and it is the only thing that stops a concurrent rename from being
/// overwritten by a pipeline stage that read the file first.
enum MetadataSerialisation {
    private static let locks = Mutex<[String: NSLock]>([:])

    static func withLock<T>(for url: URL, _ body: () throws -> T) rethrows -> T {
        let path = url.standardizedFileURL.path
        let fileLock = locks.withLock { locks -> NSLock in
            if let existing = locks[path] { return existing }
            let created = NSLock()
            locks[path] = created
            return created
        }
        fileLock.lock()
        defer { fileLock.unlock() }
        return try body()
    }
}

/// Creates, finds and lists meetings under the archive root.
///
/// The root is resolved on each use rather than captured, so choosing a new
/// folder in Settings takes effect immediately instead of at the next launch.
public struct MeetingRepository: Sendable {
    private let rootProvider: @Sendable () -> URL

    public var archive: MeetingArchiveLayout { MeetingArchiveLayout(root: rootProvider()) }

    public init(archive: MeetingArchiveLayout) {
        let root = archive.root
        self.rootProvider = { root }
    }

    public init(root: URL) {
        self.rootProvider = { root }
    }

    public init(rootProvider: @escaping @Sendable () -> URL) {
        self.rootProvider = rootProvider
    }

    /// Creates the directory and writes the first metadata.json.
    ///
    /// `titles` carries whatever is known at start: a provider or window title for
    /// an automatic recording, nothing at all for a manual one. The folder is
    /// named from the best candidate, so it is readable in Finder while the
    /// meeting is still recording rather than anonymous until processing ends.
    public func createMeeting(
        source: MeetingSource,
        provider: MeetingProvider,
        startedAt: Date,
        titles: TitleCandidates? = nil,
        now: Date
    ) throws -> (metadata: MeetingMetadata, store: MeetingStore) {
        let fallback = Self.timestampTitle(startedAt: startedAt, source: source)
        var candidates = titles ?? TitleCandidates(timestampFallback: fallback)
        if candidates.timestampFallback.isEmpty { candidates.timestampFallback = fallback }
        let slugHint = candidates.resolvedOrigin == "timestamp" ? nil : candidates.resolved
        let base = MeetingArchiveLayout.meetingID(startedAt: startedAt, source: source, title: slugHint)
        let id = uniqueMeetingID(base: base, startedAt: startedAt)
        var metadata = MeetingMetadata(
            id: id,
            source: source,
            provider: provider,
            createdAt: now,
            startedAt: startedAt,
            titles: candidates
        )
        metadata.processing = ProcessingStatus(state: .recording, updatedAt: now)
        let name = archive.uniqueDirectoryName(
            base: MeetingFolderName.base(for: metadata), startedAt: startedAt
        )
        metadata.directoryName = name
        let directory = archive.directory(named: name, startedAt: startedAt)
        let store = MeetingStore(layout: MeetingLayout(root: directory))
        try store.createDirectories()
        try store.writeMetadata(metadata)
        stampCreationDate(of: directory, as: startedAt)
        Self.remember(id: id, directory: directory, archiveRoot: archive.root)
        return (metadata, store)
    }

    /// Makes Finder's Date Created column the date of the recording.
    ///
    /// It already is for a captured meeting, whose folder is made as recording
    /// starts. An import is the case this exists for: the folder is made today
    /// and the audio is from last month, and the date column is now how the
    /// archive is sorted chronologically, so it has to be the recording's.
    private func stampCreationDate(of directory: URL, as date: Date) {
        try? FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: directory.path)
    }

    /// An identifier no meeting in the archive already holds.
    ///
    /// It used to be enough to check whether a directory of that name existed,
    /// because the directory was named for the identifier. It no longer is, so
    /// this asks the resolver. Runs once per meeting created.
    private func uniqueMeetingID(base: String, startedAt: Date) -> String {
        // The month the identifier names, not the resolver. A new meeting's
        // identifier is free almost always, and asking the resolver made every
        // recording start by decoding every metadata.json in the archive: the
        // identifier is absent, so every cheap step misses and the scan runs to
        // the end. A meeting starting now is in this month by construction.
        let month = archive.monthDirectory(startedAt: startedAt)
        let taken = identifiers(in: month)
        var candidate = base
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func identifiers(in month: URL) -> Set<String> {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: month, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: Set<String> = []
        for entry in entries where entry.hasDirectoryPath {
            guard let metadata = try? MeetingStore(layout: MeetingLayout(root: entry))
                .readMetadata()
            else { continue }
            Self.remember(id: metadata.id, directory: entry, archiveRoot: archive.root)
            out.insert(metadata.id)
        }
        return out
    }

    // MARK: folder names

    /// Renames a meeting's folder to match what the meeting is now called.
    ///
    /// Idempotent, and safe to call on a meeting that needs nothing done: the
    /// common case is one string comparison. Call it only after every write into
    /// the folder has finished, because the pipeline holds absolute paths.
    ///
    /// Returns the directory the meeting occupies afterwards, renamed or not.
    @discardableResult
    public func settleFolderName(for metadata: MeetingMetadata) -> URL? {
        guard let found = findMeeting(id: metadata.id, includingMerged: true) else { return nil }
        let current = found.store.layout.root
        // A recording folded into another one is left where it is. It is
        // folded in after its own pipeline run, so renaming it here strands
        // whatever path the caller that folded it is still holding, and its
        // folder is already distinguishable by the time in its name.
        guard found.metadata.mergedIntoMeetingID == nil else { return current }
        // Absent for a meeting recorded before folder names and identifiers
        // parted, and for one whose folder a person renamed in Finder. Either
        // way the name on disk is not Pipit's to change.
        guard let recorded = found.metadata.directoryName,
              recorded == current.lastPathComponent
        else { return current }

        // Where it sits, not what the metadata remembers: a folder renamed in
        // Finder moves every meeting in it, and renaming one of those must not
        // drag it back to a folder that no longer exists.
        let folder = archive.folderName(ofDirectory: current)
        let desired = archive.uniqueDirectoryName(
            base: MeetingFolderName.base(for: found.metadata),
            startedAt: found.metadata.startedAt,
            excluding: current,
            folder: folder
        )
        guard desired != current.lastPathComponent else {
            repairFolderName(of: found.metadata, at: current, folder: folder)
            return current
        }

        let target = archive.directory(
            named: desired, startedAt: found.metadata.startedAt, folder: folder
        )
        do {
            try FileManager.default.moveItem(at: current, to: target)
        } catch {
            // The meeting is reachable by identifier either way, so a folder
            // that cannot be renamed is reported and left where it is.
            Log.storage.error(
                "folder rename failed: \(logSafeDescription(error), privacy: .public)"
            )
            return current
        }
        Self.remember(id: found.metadata.id, directory: target, archiveRoot: archive.root)
        do {
            _ = try MeetingStore(layout: MeetingLayout(root: target)).updateMetadata {
                $0.directoryName = desired
                $0.folderName = folder
            }
        } catch {
            // The name on disk and the name in the metadata have to agree, or
            // the next settle reads the difference as a rename made in Finder
            // and never touches the folder again. Put it back.
            Log.storage.error(
                "folder name not recorded: \(logSafeDescription(error), privacy: .public)"
            )
            do {
                try FileManager.default.moveItem(at: target, to: current)
            } catch {
                // The folder is at `target` after all. The resolver validates
                // every cached entry, so leaving the one written above is right.
                return target
            }
            Self.remember(id: found.metadata.id, directory: current, archiveRoot: archive.root)
            return current
        }
        return target
    }

    /// Settles every finished meeting whose folder is out of date with its title.
    ///
    /// The startup sweep calls this. A meeting that reached `complete` and was
    /// still compacting when the app quit never re-enters `process`, so without
    /// a pass here its folder would keep its recording-time name for good.
    ///
    /// `isBusy` names the meetings a job is writing into. Renaming one of those
    /// moves the folder out from under an absolute path the job is still using,
    /// and only the pipeline knows which they are.
    public func settleFolderNames(skipping isBusy: (String) -> Bool = { _ in false }) {
        for directory in meetingDirectories() {
            guard let metadata = try? MeetingStore(layout: MeetingLayout(root: directory))
                .readMetadata()
            else { continue }
            guard metadata.processing.state == .complete || metadata.processing.state == .failed
            else { continue }
            guard !isBusy(metadata.id) else { continue }
            settleFolderName(for: metadata)
        }
    }

    /// Writes back the folder a meeting is actually in, when the metadata has
    /// fallen behind the path.
    ///
    /// A folder renamed in Finder moves every meeting inside it without
    /// touching a single `metadata.json`, and the next settle is the first
    /// thing to notice. Cheap: one comparison per meeting, a write only when
    /// they disagree.
    private func repairFolderName(of metadata: MeetingMetadata, at directory: URL, folder: String?) {
        guard metadata.folderName != folder else { return }
        _ = try? MeetingStore(layout: MeetingLayout(root: directory)).updateMetadata {
            $0.folderName = folder
        }
    }

    // MARK: filing

    /// Files a meeting into a folder, or takes it out of one.
    ///
    /// The directory moves; nothing inside it is rewritten. The identifier does
    /// not change, so the speakers database, the transcript index and every
    /// reference by identifier keep working across the move.
    ///
    /// Returns where the meeting sits afterwards.
    @discardableResult
    public func move(meetingID: String, toFolder folder: String?) throws -> URL {
        guard let found = findMeeting(id: meetingID, includingMerged: true) else {
            throw MeetingFolderError.meetingNotFound(meetingID)
        }
        let current = found.store.layout.root
        let metadata = found.metadata
        // Capture appends segments to paths it holds open, and the pipeline
        // holds absolute paths for the length of a run. Either way the folder
        // must not move out from under them.
        guard metadata.processing.state == .complete || metadata.processing.state == .failed else {
            throw MeetingFolderError.meetingIsBusy(meetingID)
        }
        let destination = folder.map(MeetingFolderStore.sanitize)
        if let destination {
            guard !destination.isEmpty else {
                throw MeetingFolderError.invalidFolderName(folder ?? "")
            }
            guard MeetingFolderStore(archive: archive).exists(destination) else {
                throw MeetingFolderError.folderNotFound(destination)
            }
        }
        let from = archive.folderName(ofDirectory: current)
        guard from != destination else { return current }

        let desired = archive.uniqueDirectoryName(
            base: current.lastPathComponent, startedAt: metadata.startedAt, folder: destination
        )
        let target = archive.directory(
            named: desired, startedAt: metadata.startedAt, folder: destination
        )
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: current, to: target)
        Self.remember(id: metadata.id, directory: target, archiveRoot: archive.root)
        do {
            _ = try MeetingStore(layout: MeetingLayout(root: target)).updateMetadata {
                $0.folderName = destination
                // Only when Pipit was the one naming the folder. A folder a
                // person renamed in Finder is left unclaimed, the way a rename
                // leaves it, so a later settle still keeps its hands off.
                if $0.directoryName == current.lastPathComponent {
                    $0.directoryName = desired
                }
                // Being moved out is a plainer answer than any rule, so the
                // folder left behind is never offered for this meeting again.
                if let from {
                    var removed = $0.removedFromFolders ?? []
                    if !removed.contains(from) { removed.append(from) }
                    $0.removedFromFolders = removed
                }
            }
        } catch {
            // The metadata is the record and the path is the truth, so a write
            // that fails leaves them disagreeing. Put the folder back rather
            // than leave a meeting filed somewhere its own file denies.
            try? FileManager.default.moveItem(at: target, to: current)
            Self.remember(id: metadata.id, directory: current, archiveRoot: archive.root)
            throw error
        }
        return target
    }

    /// Every folder with enough of its contents to judge a new meeting against.
    ///
    /// One metadata read per filed meeting, capped per folder: the ladder only
    /// needs to know what a folder usually looks like, and a folder with two
    /// hundred meetings in it does not describe itself any better than its
    /// newest forty do.
    public func folderProfiles(sampling limit: Int = 40) -> [FolderProfile] {
        let store = MeetingFolderStore(archive: archive)
        return store.folders().map { folder in
            let members = meetingMetadata(inFolder: folder.name, limit: limit)
            return FolderProfile(
                name: folder.name,
                about: folder.about,
                rule: folder.rule,
                filesAutomatically: folder.filesAutomatically,
                members: members.map { MeetingFacts(metadata: $0) }
            )
        }
    }

    /// The metadata of the meetings in one folder, newest first.
    public func meetingMetadata(inFolder folder: String, limit: Int? = nil) -> [MeetingMetadata] {
        let directory = archive.folderDirectory(folder)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        let all = entries
            .filter(\.hasDirectoryPath)
            .compactMap { try? MeetingStore(layout: MeetingLayout(root: $0)).readMetadata() }
            .filter { $0.mergedIntoMeetingID == nil }
            .sorted { $0.startedAt > $1.startedAt }
        guard let limit else { return all }
        return Array(all.prefix(limit))
    }

    /// Every meeting in one folder, newest first.
    public func meetings(inFolder folder: String) -> [MeetingSummary] {
        let directory = archive.folderDirectory(folder)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter(\.hasDirectoryPath)
            .compactMap { summary(forDirectory: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public static func timestampTitle(startedAt: Date, source: MeetingSource) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        return "\(source.displayName), \(startedAt.formatted(style))"
    }

    /// Every meeting directory under the archive root, newest first.
    /// Identifiers of meetings folded into another one.
    ///
    /// Hidden from `listMeetings`, but their folders hold the only copy of the
    /// audio a reconnection recorded, so processing and recovery have to be able
    /// to enumerate them.
    public func mergedMeetingIDs() -> [String] {
        var out: [String] = []
        for directory in meetingDirectories() {
            let store = MeetingStore(layout: MeetingLayout(root: directory))
            guard let metadata = try? store.readMetadata(),
                  metadata.mergedIntoMeetingID != nil
            else { continue }
            out.append(metadata.id)
        }
        return out
    }

    /// Every meeting directory in the archive, folded continuations included.
    public func meetingDirectories() -> [URL] {
        let fileManager = FileManager.default
        guard let years = try? fileManager.contentsOfDirectory(
            at: archive.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        var directories: [URL] = []
        let foldersRoot = archive.foldersRoot.standardizedFileURL.path
        for year in years where year.hasDirectoryPath {
            // `Folders` is a sibling of the year directories, and two levels
            // below it is a meeting, exactly where a month walk expects one.
            // Without this every filed meeting was listed twice.
            guard year.standardizedFileURL.path != foldersRoot else { continue }
            guard let months = try? fileManager.contentsOfDirectory(
                at: year, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for month in months where month.hasDirectoryPath {
                guard let meetings = try? fileManager.contentsOfDirectory(
                    at: month, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ) else { continue }
                directories.append(contentsOf: meetings.filter(\.hasDirectoryPath))
            }
        }
        directories.append(contentsOf: filedMeetingDirectories())
        return directories
    }

    /// Every meeting directory sitting inside a folder the user made.
    ///
    /// A second place to look rather than a replacement: an unfiled meeting
    /// keeps the `YYYY/MM` path it has always had, and filing one moves it here.
    public func filedMeetingDirectories() -> [URL] {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(
            at: archive.foldersRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var directories: [URL] = []
        for folder in folders where folder.hasDirectoryPath {
            guard let meetings = try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            directories.append(contentsOf: meetings.filter(\.hasDirectoryPath))
        }
        return directories
    }

    /// Moves every meeting folder still in the pre-`raw/` layout forward.
    ///
    /// Cheap renames only; run before the recovery scan so recovery and
    /// processing see one layout. A folder whose move fails is left for the
    /// next launch and reported, not fatal: its metadata still reads through
    /// the legacy fallback.
    @discardableResult
    public func migrateLayouts() -> (migrated: Int, failed: Int) {
        var migrated = 0
        var failed = 0
        for directory in meetingDirectories() {
            let layout = MeetingLayout(root: directory)
            guard MeetingLayoutMigration.needsMigration(layout: layout) else { continue }
            do {
                try MeetingLayoutMigration.migrate(layout: layout)
                migrated += 1
            } catch {
                failed += 1
                Log.storage.error("layout migration failed: \(logSafeDescription(error), privacy: .public)")
            }
        }
        return (migrated, failed)
    }

    public func listMeetings(limit: Int? = nil) -> [MeetingSummary] {
        let directories = meetingDirectories()
        var summaries: [MeetingSummary] = []
        for directory in directories {
            guard let summary = summary(forDirectory: directory) else { continue }
            summaries.append(summary)
        }
        summaries.sort { $0.startedAt > $1.startedAt }
        if let limit { return Array(summaries.prefix(limit)) }
        return summaries
    }

    public func summary(forDirectory directory: URL) -> MeetingSummary? {
        let layout = MeetingLayout(root: directory)
        guard let metadata = try? MeetingStore(layout: layout).readMetadata() else { return nil }
        guard metadata.mergedIntoMeetingID == nil else { return nil }
        // A conversation recorded in two halves is one row, reporting the audio
        // both halves hold. Derived here rather than added into the first
        // recording's own metadata when the two were linked: that made undoing
        // the link a subtraction, and a subtraction that goes wrong reports a
        // duration no file supports.
        let continuations = logicalMeeting(id: metadata.id)?.continuations ?? []
        return MeetingSummary(
            id: metadata.id,
            directory: directory,
            title: metadata.displayTitle,
            startedAt: metadata.startedAt,
            durationSeconds: metadata.durationSeconds
                + continuations.reduce(0) { $0 + $1.metadata.durationSeconds },
            source: metadata.source,
            provider: metadata.provider,
            processingState: metadata.processing.state,
            wasInterrupted: metadata.runs.contains(where: \.wasInterrupted)
                || !continuations.isEmpty,
            hasTranscript: FileManager.default.fileExists(atPath: layout.canonicalTranscript.path),
            recordingCount: 1 + continuations.count,
            isArchived: metadata.isArchived,
            // Where it sits, not what the metadata remembers. A folder renamed
            // in Finder moves every meeting in it without touching a file.
            folderName: archive.folderName(ofDirectory: directory)
        )
    }

    /// Every recording of the conversation a summary stands for, in order.
    ///
    /// A summary already reports the duration of both halves of a dropped call,
    /// so anything reading a row's files has to read both too. Falls back to
    /// the summary's own folder when the conversation cannot be resolved, so a
    /// row is never left with nothing.
    public func stores(ofConversation summary: MeetingSummary) -> [MeetingStore] {
        guard summary.recordingCount > 1, let logical = logicalMeeting(id: summary.id) else {
            return [MeetingStore(layout: MeetingLayout(root: summary.directory))]
        }
        return logical.recordings.map(\.store)
    }

    /// The whole conversation an identifier belongs to.
    ///
    /// Answers for either half. Given a continuation's identifier it resolves up
    /// to the recording the conversation started with, so nothing recorded is
    /// unreachable through an identifier a notification or a link still carries.
    public func logicalMeeting(id: String) -> LogicalMeeting? {
        guard var found = findMeeting(id: id, includingMerged: true) else { return nil }
        var hops = 0
        while let parentID = found.metadata.mergedIntoMeetingID, hops < 16 {
            hops += 1
            guard let parent = findMeeting(id: parentID, includingMerged: true) else { break }
            found = parent
        }
        let primary = RecordedMeeting(metadata: found.metadata, store: found.store)
        // Collected transitively. `combine` resolves its target through this
        // function, so a chain cannot form now, but reading only one level meant
        // any chain that already existed hid its last recording completely,
        // which is the failure this whole path exists to prevent.
        var continuations: [RecordedMeeting] = []
        var seen: Set<String> = [found.metadata.id]
        var frontier = found.metadata.absorbedMeetingIDs
        while let next = frontier.popLast(), seen.count < 64 {
            guard seen.insert(next).inserted,
                  let child = findMeeting(id: next, includingMerged: true)
            else { continue }
            continuations.append(
                RecordedMeeting(metadata: child.metadata, store: child.store)
            )
            frontier.append(contentsOf: child.metadata.absorbedMeetingIDs)
        }
        return LogicalMeeting(primary: primary, continuations: continuations)
    }

    /// Finds one meeting by its identifier.
    ///
    /// This used to build the whole summary list and filter it, which read and
    /// decoded every metadata.json in the archive. Finishing a meeting does this
    /// several times on the actor that also arms the next recording, and
    /// applying one name to thirty corrected lines did it thirty-one times, so
    /// the cheap answers come first:
    ///
    /// 1. The cache, checked against the metadata it points at.
    /// 2. A directory named for the identifier. Every meeting recorded before
    ///    folder names and identifiers parted answers here.
    /// 3. A scan. The identifier opens with `YYYY-MM-DD`, so it reads that one
    ///    month before falling back to the whole archive.
    public func findMeeting(
        id: String, includingMerged: Bool = false
    ) -> (metadata: MeetingMetadata, store: MeetingStore)? {
        guard let directory = resolveDirectory(id: id) else { return nil }
        let store = MeetingStore(layout: MeetingLayout(root: directory))
        guard let metadata = try? store.readMetadata(), metadata.id == id else { return nil }
        // Matches listMeetings, which hides a meeting folded into another.
        // Processing asks for it anyway: the audio lives in this folder and
        // nothing else can transcribe it.
        guard includingMerged || metadata.mergedIntoMeetingID == nil else { return nil }
        return (metadata, store)
    }

    private func resolveDirectory(id: String) -> URL? {
        let root = archive.root
        if let cached = Self.cachedDirectory(id: id, archiveRoot: root) {
            if holdsMeeting(id: id, at: cached) { return cached }
            // The folder was renamed, moved or deleted since it was cached.
            Self.forget(id: id, archiveRoot: root)
        }
        if let named = directoryNamedForIdentifier(id) {
            Self.remember(id: id, directory: named, archiveRoot: root)
            return named
        }
        if let found = scanForMeeting(id: id) {
            Self.remember(id: id, directory: found, archiveRoot: root)
            return found
        }
        return nil
    }

    /// The pre-rename layout, where the folder is called what the meeting is
    /// identified by.
    private func directoryNamedForIdentifier(_ id: String) -> URL? {
        let fileManager = FileManager.default
        guard let years = try? fileManager.contentsOfDirectory(
            at: archive.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        let foldersRoot = archive.foldersRoot.standardizedFileURL.path
        for year in years where year.hasDirectoryPath {
            guard year.standardizedFileURL.path != foldersRoot else { continue }
            guard let months = try? fileManager.contentsOfDirectory(
                at: year, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for month in months where month.hasDirectoryPath {
                let candidate = month.appendingPathComponent(id, isDirectory: true)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else { continue }
                if holdsMeeting(id: id, at: candidate) { return candidate }
            }
        }
        // A meeting recorded before folder names and identifiers parted keeps
        // its identifier as a folder name after it is filed, so the same fast
        // path has to cover the folders as well as the months.
        if let folders = try? fileManager.contentsOfDirectory(
            at: archive.foldersRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) {
            for folder in folders where folder.hasDirectoryPath {
                let candidate = folder.appendingPathComponent(id, isDirectory: true)
                if holdsMeeting(id: id, at: candidate) { return candidate }
            }
        }
        return nil
    }

    private func holdsMeeting(id: String, at directory: URL) -> Bool {
        guard let metadata = try? MeetingStore(layout: MeetingLayout(root: directory))
            .readMetadata()
        else { return false }
        return metadata.id == id
    }

    /// Reads metadata until one matches. The month the identifier names is read
    /// first, because that is where the meeting is unless someone moved it.
    private func scanForMeeting(id: String) -> URL? {
        var searched: Set<String> = []
        if let month = Self.monthDirectory(forIdentifier: id, root: archive.root) {
            searched.insert(month.standardizedFileURL.path)
            if let found = scanMonth(month, for: id) { return found }
        }
        for directory in meetingDirectories() {
            let month = directory.deletingLastPathComponent()
            guard searched.insert(month.standardizedFileURL.path).inserted else { continue }
            if let found = scanMonth(month, for: id) { return found }
        }
        return nil
    }

    /// Every metadata this reads on the way past is cached, not just the match.
    /// The first `listMeetings` of a launch resolves one identifier per meeting,
    /// and without this each of those re-read the whole month.
    private func scanMonth(_ month: URL, for id: String) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: month, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        var match: URL?
        for entry in entries where entry.hasDirectoryPath {
            guard let metadata = try? MeetingStore(layout: MeetingLayout(root: entry))
                .readMetadata()
            else { continue }
            Self.remember(id: metadata.id, directory: entry, archiveRoot: archive.root)
            if metadata.id == id { match = entry }
        }
        return match
    }

    /// `2026-08-18-1418-slack-huddle` sits under `2026/08`.
    private static func monthDirectory(forIdentifier id: String, root: URL) -> URL? {
        let parts = id.split(separator: "-")
        guard parts.count >= 2,
              parts[0].count == 4, parts[1].count == 2,
              parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber)
        else { return nil }
        let month = root
            .appendingPathComponent(String(parts[0]), isDirectory: true)
            .appendingPathComponent(String(parts[1]), isDirectory: true)
        return FileManager.default.fileExists(atPath: month.path) ? month : nil
    }

    // MARK: identifier cache

    /// Where an identifier was last found, so a folder no longer named for its
    /// meeting still costs one metadata read to reach.
    ///
    /// Keyed by archive root as well as identifier, because choosing a new
    /// meetings folder in Settings takes effect immediately and every test
    /// builds its own archive under a temporary directory.
    private static let directoryCache = Mutex<[String: URL]>([:])

    private static func key(id: String, archiveRoot: URL) -> String {
        "\(archiveRoot.standardizedFileURL.path)\u{0}\(id)"
    }

    private static func cachedDirectory(id: String, archiveRoot: URL) -> URL? {
        directoryCache.withLock { $0[key(id: id, archiveRoot: archiveRoot)] }
    }

    static func remember(id: String, directory: URL, archiveRoot: URL) {
        directoryCache.withLock { $0[key(id: id, archiveRoot: archiveRoot)] = directory }
    }

    private static func forget(id: String, archiveRoot: URL) {
        _ = directoryCache.withLock { $0.removeValue(forKey: key(id: id, archiveRoot: archiveRoot)) }
    }
}
