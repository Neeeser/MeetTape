import FluidAudio
import Foundation
import MeetTapeCore

/// Where MeetTape keeps the speech models.
///
/// WhisperKit defaults to `~/Documents/huggingface`, which puts 624 MB into the
/// user's Documents folder where it shows up in Finder and syncs to iCloud
/// Drive. Everything goes under Application Support instead, in one directory
/// MeetTape owns and can report on, delete and re-download, one subdirectory
/// per install unit.
public struct LocalModelLocations: Sendable, Equatable {
    public let root: URL

    public init(applicationSupport: URL) {
        self.root = applicationSupport.appendingPathComponent("Models", isDirectory: true)
    }

    /// `WhisperKitConfig.downloadBase`. The model files and the tokenizer both
    /// land under it.
    public var whisperBase: URL { root.appendingPathComponent("Whisper", isDirectory: true) }

    /// The variant directory inside the Hugging Face cache layout the library
    /// builds under `whisperBase`.
    public var whisperModelFolder: URL {
        whisperBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(LocalSpeechStack.whisperModel, isDirectory: true)
    }

    public var diarizerDirectory: URL {
        root.appendingPathComponent("Diarizer", isDirectory: true)
    }

    /// FluidAudio's downloaders resolve each repository's own folder name
    /// under a base directory, so the unit directories are those names rather
    /// than names of MeetTape's choosing: giving the library a different
    /// directory meant it downloaded to the resolved one and every presence
    /// check looked at an empty folder.
    public var parakeetDirectory: URL {
        root.appendingPathComponent(
            AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent, isDirectory: true
        )
    }

    /// Includes the precision subpath (`…/q8`); the compiled models and the
    /// vocabulary all land inside it.
    public var cohereDirectory: URL {
        root.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName, isDirectory: true)
    }

    public var canaryDirectory: URL {
        root.appendingPathComponent(Repo.canary1bV2.folderName, isDirectory: true)
    }

    public var alignerDirectory: URL {
        root.appendingPathComponent(
            CtcModelVariant.ctc06b.repo.folderName, isDirectory: true
        )
    }

    /// Where a unit's files are read from.
    public func directory(for unit: LocalModelUnit) -> URL {
        switch unit {
        case .whisper: whisperBase
        case .parakeet: parakeetDirectory
        case .cohere: cohereDirectory
        case .canary: canaryDirectory
        case .ctcAligner: alignerDirectory
        case .diarizer: diarizerDirectory
        }
    }

    /// The top-level folder under `root` that a unit occupies: what gets
    /// sized and deleted. Differs from `directory(for:)` only when the
    /// repository nests a precision subpath.
    public func containerDirectory(for unit: LocalModelUnit) -> URL {
        let deep = directory(for: unit)
        var container = deep
        while container.deletingLastPathComponent().standardizedFileURL.path
            != root.standardizedFileURL.path,
            container.path.hasPrefix(root.path) {
            container = container.deletingLastPathComponent()
        }
        return container.path.hasPrefix(root.path) ? container : deep
    }

    /// One receipt per installed unit, written after each unit completes.
    public var inventory: URL { root.appendingPathComponent("units.json") }

    /// The single-receipt file builds before per-unit installs wrote. Read for
    /// migration, never written again.
    public var legacyReceipt: URL { root.appendingPathComponent("installed.json") }
}

/// What one unit's successful install left behind.
public struct LocalUnitReceipt: Codable, Sendable, Equatable {
    /// The pinned revision the files came from, compared against
    /// `LocalSpeechStack.revision(for:)` so a dependency bump is visible as a
    /// stale receipt rather than as strange results.
    public var revision: String
    public var bytes: Int64
    public var installedAt: Date
    /// Unit-specific: Whisper records the resolved model folder path here.
    public var detail: String?

    public init(revision: String, bytes: Int64, installedAt: Date, detail: String? = nil) {
        self.revision = revision
        self.bytes = bytes
        self.installedAt = installedAt
        self.detail = detail
    }

    public func matchesCurrentBuild(for unit: LocalModelUnit) -> Bool {
        revision == LocalSpeechStack.revision(for: unit)
    }
}

