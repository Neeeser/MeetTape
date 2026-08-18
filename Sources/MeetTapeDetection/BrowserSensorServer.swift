import Foundation
import MeetTapeCore

/// Accepts connections from browser native-messaging hosts.
///
/// The app listens on a Unix socket in Application Support; each browser host
/// process connects and relays newline-delimited JSON. If the app is not running
/// the host simply fails to connect, and if the host dies the app falls back to
/// native detection. Neither side can take a recording down with it.
public final class BrowserSensorServer: @unchecked Sendable {
    public struct Status: Sendable, Equatable {
        public var isListening: Bool
        public var connectionCount: Int
        public var lastMessageAt: Date?
        public var lastHello: SensorMessage.Hello?
        /// Connections refused because the peer was not MeetTape's own relay.
        public var rejectedConnections = 0
    }

    /// One connection per supported browser is plenty. A local process opening
    /// thousands would exhaust the app's file descriptors, and a recorder that
    /// cannot open a file stops writing audio.
    public static let maximumConnections = 4
    /// A peer that never sends a newline must not grow memory without bound.
    private static let maximumBufferedBytes = 256 * 1_024

    private let socketURL: URL
    private let verifier: SensorPeerVerifier
    private let queue = DispatchQueue(label: "com.meettape.sensor-server")
    private let lock = NSLock()
    private var listenDescriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: DispatchSourceRead] = [:]
    private var buffers: [Int32: Data] = [:]
    private var status = Status(
        isListening: false, connectionCount: 0, lastMessageAt: nil, lastHello: nil
    )

    private let onMessage: @Sendable (SensorMessage) -> Void
    private let onConnectionChange: @Sendable (Int) -> Void

    public init(
        socketURL: URL = SensorTransport.socketURL(
            applicationSupport: SensorTransport.defaultApplicationSupport
        ),
        verifier: SensorPeerVerifier = SensorPeerVerifier(),
        onMessage: @escaping @Sendable (SensorMessage) -> Void,
        onConnectionChange: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.socketURL = socketURL
        self.verifier = verifier
        self.onMessage = onMessage
        self.onConnectionChange = onConnectionChange
    }

    deinit { stop() }

    public var currentStatus: Status {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    public func start() throws {
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: socketURL)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw StorageError.fileWriteFailed(path: socketURL.path, underlying: "socket errno \(errno)")
        }

        let path = socketURL.path
        guard var address = UnixSocketAddress.make(path: path) else {
            close(descriptor)
            throw StorageError.fileWriteFailed(path: path, underlying: "socket path too long")
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, UnixSocketAddress.size)
            }
        }
        guard bindResult == 0 else {
            close(descriptor)
            throw StorageError.fileWriteFailed(path: path, underlying: "bind errno \(errno)")
        }
        // The socket is created inside the umask window, so the mode is tightened
        // immediately; the parent directory is the real boundary.
        chmod(path, 0o600)
        guard listen(descriptor, 4) == 0 else {
            close(descriptor)
            throw StorageError.fileWriteFailed(path: path, underlying: "listen errno \(errno)")
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.setCancelHandler { close(descriptor) }
        source.resume()

        lock.lock()
        listenDescriptor = descriptor
        acceptSource = source
        status.isListening = true
        lock.unlock()

        Log.detection.info("browser sensor server listening")
    }

    public func stop() {
        lock.lock()
        let sources = connections
        connections = [:]
        buffers = [:]
        let accept = acceptSource
        acceptSource = nil
        listenDescriptor = -1
        status = Status(
            isListening: false, connectionCount: 0, lastMessageAt: nil, lastHello: nil
        )
        lock.unlock()

        for (_, source) in sources { source.cancel() }
        accept?.cancel()
        try? FileManager.default.removeItem(at: socketURL)
    }

    private func acceptConnection() {
        lock.lock()
        let listener = listenDescriptor
        lock.unlock()
        guard listener >= 0 else { return }

        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }

        // Only MeetTape's own relay, launched by a browser, may drive detection.
        guard let peer = verifier.peer(of: client) else {
            Log.detection.notice("rejected a sensor connection: the peer could not be identified")
            lock.withLock { status.rejectedConnections += 1 }
            close(client)
            return
        }
        guard verifier.isTrusted(peer) else {
            let reason = self.verifier.rejectionReason(peer)
            Log.detection.notice("rejected a sensor connection: \(reason, privacy: .public)")
            lock.withLock { status.rejectedConnections += 1 }
            close(client)
            return
        }
        let atCapacity = lock.withLock { connections.count >= Self.maximumConnections }
        if atCapacity {
            Log.detection.notice("sensor connection refused: already at capacity")
            close(client)
            return
        }

        var flags = fcntl(client, F_GETFL, 0)
        flags |= O_NONBLOCK
        _ = fcntl(client, F_SETFL, flags)

        let source = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable(from: client) }
        source.setCancelHandler { close(client) }

        lock.lock()
        connections[client] = source
        buffers[client] = Data()
        status.connectionCount = connections.count
        let count = connections.count
        lock.unlock()

        source.resume()
        onConnectionChange(count)
        Log.detection.info("browser sensor connected")
    }

    private func readAvailable(from descriptor: Int32) {
        var chunk = [UInt8](repeating: 0, count: 8_192)
        let bytesRead = read(descriptor, &chunk, chunk.count)
        if bytesRead <= 0 {
            if bytesRead < 0, errno == EAGAIN || errno == EINTR { return }
            closeConnection(descriptor)
            return
        }

        var completeLines: [Data] = []
        lock.lock()
        var buffer = buffers[descriptor] ?? Data()
        buffer.append(contentsOf: chunk[0..<bytesRead])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { completeLines.append(line) }
        }
        if buffer.count > Self.maximumBufferedBytes { buffer.removeAll(keepingCapacity: false) }
        buffers[descriptor] = buffer
        if !completeLines.isEmpty { status.lastMessageAt = Date() }
        lock.unlock()

        for line in completeLines {
            guard let message = try? SensorTransport.decodeLine(line) else {
                Log.detection.notice("dropping unparsable sensor line")
                continue
            }
            if case .hello(let hello) = message {
                lock.lock()
                status.lastHello = hello
                lock.unlock()
            }
            onMessage(message)
        }
    }

    private func closeConnection(_ descriptor: Int32) {
        lock.lock()
        let source = connections.removeValue(forKey: descriptor)
        buffers.removeValue(forKey: descriptor)
        status.connectionCount = connections.count
        let count = connections.count
        lock.unlock()
        source?.cancel()
        onConnectionChange(count)
        Log.detection.info("browser sensor disconnected")
    }
}
