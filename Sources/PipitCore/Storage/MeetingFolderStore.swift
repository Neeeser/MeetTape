import Foundation

/// What can go wrong filing a meeting or changing a folder.
public enum MeetingFolderError: Error, Equatable, Sendable {
    case meetingNotFound(String)
    /// A meeting still recording or still being processed. Its segments are
    /// being appended to paths the capture holds open, so moving the directory
    /// out from under them loses audio.
    case meetingIsBusy(String)
    case folderNotFound(String)
    case folderExists(String)
    /// A name that sanitizes to nothing, or one the archive reserves.
    case invalidFolderName(String)

    public var message: String {
        switch self {
        case .meetingNotFound(let id): "No meeting on disk with the identifier \(id)."
        case .meetingIsBusy: "This meeting is still being recorded or processed."
        case .folderNotFound(let name): "There is no folder called \(name)."
        case .folderExists(let name): "There is already a folder called \(name)."
        case .invalidFolderName(let name): "\(name) cannot be used as a folder name."
        }
    }
}

/// The folders in an archive: reading them, making them, and taking them away.
///
/// A folder is a directory, so most of this is thin. `folder.json` holds the
/// two things a directory listing cannot say, which are what the folder is
/// about and what it may file without asking.
public struct MeetingFolderStore: Sendable {
    public let archive: MeetingArchiveLayout

    public init(archive: MeetingArchiveLayout) {
        self.archive = archive
    }

    public init(root: URL) {
        self.init(archive: MeetingArchiveLayout(root: root))
    }

    /// Every folder, by name.
    ///
    /// A directory with no `folder.json` is still a folder. Someone can make
    /// one in Finder and drop meetings into it, and refusing to list it would
    /// hide meetings that are plainly there.
    public func folders() -> [MeetingFolder] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: archive.foldersRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter(\.hasDirectoryPath)
            .map { read(named: $0.lastPathComponent) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func folder(named name: String) -> MeetingFolder? {
        guard exists(name) else { return nil }
        return read(named: name)
    }

    public func exists(_ name: String) -> Bool {
        var isDirectory: ObjCBool = false
        let found = FileManager.default.fileExists(
            atPath: archive.folderDirectory(name).path, isDirectory: &isDirectory
        )
        return found && isDirectory.boolValue
    }

    @discardableResult
    public func create(
        name: String,
        about: String = "",
        tintIndex: Int? = nil,
        rule: FolderRule = FolderRule(),
        filesAutomatically: Bool = false,
        now: Date = Date()
    ) throws -> MeetingFolder {
        let clean = Self.sanitize(name)
        guard !clean.isEmpty else { throw MeetingFolderError.invalidFolderName(name) }
        guard !exists(clean) else { throw MeetingFolderError.folderExists(clean) }
        try FileManager.default.createDirectory(
            at: archive.folderDirectory(clean), withIntermediateDirectories: true
        )
        let folder = MeetingFolder(
            name: clean,
            about: about,
            // Spread around the palette rather than starting every folder blue.
            tintIndex: tintIndex ?? (folders().count % MeetingFolder.tintCount),
            rule: rule,
            filesAutomatically: filesAutomatically,
            createdAt: now
        )
        try write(folder)
        return folder
    }

    /// Writes a folder's manifest. The name has to name a folder that exists;
    /// renaming goes through `rename`, which moves the directory.
    public func write(_ folder: MeetingFolder) throws {
        guard exists(folder.name) else { throw MeetingFolderError.folderNotFound(folder.name) }
        let data = try ArchiveCoding.encode(folder)
        try AtomicFile.write(data, to: archive.folderManifest(folder.name))
    }

    @discardableResult
    public func rename(_ name: String, to newName: String) throws -> MeetingFolder {
        let clean = Self.sanitize(newName)
        guard !clean.isEmpty else { throw MeetingFolderError.invalidFolderName(newName) }
        guard exists(name) else { throw MeetingFolderError.folderNotFound(name) }
        guard clean != name else { return read(named: name) }
        guard !exists(clean) else { throw MeetingFolderError.folderExists(clean) }
        try FileManager.default.moveItem(
            at: archive.folderDirectory(name), to: archive.folderDirectory(clean)
        )
        var folder = read(named: clean)
        folder.name = clean
        try write(folder)
        return folder
    }

    /// Removes an empty folder. The caller moves the meetings out first, which
    /// is what puts them back under `YYYY/MM` and updates their metadata.
    public func delete(_ name: String) throws {
        guard exists(name) else { throw MeetingFolderError.folderNotFound(name) }
        try FileManager.default.removeItem(at: archive.folderDirectory(name))
    }

    /// A name a directory can be called, with the characters that break a macOS
    /// path taken out. Case, spaces and accents survive, because these are read
    /// in Finder.
    public static func sanitize(_ name: String) -> String {
        let clean = MeetingFolderName.sanitize(name)
        // Reserved because the archive root already uses it, and a folder
        // called `Folders` would sit at `Meetings/Folders/Folders`.
        return clean == "Folders" ? "" : clean
    }

    private func read(named name: String) -> MeetingFolder {
        guard let data = try? Data(contentsOf: archive.folderManifest(name)),
              var folder = try? ArchiveCoding.decode(
                  MeetingFolder.self, from: data, path: archive.folderManifest(name).path
              )
        else { return MeetingFolder(name: name) }
        // The directory is the identity. A manifest carried in from somewhere
        // else, or left behind by a rename made in Finder, does not get to say
        // the folder is called something other than where it is.
        folder.name = name
        return folder
    }
}