/// Every unit that is installed right now.
public struct LocalModelSnapshot: Sendable, Equatable {
    public var receipts: [LocalModelUnit: LocalUnitReceipt]

    public init(receipts: [LocalModelUnit: LocalUnitReceipt] = [:]) {
        self.receipts = receipts
    }

    public var totalBytes: Int64 { receipts.values.reduce(0) { $0 + $1.bytes } }
    public var units: Set<LocalModelUnit> { Set(receipts.keys) }
    public func bytes(for unit: LocalModelUnit) -> Int64? { receipts[unit]?.bytes }
}

/// Whether the units the current configuration needs can run right now.
public enum LocalModelState: Sendable, Equatable {
    /// Every case carries what is on disk, not just the usable ones: a user
    /// who has Whisper and switches to Cohere is mid-download, and the rows
    /// for what they already have must still say so.
    case notInstalled(LocalModelSnapshot)
    case downloading(fraction: Double, detail: String, present: LocalModelSnapshot)
    case installed(LocalModelSnapshot)
    /// Present, but installed by a build that pinned different revisions.
    case outdated(LocalModelSnapshot)
    case failed(String, present: LocalModelSnapshot)

    /// What is on disk right now, whatever the aggregate says.
    public var present: LocalModelSnapshot {
        switch self {
        case .notInstalled(let snapshot), .installed(let snapshot),
            .outdated(let snapshot): snapshot
        case .downloading(_, _, let snapshot), .failed(_, let snapshot): snapshot
        }
    }

    public var isUsable: Bool {
        switch self {
        case .installed, .outdated: true
        case .notInstalled, .downloading, .failed: false
        }
    }

    public var isBusy: Bool {
        if case .downloading = self { return true }
        return false
    }
}

/// Reads and writes the per-unit receipts, migrating the single-receipt file
/// a previous build wrote.
public struct LocalModelReceiptStore: Sendable {
    public let locations: LocalModelLocations

    public init(locations: LocalModelLocations) {
        self.locations = locations
    }

    public func read() -> [LocalModelUnit: LocalUnitReceipt] {
        if let data = try? Data(contentsOf: locations.inventory),
            let stored = try? Self.decoder.decode([String: LocalUnitReceipt].self, from: data) {
            var receipts: [LocalModelUnit: LocalUnitReceipt] = [:]
            for (key, receipt) in stored {
                guard let unit = LocalModelUnit(rawValue: key) else { continue }
                receipts[unit] = receipt
            }
            return receipts
        }
        return migratedLegacyReceipts()
    }

    /// A pre-unit install was always Whisper plus the diarizer. The legacy
    /// receipt names the packages it was built against, which carry over so an
    /// install pinned by an older build still reads as outdated, not current.
    private func migratedLegacyReceipts() -> [LocalModelUnit: LocalUnitReceipt] {
        guard let data = try? Data(contentsOf: locations.legacyReceipt),
            let legacy = try? Self.decoder.decode(LegacyReceipt.self, from: data)
        else { return [:] }
        return [
            .whisper: LocalUnitReceipt(
                revision: "\(legacy.whisperVariant) @ \(legacy.whisperPackage)",
                bytes: legacy.whisperBytes,
                installedAt: legacy.installedAt,
                detail: legacy.whisperFolderPath
            ),
            .diarizer: LocalUnitReceipt(
                revision: legacy.diarizerPackage,
                bytes: legacy.diarizerBytes,
                installedAt: legacy.installedAt
            ),
        ]
    }

    public func write(_ receipts: [LocalModelUnit: LocalUnitReceipt]) throws {
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let stored = Dictionary(uniqueKeysWithValues: receipts.map { ($0.key.rawValue, $0.value) })
        try encoder.encode(stored).write(to: locations.inventory, options: .atomic)
        try? FileManager.default.removeItem(at: locations.legacyReceipt)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private struct LegacyReceipt: Codable {
        var whisperVariant: String
        var whisperFolderPath: String
        var whisperBytes: Int64
        var diarizerBytes: Int64
        var installedAt: Date
        var whisperPackage: String
        var diarizerPackage: String
    }
}

/// Recursive on-disk size, for the size shown in Settings.
enum DirectorySize {
    static func bytes(of url: URL) -> Int64 {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            let attributes = try? manager.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let enumerator = manager.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}
