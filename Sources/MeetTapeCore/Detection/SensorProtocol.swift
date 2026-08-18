import Foundation

/// The wire format between the Firefox native messaging host and MeetTape.
///
/// The host is a thin relay: it speaks Firefox's length-prefixed protocol on one
/// side and newline-delimited JSON over a Unix socket on the other. Keeping the
/// two apart means a browser update that changes the extension side never touches
/// the app side.
public enum SensorMessage: Codable, Sendable, Equatable {
    case hello(Hello)
    case event(BrowserMeetingEvent)
    case tabClosed(tabID: Int)
    case goodbye

    public struct Hello: Codable, Sendable, Equatable {
        public var browser: BrowserKind
        public var extensionVersion: String?
        public var hostVersion: String

        public init(browser: BrowserKind, extensionVersion: String?, hostVersion: String) {
            self.browser = browser
            self.extensionVersion = extensionVersion
            self.hostVersion = hostVersion
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case hello
        case event
        case tabID
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let payload):
            try container.encode("hello", forKey: .type)
            try container.encode(payload, forKey: .hello)
        case .event(let payload):
            try container.encode("event", forKey: .type)
            try container.encode(payload, forKey: .event)
        case .tabClosed(let tabID):
            try container.encode("tab_closed", forKey: .type)
            try container.encode(tabID, forKey: .tabID)
        case .goodbye:
            try container.encode("goodbye", forKey: .type)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "hello":
            self = .hello(try container.decode(Hello.self, forKey: .hello))
        case "event":
            self = .event(try container.decode(BrowserMeetingEvent.self, forKey: .event))
        case "tab_closed":
            self = .tabClosed(tabID: try container.decode(Int.self, forKey: .tabID))
        case "goodbye":
            self = .goodbye
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "unknown sensor message \(other)"
            )
        }
    }
}

public enum SensorTransport {
    /// The socket the app listens on and the host connects to.
    ///
    /// Application Support, not Documents: a native messaging host installed under
    /// a TCC-protected directory never launches at all, silently.
    public static func socketURL(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("sensor.sock")
    }

    public static var defaultApplicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeetTape", isDirectory: true)
    }

    public static let nativeMessagingHostName = "com.meettape.sensor"

    /// Firefox reads per-user host manifests from here.
    public static var firefoxHostManifestDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mozilla/NativeMessagingHosts", isDirectory: true)
    }

    public static var chromeHostManifestDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
    }

    /// Encodes one message as a single line.
    public static func encodeLine(_ message: SensorMessage) throws -> Data {
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        return data
    }

    public static func decodeLine(_ data: Data) throws -> SensorMessage {
        try JSONDecoder().decode(SensorMessage.self, from: data)
    }
}

/// Fills a `sockaddr_un` for a filesystem path.
///
/// Kept in one place because both the listening app and the relay host need it,
/// and because writing into `sun_path` in place trips Swift's exclusivity rules.
public enum UnixSocketAddress {
    public static let maximumPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    public static func make(path: String) -> sockaddr_un? {
        var bytes = Array(path.utf8)
        guard bytes.count <= maximumPathLength else { return nil }
        bytes.append(0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.baseAddress?.copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
        }
        return address
    }

    public static var size: socklen_t { socklen_t(MemoryLayout<sockaddr_un>.size) }
}
