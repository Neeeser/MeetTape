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
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw StorageError.fileWriteFailed(path: url.path, underlying: "open errno \(errno)")
        }
        state = Mutex(State(descriptor: descriptor))
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
