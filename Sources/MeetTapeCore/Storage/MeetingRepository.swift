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
        for directory in [layout.root, layout.segments] {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw StorageError.directoryCreationFailed(path: directory.path, underlying: "\(error)")
            }
        }
    }

    // MARK: metadata

    public func readMetadata() throws -> MeetingMetadata {
        let data = try read(layout.metadata)
        return try ArchiveCoding.decode(MeetingMetadata.self, from: data, path: layout.metadata.path)
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

    public func readSpeakerMap() throws -> SpeakerMap {
        guard FileManager.default.fileExists(atPath: layout.speakerMap.path) else { return SpeakerMap() }
        let data = try read(layout.speakerMap)
        return try ArchiveCoding.decode(SpeakerMap.self, from: data, path: layout.speakerMap.path)
    }

    public func writeSpeakerMap(_ map: SpeakerMap) throws {
        try AtomicFile.write(try ArchiveCoding.encode(map), to: layout.speakerMap)
    }

    public func readCanonicalTranscript() throws -> CanonicalTranscript? {
        guard FileManager.default.fileExists(atPath: layout.canonicalTranscript.path) else { return nil }
        let data = try read(layout.canonicalTranscript)
        return try ArchiveCoding.decode(CanonicalTranscript.self, from: data, path: layout.canonicalTranscript.path)
    }

    public func writeCanonicalTranscript(_ transcript: CanonicalTranscript) throws {
        try AtomicFile.write(try ArchiveCoding.encode(transcript), to: layout.canonicalTranscript)
    }

    public func writeTranscriptMarkdown(_ text: String) throws {
        try AtomicFile.writeText(text, to: layout.transcriptMarkdown)
    }

    public func writeAPIResponse(_ data: Data, named name: String) throws {
        try AtomicFile.write(data, to: layout.apiResponseFile(named: name))
    }

    // MARK: timeline

    public func readTimeline() throws -> RecordingTimeline {
        guard FileManager.default.fileExists(atPath: layout.manifest.path) else {
            return ManifestReader.timeline(
                from: ManifestReadResult(lines: [], hasTruncatedTail: false, unrecognisedLines: 0)
            )
        }
        return try ManifestReader.timeline(contentsOf: layout.manifest)
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

    public init(
        id: String, directory: URL, title: String, startedAt: Date, durationSeconds: Double,
        source: MeetingSource, provider: MeetingProvider, processingState: ProcessingState,
        wasInterrupted: Bool, hasTranscript: Bool
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

    public func store(for metadata: MeetingMetadata) -> MeetingStore {
        MeetingStore(layout: archive.layout(forMeetingID: metadata.id, startedAt: metadata.startedAt))
    }

    public func store(forMeetingID id: String, startedAt: Date) -> MeetingStore {
        MeetingStore(layout: archive.layout(forMeetingID: id, startedAt: startedAt))
    }

    /// Creates the directory and writes the first metadata.json.
    ///
    /// `titles` carries whatever is known at start: a provider or window title for
    /// an automatic recording, nothing at all for a manual one. The directory name
    /// is derived from the best candidate so the archive stays browsable.
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
        let id = archive.uniqueMeetingID(base: base, startedAt: startedAt)
        var metadata = MeetingMetadata(
            id: id,
            source: source,
            provider: provider,
            createdAt: now,
            startedAt: startedAt,
            titles: candidates
        )
        metadata.processing = ProcessingStatus(state: .recording, updatedAt: now)
        let store = MeetingStore(layout: archive.layout(forMeetingID: id, startedAt: startedAt))
        try store.createDirectories()
        try store.writeMetadata(metadata)
        return (metadata, store)
    }

    public static func timestampTitle(startedAt: Date, source: MeetingSource) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        return "\(source.displayName), \(startedAt.formatted(style))"
    }

    /// Every meeting directory under the archive root, newest first.
    public func listMeetings(limit: Int? = nil) -> [MeetingSummary] {
        let fileManager = FileManager.default
        guard let years = try? fileManager.contentsOfDirectory(
            at: archive.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        var directories: [URL] = []
        for year in years where year.hasDirectoryPath {
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
        guard let data = try? Data(contentsOf: layout.metadata),
              let metadata = try? ArchiveCoding.decode(
                  MeetingMetadata.self, from: data, path: layout.metadata.path
              )
        else { return nil }
        guard metadata.mergedIntoMeetingID == nil else { return nil }
        return MeetingSummary(
            id: metadata.id,
            directory: directory,
            title: metadata.displayTitle,
            startedAt: metadata.startedAt,
            durationSeconds: metadata.durationSeconds,
            source: metadata.source,
            provider: metadata.provider,
            processingState: metadata.processing.state,
            wasInterrupted: metadata.runs.contains(where: \.wasInterrupted),
            hasTranscript: FileManager.default.fileExists(atPath: layout.canonicalTranscript.path)
        )
    }

    /// Finds one meeting by its identifier.
    ///
    /// A meeting's directory is named for its identifier, so this matches on
    /// names and decodes exactly one metadata file. It used to build the whole
    /// summary list and filter it, which read and decoded every metadata.json in
    /// the archive; finishing a meeting does this several times on the actor
    /// that also arms the next recording, and applying one name to thirty
    /// corrected lines did it thirty-one times.
    public func findMeeting(id: String) -> (metadata: MeetingMetadata, store: MeetingStore)? {
        let fileManager = FileManager.default
        guard let years = try? fileManager.contentsOfDirectory(
            at: archive.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }

        for year in years where year.hasDirectoryPath {
            guard let months = try? fileManager.contentsOfDirectory(
                at: year, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for month in months where month.hasDirectoryPath {
                let candidate = month.appendingPathComponent(id, isDirectory: true)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else { continue }
                let store = MeetingStore(layout: MeetingLayout(root: candidate))
                guard let metadata = try? store.readMetadata(), metadata.id == id else { continue }
                // Matches listMeetings, which hides a meeting folded into another.
                guard metadata.mergedIntoMeetingID == nil else { return nil }
                return (metadata, store)
            }
        }
        return nil
    }
}
