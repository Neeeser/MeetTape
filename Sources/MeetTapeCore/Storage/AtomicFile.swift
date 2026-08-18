import Foundation

/// Write-then-rename with an fsync in between.
///
/// A crash mid-write leaves either the previous file or the new one, never a
/// half-written metadata.json. The directory is synced too, so the rename itself
/// survives power loss.
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StorageError.directoryCreationFailed(path: directory.path, underlying: "\(error)")
        }

        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else {
            throw StorageError.fileWriteFailed(path: temporary.path, underlying: "open errno \(errno)")
        }

        var writeError: StorageError?
        data.withUnsafeBytes { buffer in
            if !writeAllBytes(descriptor: descriptor, buffer: buffer) {
                writeError = .fileWriteFailed(path: temporary.path, underlying: "write errno \(errno)")
            }
        }
        fsync(descriptor)
        close(descriptor)

        if let writeError {
            try? FileManager.default.removeItem(at: temporary)
            throw writeError
        }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            // replaceItemAt fails when the destination does not exist yet.
            do {
                try FileManager.default.moveItem(at: temporary, to: url)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw StorageError.fileWriteFailed(path: url.path, underlying: "\(error)")
            }
        }

        syncDirectory(directory)
    }

    public static func writeText(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    private static func syncDirectory(_ url: URL) {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        fsync(descriptor)
        close(descriptor)
    }
}

/// Writes an entire buffer, retrying on interruption.
private func writeAllBytes(descriptor: Int32, buffer: UnsafeRawBufferPointer) -> Bool {
    guard let base = buffer.baseAddress else { return true }
    var offset = 0
    while offset < buffer.count {
        let result = write(descriptor, base.advanced(by: offset), buffer.count - offset)
        if result <= 0 {
            if errno == EINTR { continue }
            return false
        }
        offset += result
    }
    return true
}

/// JSON coders for archive files. Dates are ISO 8601 so the files stay readable
/// without MeetTape.
public enum ArchiveCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ManifestCoding.string(from: date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = ManifestCoding.date(from: text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "bad timestamp \(text)")
                )
            }
            return date
        }
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> T {
        do {
            return try makeDecoder().decode(type, from: data)
        } catch {
            throw StorageError.decodeFailed(path: path, underlying: "\(error)")
        }
    }
}
