import Foundation
import Synchronization

/// Append-only, fsync'd JSONL writer.
///
/// Each record is flushed before the call returns, so a hard kill can lose at most
/// the line currently being written; the reader tolerates a truncated tail. Callers
/// must keep this off the render thread. Segment writing runs on its own queue.
public final class ManifestWriter: Sendable {
    private struct State {
        var descriptor: Int32
        var writeFailures = 0
        var isClosed = false
    }

    private let state: Mutex<State>
    private let encoder = ManifestCoding.makeEncoder()
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StorageError.directoryCreationFailed(path: directory.path, underlying: "\(error)")
        }
        // Read-write, because reopening an interrupted manifest has to look at the
        // last byte before appending to it. Writes still go through O_APPEND.
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw StorageError.fileWriteFailed(path: url.path, underlying: "open errno \(errno)")
        }
        Self.terminatePartialLine(descriptor: descriptor)
        state = Mutex(State(descriptor: descriptor))
    }

    /// Ends a partial final line before appending to it.
    ///
    /// A recording killed mid-write leaves a line with no newline. Appending
    /// straight onto it glues the next record to the fragment, and the reader
    /// tolerates a partial line only when it is last, so both the fragment and
    /// the record that recovery just wrote are lost.
    private static func terminatePartialLine(descriptor: Int32) {
        let end = lseek(descriptor, 0, SEEK_END)
        guard end > 0 else { return }
        var last: UInt8 = 0
        guard pread(descriptor, &last, 1, end - 1) == 1, last != 0x0A else { return }
        var newline: UInt8 = 0x0A
        _ = write(descriptor, &newline, 1)
    }

    public var writeFailures: Int { state.withLock { $0.writeFailures } }

    @discardableResult
    public func append(_ event: ManifestEvent, hostTime: Double = HostTime.now, wallClock: Date = Date()) -> Bool {
        let line = ManifestLine(hostTime: hostTime, wallClock: wallClock, event: event)
        guard var data = try? encoder.encode(line) else {
            state.withLock { $0.writeFailures += 1 }
            return false
        }
        data.append(0x0A)
        return state.withLock { state in
            guard !state.isClosed else { return false }
            let written = data.withUnsafeBytes { buffer -> Int in
                var offset = 0
                while offset < buffer.count {
                    let result = write(state.descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if result <= 0 {
                        if errno == EINTR { continue }
                        return offset
                    }
                    offset += result
                }
                return offset
            }
            guard written == data.count else {
                state.writeFailures += 1
                return false
            }
            fsync(state.descriptor)
            return true
        }
    }

    public func close() {
        state.withLock { state in
            guard !state.isClosed else { return }
            fsync(state.descriptor)
            Foundation.close(state.descriptor)
            state.isClosed = true
        }
    }

    deinit { close() }
}
