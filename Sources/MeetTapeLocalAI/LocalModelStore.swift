import Foundation
import MeetTapeCore

/// Where MeetTape keeps the speech models.
///
/// WhisperKit defaults to `~/Documents/huggingface`, which puts 624 MB into the
/// user's Documents folder where it shows up in Finder and syncs to iCloud
/// Drive. Everything goes under Application Support instead, in one directory
/// MeetTape owns and can report on, delete and re-download.
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

    /// Written after a full install, so "is it there" does not need the network.
    public var receipt: URL { root.appendingPathComponent("installed.json") }
}

/// What a successful install left behind.
public struct LocalModelReceipt: Codable, Sendable, Equatable {
    public var whisperVariant: String
    public var whisperFolderPath: String
    public var whisperBytes: Int64
    public var diarizerBytes: Int64
    public var installedAt: Date
    /// The package revisions the files came from, so a dependency bump is
    /// visible as a stale receipt rather than as strange results.
    public var whisperPackage: String
    public var diarizerPackage: String

    public init(
        whisperVariant: String, whisperFolderPath: String, whisperBytes: Int64,
        diarizerBytes: Int64, installedAt: Date, whisperPackage: String, diarizerPackage: String
    ) {
        self.whisperVariant = whisperVariant
        self.whisperFolderPath = whisperFolderPath
        self.whisperBytes = whisperBytes
        self.diarizerBytes = diarizerBytes
        self.installedAt = installedAt
        self.whisperPackage = whisperPackage
        self.diarizerPackage = diarizerPackage
    }

    public var matchesCurrentBuild: Bool {
        whisperVariant == LocalSpeechStack.whisperModel
            && whisperPackage == LocalSpeechStack.whisperPackage
            && diarizerPackage == LocalSpeechStack.diarizerPackage
    }
}

/// Whether the local stack can run right now.
public enum LocalModelState: Sendable, Equatable {
    case notInstalled
    case downloading(fraction: Double, detail: String)
    case installed(LocalModelReceipt)
    /// Installed by a build that pinned different model revisions.
    case outdated(LocalModelReceipt)
    case failed(String)

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

/// Reads and writes the install receipt.
struct LocalModelReceiptStore: Sendable {
    let locations: LocalModelLocations

    func read() -> LocalModelReceipt? {
        guard let data = try? Data(contentsOf: locations.receipt) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LocalModelReceipt.self, from: data)
    }

    func write(_ receipt: LocalModelReceipt) throws {
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(receipt).write(to: locations.receipt, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: locations.receipt)
    }
}

/// Recursive on-disk size, for the size shown in Settings.
enum DirectorySize {
    static func bytes(of url: URL) -> Int64 {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int64) as? Int64 ?? 0
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
