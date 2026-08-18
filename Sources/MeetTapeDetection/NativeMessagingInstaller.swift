import Foundation
import MeetTapeCore

/// Registers MeetTape's native messaging host with the browsers on this Mac.
///
/// The host binary is copied out of the app bundle into Application Support and
/// the manifest points at that copy. Two measured constraints shape this: a host
/// under a TCC-protected directory such as Documents never launches, and a
/// `#!/usr/bin/env` shebang never resolves because browsers spawn hosts with a
/// minimal PATH. A compiled binary at an absolute path avoids both.
public struct NativeMessagingInstaller: Sendable {
    public struct Status: Sendable, Equatable {
        public var hostInstalled: Bool
        public var firefoxManifestInstalled: Bool
        public var chromeManifestInstalled: Bool
        public var installedHostPath: String?

        public var isReadyForFirefox: Bool { hostInstalled && firefoxManifestInstalled }
    }

    public let applicationSupport: URL
    /// Extension identifiers allowed to talk to the host.
    public let firefoxExtensionIDs: [String]
    public let chromeExtensionIDs: [String]

    public init(
        applicationSupport: URL = SensorTransport.defaultApplicationSupport,
        firefoxExtensionIDs: [String] = ["sensor@meettape.app"],
        chromeExtensionIDs: [String] = []
    ) {
        self.applicationSupport = applicationSupport
        self.firefoxExtensionIDs = firefoxExtensionIDs
        self.chromeExtensionIDs = chromeExtensionIDs
    }

    public var installedHostURL: URL {
        applicationSupport.appendingPathComponent("meettape-nativehost")
    }

    public func status() -> Status {
        let manager = FileManager.default
        return Status(
            hostInstalled: manager.isExecutableFile(atPath: installedHostURL.path),
            firefoxManifestInstalled: manager.fileExists(atPath: firefoxManifestURL.path),
            chromeManifestInstalled: manager.fileExists(atPath: chromeManifestURL.path),
            installedHostPath: manager.fileExists(atPath: installedHostURL.path)
                ? installedHostURL.path : nil
        )
    }

    public var firefoxManifestURL: URL {
        SensorTransport.firefoxHostManifestDirectory
            .appendingPathComponent("\(SensorTransport.nativeMessagingHostName).json")
    }

    public var chromeManifestURL: URL {
        SensorTransport.chromeHostManifestDirectory
            .appendingPathComponent("\(SensorTransport.nativeMessagingHostName).json")
    }

    /// Copies the host binary and writes the manifests. Safe to run on every launch.
    @discardableResult
    public func install(hostBinary: URL) throws -> Status {
        let manager = FileManager.default
        try manager.createDirectory(at: applicationSupport, withIntermediateDirectories: true)

        if manager.fileExists(atPath: installedHostURL.path) {
            let existing = try? Data(contentsOf: installedHostURL)
            let incoming = try? Data(contentsOf: hostBinary)
            if existing != incoming {
                try? manager.removeItem(at: installedHostURL)
                try manager.copyItem(at: hostBinary, to: installedHostURL)
            }
        } else {
            try manager.copyItem(at: hostBinary, to: installedHostURL)
        }
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedHostURL.path)

        try writeManifest(
            to: firefoxManifestURL,
            allowedKey: "allowed_extensions",
            allowed: firefoxExtensionIDs
        )
        if !chromeExtensionIDs.isEmpty {
            try writeManifest(
                to: chromeManifestURL,
                allowedKey: "allowed_origins",
                allowed: chromeExtensionIDs.map { "chrome-extension://\($0)/" }
            )
        }
        return status()
    }

    public func uninstall() {
        try? FileManager.default.removeItem(at: firefoxManifestURL)
        try? FileManager.default.removeItem(at: chromeManifestURL)
        try? FileManager.default.removeItem(at: installedHostURL)
    }

    private func writeManifest(to url: URL, allowedKey: String, allowed: [String]) throws {
        let manifest: [String: Any] = [
            "name": SensorTransport.nativeMessagingHostName,
            "description": "MeetTape browser sensor relay",
            "path": installedHostURL.path,
            "type": "stdio",
            allowedKey: allowed,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try AtomicFile.write(data, to: url)
    }

    /// Where the host binary lives inside a packaged app, falling back to the
    /// build directory during development.
    public static func bundledHostURL(bundle: Bundle = .main) -> URL? {
        if let helpers = bundle.executableURL?.deletingLastPathComponent() {
            let candidate = helpers.appendingPathComponent("meettape-nativehost")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        if let resource = bundle.url(forResource: "meettape-nativehost", withExtension: nil) {
            return resource
        }
        return nil
    }
}
