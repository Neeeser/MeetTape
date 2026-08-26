import Foundation
import PipitCore

// Pipit's Firefox/Chrome native messaging host.
//
// A compiled binary on purpose. Browsers spawn hosts with a minimal PATH, so an
// interpreter shebang resolves to nothing and the host silently never starts:
// connectNative appears to succeed and onDisconnect fires with a null error.
//
// The host does nothing but relay. Browser stdin speaks the 4-byte
// length-prefixed protocol; the app side is newline-delimited JSON over a Unix
// socket in Application Support. If the app is not running, messages are dropped
// and the browser side is told so, which is exactly the behaviour that lets
// Pipit fall back to native detection.

let hostVersion = "1.0.0"

/// Reads the browser's length-prefixed messages from standard input.
struct BrowserMessageReader {
    /// Reads exactly `count` bytes, or nil once the stream ends.
    private func readExactly(_ count: Int) -> Data? {
        var data = Data()
        while data.count < count {
            let chunk = FileHandle.standardInput.readData(ofLength: count - data.count)
            if chunk.isEmpty { return nil }
            data.append(chunk)
        }
        return data
    }

    func next() -> [String: Any]? {
        guard let header = readExactly(4) else { return nil }
        let length = Int(header[header.startIndex])
            | Int(header[header.startIndex + 1]) << 8
            | Int(header[header.startIndex + 2]) << 16
            | Int(header[header.startIndex + 3]) << 24
        // A hostile or confused peer must not be able to make the host allocate
        // without bound; browsers cap messages far below this.
        guard length > 0, length <= 1_048_576 else { return nil }
        guard let payload = readExactly(length) else { return nil }
        return (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    }
}

/// Writes a length-prefixed reply back to the browser.
func replyToBrowser(_ object: [String: Any]) {
    guard let payload = try? JSONSerialization.data(withJSONObject: object) else { return }
    var length = UInt32(payload.count).littleEndian
    var frame = Data(bytes: &length, count: 4)
    frame.append(payload)
    FileHandle.standardOutput.write(frame)
}

/// Connects to Pipit's socket, reconnecting when the app restarts.
final class AppConnection {
    private let socketPath: String
    private var descriptor: Int32 = -1

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    var isConnected: Bool { descriptor >= 0 }

    @discardableResult
    func connect() -> Bool {
        disconnect()
        guard var address = UnixSocketAddress.make(path: socketPath) else { return false }
        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else { return false }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(handle, $0, UnixSocketAddress.size)
            }
        }
        guard result == 0 else {
            close(handle)
            return false
        }
        descriptor = handle
        return true
    }

    func disconnect() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    @discardableResult
    func send(_ message: SensorMessage) -> Bool {
        guard let line = try? SensorTransport.encodeLine(message) else { return false }
        if !isConnected, !connect() { return false }
        return line.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written <= 0 {
                    if errno == EINTR { continue }
                    disconnect()
                    return false
                }
                offset += written
            }
            return true
        }
    }
}

/// Translates one extension message into the app's wire format.
func sensorMessage(from raw: [String: Any], browser: BrowserKind) -> SensorMessage? {
    switch raw["type"] as? String {
    case "hello":
        return .hello(SensorMessage.Hello(
            browser: browser,
            extensionVersion: raw["extensionVersion"] as? String,
            hostVersion: hostVersion
        ))
    case "tab_removed":
        guard let tabID = raw["tabId"] as? Int else { return nil }
        return .tabClosed(browser: browser, tabID: tabID)
    case "state":
        let provider: MeetingProvider = switch raw["provider"] as? String {
        case "meet": .googleMeet
        case "zoom": .zoom
        default: .unknown
        }
        let state = BrowserMeetingState(rawValue: (raw["state"] as? String) ?? "unknown") ?? .unknown
        let timestamp = (raw["sentAt"] as? Double).map { $0 / 1_000 } ?? Date().timeIntervalSince1970
        return .event(BrowserMeetingEvent(
            browser: browser,
            provider: provider,
            state: state,
            timestamp: timestamp,
            url: raw["url"] as? String,
            meetingID: raw["meetingId"] as? String,
            title: raw["title"] as? String,
            muted: raw["muted"] as? Bool,
            tabID: raw["tabId"] as? Int,
            participants: raw["participants"] as? [String],
            people: people(from: raw["people"]),
            activeSpeaker: raw["activeSpeaker"] as? String,
            otherAudibleTabs: raw["otherAudibleTabs"] as? Int
        ))
    default:
        return nil
    }
}

/// The roster a page reported. Anything without an identifier is dropped rather
/// than given a made-up one: an identifier is what ties a person to a voice, and
/// a placeholder would tie them to the wrong one.
private func people(from value: Any?) -> [BrowserParticipant]? {
    guard let rows = value as? [[String: Any]] else { return nil }
    let parsed = rows.compactMap { row -> BrowserParticipant? in
        guard let id = row["id"] as? String, !id.isEmpty else { return nil }
        let name = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return BrowserParticipant(
            id: String(id.prefix(200)),
            displayName: name.map { String($0.prefix(80)) },
            isSelf: (row["isSelf"] as? Bool) ?? false,
            isMuted: row["muted"] as? Bool
        )
    }
    return parsed.isEmpty ? nil : Array(parsed.prefix(50))
}

let arguments = CommandLine.arguments
// Browsers pass the manifest path (and on Chrome the extension origin) as
// arguments; the browser is identified from the manifest location.
let browser: BrowserKind = arguments.contains { $0.contains("Chrome") || $0.contains("chromium") }
    ? .chrome
    : .firefox

let socketPath = SensorTransport.socketURL(
    applicationSupport: SensorTransport.defaultApplicationSupport
).path
let connection = AppConnection(socketPath: socketPath)
let reader = BrowserMessageReader()

connection.connect()
replyToBrowser(["type": "ready", "connected": connection.isConnected, "hostVersion": hostVersion])

while let raw = reader.next() {
    guard let message = sensorMessage(from: raw, browser: browser) else { continue }
    var delivered = connection.send(message)
    if !delivered {
        // The app may have restarted since the last message.
        delivered = connection.connect() && connection.send(message)
    }
    if raw["type"] as? String == "hello" || !delivered {
        replyToBrowser(["type": "ack", "connected": delivered])
    }
}

connection.send(.goodbye(browser: browser))
connection.disconnect()
